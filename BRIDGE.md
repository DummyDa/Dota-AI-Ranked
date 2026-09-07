# Dota AI bridge

The bridge connects the UCZone Lua controller to local Python over
`http://127.0.0.1:8765`. It has three layers:

1. Lua safety and precise mechanics.
2. A future local micro policy, represented by the `micro` command slot.
3. A slower macro policy, represented by the `macro` command slot and optional
   OpenAI Responses API worker.

The goal dispatcher keeps one stable macro goal and one short-lived micro
override. Micro temporarily overrides macro; when it finishes or its TTL
expires, the same macro goal is redispatched automatically. Lua safety
overrides both.

Macro goals have a stable `goalId`, `revision`, lifecycle `status`, remaining
TTL, and a replaceable `currentCommandId`. A different non-emergency macro goal
waits until the current goal has been held for at least three seconds.
`RETREAT`, `GO_FOUNTAIN`, and `HOLD_SAFE` can replace it immediately. Repeating
the same action and parameters refreshes the existing goal instead of creating
a competing one.

## Record manual games safely

Start the service in its default observe-only mode:

```powershell
cd '<path-to-Dota-AI-Ranked>'
.\start_bridge.ps1
```

Reload Umbrella scripts with `C`. The overlay should change from
`bridge: offline` to `bridge: REC`. Use the draggable `Recording` button to
start or pause collection. AI execution is currently hidden and forced off.
Observations and your orders will be appended to `data/*.jsonl`. The state
captured in `manualOrder.stateBefore` is taken immediately before the order.
The recorder currently understands the default Dota hotkeys: right click,
`A/S/H`, hero abilities on `Q/W/E/D/F/R`, inventory on `Z/X/C/V/B/N`, and the
TP slot on `T`. Ability upgrades and purchases are also inferred from state
changes. The overlay shows the total captured `orders` and the unsent queue
size `q`; custom hotkey layouts need a matching Lua key map.
Held right-click movement is sampled at up to 5 Hz and only after meaningful
cursor movement, preventing the auto-repeat setting from flooding the dataset.

Stop the service with `Ctrl+C`.

Build an imitation-learning dataset:

```powershell
$inputs = Get-ChildItem .\data\*.jsonl | ForEach-Object FullName
python .\prepare_dataset.py @inputs
```

This writes `dataset/train.jsonl` and `dataset/validation.jsonl`.

## Test command execution

Execution must be enabled explicitly:

```powershell
.\start_bridge.ps1 -Execute
```

Queue a macro action from another terminal:

```powershell
python .\send_command.py PUSH_LANE --layer macro --params '{"lane":"mid"}' --duration 8
```

Queue a short micro override:

```powershell
python .\send_command.py RETREAT --layer micro --params '{"position":{"x":-1000,"y":-1200,"z":0}}' --duration 1 --ttl 1
```

Inspect status at `http://127.0.0.1:8765/v1/status`.
The response includes `macroGoal`, `pendingMacroGoal`, `microAction`, recent
`goalHistory`, and the currently selected executable command.

## Optional OpenAI macro worker

This is disabled by default. Set credentials in the environment and explicitly
select a model available to your API project:

```powershell
$env:OPENAI_API_KEY = '...'
$env:OPENAI_MODEL = '...'
python .\bridge_server.py --execute --openai-macro --macro-interval 10 --data-dir .\data
```

The worker uses the Responses API with a strict JSON schema and sends only a
compact structured observation. It never receives screenshots and does not make
micro decisions. Do not store the API key in this repository.

## HTTP protocol

- `POST /v1/tick`: Lua observation in, selected command out.
- `POST /v1/control`: queue a `macro` or `micro` command.
- `POST /v1/mode`: switch `observeOnly` at runtime.
- `GET /health` and `GET /v1/status`: service health and arbitration state.

The default mode returns no executable command even when commands are queued.
Each command has a unique ID; Lua ignores replayed IDs. Unsupported command
errors are isolated from the main farming controller.
