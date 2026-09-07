from __future__ import annotations

import argparse
import json
import logging
import os
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from macro_openai import OpenAIMacroPolicy


PROTOCOL_VERSION = 1
ALLOWED_ACTIONS = {
    "AUTO", "STOP", "HOLD_SAFE", "MOVE_TO", "ATTACK_MOVE", "RETREAT",
    "GO_FOUNTAIN", "GO_TO_LANE", "FARM_LANE", "PUSH_LANE", "DEFEND_LANE",
    "FARM_NEAREST_CAMP", "FARM_CAMP", "PICKUP_RUNE", "ATTACK_UNIT",
    "ATTACK_HERO", "HARASS_HERO", "ATTACK_TOWER", "CAST_ABILITY_TARGET",
    "CAST_ABILITY_POSITION", "CAST_ABILITY_NO_TARGET", "USE_ITEM_TARGET",
    "USE_ITEM_POSITION", "USE_ITEM_NO_TARGET", "LEVEL_ABILITY", "SET_QUICKBUY",
    "SECURE_RUNE", "FOLLOW_CORE", "GROUP_WITH_TEAM", "PLACE_WARD", "DEWARD",
    "CONTEST_OBJECTIVE", "CHARGE_HERO", "BULLDOZE", "NETHER_STRIKE",
}
EMERGENCY_MACRO_ACTIONS = {"RETREAT", "GO_FOUNTAIN", "HOLD_SAFE"}
ONE_SHOT_MACRO_ACTIONS = {"PICKUP_RUNE", "PLACE_WARD", "LEVEL_ABILITY", "SET_QUICKBUY"}
MACRO_MIN_HOLD_SECONDS = 3.0


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class Command:
    action: str
    params: dict[str, Any] = field(default_factory=dict)
    duration: float = 1.0
    layer: str = "micro"
    ttl: float = 2.0
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    goal_id: str | None = None
    reason: str = ""
    created_monotonic: float = field(default_factory=time.monotonic)

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> "Command":
        action = str(payload.get("action", "")).upper()
        if action not in ALLOWED_ACTIONS:
            raise ValueError(f"unsupported action: {action}")
        layer = str(payload.get("layer", "micro")).lower()
        if layer not in {"micro", "macro"}:
            raise ValueError("layer must be 'micro' or 'macro'")
        params = payload.get("params") or {}
        if not isinstance(params, dict):
            raise ValueError("params must be an object")
        duration = max(0.0, min(float(payload.get("duration", 1.0)), 60.0))
        ttl_default = 1.0 if layer == "micro" else 30.0
        ttl = max(0.1, min(float(payload.get("ttl", ttl_default)), 120.0))
        return cls(
            action=action,
            params=params,
            duration=duration,
            layer=layer,
            ttl=ttl,
            reason=str(payload.get("reason", "")),
        )

    def expired(self, now: float) -> bool:
        return now - self.created_monotonic > self.ttl

    def wire(self) -> dict[str, Any]:
        value = {
            "id": self.id,
            "layer": self.layer,
            "action": self.action,
            "params": self.params,
            "duration": self.duration,
        }
        if self.goal_id:
            value["goalId"] = self.goal_id
        return value


@dataclass
class MacroGoal:
    action: str
    params: dict[str, Any]
    duration: float
    ttl: float
    reason: str = ""
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    created_monotonic: float = field(default_factory=time.monotonic)
    status: str = "active"
    revision: int = 1
    dispatch: Command | None = None
    next_dispatch_monotonic: float = 0.0

    @classmethod
    def from_command(cls, command: Command) -> "MacroGoal":
        return cls(
            action=command.action,
            params=command.params,
            duration=max(0.5, command.duration),
            ttl=max(3.0, command.ttl),
            reason=command.reason,
        )

    def expired(self, now: float) -> bool:
        return now - self.created_monotonic > self.ttl

    def force_redispatch(self) -> None:
        self.next_dispatch_monotonic = 0.0

    def selected_command(self, now: float) -> Command:
        if self.dispatch is None or now >= self.next_dispatch_monotonic:
            self.dispatch = Command(
                action=self.action,
                params=dict(self.params),
                duration=self.duration,
                layer="macro",
                ttl=max(2.0, self.duration + 1.0),
                goal_id=self.id,
                reason=self.reason,
            )
            # Refresh long-running Lua actions before their duration expires.
            self.next_dispatch_monotonic = now + max(0.5, self.duration * 0.8)
        return self.dispatch

    def wire(self, now: float, blocked_by_micro: bool = False) -> dict[str, Any]:
        remaining = max(0.0, self.ttl - (now - self.created_monotonic))
        return {
            "id": self.id,
            "revision": self.revision,
            "status": "micro_override" if blocked_by_micro else self.status,
            "action": self.action,
            "params": self.params,
            "duration": self.duration,
            "remainingSeconds": round(remaining, 3),
            "reason": self.reason,
            "currentCommandId": self.dispatch.id if self.dispatch else None,
        }


