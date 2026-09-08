from __future__ import annotations

import json
import unittest
from collections import deque
from unittest.mock import patch

from chat_responder import ChatResponder


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


if __name__ == "__main__":
    unittest.main()
