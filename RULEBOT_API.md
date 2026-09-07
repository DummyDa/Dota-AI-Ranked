# DotaAI: rule-based controller interface

The global DotaAI table and all legacy action names/convenience functions are
retained. Runtime no longer records datasets. Read-only methods work immediately;
external commands are intentionally rejected until explicitly enabled.

```lua
local observation = DotaAI.GetObservation()
DotaAI.SetExternalEnabled(true) -- false by default
local ok, sequence = DotaAI.Command('FOLLOW_CORE', {targetIndex=123}, 10)
DotaAI.Cancel()                -- cancel external goal, resume autonomous rules
DotaAI.SetEnabled(false)       -- stop controller for manual play
```

Command returns `(true, sequence)` or `(false, error)`. GetObservation retains
actionSequence/completedSequence/lastResult/lastError. Accepted one-shot casts
are only reported successful after observed cooldown/charges/level change;
issuing an order is not cast completion. Travel goals can expire rather than
falsely reporting arrival. Cancel does not interrupt a local Charge mid-flight.

New fields: botEnabled, role, roleSource, laneSelectionFlags, activeMode,
modeDesires, decisionReason, targetIndex, route, capabilities, orders, version.
The observation contains no engine handles. Units expose pos/hp/hpPct, and the
hero additionally retains position/health/healthPercent/attackRange aliases.
Unknown data is omitted. Enemies are visible-only snapshots.

Safety and local hero/item micro retain priority over external macro goals.
FOLLOW_CORE is a support goal, not a persistent engine follow order; protection,
combat and retreat interrupt it. ATTACK_TOWER may allow tower entry, but does
not disable tower-aggro escape. Macro cannot bypass early core farm protection.

Legacy names preserved: AUTO, STOP, HOLD_SAFE, MOVE_TO, ATTACK_MOVE, RETREAT,
GO_FOUNTAIN, GO_TO_LANE, FARM_LANE, PUSH_LANE, DEFEND_LANE, FARM_NEAREST_CAMP,
FARM_CAMP, PICKUP_RUNE, SECURE_RUNE, FOLLOW_CORE, GROUP_WITH_TEAM, PLACE_WARD,
DEWARD, CONTEST_OBJECTIVE, ATTACK_UNIT, ATTACK_HERO, HARASS_HERO, ATTACK_TOWER,
CAST_ABILITY_TARGET/POSITION/NO_TARGET, USE_ITEM_TARGET/POSITION/NO_TARGET,
LEVEL_ABILITY, SET_QUICKBUY, CHARGE_HERO, BULLDOZE, NETHER_STRIKE.
Additional names: PLANAR_POCKET, PULL, STACK, ROSHAN, TORMENTOR, OUTPOST.
OUTPOST is deliberately rejected as unverified; dispenser placement is disabled.

## Optional existing Python bridge

`bridge_server.py` and its launch scripts remain available, not started by this
controller. To opt in later, run the existing server, enable external commands,
and call `DotaAI.SetBridgeEnabled(true)`. The embedded transport posts at most
once/second to loopback `/v1/tick`, always with `recordingEnabled=false` and
without recorded/manual orders. Failure leaves autonomous rules running.
It accepts only `layer='macro'`; a legacy micro-layer message cannot replace
the local controller. Default bridge observe-only mode still refuses execution.
JSON is embedded; assets.JSON and runtime require are not necessary.

Disabling bridge invalidates late HTTP callbacks. Existing server/dataset tools
are preserved for future work but are not part of autonomous gameplay runtime.