class Recorder:
    def __init__(self, data_dir: Path, enabled: bool, snapshot_interval: float = 1.0) -> None:
        self.enabled = enabled
        self.data_dir = data_dir
        self.snapshot_interval = max(0.0, snapshot_interval)
        self._lock = threading.Lock()
        self._day = ""
        self._path: Path | None = None
        self._last_snapshot = 0.0

    def append(self, record: dict[str, Any]) -> None:
        if not self.enabled or record.get("recordingEnabled") is False:
            return
        now = time.monotonic()
        # Goals are attached to periodic snapshots; only human orders require
        # lossless per-event recording.
        important = bool(record.get("manualOrder"))
        if not important and now - self._last_snapshot < self.snapshot_interval:
            return
        day = datetime.now().strftime("%Y-%m-%d")
        with self._lock:
            if not important and now - self._last_snapshot < self.snapshot_interval:
                return
            if day != self._day:
                self.data_dir.mkdir(parents=True, exist_ok=True)
                self._day = day
                self._path = self.data_dir / f"dota-observations-{day}.jsonl"
            assert self._path is not None
            with self._path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
                stream.write("\n")
            if not important:
                self._last_snapshot = now


class BridgeState:
    def __init__(self, recorder: Recorder, observe_only: bool) -> None:
        self.recorder = recorder
        self.observe_only = observe_only
        self.lock = threading.RLock()
        self.started = time.monotonic()
        self.tick_count = 0
        self.last_tick_wall = 0.0
        self.last_observation: dict[str, Any] | None = None
        self.last_client: dict[str, Any] = {}
        self.micro_action: Command | None = None
        self.macro_goal: MacroGoal | None = None
        self.pending_macro_goal: MacroGoal | None = None
        self.goal_history: list[dict[str, Any]] = []
        self.last_sent_command_id: str | None = None

    def queue(self, command: Command) -> Command | MacroGoal:
        with self.lock:
            if command.layer == "micro":
                self.micro_action = command
                return command
            now = time.monotonic()
            current = self.macro_goal
            if current and not current.expired(now) and current.action == command.action and current.params == command.params:
                current.created_monotonic = now
                current.duration = max(0.5, command.duration)
                current.ttl = max(3.0, command.ttl)
                current.reason = command.reason or current.reason
                current.revision += 1
                current.status = "active"
                current.force_redispatch()
                return current
            candidate = MacroGoal.from_command(command)
            if (
                current
                and not current.expired(now)
                and now - current.created_monotonic < MACRO_MIN_HOLD_SECONDS
                and command.action not in EMERGENCY_MACRO_ACTIONS
            ):
                candidate.status = "queued"
                self.pending_macro_goal = candidate
                return candidate
            if current:
                current.status = "replaced"
                self.goal_history.append(current.wire(now))
                self.goal_history = self.goal_history[-20:]
            self.macro_goal = candidate
            self.pending_macro_goal = None
            return self.macro_goal

    def _promote_pending_goal(self, now: float) -> None:
        pending = self.pending_macro_goal
        current = self.macro_goal
        if not pending:
            return
        if current and not current.expired(now) and now - current.created_monotonic < MACRO_MIN_HOLD_SECONDS:
            return
        if current:
            current.status = "replaced"
            self.goal_history.append(current.wire(now))
        pending.status = "active"
        pending.created_monotonic = now
        self.macro_goal = pending
        self.pending_macro_goal = None
        self.goal_history = self.goal_history[-20:]

    def _reconcile_observation(self, observation: dict[str, Any]) -> None:
        command_id = observation.get("bridgeCommandId")
        goal_id = observation.get("bridgeGoalId")
        sequence = int(observation.get("bridgeCommandSequence") or 0)
        completed = int(observation.get("completedSequence") or 0)
        result = str(observation.get("lastResult") or "")
        failed = bool(observation.get("lastError")) or result == "failed"

        if self.micro_action and command_id == self.micro_action.id and sequence > 0 and completed >= sequence:
            self.micro_action = None
            if self.macro_goal:
                self.macro_goal.force_redispatch()

        goal = self.macro_goal
        if not goal or goal_id != goal.id:
            return
        goal.status = "executing"
        if sequence <= 0 or completed < sequence:
            return
        if failed:
            goal.status = "failed"
            self.goal_history.append(goal.wire(time.monotonic()))
            self.macro_goal = None
        elif goal.action in ONE_SHOT_MACRO_ACTIONS:
            goal.status = "completed"
            self.goal_history.append(goal.wire(time.monotonic()))
            self.macro_goal = None
        else:
            goal.status = "active"
            goal.force_redispatch()

    def macro_wire(self, now: float | None = None) -> dict[str, Any] | None:
        now = now or time.monotonic()
        goal = self.macro_goal
        if not goal:
            return None
        return goal.wire(now, blocked_by_micro=self.micro_action is not None)

    def selected_command(self) -> Command | None:
        now = time.monotonic()
        with self.lock:
            self._promote_pending_goal(now)
            if self.micro_action and self.micro_action.expired(now):
                self.micro_action = None
                if self.macro_goal:
                    self.macro_goal.force_redispatch()
            if self.macro_goal and self.macro_goal.expired(now):
                self.macro_goal.status = "expired"
                self.goal_history.append(self.macro_goal.wire(now))
                self.goal_history = self.goal_history[-20:]
                self.macro_goal = None
            if self.micro_action:
                return self.micro_action
            if self.macro_goal:
                return self.macro_goal.selected_command(now)
            return None

    def accept_tick(self, payload: dict[str, Any], remote: str) -> dict[str, Any]:
        now = time.time()
        observation = payload.get("observation") or {}
        with self.lock:
            self.tick_count += 1
            self.last_tick_wall = now
            self.last_observation = observation
            self.last_client = {
                "remote": remote,
                "clientTime": payload.get("clientTime"),
                "luaLatencyMs": payload.get("lastLatencyMs"),
                "aiEnabled": payload.get("aiEnabled"),
                "recordingEnabled": payload.get("recordingEnabled"),
            }
            self._reconcile_observation(observation)
        command = self.selected_command()
        macro_goal = self.macro_wire()
        micro_action = self.micro_action.wire() if self.micro_action else None
        self.recorder.append({
            "recordedAt": utc_now(),
            "protocolVersion": payload.get("protocolVersion"),
            "recordingEnabled": payload.get("recordingEnabled", True),
            "observation": observation,
            "manualOrder": payload.get("manualOrder"),
            "activeMacro": macro_goal,
            "activeMicro": micro_action,
        })
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "serverTimeMs": int(now * 1000),
            "observeOnly": self.observe_only,
            "command": None if self.observe_only or command is None else command.wire(),
            "macroGoal": macro_goal,
            "microAction": micro_action,
            "controlState": {
                "activeLayer": command.layer if command else None,
                "luaSafetyPriority": True,
            },
        }

    def status(self) -> dict[str, Any]:
        command = self.selected_command()
        with self.lock:
            macro_goal = self.macro_wire()
            return {
                "ok": True,
                "protocolVersion": PROTOCOL_VERSION,
                "observeOnly": self.observe_only,
                "recorderEnabled": self.recorder.enabled,
                "dataDirectory": str(self.recorder.data_dir),
                "uptimeSeconds": round(time.monotonic() - self.started, 1),
                "tickCount": self.tick_count,
                "lastTickAgeSeconds": None if not self.last_tick_wall else round(time.time() - self.last_tick_wall, 3),
                "selectedCommand": command.wire() if command else None,
                "macroGoal": macro_goal,
                "microAction": self.micro_action.wire() if self.micro_action else None,
                "goalHistory": self.goal_history[-5:],
                "pendingMacroGoal": self.pending_macro_goal.wire(time.monotonic()) if self.pending_macro_goal else None,
                "lastClient": self.last_client,
            }


