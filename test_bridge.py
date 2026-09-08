from __future__ import annotations

import json
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from bridge_server import BridgeHTTPServer, BridgeState, Command, MacroGoal, Recorder
from prepare_dataset import deduplicate, sample


class BridgeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        state = BridgeState(Recorder(Path(self.temp.name), enabled=True), observe_only=True)
        self.state = state
        self.server = BridgeHTTPServer(("127.0.0.1", 0), state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def request(self, path: str, payload: dict) -> dict:
        request = Request(
            self.base + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request, timeout=2) as response:
            return json.loads(response.read())

    def test_observe_only_records_but_does_not_execute(self) -> None:
        queued = self.request("/v1/control", {
            "action": "PUSH_LANE", "layer": "macro", "params": {"lane": "mid"}, "duration": 8,
        })
        self.assertTrue(queued["ok"])
        tick = self.request("/v1/tick", {
            "protocolVersion": 1,
            "observation": {"hero": {"health": 500}},
            "manualOrder": {"order": 1},
        })
        self.assertTrue(tick["observeOnly"])
        self.assertIsNone(tick["command"])
        self.assertEqual(tick["macroGoal"]["action"], "PUSH_LANE")
        files = list(Path(self.temp.name).glob("*.jsonl"))
        self.assertEqual(len(files), 1)
        record = json.loads(files[0].read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(record["manualOrder"]["order"], 1)

    def test_micro_overrides_macro_in_execute_mode(self) -> None:
        self.request("/v1/mode", {"observeOnly": False})
        self.request("/v1/control", {"action": "FARM_LANE", "layer": "macro", "params": {"lane": "mid"}})
        self.request("/v1/control", {"action": "RETREAT", "layer": "micro", "params": {"position": {"x": 1, "y": 2}}})
        tick = self.request("/v1/tick", {"protocolVersion": 1, "observation": {}})
        self.assertEqual(tick["command"]["action"], "RETREAT")
        self.assertEqual(tick["command"]["layer"], "micro")
        self.assertEqual(tick["macroGoal"]["status"], "micro_override")

    def test_macro_goal_resumes_with_new_dispatch_after_micro(self) -> None:
        goal = self.state.queue(Command(
            action="FARM_LANE", params={"lane": "mid"}, duration=5, layer="macro", ttl=20,
        ))
        self.assertIsInstance(goal, MacroGoal)
        first = self.state.selected_command()
        micro = Command(action="RETREAT", duration=0.5, layer="micro", ttl=0.1)
        self.state.queue(micro)
        self.assertEqual(self.state.selected_command().id, micro.id)
        micro.created_monotonic -= 1
        resumed = self.state.selected_command()
        self.assertEqual(resumed.layer, "macro")
        self.assertEqual(resumed.goal_id, goal.id)
        self.assertNotEqual(resumed.id, first.id)

    def test_macro_goal_has_minimum_hold_before_replacement(self) -> None:
        first = self.state.queue(Command(action="FARM_LANE", layer="macro", duration=5, ttl=20))
        second = self.state.queue(Command(action="PUSH_LANE", layer="macro", duration=5, ttl=20))
        self.assertEqual(second.status, "queued")
        self.assertEqual(self.state.selected_command().goal_id, first.id)

    def test_dataset_prefers_pre_order_state(self) -> None:
        value = sample({
            "recordedAt": "2026-01-01T00:00:00+00:00",
            "observation": {"frame": "after"},
            "manualOrder": {"sequence": 2, "order": 1, "stateBefore": {"frame": "before"}},
        })
        self.assertEqual(value["observation"]["frame"], "before")
        self.assertEqual(value["label"]["orderName"], "MOVE_TO_POSITION")

    def test_recorder_thins_unlabeled_ticks_but_keeps_orders(self) -> None:
        data_dir = Path(self.temp.name) / "thin"
        recorder = Recorder(data_dir, enabled=True, snapshot_interval=60)
        recorder.append({"observation": {"frame": 1}, "manualOrder": None})
        recorder.append({"observation": {"frame": 2}, "manualOrder": None})
        recorder.append({"observation": {"frame": 3}, "manualOrder": {"order": 1}})
        lines = next(data_dir.glob("*.jsonl")).read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)

    def test_recorder_respects_client_recording_toggle(self) -> None:
        data_dir = Path(self.temp.name) / "paused"
        recorder = Recorder(data_dir, enabled=True, snapshot_interval=0)
        recorder.append({"recordingEnabled": False, "manualOrder": {"order": 1}})
        self.assertEqual(list(data_dir.glob("*.jsonl")), [])

    def test_dataset_deduplicates_keyboard_and_callback_cast(self) -> None:
        keyboard = sample({
            "manualOrder": {
                "order": 5, "gameTime": 10.0, "abilityName": "sniper_shrapnel",
                "source": "keyboard_then_left_click",
            }
        })
        callback = sample({
            "manualOrder": {
                "order": 5, "gameTime": 10.1, "abilityName": "sniper_shrapnel",
                "source": "prepare_unit_orders",
            }
        })
        values = deduplicate([keyboard, callback])
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0]["label"]["source"], "prepare_unit_orders")

    def test_dataset_coalesces_held_right_click_target(self) -> None:
        values = deduplicate([
            sample({"manualOrder": {"order": 4, "gameTime": 20.0, "targetIndex": 7,
                                     "source": "inferred_right_click"}}),
            sample({"manualOrder": {"order": 4, "gameTime": 20.2, "targetIndex": 7,
                                     "source": "inferred_right_click"}}),
            sample({"manualOrder": {"order": 4, "gameTime": 20.4, "targetIndex": 7,
                                     "source": "sampled_held_right_click"}}),
        ])
        self.assertEqual(len(values), 1)

    def test_dataset_keeps_changed_held_right_click_destination(self) -> None:
        values = deduplicate([
            sample({"manualOrder": {"order": 1, "gameTime": 20.0,
                                     "position": {"x": 10, "y": 10},
                                     "source": "inferred_right_click"}}),
            sample({"manualOrder": {"order": 1, "gameTime": 20.2,
                                     "position": {"x": 100, "y": 100},
                                     "source": "sampled_held_right_click"}}),
        ])
        self.assertEqual(len(values), 2)

    def test_disabled_chat_responder_returns_service_unavailable(self) -> None:
        request = Request(
            self.base + "/v1/chat",
            data=json.dumps({"messageText": "hello"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with self.assertRaises(HTTPError) as raised:
            urlopen(request, timeout=2)
        try:
            self.assertEqual(raised.exception.code, 503)
        finally:
            raised.exception.close()

    def test_empty_lua_array_body_is_accepted_for_voice_poll(self) -> None:
        request = Request(
            self.base + "/v1/voice/poll",
            data=b"[]",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request, timeout=2) as response:
            payload = json.loads(response.read())
        self.assertTrue(payload["ok"])
        self.assertFalse(payload["ready"])


if __name__ == "__main__":
    unittest.main()
