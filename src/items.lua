-- Origins: vendor/OpenHyperAI/bots/ability_item_usage_generic.lua,
-- ItemUsageComplement and ConsiderItemDesire entries for each named item below.
-- Ported principles: cast/channel locks, charged healing, ally saves, facing-aware
-- Force, regen outside combat, grouped smoke and guarded TP. All output is intent.
return function(B)
    local I = {}
    B.items = I
    local pending, owner, lastTime
    local sidePending, restockedAt = nil, -math.huge
    local starter, starterDone, pendingAt, retryAt, inheritedAt
    local function queueCount(s)
        local q=s.quickbuy and s.quickbuy.m_quickBuyItems
        if type(q)~='table' then return nil end
        local n=0 for _,id in pairs(q) do if type(id)=='number' and id>0 and id<65535 then n=n+1 end end
        return n
    end
    local function waiting(s,label,since)
        local n=queueCount(s)
        I.status=label..' | quick-buy '..tostring(n or '?')
        if s.now-(since or s.now)>8 then
            B.log('shop.wait','Waiting for autobuy: '..label..', quick-buy entries='..tostring(n)..', gold='..tostring(s.gold),15)
        end
    end
    local function wardOnlyQueue(s)
        local q=s.quickbuy and s.quickbuy.m_quickBuyItems
        if type(q)~='table' then return false end
        local found=false
        for _,id in pairs(q) do
            if type(id)=='number' and id>0 and id<65535 then
                if id~=42 and id~=43 then return false end
                found=true
            end
        end
        return found
    end

    local function flag(value, bit)
        return type(value) == 'number' and math.floor(value / bit) % 2 == 1
    end
    local function valid(u)
        return u and u.handle and u.pos and u.alive == true
            and u.visible == true and not u.illusion and not u.invulnerable
    end
    local function distance(a, b)
        return a and b and a.pos and b.pos and B.dist(a.pos, b.pos) or math.huge
    end
    local function hasAny(u, names)
        for _, n in ipairs(names) do if B.has(u, n) then return true end end
        return false
    end
    local function hurt(u)
        return (u.recentDamage or 0) > 0 or (u.healthLossRate or 0) > 0
    end
    local function countEnemies(s, u, radius)
        local count = 0
        for _, e in ipairs(s.enemies or {}) do
            if valid(e) and distance(u, e) < radius then count = count + 1 end
        end
        return count
    end
    local function towerAt(s, pos, margin)
        for _, t in ipairs(s.towers or {}) do
            if t.alive and t.team ~= s.hero.team and t.pos
                and B.dist(pos, t.pos) < (t.range or 800) + margin then return true end
        end
        return false
    end
    local function locked(s)
        local h = s.hero
        if not h or not h.alive or h.stunned or h.muted or h.invulnerable
            or h.channeling or h.casting or B.has(h, 'modifier_teleporting')
            or B.has(h, 'modifier_spirit_breaker_charge_of_darkness') then return true end
        for _, a in pairs(s.abilities or {}) do if a.inPhase then return true end end
        for _, a in pairs(s.items or {}) do if a.inPhase then return true end end
        return false
    end
    local function ready(s, name, castType, target)
        local a = (s.items or {})[name]
        if not a or not a.handle or a.castable ~= true or a.hidden or a.passive or a.inPhase then return nil end
        -- Backpack/stash items cannot be activated. TP/neutral dedicated slots
        -- match ItemUsageComplement's 0..5,15,16 scan; unknown slot is not usable.
        if type(a.slot) ~= 'number' or not ((a.slot >= 0 and a.slot <= 5)
            or a.slot == 15 or a.slot == 16) then return nil end
        local bit = castType == 'target' and 8 or (castType == 'position' and 16 or 4)
        if not flag(a.behavior, bit) then return nil end
        if type(a.manaCost) == 'number' and type(s.hero.mana) == 'number'
            and s.hero.mana < a.manaCost then return nil end
        if target then
            if not valid(target) then return nil end
            local teamBit = target.team == s.hero.team and 1 or 2
            if not flag(a.targetTeam, teamBit) then return nil end
            if target.index ~= s.hero.index and (type(a.range) ~= 'number'
                or a.range <= 0 or distance(s.hero, target) > a.range) then return nil end
        end
        return a
    end
    local function cast(a, target, reason, priority, pos)
        return { kind = 'cast', ability = a, target = target, pos = pos,
            castType = pos and 'position' or (target and 'target' or 'none'),
            reason = reason, priority = priority }
    end
    local function threatened(s, u)
        return countEnemies(s, u, 900) > 0 and (hurt(u) or u.stunned or u.rooted or u.silenced)
    end
    local function quiet(s, u)
        -- Unknown damage history is not evidence of uninterrupted regen.
        return type(u.recentDamage) == 'number' and u.recentDamage <= 2
            and type(u.healthLossRate) == 'number' and u.healthLossRate <= 1
            and countEnemies(s, u, 1100) == 0 and not towerAt(s, u.pos, 100)
            and not B.has(u, 'modifier_fountain_aura_buff')
            and not B.has(u, 'modifier_fountain_aura')
    end
    local function missing(u, resource)
        local current, maximum = u[resource], u[resource == 'hp' and 'maxHp' or 'maxMana']
        if type(current) ~= 'number' or type(maximum) ~= 'number' then return 0 end
        return maximum - current
    end

    local function forceSafe(s, ally, item)
        if ally.channeling or ally.casting or ally.magicImmune
            or B.has(ally, 'modifier_teleporting')
            or B.has(ally, 'modifier_spirit_breaker_charge_of_darkness') then return false end
        -- CONTRACT.facing must be an observed forward {x,y,z}, not an angle with
        -- guessed units. Missing/ambiguous direction or push length => no Force.
        local facing = ally.facing
        local length = item.specials and item.specials.push_length
        if type(facing) ~= 'table' or type(facing.x) ~= 'number' or type(facing.y) ~= 'number'
            or type(length) ~= 'number' or length <= 0 then return false end
        local magnitude = math.sqrt(facing.x * facing.x + facing.y * facing.y)
        if magnitude < 0.01 or not B.threat or not B.threat.at then return false end
        local finish = B.add(ally.pos, { x = facing.x / magnitude * length,
            y = facing.y / magnitude * length, z = 0 })
        local before, after = B.threat.at(s, ally.pos), B.threat.at(s, finish)
        if type(before) ~= 'number' or type(after) ~= 'number' or after >= before then return false end
        if towerAt(s, finish, 200) then return false end
        -- Reject pushes through a more dangerous corridor, not just bad endpoints.
        for step = 1, 3 do
            local risk = B.threat.at(s, B.toward(ally.pos, finish, length * step / 4))
            if type(risk) ~= 'number' or risk > before then return false end
        end
        return true
    end

    local invisMods = {
        'modifier_invisible', 'modifier_riki_permanent_invisibility',
        'modifier_bounty_hunter_wind_walk', 'modifier_clinkz_wind_walk',
        'modifier_nyx_assassin_vendetta', 'modifier_weaver_shukuchi',
        'modifier_item_invisibility_edge_windwalk', 'modifier_item_silver_edge_windwalk',
        'modifier_item_glimmer_cape', 'modifier_invoker_ghost_walk_self',
    }
    local revealMods = { 'modifier_item_dustofappearance', 'modifier_slardar_amplify_damage',
        'modifier_bounty_hunter_track' }
    local saveMods = { 'modifier_abaddon_borrowed_time', 'modifier_dazzle_shallow_grave',
        'modifier_oracle_false_promise_timer', 'modifier_oracle_fates_edict',
        'modifier_item_aeon_disk_buff', 'modifier_item_sphere_target',
        'modifier_item_lotus_orb_active', 'modifier_antimage_counterspell' }
    local healMods = { 'modifier_item_urn_heal', 'modifier_item_spirit_vessel_heal',
        'modifier_flask_healing', 'modifier_fountain_aura', 'modifier_fountain_aura_buff' }

    function I.consider(s, mode)
        if locked(s) then return nil end
        local h, n = s.hero, mode and mode.name or ''
        local enemies = countEnemies(s, h, 900)
        local retreat = n == 'SAFETY' or n == 'retreat' or n == 'emergency' or n == 'heal' or n == 'fountain'
        local fight = n == 'fight' or n == 'teamfight' or n == 'attack' or n == 'gank'
            or n == 'harass' or n == 'defend' or n == 'save' or n == 'save_ally' or n == 'protect_core'

        for _, name in ipairs({ 'item_magic_wand', 'item_magic_stick' }) do
            local a = ready(s, name, 'none')
            if a and (a.charges or 0) > 0 and (missing(h, 'hp') > 0 or missing(h, 'mana') > 0)
                and ((enemies > 0 and ((h.hpPct or 1) < 0.5 or (h.manaPct or 1) < 0.3))
                    or ((h.hpPct or 1) < 0.3 and hurt(h))) then
                return cast(a, nil, 'restore health/mana with observed stick charges', 94)
            end
        end
        local bkb = ready(s, 'item_black_king_bar', 'none')
        if bkb and enemies > 0 and not h.magicImmune
            and not B.has(h, 'modifier_black_king_bar_immune')
            and (h.rooted or h.silenced or (hurt(h) and (h.hpPct or 1) < 0.55 and (fight or retreat))) then
            return cast(bkb, nil, 'BKB against immediate disable/damage pressure', 92)
        end

        local allies = { h }
        for _, a in ipairs(s.allies or {}) do if valid(a) then allies[#allies + 1] = a end end
        table.sort(allies, function(a, b)
            local av = (a.hpPct or 1) - ((a.role or 5) <= 3 and 0.08 or 0)
            local bv = (b.hpPct or 1) - ((b.role or 5) <= 3 and 0.08 or 0)
            return av < bv
        end)
        for _, ally in ipairs(allies) do
            if valid(ally) and threatened(s, ally) then
                local force = ready(s, 'item_force_staff', 'target', ally)
                if force and (ally.hpPct or 1) < 0.5 and forceSafe(s, ally, force) then
                    return cast(force, ally, 'Force ally toward observed lower threat', 90)
                end
                local glimmer = ready(s, 'item_glimmer_cape', 'target', ally)
                if glimmer and (ally.hpPct or 1) < 0.55 and not ally.magicImmune
                    and not B.has(ally, 'modifier_item_glimmer_cape')
                    and not hasAny(ally, revealMods) and not towerAt(s, ally.pos, 100) then
                    return cast(glimmer, ally, 'Glimmer injured ally under pressure', 89)
                end
                local lotus = ready(s, 'item_lotus_orb', 'target', ally)
                if lotus and not B.has(ally, 'modifier_item_lotus_orb_active')
                    and not ally.magicImmune and (ally.rooted or ally.silenced or ally.disarmed) then
                    return cast(lotus, ally, 'Lotus dispel for pressured ally', 88)
                end
            end
        end

        local dust = ready(s, 'item_dust', 'none')
        local dustRadius = dust and dust.specials and dust.specials.radius
        if dust and (dust.charges or 0) > 0 and type(dustRadius) == 'number' and dustRadius > 0 then
            for _, e in ipairs(s.enemies or {}) do
                if valid(e) and distance(h, e) <= dustRadius and hasAny(e, invisMods)
                    and not hasAny(e, revealMods) then
                    return cast(dust, nil, 'reveal observed nearby invisibility', 82)
                end
            end
        end

        for _, name in ipairs({ 'item_spirit_vessel', 'item_urn_of_shadows' }) do
            for _, ally in ipairs(allies) do
                local a = ready(s, name, 'target', ally)
                if a and (a.charges or 0) > 0 and missing(ally, 'hp') > 400
                    and quiet(s, ally) and not hasAny(ally, healMods) then
                    return cast(a, ally, 'heal ally between fights with urn/vessel', 55)
                end
            end
            local target = mode and mode.target
            local a = target and ready(s, name, 'target', target)
            if a and fight and (a.charges or 0) > 0 and target.team ~= h.team
                and not target.magicImmune and not hasAny(target, saveMods)
                and not B.has(target, 'modifier_item_urn_damage')
                and not B.has(target, 'modifier_item_spirit_vessel_damage')
                and (target.hpPct or 1) < 0.9 then
                return cast(a, target, 'urn/vessel pressure on unprotected fight target', 54)
            end
        end

        local phase = ready(s, 'item_phase_boots', 'none')
        local destination = mode and (mode.pos or (mode.target and mode.target.pos))
        if phase and not h.rooted and not B.has(h, 'modifier_item_phase_boots_active')
            and ((retreat and enemies > 0) or (destination and B.dist(h.pos, destination) > 400
                and (not h.attacking or fight))) then
            return cast(phase, nil, 'Phase movement toward current objective', 45)
        end

        for _, ally in ipairs(allies) do
            if valid(ally) and quiet(s, ally) then
                local flask = ready(s, 'item_flask', 'target', ally)
                if flask and (flask.charges or 0) > 0 and missing(ally, 'hp') > 450
                    and not hasAny(ally, healMods) then
                    return cast(flask, ally, 'safe healing salve between fights', 35)
                end
                local clarity = ready(s, 'item_clarity', 'target', ally)
                if clarity and (clarity.charges or 0) > 0 and missing(ally, 'mana') > 250
                    and (ally.manaPct or 1) < 0.4 and not B.has(ally, 'modifier_clarity_potion') then
                    return cast(clarity, ally, 'safe mana regeneration between fights', 34)
                end
            end
        end

        local smoke = ready(s, 'item_smoke_of_deceit', 'none')
        local radius = smoke and smoke.specials and smoke.specials.application_radius
        if smoke and (smoke.charges or 0) > 0 and type(radius) == 'number' and radius > 0
            and (n == 'gank' or n == 'roam' or n == 'roshan') and destination
            and B.dist(h.pos, destination) > 1800 and not B.has(h, 'modifier_smoke_of_deceit') then
            local grouped, safe = 0, true
            for _, ally in ipairs(allies) do
                if distance(h, ally) <= radius then
                    if countEnemies(s, ally, 1400) > 0 or towerAt(s, ally.pos, 600)
                        or hurt(ally) or ally.channeling or (ally.hpPct or 0) < 0.6 then safe = false end
                    if ally.index ~= h.index and not B.has(ally, 'modifier_smoke_of_deceit') then
                        grouped = grouped + 1
                    end
                end
            end
            if safe and grouped >= 2 then return cast(smoke, nil, 'smoke healthy group for planned rotation', 30) end
        end

        local tp = ready(s, 'item_tpscroll', 'position')
        if tp and (tp.charges or 0) > 0 and retreat and not h.rooted and quiet(s, h)
            and ((h.hpPct or 1) < 0.3 or ((h.manaPct or 1) < 0.15 and (h.hpPct or 1) < 0.6))
            and not B.has(h, 'modifier_kunkka_x_marks_the_spot') then
            local home = B.map and B.map.home and B.map.home(s)
            if home and B.dist(h.pos, home) > 3500 then
                return cast(tp, nil, 'safe fountain TP to recover', 40, home)
            end
        end
        return nil
    end

    local healingHeroes = { npc_dota_hero_huskar = true, npc_dota_hero_alchemist = true,
        npc_dota_hero_necrolyte = true, npc_dota_hero_morphling = true,
        npc_dota_hero_dazzle = true, npc_dota_hero_oracle = true,
        npc_dota_hero_witch_doctor = true, npc_dota_hero_leshrac = true }
    local invisHeroes = { npc_dota_hero_riki = true, npc_dota_hero_bounty_hunter = true,
        npc_dota_hero_clinkz = true, npc_dota_hero_nyx_assassin = true,
        npc_dota_hero_weaver = true, npc_dota_hero_invoker = true }
    local upgrades = {
        item_boots = { 'item_phase_boots', 'item_tranquil_boots', 'item_power_treads',
            'item_arcane_boots', 'item_guardian_greaves', 'item_boots_of_bearing',
            'item_travel_boots', 'item_travel_boots_2' },
        item_magic_stick = { 'item_magic_wand', 'item_holy_locket' },
        item_magic_wand = { 'item_holy_locket' },
        item_urn_of_shadows = { 'item_spirit_vessel' },
        item_force_staff = { 'item_hurricane_pike' },
    }
    local function owned(s, name)
        local quantity = (s.ownedItems or {})[name]
        return type(quantity) == 'number' and quantity > 0
    end
    local function satisfied(s, name)
        if owned(s, name) then return true end
        for _, upgrade in ipairs(upgrades[name] or {}) do
            if owned(s, upgrade) then return true end
        end
        return false
    end

    function I.purchase(s)
        if not s.hero or not s.hero.handle or type(s.ownedItems) ~= 'table' then return nil end
        local now = s.now
        if owner ~= s.hero.handle or (type(now) == 'number' and lastTime and now < lastTime) then I.reset() end
        owner, lastTime = s.hero.handle, now
        if B.executor and B.executor.quickbuyJob then return nil end
        -- A free ward must never be the gate in front of the entire starting kit.
        -- Queue inexpensive starting items together; append the optional ward last.
        if not starterDone and not starter then
            if s.time>=600 or satisfied(s,'item_magic_stick') then starterDone=true
            elseif (queueCount(s) or 0)>0 and not wardOnlyQueue(s) then
                inheritedAt=inheritedAt or now
                waiting(s,'existing queue retained',inheritedAt)
                return nil
            else
                local names,required={},{}
                for _,entry in ipairs({{'item_magic_stick',1},{'item_flask',1},{'item_clarity',1},{'item_branches',2}}) do
                    local name,count=entry[1],entry[2]
                    local have=s.ownedItems[name] or 0
                    if have<count then required[name]=count
                        for _=have+1,count do names[#names+1]=name end
                    end
                end
                local stock=B.call('Item','GetStockCount',nil,42,s.hero.team)
                if not owned(s,'item_ward_observer') and not owned(s,'item_ward_dispenser') and type(stock)=='number' and stock>0 then
                    names[#names+1]='item_ward_observer'; restockedAt=now
                end
                if #names>0 then
                    starter={required=required,seen={},since=now,names=names}
                    I.status='starting kit queued'
                    return {kind='quickbuy',itemNames=names,itemName=names[1],reset=true,reason='Support starting kit; ward is optional'}
                end
                starterDone=true
            end
        end
        if starter then
            local complete=true
            for name,count in pairs(starter.required) do
                if (s.ownedItems[name] or 0)>=count then starter.seen[name]=true end
                if not starter.seen[name] then complete=false end
            end
            if complete then starter=nil starterDone=true
            else
                waiting(s,'starting kit awaiting purchase',starter.since)
                if queueCount(s)==0 and now-starter.since>3 and now-(retryAt or -100)>5 then
                    retryAt=now
                    local missing={}
                    for _,entry in ipairs({{'item_magic_stick',1},{'item_flask',1},{'item_clarity',1},{'item_branches',2}}) do
                        if starter.required[entry[1]] and not starter.seen[entry[1]] then
                            for _=(s.ownedItems[entry[1]] or 0)+1,entry[2] do missing[#missing+1]=entry[1] end
                        end
                    end
                    if #missing>0 then return {kind='quickbuy',itemNames=missing,itemName=missing[1],reset=true,reason='Restore empty starting queue'} end
                end
                return nil
            end
        end
        if sidePending and owned(s,sidePending) then sidePending=nil end
        -- Ward IDs are public metadata from Umbrella assets/data/items.json.
        -- Never erase a partly purchased major item to replenish consumables.
        local hasWard=owned(s,'item_ward_observer') or owned(s,'item_ward_sentry') or owned(s,'item_ward_dispenser')
        local observerStock=B.call('Item','GetStockCount',nil,42,s.hero.team)
        if not hasWard and not sidePending and now-restockedAt>180
            and type(observerStock)=='number' and observerStock>0 then
            sidePending='item_ward_observer'; restockedAt=now
            return {kind='quickbuy',itemName=sidePending,reset=pending==nil,
                reason='Restock support observer without discarding the major item queue',priority=6}
        end
        if sidePending and not pending then
            -- The optional ward gets a bounded wait, never blocks boots forever.
            if now-restockedAt<3 then return nil end
            sidePending=nil
        end
        if pending then
            if not satisfied(s, pending) then
                waiting(s,pending,pendingAt)
                if queueCount(s)==0 and now-(pendingAt or now)>3 and now-(retryAt or -100)>5 then
                    retryAt=now
                    return {kind='quickbuy',itemName=pending,reset=true,reason='Restore lost empty quick-buy queue'}
                end
                return nil
            end
            pending = nil
        end
        local antiheal, detection, pressure = false, false, 0
        for _, e in ipairs(s.enemies or {}) do
            if valid(e) then
                antiheal = antiheal or healingHeroes[e.name] or false
                detection = detection or invisHeroes[e.name] or hasAny(e, invisMods)
                if e.casting or e.channeling then pressure = pressure + 1 end
            end
        end
        local wanted = {}
        local function want(name, condition)
            if condition ~= false and not satisfied(s, name) then wanted[#wanted + 1] = name end
        end
        -- Support adaptation of hero_spirit_breaker.lua's sRoleItemsBuyList:
        -- saves/detection first; deliberately no farming accelerator / Midas.
        want('item_magic_stick')
        want('item_boots')
        want('item_tpscroll')
        want('item_dust', detection)
        local early = type(s.time) == 'number' and s.time < 600
        want('item_flask', early and (s.hero.hpPct or 1) < 0.5)
        want('item_clarity', early and (s.hero.manaPct or 1) < 0.35)
        want('item_magic_wand')
        -- Retain any existing upgraded boots. Phase is a preference, not a
        -- reason to purchase a second set after the player chose different boots.
        want('item_phase_boots', owned(s, 'item_boots'))
        want('item_urn_of_shadows', antiheal)
        local needsDispel = s.hero.rooted or s.hero.silenced
        for _, a in ipairs(s.allies or {}) do
            if valid(a) and (a.rooted or a.silenced) then needsDispel = true end
        end
        want('item_glimmer_cape', pressure > 0 or s.role == 5)
        want('item_force_staff')
        want('item_spirit_vessel', antiheal)
        want('item_lotus_orb', needsDispel)
        want('item_glimmer_cape')
        want('item_black_king_bar', pressure >= 2 or (needsDispel and hurt(s.hero)))
        want('item_lotus_orb')
        -- Queue smoke only once core save tools are owned, with a grouped team.
        local grouped = 0
        for _, a in ipairs(s.allies or {}) do
            if valid(a) and distance(a, s.hero) < 1000 then grouped = grouped + 1 end
        end
        want('item_smoke_of_deceit', grouped >= 2)
        if wanted[1] then
            pending = wanted[1]
            pendingAt=now I.status='queued '..pending
            -- Record only a PROPOSAL, never assumed purchase success. No elapsed
            -- timeout advances/reissues it: that would overwrite a partially
            -- bought component queue. Completion is observed across inventory,
            -- stash and courier via ownedItems. CONTRACT has no quickbuy receipt;
            -- after a rejected queue proposal, the coordinator can call reset()
            -- to retry. Executor alone sets quickbuy; this is not auto-purchase.
            return { kind = 'quickbuy', itemName = pending,
                reason = 'support purchase goal; retain until ownership observed', priority = 5 }
        end
        return nil
    end

    function I.reset()
        pending, owner, lastTime = nil, nil, nil
        sidePending, restockedAt = nil, -math.huge
        starter,starterDone,pendingAt,retryAt,inheritedAt=nil,false,nil,nil,nil
        I.status='initializing'
    end
end