class MacroWorker:
    def __init__(self, bridge: BridgeState, policy: OpenAIMacroPolicy, interval: float) -> None:
        self.bridge = bridge
        self.policy = policy
        self.interval = interval
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.run, name="openai-macro", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=2)

    def run(self) -> None:
        while not self.stop_event.wait(self.interval):
            with self.bridge.lock:
                observation = self.bridge.last_observation
                current_goal = self.bridge.macro_wire()
            if not observation or not observation.get("ready"):
                continue
            try:
                policy_observation = dict(observation)
                policy_observation["currentMacroGoal"] = current_goal
                decision = self.policy.decide(policy_observation)
                decision["layer"] = "macro"
                command = Command.from_json(decision)
                goal = self.bridge.queue(command)
                logging.info(
                    "OpenAI macro goal: %s goal=%s (%s)",
                    command.action,
                    goal.id,
                    decision.get("reason", ""),
                )
            except Exception:
                logging.exception("OpenAI macro decision failed")


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "DotaAIBridge/1"

    @property
    def bridge(self) -> BridgeState:
        return self.server.bridge  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("%s - %s", self.client_address[0], fmt % args)

    def _json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 2_000_000:
            raise ValueError("invalid body length")
        payload = json.loads(self.rfile.read(length).decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload

    def _send(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path in {"/health", "/v1/status"}:
            self._send(HTTPStatus.OK, self.bridge.status())
            return
        self._send(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        try:
            payload = self._json_body()
            if self.path == "/v1/tick":
                if payload.get("protocolVersion") != PROTOCOL_VERSION:
                    raise ValueError("protocolVersion mismatch")
                response = self.bridge.accept_tick(payload, self.client_address[0])
                self._send(HTTPStatus.OK, response)
                return
            if self.path == "/v1/control":
                command = Command.from_json(payload)
                queued = self.bridge.queue(command)
                result_key = "goal" if command.layer == "macro" else "command"
                result = queued.wire(time.monotonic()) if isinstance(queued, MacroGoal) else queued.wire()
                self._send(HTTPStatus.ACCEPTED, {"ok": True, result_key: result})
                return
            if self.path == "/v1/mode":
                with self.bridge.lock:
                    self.bridge.observe_only = bool(payload.get("observeOnly", True))
                self._send(HTTPStatus.OK, self.bridge.status())
                return
            self._send(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self._send(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
        except Exception as exc:  # keep the bridge alive while iterating on adapters
            logging.exception("request failed")
            self._send(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": str(exc)})


class BridgeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], bridge: BridgeState) -> None:
        super().__init__(address, BridgeHandler)
        self.bridge = bridge


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local bridge between UCZone Lua and Dota AI controllers")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--no-record", action="store_true")
    parser.add_argument("--snapshot-interval", type=float, default=1.0,
                        help="seconds between unlabeled observation snapshots")
    parser.add_argument("--execute", action="store_true", help="allow queued commands to reach Lua")
    parser.add_argument("--openai-macro", action="store_true", help="enable periodic OpenAI macro decisions")
    parser.add_argument("--openai-model", default=os.environ.get("OPENAI_MODEL"))
    parser.add_argument("--macro-interval", type=float, default=10.0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    recorder = Recorder(
        args.data_dir.resolve(),
        enabled=not args.no_record,
        snapshot_interval=args.snapshot_interval,
    )
    bridge = BridgeState(recorder, observe_only=not args.execute)
    server = BridgeHTTPServer((args.host, args.port), bridge)
    macro_worker = None
    if args.openai_macro:
        macro_worker = MacroWorker(
            bridge,
            OpenAIMacroPolicy(model=args.openai_model),
            interval=max(3.0, args.macro_interval),
        )
        macro_worker.start()
    mode = "EXECUTE" if args.execute else "OBSERVE-ONLY"
    logging.info("Dota AI bridge listening on http://%s:%d (%s)", args.host, args.port, mode)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        logging.info("stopping")
    finally:
        if macro_worker:
            macro_worker.stop()
        server.server_close()


if __name__ == "__main__":
    main()
