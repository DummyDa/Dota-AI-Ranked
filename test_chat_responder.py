from __future__ import annotations

import json
import unittest
from collections import deque
from unittest.mock import patch

from chat_responder import ChatResponder, VoiceOutput


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self) -> bytes:
        return json.dumps(self.payload).encode()


class ChatResponderTest(unittest.TestCase):
    def responder(self) -> ChatResponder:
        value = ChatResponder.__new__(ChatResponder)
        value.api_key = "test-key"
        value.model = "qwen/qwen3.7-flash"
        value.history = deque(maxlen=12)
        return value

    @patch("chat_responder.urlopen")
    def test_enemy_can_never_trigger_voice_reply(self, mocked) -> None:
        mocked.return_value = FakeResponse({
            "model": "free/test",
            "choices": [{"message": {"content": '{"addressed":true,"reply":"hello"}'}}],
        })
        result = self.responder()._openrouter({
            "sourcePlayerId": 4, "sourceName": "Enemy", "sourceHero": "Lina",
            "isAlly": False, "channelType": 11, "messageText": "bara hello",
        })
        self.assertFalse(result["addressed"])
        self.assertEqual(result["reply"], "")

    @patch("chat_responder.urlopen")
    def test_allied_direct_message_gets_short_reply(self, mocked) -> None:
        mocked.return_value = FakeResponse({
            "model": "free/test",
            "choices": [{"message": {"content": '{"addressed":true,"reply":"Да, уже иду на верх."}'}}],
        })
        result = self.responder()._openrouter({
            "sourcePlayerId": 1, "sourceName": "Carry", "sourceHero": "Juggernaut",
            "isAlly": True, "channelType": 12, "messageText": "бара иди топ",
        })
        self.assertTrue(result["addressed"])
        self.assertEqual(result["reply"], "Да, уже иду на верх.")

    def test_explicit_self_test_is_accepted(self) -> None:
        value = ChatResponder.__new__(ChatResponder)
        value.input_queue = __import__("queue").Queue(maxsize=1)
        value.last_error = ""
        self.assertTrue(value.submit({"isSelf": True, "selfTest": True, "messageText": "бара привет"}))

    def test_normal_self_message_is_ignored(self) -> None:
        value = ChatResponder.__new__(ChatResponder)
        value.input_queue = __import__("queue").Queue(maxsize=1)
        value.last_error = ""
        self.assertFalse(value.submit({"isSelf": True, "messageText": "иду топ"}))

    def test_voice_output_resamples_for_virtual_cable(self) -> None:
        import numpy as np

        calls = []
        fake_sd = type("FakeSD", (), {
            "play": staticmethod(lambda audio, **kwargs: calls.append((audio, kwargs)))
        })()
        output = VoiceOutput.__new__(VoiceOutput)
        output._sd = fake_sd
        output.device_index = 22
        output.output_sample_rate = 48000
        output.play(np.ones(22050, dtype="float32"), 22050)
        self.assertEqual(len(calls[0][0]), 48000)
        self.assertEqual(calls[0][1]["samplerate"], 48000)


if __name__ == "__main__":
    unittest.main()
