# DotaAI control API v1

> Historical recorder/bridge controller reference. The active autonomous bot
> is now `spirit_breaker_bot.lua`; see `RULEBOT_API.md` and `BOT_README.md` for
> its default-disabled external control, observation fields and restrictions.

`mid_t1_start.lua` registers the global Lua table `DotaAI` during `OnUpdate`.
Call methods with dot syntax. Commands are intended for private/local lobbies.
The active hero profile is Spirit Breaker support/hard support.

## State

```lua
local state = DotaAI.GetObservation()
```

The observation includes the current/completed action sequence and error,
hero health, mana, level, gold, position, attack range and ability points;
visible enemy heroes; nearby allied heroes; nearby lane creeps and towers; abilities, inventory,
neutral camps and visible runes. Entity snapshots expose their game `index`,
which can be sent back as `targetIndex`.

Bridge observations also expose `bridgeCommandId`, `bridgeCommandLayer`,
`bridgeGoalId`, `bridgeCommandSequence`, and `macroGoal`. These fields let the
dispatcher correlate Lua completion with a stable macro goal while temporary
micro commands use separate command IDs.

Mandatory safety has priority over commands: tower escape, exit from enemy
creep packs in AUTO, and early creep-aggro retreat.

## Movement and map

```lua
DotaAI.MoveTo(Vector(0, 0, 0), 6)
DotaAI.AttackMove(Vector(0, 0, 0), 6)
DotaAI.GoToLane("bot", 8)
DotaAI.GoFountain(12)
DotaAI.PickupRune(runeEntity, 8)
DotaAI.SecureRune(runeEntity, Vector(0, 0, 0), 12)
DotaAI.FollowCore(allyHero, 12)
DotaAI.GroupWithTeam(allyHero, 12)
DotaAI.Retreat(Vector(-1000, -1200, 0), 3)
DotaAI.HoldSafe(1)
```

## Farming and objectives

```lua
DotaAI.FarmLane("bot", 8)
DotaAI.PushLane("bot", 10)
DotaAI.DefendLane("top", 10)
DotaAI.FarmNearestCamp(18)
DotaAI.FarmCamp(campIndex, 18)
DotaAI.AttackUnit(enemyUnit, 2)
DotaAI.AttackHero(enemyHero, 2)
DotaAI.HarassHero(enemyHero, 1.2)
DotaAI.AttackTower(enemyTower, 5)
DotaAI.PlaceWard(Vector(100, 200, 0), "observer")
DotaAI.Deward(enemyWard, 3)
```

The support profile never attacks lane creeps before 10:00. After 10:00,
`FarmLane`, `PushLane`, and neutral-camp farming are explicit low-priority macro
orders only; AUTO stays with allies instead of taking farm.

Camp indexes come from `state.camps[].index`. If no index is supplied,
`FarmNearestCamp` first prefers the nearest camp with visible neutral creeps.

## Spells, items, leveling and quick-buy

```lua
DotaAI.ChargeHero(enemyHero)
DotaAI.Bulldoze()
DotaAI.NetherStrike(enemyHero)
DotaAI.CastAbilityTarget("spirit_breaker_charge_of_darkness", enemyHero)

DotaAI.UseItemTarget("item_force_staff", selfHero)
DotaAI.UseItemPosition("item_blink", Vector(100, 200, 0))
DotaAI.UseItemNoTarget("item_phase_boots")

DotaAI.LevelAbility("spirit_breaker_greater_bash")
DotaAI.SetQuickBuy("ward_observer", true)
```

Spell and item commands are one-shot and validate existence/castability.
Quick-buy uses the documented `Engine.SetQuickBuy`; names may be passed with or
without the `item_` prefix. Automatic purchasing is intentionally not faked:
the UCZone API documents quick-buy setup but does not expose an item-name
purchase call through `Player.PrepareUnitOrders`.

## Generic command and results

```lua
local ok, sequence = DotaAI.Command("FOLLOW_CORE", { targetIndex = 123 }, 10)
DotaAI.Cancel()
```

All convenience methods call `DotaAI.Command`. A positive duration returns to
`AUTO` when it expires. Read `actionSequence`, `completedSequence`, `lastResult`
and `lastError` from the next observation to correlate asynchronous commands.
An unsupported or failed action is isolated with `pcall`, so it cannot disable
the rest of the script.
