# Dota AI Ranked

## Optional voice chat responder

The autonomous Lua bot does not require a server. To let it analyze match chat
with the low-cost `qwen/qwen3.7-flash` OpenRouter model and answer allied
messages through local Piper TTS:

1. Run `setup_voice.ps1` once.
2. Install VB-CABLE, reboot Windows, then select `CABLE Output (VB-Audio
   Virtual Cable)` as Dota's voice input. Piper writes to `CABLE Input`.
3. Run `configure_openrouter.bat` and paste a newly-created OpenRouter key.
4. Keep `start_voice_bridge.bat` open while playing.

The API key is read from `OPENROUTER_API_KEY`; it is never stored in this
repository. Incoming player chat is sent to OpenRouter for classification.

Experimental autonomous Spirit Breaker support/hard-support controller for the
Umbrella Lua API. The controller is rule-based and runs without Python, an LLM,
or a local neural network. A separate optional bridge and human-play recorder
are included for future imitation-learning experiments.

> Development scope: Spirit Breaker in local/private Dota 2 lobbies. This is an
> experimental prototype, not a verified ranked-match bot.

## Current behavior

- Pos 4/5 lane selection and support positioning.
- Short lane trades, core protection, retreat and tower safety.
- Global low-HP Charge, supported rotations from level 2, base exit through
  Charge while TP is on cooldown, and safe creep Charge for spare farm.
- Charge, Bulldoze during Charge, Nether Strike and optional Planar Pocket.
- Wards, runes, pull/stack attempts, role-aware grouping, towers and observed objectives.
- Spirit Breaker quick-buy core: Wind Lace/two Branches/Tango/Faerie Fire,
  Phase Boots, Shadow Blade, Yasha & Kaya or Eul, then Silver Edge. Dota
  autobuy/autocourier perform
  the actual purchase and delivery.
- One draggable `Bot: ON/OFF` button. The bot starts enabled.

The bot never intentionally reads hidden enemy state. Unknown or undocumented
Umbrella interactions are disabled and logged instead of simulated with clicks.

## Build and install

Requirements for development: Python 3, Node.js and `luaparse`. Runtime needs
only Umbrella.

```powershell
python -m unittest test_bot test_bridge test_recorder test_chat_responder
python build_bot.py
```

The generated file is `dist/spirit_breaker_bot.lua`. Copy it to
`C:\Umbrella\scripts\spirit_breaker_bot.lua`, reload Umbrella scripts, select
Spirit Breaker in a private lobby, and enable Dota's autobuy/autocourier options.

`python build_bot.py --deploy` performs the same installation on Windows and
backs up an existing controller first.

## Project layout

- `src/` — state adapter, navigation, threat model, arbiter, hero logic, items,
  support modes, UI and executor.
- `dist/` — generated single-file Lua controller.
- `test_bot.py` — Lua contract and scenario tests using a mocked Umbrella API.
- `bridge_server.py` — optional observe-only recorder/external-control bridge.
- `spirit_breaker_recorder.lua` — human input and state recorder.
- `prepare_dataset.py` — event extraction and duplicate cleanup.
- `BOT_README.md`, `RULEBOT_API.md`, `NEURAL_API.md`, `BRIDGE.md` — detailed docs.

Recordings, datasets, logs, caches and local backups are excluded by
`.gitignore` and must not be committed.

## Third-party notice

Some decision rules were adapted from OpenHyperAI at commit
`cb814c6c8dc51ed08045d6efd9f4a48147992711`. Its MIT license is preserved in
`OPENHYPERAI_LICENSE` and in the generated Lua bundle.
