-- Decision rules adapted from vendor/OpenHyperAI/bots/BotLib/hero_spirit_breaker.lua:
-- SkillsComplement charge lock; ConsiderChargeOfDarkness interrupts/team balance;
-- ConsiderNetherStrike save modifiers; optional ConsiderPlanarPocket.
-- No Valve bot methods or Action_* orders are used in this adapter-based port.
return function(B)
    local H = {}
    B.hero = H
    local chargeName = 'spirit_breaker_charge_of_darkness'
    local bashName = 'spirit_breaker_greater_bash'
    local bulldozeName = 'spirit_breaker_bulldoze'
    local strikeName = 'spirit_breaker_nether_strike'
    local pocketName = 'spirit_breaker_planar_pocket'

    local function valid(u)
        return u and u.handle and u.pos and u.alive == true
            and u.visible == true and not u.illusion and not u.invulnerable
    end

    local function hasAny(u, names)
        for _, name in ipairs(names) do
            if B.has(u, name) then return true end
        end
        return false
    end

    local protectedMods = {
        'modifier_abaddon_borrowed_time', 'modifier_dazzle_shallow_grave',
        'modifier_oracle_false_promise_timer', 'modifier_oracle_fates_edict',
        'modifier_necrolyte_reapers_scythe', 'modifier_templar_assassin_refraction_absorb',
        'modifier_item_aeon_disk_buff', 'modifier_item_sphere_target',
        'modifier_item_lotus_orb_active', 'modifier_antimage_counterspell',
        'modifier_antimage_spell_shield', 'modifier_faceless_void_chronosphere_freeze',
    }

    local function enemy(s, u)
        -- Immunity piercing is not in CONTRACT.md: conservatively decline immune
        -- targets, even for abilities that may pierce it on a particular patch.
        return valid(u) and u.team ~= nil and u.team ~= s.hero.team
            and not u.magicImmune and not hasAny(u, protectedMods)
    end

    local function flag(value, bit)
        return type(value) == 'number' and math.floor(value / bit) % 2 == 1
    end

    local function ready(s, a, castType, target)
        if not a or not a.handle or a.hidden or a.passive or a.inPhase
            or a.castable ~= true or type(a.level) ~= 'number' or a.level < 1 then
            return false
        end
        -- DOTA_ABILITY_BEHAVIOR_NO_TARGET=4, UNIT_TARGET=8. Metadata is
        -- supplied by the adapter; unknown behavior/range never becomes a guess.
        if not flag(a.behavior, castType == 'none' and 4 or 8) then return false end
        if type(a.manaCost) == 'number' and type(s.hero.mana) == 'number'
            and s.hero.mana < a.manaCost then return false end
        if target then
            return flag(a.targetTeam, 2) and B.inCastRange(a,B.dist(s.hero.pos,target.pos))
        end
        return true
    end

    local function locked(s)
        local h = s.hero
        if not h or not h.alive or h.channeling or h.casting
            or B.has(h, 'modifier_teleporting') then return true end
        for _, a in pairs(s.abilities or {}) do
            if a.inPhase then return true end
        end
        for _, a in pairs(s.items or {}) do
            if a.inPhase then return true end
        end
        return false
    end

    local function cast(a, target, reason, priority)
        return { kind = 'cast', ability = a, target = target,
            castType = target and 'target' or 'none', reason = reason, priority = priority }
    end

    local function distance(a, b)
        return a and b and a.pos and b.pos and B.dist(a.pos, b.pos) or math.huge
    end

    local function hurt(u)
        return (u.recentDamage or 0) > 0 or (u.healthLossRate or 0) > 0
    end

    local function supported(s, target)
        if not B.threat or not B.threat.safeEngage
            or B.threat.safeEngage(s, target) ~= true then return false end
        local allies = 0
        for _, a in ipairs(s.allies or {}) do
            if valid(a) and (a.hpPct or 0) > 0.35 and distance(a, target) < 1100 then
                allies = allies + 1
            end
        end
        -- Support does not start solo global charges or chase into tower range.
        if (s.hero.hpPct or 0) < 0.42 then return false end
        if allies==0 then
            local isolatedFinish=(target.hpPct or 1)<0.18 and (s.hero.hpPct or 0)>0.7 and distance(s.hero,target)<950
            for _,e in ipairs(s.enemies or {}) do if e.index~=target.index and distance(e,target)<1200 then isolatedFinish=false end end
            if not isolatedFinish then return false end
        end
        for _, tower in ipairs(s.towers or {}) do
            if tower.alive and tower.team ~= s.hero.team and tower.pos
                and distance(tower, target) < (tower.range or 800) + 200 then return false end
        end
        return true
    end

    local function towerDanger(s, target)
        for _, tower in ipairs(s.towers or {}) do
            if tower.alive and tower.team ~= s.hero.team and tower.pos
                and distance(tower, target) < (tower.range or 800) + 180 then return true end
        end
        return false
    end

    local function coreReserves(s, target, radius)
        for _, a in ipairs(s.allies or {}) do
            if valid(a) and (a.role == nil or a.role <= 3)
                and distance(a, target) < (radius or 1400) then return true end
        end
        return false
    end

    local function alliedCover(s, target)
        local heroes, creeps = 0, 0
        for _, a in ipairs(s.allies or {}) do
            if valid(a) and (a.hpPct or 0) > 0.4 and distance(a, target) < 1100 then heroes = heroes + 1 end
        end
        for _, c in ipairs(s.creeps or {}) do
            if valid(c) and c.team == s.hero.team and distance(c, target) < 900 then creeps = creeps + 1 end
        end
        return heroes, creeps
    end

    local function mapFightActive(s)
        for _, e in ipairs(s.enemies or {}) do
            if enemy(s, e) then
                for _, a in ipairs(s.allies or {}) do
                    if valid(a) and distance(a, e) < 1100
                        and (a.attackTarget == e.index or e.attackTarget == a.index
                            or (a.recentDamage or 0) > 10 or (e.recentDamage or 0) > 10
                            or a.stunned or e.channeling) then return true end
                end
            end
        end
        return false
    end

    local function baseChargeTarget(s)
        local anchor = valid(s.core) and s.core.pos or B.map.lanePoint(s, s.lane)
        local best, score
        -- A real supported fight is a better exit from base than a creep taxi.
        for _, e in ipairs(s.enemies or {}) do
            if enemy(s, e) and supported(s, e) then
                local value = 1000 + (1 - (e.hpPct or 1)) * 100 - distance(e, {pos=anchor}) / 1000
                if not score or value > score then best, score = e, value end
            end
        end
        if best then return best end
        for _, c in ipairs(s.creeps or {}) do
            local heroes, creeps = alliedCover(s, c)
            if enemy(s, c) and (c.hpPct or 0) > 0.45
                and distance(s.hero, c) > 2500 and not towerDanger(s, c)
                and B.threat.safeEngage(s, c) then
                local value = -distance(c, {pos=anchor}) / 1000 + heroes * 2 + creeps * 0.15
                if not score or value > score then best, score = c, value end
            end
        end
        if best then return best end
        for _, n in ipairs(s.neutrals or {}) do
            local name=n.name or ''
            if enemy(s,n) and (n.hpPct or 0)>0.65 and distance(s.hero,n)>1800
                and not name:find('ancient') and not name:find('roshan') and not name:find('miniboss')
                and not towerDanger(s,n) and B.threat.safeEngage(s,n) then
                local value=-distance(n,{pos=anchor})/1000
                if not score or value>score then best,score=n,value end
            end
        end
        return best
    end

    local function freeFarmChargeTarget(s, mode)
        local modeName = mode and mode.name or ''
        if s.time < 600 or (modeName ~= 'farm' and modeName ~= 'lane' and modeName ~= 'idle'
            and modeName ~= 'group')
            or mapFightActive(s) then return nil end
        for _, e in ipairs(s.enemies or {}) do
            if enemy(s, e) and distance(s.hero, e) < 1800 then return nil end
        end
        local best, score
        local function consider(u, maxDistance)
            local d = distance(s.hero, u)
            if not enemy(s, u) or (u.hpPct or 0) < 0.6 or d < 500 or d > maxDistance
                or towerDanger(s, u) or coreReserves(s, u, 1500)
                or not B.threat.safeEngage(s, u) then return end
            local travel = d / 800
            if (u.hp or 0) - (u.healthLossRate or 0) * travel < (u.maxHp or 1) * 0.3 then return end
            local value = (u.hpPct or 0) * 10 - d / 5000
            if not score or value > score then best, score = u, value end
        end
        for _, c in ipairs(s.creeps or {}) do consider(c, 4500) end
        for _, n in ipairs(s.neutrals or {}) do
            if not (n.name or ''):find('ancient') and not (n.name or ''):find('roshan')
                and not (n.name or ''):find('miniboss') then consider(n, 3000) end
        end
        return best
    end

    local function attackingAlly(s, e)
        if not e.attacking or e.attackTarget == nil then return nil end
        for _, a in ipairs(s.allies or {}) do
            if valid(a) and a.index == e.attackTarget and distance(e, a) < 950
                and ((a.hpPct or 1) < 0.55 or a.channeling) and hurt(a) then return a end
        end
        return nil
    end

    local function offensive(mode)
        local n = mode and mode.name or ''
        return n == 'fight' or n == 'teamfight' or n == 'gank' or n == 'roam'
            or n == 'harass' or n == 'attack' or n == 'defend' or n == 'save'
            or n == 'save_ally' or n == 'protect_core'
    end

    local function retreating(mode)
        local n = mode and mode.name or ''
        return n == 'SAFETY' or n == 'retreat' or n == 'emergency' or n == 'heal' or n == 'fountain'
    end

    function H.consider(s, mode)
        if locked(s) then return nil end
        local h = s.hero
        if h.stunned or h.silenced or h.invulnerable then return nil end
        local abilities = s.abilities or {}
        local charging = B.charging(s)
        local chargeTarget = B.chargeTarget and B.find(s.enemies, B.chargeTarget.index)
        -- Human demonstration: Bulldoze is commonly held until the Charge is
        -- close to connecting. Charge itself must not lock this no-target cast.
        if charging then
            local bulldoze = abilities[bulldozeName]
            local nearArrival = chargeTarget and distance(h, chargeTarget) <= 2400
            local travelled = B.chargeTarget and s.now - B.chargeTarget.issuedAt >= 5
            if ready(s, bulldoze, 'none')
                and not B.has(h, 'modifier_spirit_breaker_bulldoze')
                and (nearArrival or travelled) then
                return cast(bulldoze, nil, 'Bulldoze before Charge impact', 91)
            end
            return nil
        end
        -- Global finisher: act independently of the current walking/laning mode.
        -- The adapter exposes only visible enemies, and safeEngage retains the
        -- known-tower / obvious-outnumbering guard for the destination.
        if not retreating(mode) then
            local charge = abilities[chargeName]
            local threshold = (B.config and B.config.lowHpChargeThreshold) or 0.25
            local best, score
            for _, e in ipairs(s.enemies or {}) do
                if enemy(s, e) and (e.hpPct or 1) <= threshold
                    and not e.stunned and B.threat and B.threat.safeEngage(s, e) then
                    local value = (1 - (e.hpPct or 1)) * 100 - distance(h, e) / 5000
                    if e.channeling then value = value + 10 end
                    if not score or value > score then best, score = e, value end
                end
            end
            if best and not h.rooted and ready(s, charge, 'target', best) then
                local i = cast(charge, best, 'Global Charge on visible low-health enemy', 95)
                i.lowHpFinisher = true
                return i
            end
        end
        if not retreating(mode) and (h.hpPct or 0) >= 0.78 then
            local charge = abilities[chargeName]
            local tp = (s.items or {}).item_tpscroll
            local atBase = B.map and distance(h, {pos=B.map.home(s)}) <= 1100
            local tpUnavailable = not tp or (tp.charges or 0)<1
                or (type(tp.cooldown) == 'number' and tp.cooldown > 0.1)
            if atBase and tpUnavailable then
                local target = baseChargeTarget(s)
                if target and not h.rooted and ready(s, charge, 'target', target) then
                    local i = cast(charge, target, 'Leave base via Charge while TP is on cooldown', 90)
                    i.baseExitCharge = true
                    return i
                end
            end
        end
        -- Local team fights are independent of the selected walking/warding
        -- mode and of the level-two cross-lane rotation rule.
        if not retreating(mode) and not (mode and mode.name=='gank') and B.support then
            local best,score
            for _,e in ipairs(s.enemies or {}) do
                local intent=B.support.localCharge(s,e)
                if intent and enemy(s,e) and ready(s,intent.ability,'target',e) then
                    local value=(1-e.hpPct)*10+(e.channeling and 20 or 0)-distance(h,e)/1000
                    if not score or value>score then best,score=intent,value end
                end
            end
            if best then return best end
        end
        if mode and mode.name=='gank' and B.support and B.support.canGank(s,mode.target) then
            local a=abilities[chargeName]
            if ready(s,a,'target',mode.target) then
                local i=cast(a,mode.target,'Supported cross-lane Charge from level 2',62)
                i.gank=true return i
            end
        end
        local charge, strike = abilities[chargeName], abilities[strikeName]
        local bulldoze, pocket = abilities[bulldozeName], abilities[pocketName]
        local nearby = 0
        for _, e in ipairs(s.enemies or {}) do
            if valid(e) and distance(h, e) < 850 then nearby = nearby + 1 end
        end

        -- Interrupt channels / peel an observed attacker before ordinary aggression.
        -- Avoid a long-travel "interrupt" and do not interrupt an existing stun.
        for _, e in ipairs(s.enemies or {}) do
            if enemy(s, e) and not e.stunned and supported(s, e) then
                local ally = attackingAlly(s, e)
                if e.channeling or ally then
                    local reason = e.channeling and 'interrupt enemy channel' or 'peel attacker from ally'
                    if not h.rooted and ready(s, strike, 'target', e) then
                        return cast(strike, e, reason, 88)
                    end
                    if not h.rooted and distance(h, e) <= 1000
                        and ready(s, charge, 'target', e) then
                        return cast(charge, e, reason, 86)
                    end
                end
            end
        end

        if ready(s, bulldoze, 'none')
            and not B.has(h, 'modifier_spirit_breaker_bulldoze') and nearby > 0
            and (h.rooted or (hurt(h) and (retreating(mode) or offensive(mode)))) then
            return cast(bulldoze, nil, 'reduce disable duration under pressure', 76)
        end

        -- Planar Pocket can disappear with facet/shard/patch changes. Presence,
        -- training, no-target behavior and observed radius are all required.
        local radius = pocket and pocket.specials and pocket.specials.radius
        if ready(s, pocket, 'none') and type(radius) == 'number' and radius > 0
            and (h.hpPct or 0) > 0.65 and nearby > 0
            and not B.has(h, 'modifier_spirit_breaker_planar_pocket') then
            for _, a in ipairs(s.allies or {}) do
                if valid(a) and distance(h, a) <= radius and (a.hpPct or 1) < 0.5
                    and hurt(a) then
                    return cast(pocket, nil, 'protect nearby injured ally with Planar Pocket', 78)
                end
            end
        end

        if not offensive(mode) or retreating(mode) or h.rooted then
            if not retreating(mode) and not h.rooted and (h.hpPct or 0) >= 0.68 then
                local target = freeFarmChargeTarget(s, mode)
                if target and ready(s, charge, 'target', target) then
                    local i = cast(charge, target, 'Charge a free creep while no fight or team task is active', 48)
                    i.farmCharge = true
                    return i
                end
            end
            return nil
        end
        local best, score
        for _, e in ipairs(s.enemies or {}) do
            if enemy(s, e) and not e.stunned and not e.rooted and supported(s, e)
                and not B.has(e, 'modifier_legion_commander_duel')
                and distance(h, e) <= 1900 then
                local value = (1 - (e.hpPct or 1)) * 20
                    + (mode and mode.target and mode.target.index == e.index and 15 or 0)
                    + (attackingAlly(s, e) and 30 or 0) - distance(h, e) / 200
                if not score or value > score then best, score = e, value end
            end
        end
        if not best then return nil end
        if ready(s, strike, 'target', best) then
            -- No guessed damage/magic-resistance calculation: use Strike for
            -- supported control, not a purported guaranteed magical last hit.
            return cast(strike, best, 'supported Nether Strike on unprotected enemy', 64)
        end
        if distance(h, best) > math.max(350, (h.range or 150) + 100)
            and ready(s, charge, 'target', best) then
            return cast(charge, best, 'short supported Charge initiation', 60)
        end
        return nil
    end

    function H.level(s)
        if locked(s) or not s.hero.handle then return nil end
        -- Verified read-only calls already used by mid_t1_start.lua's LEVEL path.
        -- https://uczone.gitbook.io/api-v2.0/game-components/core/hero
        -- CONTRACT.md has no abilityPoints/upgradeability fields. B.call is the
        -- adapter gateway; nil means unknown, never permission to spend a point.
        local points = B.call('Hero', 'GetAbilityPoints', nil, s.hero.handle)
        if type(points) ~= 'number' or points < 1 then return nil end
        local available, levels = {}, {}
        for name, a in pairs(s.abilities or {}) do
            levels[name] = a.level or 0
            if a.handle and not a.item and not a.hidden and name ~= 'generic_hidden'
                and B.call('Ability', 'CanBeUpgraded', nil, a.handle) == true then
                available[#available + 1] = { name = name, ability = a }
            end
        end
        local function preference(entry)
            local n = entry.name
            -- The recorded pos-4 game opened Bash at level 1 and Charge at
            -- level 2, enabling lane trading first and rotations immediately after.
            if n == bashName and (levels[n] or 0) == 0 then return 130 end
            if n == chargeName and (levels[n] or 0) == 0 then return 125 end
            if n == strikeName then return 115 end
            if n == bulldozeName and (levels[n] or 0) == 0 then return 105 end
            -- Enumerate actual talent names, never hardcode slots/talent IDs.
            -- CanBeUpgraded handles tier requirements, caps and opposite talents.
            if n:match('^special_bonus_') and n ~= 'special_bonus_attributes' then return 100 end
            if n == bashName then return 90 end
            if n == chargeName then return 85 end
            if n == bulldozeName then return 80 end
            if n == 'special_bonus_attributes' then return 10 end
            return 20
        end
        table.sort(available, function(a, b)
            local pa, pb = preference(a), preference(b)
            if pa ~= pb then return pa > pb end
            return a.name < b.name
        end)
        -- As in ability_item_usage_generic.lua AbilityLevelUpComplement, skip
        -- invalid/maxed abilities. Unlike its mutable build cursor, retry against
        -- observed levels so a rejected proposal cannot skip a skill point.
        if available[1] then
            return { kind = 'level', ability = available[1].ability,
                reason = 'level available support skill or valid talent', priority = 15 }
        end
        return nil
    end

    function H.reset() end -- All hero decisions use current observations.
end
