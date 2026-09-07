from __future__ import annotations

import json
import os
from typing import Any
from urllib.request import Request, urlopen


MACRO_ACTIONS = [
    "HOLD_SAFE",
    "RETREAT",
    "GO_FOUNTAIN",
    "GO_TO_LANE",
    "FOLLOW_CORE",
    "GROUP_WITH_TEAM",
    "FARM_LANE",
    "PUSH_LANE",
    "DEFEND_LANE",
    "FARM_NEAREST_CAMP",
    "PICKUP_RUNE",
    "SECURE_RUNE",
    "PLACE_WARD",
    "DEWARD",
    "CONTEST_OBJECTIVE",
    "ATTACK_TOWER",
    "LEVEL_ABILITY",
    "SET_QUICKBUY",
]

DECISION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "action": {"type": "string", "enum": MACRO_ACTIONS},
        "params": {"type": "object", "additionalProperties": True},
        "duration": {"type": "number", "minimum": 0.2, "maximum": 30},
        "ttl": {"type": "number", "minimum": 1, "maximum": 60},
        "reason": {"type": "string"},
    },
    "required": ["action", "params", "duration", "ttl", "reason"],
}


def compact_observation(observation: dict[str, Any]) -> dict[str, Any]:
    hero = observation.get("hero") or {}
    return {
        "gameTime": observation.get("gameTime"),
        "lane": observation.get("lane"),
        "hero": hero,
        "visibleEnemyHeroes": observation.get("visibleEnemyHeroes", []),
        "nearbyAlliedHeroes": observation.get("nearbyAlliedHeroes", []),
        "nearbyLaneCreeps": observation.get("nearbyLaneCreeps", []),
        "nearbyTowers": observation.get("nearbyTowers", []),
        "runes": observation.get("runes", []),
        "camps": observation.get("camps", []),
        "abilities": observation.get("abilities", []),
        "items": observation.get("items", []),
        "lastResult": observation.get("lastResult"),
        "lastError": observation.get("lastError"),
        "currentMacroGoal": observation.get("currentMacroGoal"),
    }


class OpenAIMacroPolicy:
    def __init__(self, model: str | None = None, timeout: float = 15.0) -> None:
        self.api_key = os.environ.get("OPENAI_API_KEY", "")
        self.model = model or os.environ.get("OPENAI_MODEL", "")
        self.timeout = timeout
        if not self.api_key:
            raise RuntimeError("OPENAI_API_KEY is required when --openai-macro is enabled")
        if not self.model:
            raise RuntimeError("OPENAI_MODEL is required when --openai-macro is enabled")

    def decide(self, observation: dict[str, Any]) -> dict[str, Any]:
        body = {
            "model": self.model,
            "store": False,
            "max_output_tokens": 300,
            "instructions": (
                "You are the macro controller for a Spirit Breaker position 5/4 support in a "
                "private Dota 2 lobby. Choose exactly one safe macro action for the next few "
                "seconds. During the laning phase (before 10:00), never farm or push lane creeps: "
                "stay with the lane core, secure runes, ward/deward, protect allies and react to "
                "objectives. After 10:00, farm a lane or neutral camp only when no support duty, "
                "team move, rune, ward task or objective needs attention. Lua handles tower escape, "
                "creep-aggro safety and immediate micro. Do not choose spell targets or make "
                "frame-level decisions; the local micro policy handles Charge, Bulldoze, Nether "
                "Strike, attacks and items. Prefer continuing currentMacroGoal when it remains "
                "sensible. Use only entities, indexes and positions present in the observation."
            ),
            "input": json.dumps(compact_observation(observation), ensure_ascii=False),
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "dota_macro_decision",
                    "strict": True,
                    "schema": DECISION_SCHEMA,
                }
            },
        }
        request = Request(
            "https://api.openai.com/v1/responses",
            data=json.dumps(body).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urlopen(request, timeout=self.timeout) as response:
            payload = json.loads(response.read())
        text = payload.get("output_text")
        if not text:
            for item in payload.get("output", []):
                if item.get("type") != "message":
                    continue
                for content in item.get("content", []):
                    if content.get("type") == "output_text":
                        text = content.get("text")
                        break
        if not text:
            raise RuntimeError("OpenAI response did not contain output text")
        decision = json.loads(text)
        if decision.get("action") not in MACRO_ACTIONS:
            raise RuntimeError("OpenAI returned an action outside the macro allowlist")
        return decision
