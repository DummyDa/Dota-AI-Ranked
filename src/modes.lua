-- Snapshot-only support modes. Adapted rules (not engine orders) from OpenHyperAI:
-- FunLib/override_generic/mode_{laning,attack}_generic.lua: denies, partner
-- priority, creep aggro and helping allies; mode_rune_generic.lua: contest checks;
-- mode_ward_generic.lua + FunLib/aba_ward_utility.lua: typed wards and coverage;
-- FunLib/aba_site.lua: camp types and late-minute stacking; FunLib/aba_{push,
-- defend}.lua: local strength and creep cover; mode_assemble_generic.lua:
-- bounded grouping; mode_{roshan,side_shop,outpost}_generic.lua: team support.
-- Camp routing below is original: observed boxes/aggro replace upstream fixed
-- coordinates. No last-seen enemies, global objective timers or spawn guesses.
return function(B)
    local M = {}
    B.modes = M
    local active, campJob, lastClock, lastAct, heroIndex
    local blocked = {}
    local lastLaneHit = -math.huge
    local EMPTY = {}

    local function number(n)
        return type(n) == 'number' and n == n and math.abs(n) < math.huge
    end
    local function position(p)
        return type(p) == 'table' and number(p.x) and number(p.y)
            and (p.x ~= 0 or p.y ~= 0)
    end
    local function distance(a, b)
        if not position(a) or not position(b) then return math.huge end
        return B.dist(a, b)
    end
    local function alive(u)
        return u and u.alive == true and position(u.pos)
    end
    local function observed(u)
        return alive(u) and u.visible == true
    end
    local function hp(u)
        if number(u.hpPct) then return u.hpPct end
        if number(u.hp) and number(u.maxHp) and u.maxHp > 0 then return u.hp / u.maxHp end
        return 0
    end
    local function attackable(u)
        return observed(u) and not u.invulnerable and not u.attackImmune
    end
    local function enemy(s, u)
        return observed(u) and u.team ~= nil and u.team ~= s.hero.team
    end
    local function realAlly(s, u)
        return alive(u) and u.team == s.hero.team and not u.illusion
    end
    local function targeting(u, v)
        return v and v.index ~= nil and u.attackTarget == v.index
    end
    local function clock(s) return number(s.now) and s.now or s.time end
    local function gameTime(s) return number(s.time) and s.time or s.now end
    local function isLane(s) return gameTime(s) <= ((B.config or EMPTY).laningEnd or 600) end
    local function find(list, index)
        if index == nil then return nil end
        for _, u in pairs(list or EMPTY) do if u.index == index then return u end end
    end
    local function key(name, u, p)
        if u and u.index ~= nil then return name .. ':' .. tostring(u.index) end
        if position(p) then return name .. ':' .. math.floor(p.x) .. ':' .. math.floor(p.y) end
        return name
    end
    local function clearActive(s)
        if campJob and s then blocked[campJob.key] = clock(s) + 12 end
        active, campJob, lastAct = nil, nil, nil
    end
    function M.reset()
        active, campJob, lastClock, lastAct, heroIndex = nil, nil, nil, nil, nil
        blocked, lastLaneHit = {}, -math.huge
        if B.support then B.support.reset() end
    end
    local function sync(s)
        if not s or not s.hero or not number(clock(s)) or not number(gameTime(s)) then
            M.reset()
            return false
        end
        local now = clock(s)
        if (lastClock and now < lastClock) or (heroIndex and heroIndex ~= s.hero.index) then M.reset() end
        heroIndex, lastClock = s.hero.index, now
        for k, expiry in pairs(blocked) do if expiry <= now then blocked[k] = nil end end
        if not alive(s.hero) or s.hero.team == nil or s.hero.illusion then clearActive(s); return false end
        -- Hooks give immediate invalidation; this also expires state if a caller
        -- stops invoking act (OFF, another action, a pause or a channel).
        if lastAct and now - lastAct > 1.5 then clearActive(s) end
        if s.hero.channeling or s.hero.casting or s.hero.stunned then clearActive(s) end
        if campJob and now >= campJob.deadline then clearActive(s) end
        return true
    end
    local function strength(s, p, ratio)
        if not B.threat or not B.threat.balance then return false end
        local friendly, hostile = B.threat.balance(s, p, 1200)
        if number(friendly) and distance(s.hero.pos,p)>1200 then friendly=friendly+0.5+hp(s.hero)*0.5 end
        return number(friendly) and number(hostile) and friendly > 0 and friendly >= hostile * (ratio or 1.15)
    end
    local function towerDanger(s, p)
        for _, t in pairs(s.towers or EMPTY) do
            if enemy(s, t) and distance(p, t.pos) < (t.range or 700) + 170 then return true end
        end
        return false
    end
    local function safe(s, p, ratio, allowTower)
        if not position(p) or not strength(s, p, ratio) then return false end
        if not allowTower and towerDanger(s, p) then return false end
        -- Threat has no prescribed scale. Compare with the current location;
        -- strength and explicit tower/contest checks supply absolute guards.
        if B.threat.at then
            local there, here = B.threat.at(s, p), B.threat.at(s, s.hero.pos)
            local allowance=allowTower and 6 or 2.2
            if not number(there) or not number(here) or there>math.max(allowance,here+0.35) then return false end
        end
        return true
    end
    local function routeSafe(s, p, allowTower)
        return safe(s, p, 1.15, allowTower)
            and safe(s, B.toward(s.hero.pos, p, distance(s.hero.pos, p) * 0.5), 1.15, allowTower)
    end
    local function enemiesNear(s, p, r)
        local count = 0
        for _, e in pairs(s.enemies or EMPTY) do
            if enemy(s, e) and not e.illusion and distance(e.pos, p) <= r then count = count + 1 end
        end
        return count
    end
    local function quiet(s, p)
        return hp(s.hero) >= 0.5 and (s.hero.recentDamage or 0) <= 8
            and enemiesNear(s, s.hero.pos, 1000) == 0 and enemiesNear(s, p, 1100) == 0
            and routeSafe(s, p)
    end
    local function move(s, p, reason, allowTower)
        if not position(p) or not routeSafe(s, p, allowTower) then return nil end
        if distance(s.hero.pos, p) <= 85 then return {kind = 'hold', reason = reason} end
        if s.hero.rooted then return nil end
        return {kind = 'move', pos = p, reason = reason, allowTower = allowTower}
    end
    local function attack(s, u, reason, chase, allowTower)
        if not attackable(u) or s.hero.disarmed or not number(s.hero.range) then return nil end
        local d = distance(s.hero.pos, u.pos)
        if d > s.hero.range + 35 then
            if not chase or d > chase then return nil end
            return move(s, B.toward(u.pos, s.hero.pos, math.max(80, s.hero.range - 30)), reason, allowTower)
        end
        if not safe(s, s.hero.pos, 1.05, allowTower) then return nil end
        return {kind = 'attack', target = u, reason = reason, allowTower = allowTower}
    end
    local function offer(out, s, name, desire, intent, target, p, explicitKey)
        if not intent then return end
        local k = explicitKey or key(name, target, p)
        if blocked[k] then return end
        out[#out + 1] = {name = name, desire = desire, reason = intent.reason,
            target = target, pos = p or intent.pos, intent = intent, key = k}
    end
    local function core(s)
        if realAlly(s, s.core) then return s.core end
    end
    local function rear(s, anchor, spacing)
        if not position(anchor) then return nil end
        local away, nearest = nil, math.huge
        for _, e in pairs(s.enemies or EMPTY) do
            if enemy(s, e) and distance(anchor, e.pos) < nearest then away, nearest = e.pos, distance(anchor, e.pos) end
        end
        if away and nearest < 1800 and nearest > 1 then
            return B.add(anchor, B.scale(B.norm(B.sub(anchor, away)), spacing))
        end
        local t = B.map and B.map.friendlyTower and B.map.friendlyTower(s, s.lane)
        if alive(t) and distance(anchor, t.pos) > 150 then return B.toward(anchor, t.pos, spacing) end
        if distance(anchor, s.hero.pos) > 1 then return B.toward(anchor, s.hero.pos, spacing) end
        return anchor
    end

    -- Protection proposes an actual peel attack or an approach to attack range.
    -- Hero/item modules may replace it with a disable/save using the same target.
    local function combat(out, s)
        if B.support and isLane(s) then return end -- bounded lane trades live in support.lua
        local c = core(s)
        for _, e in pairs(s.enemies or EMPTY) do
            if enemy(s, e) and not e.illusion and attackable(e)
                and B.threat and B.threat.safeEngage and B.threat.safeEngage(s, e) then
                local protecting = c and distance(s.hero.pos, c.pos) < 1600
                    and (targeting(e, c) or (distance(e.pos, c.pos) < 500
                        and (c.recentDamage or 0) > 20))
                if protecting then
                    offer(out, s, 'protect_core', 0.84, attack(s, e, 'Peel the visible attacker off our core', 1300), e)
                end
                local engaged = targeting(e, s.hero)
                for _, a in pairs(s.allies or EMPTY) do
                    if realAlly(s, a) and distance(a.pos, e.pos) < 1000
                        and (targeting(a, e) or targeting(e, a) or
                            (a.attacking and distance(a.pos,e.pos)<(a.range or 150)+90 and (e.recentDamage or 0)>10)) then engaged = true end
                end
                if engaged and hp(s.hero) >= 0.4 then
                    offer(out, s, 'fight', 0.65, attack(s, e, 'Assist the nearby fight', 1100), e)
                elseif hp(s.hero) >= 0.6 and (s.hero.recentDamage or 0) <= 8 then
                    local aggro = 0
                    for _, creep in pairs(s.creeps or EMPTY) do
                        if enemy(s, creep) and distance(creep.pos, s.hero.pos) < 600 then aggro = aggro + 1 end
                    end
                    if aggro <= 1 then
                        offer(out, s, 'harass', 0.39, attack(s, e, 'Take a short low-aggro trade', (s.hero.range or 0) + 100), e)
                    end
                end
            end
        end
    end
    local function hitDelay(u, target)
        if not number(u.attackPoint) or not number(u.range) then return nil end
        local delay = u.attackPoint
        if u.range > 250 then
            if not number(u.projectileSpeed) or u.projectileSpeed <= 0 then return nil end
            delay = delay + distance(u.pos, target.pos) / u.projectileSpeed
        end
        return delay
    end
    local function canLastHit(s, u)
        local h = s.hero
        if not number(u.hp) or not number(u.armorFactor) or not number(h.damage) then return false end
        local delay = hitDelay(h, u)
        if not delay or distance(h.pos, u.pos) > (h.range or 0) + 20 then return false end
        local loss = math.max(0, u.healthLossRate or 0)
        -- Avoid speculative future last hits: already killable and still alive
        -- at impact under the observed health trend, with a damage margin.
        return u.hp <= h.damage * u.armorFactor * 0.9 and u.hp - loss * delay > 1
    end
    local function coreCanTake(s, u)
        local candidates = {}
        if core(s) then candidates[#candidates + 1] = s.core end
        for _, a in pairs(s.allies or EMPTY) do
            if realAlly(s, a) and (a.role == nil or a.role <= 3) then candidates[#candidates + 1] = a end
        end
        for _, a in ipairs(candidates) do
            if targeting(a, u) then return true end -- includes an attack already in flight
            if distance(a.pos, u.pos) < 1100 and not a.stunned and not a.disarmed then
                if not number(a.range) or not number(a.moveSpeed) or a.moveSpeed <= 0 then return true end
                local delay = hitDelay(a, u)
                if not delay then return true end
                local travel = math.max(0, distance(a.pos, u.pos) - a.range) / a.moveSpeed
                if a.rooted and travel > 0 then travel = math.huge end
                local loss = u.healthLossRate or 0
                if loss <= 0 or (u.hp or math.huge) / loss > travel + delay then return true end
            end
        end
        return false
    end
    M.coreCanTake=coreCanTake
    local function lane(out, s)
        if not isLane(s) then return end
        for _, u in pairs(s.creeps or EMPTY) do
            if attackable(u) and canLastHit(s, u) then
                if u.team == s.hero.team and hp(u) < 0.49 then
                    offer(out, s, 'deny', 0.52, attack(s, u, 'Deny a killable allied creep'), u)
                elseif enemy(s, u) and clock(s) - lastLaneHit >= 8 and not coreCanTake(s, u)
                    and enemiesNear(s, s.hero.pos, 800) == 0 then
                    offer(out, s, 'last_hit', 0.35, attack(s, u, 'Salvage a safe last hit unavailable to a core'), u)
                end
            end
        end
        local c = core(s)
        if c and B.map.coreOnLane and not B.map.coreOnLane(s,c) then c=nil end
        local anchor = c and c.pos or (B.map and B.map.lanePoint and B.map.lanePoint(s, s.lane))
        local p = c and rear(s,anchor,s.role==5 and 280 or 220) or anchor
        offer(out, s, 'lane', 0.24, move(s, p, 'Position behind the lane partner or lane front'), c, p, 'lane')
    end
    local function runes(out, s)
        for _, r in pairs(s.runes or EMPTY) do
            local d = distance(s.hero.pos, r.pos)
            if r.handle and r.index ~= nil and type(r.type)=='number' and r.type>=0 and d < 1800 and quiet(s, r.pos) then
                local claimed = false
                for _, a in pairs(s.allies or EMPTY) do
                    if realAlly(s, a) and distance(a.pos, r.pos) + 150 < d then claimed = true end
                end
                if not claimed then
                    local intent = d <= 180 and {kind = 'rune', target = r, reason = 'Collect an observed uncontested rune'}
                        or move(s, r.pos, 'Approach the observed rune')
                    offer(out, s, 'rune', 0.43 - d / 18000, intent, r)
                end
            end
        end
    end
    local function wardKind(w)
        if w.name == 'npc_dota_observer_wards' then return 'observer' end
        if w.name == 'npc_dota_sentry_wards' then return 'sentry' end
    end
    local function coverage(s, p, kind, radius)
        for _, w in pairs(s.wards or EMPTY) do
            if alive(w) and w.team == s.hero.team and wardKind(w) == kind and distance(p, w.pos) < radius then return true end
        end
        return false
    end
    local function wardItem(s, kind)
        local items = s.items or EMPTY
        local direct = items['item_ward_' .. kind]
        if direct and direct.castable and (direct.charges or 0) > 0 then return direct end
        local both = items.item_ward_dispenser
        -- Neither selected mode nor charge mapping is verified in this adapter.
        if both and B.log then B.log('modes.dispenser', 'Ward dispenser disabled: selection and charge mapping are unverified', 60) end
        return nil
    end
    local function plant(out, s, p, kind, desire)
        local item = wardItem(s, kind)
        if not item or not number(item.range) or distance(s.hero.pos, p) > 2200 or not quiet(s, p)
            or coverage(s, p, kind, kind == 'observer' and 1300 or 850) then return end
        local intent
        if distance(s.hero.pos, p) <= item.range then
            intent = {kind = 'cast', ability = item, castType = 'position', pos = p,
                wardType = kind, itemName = item.name, reason = 'Place ' .. kind .. ' vision'}
        else
            -- Ward cliffs need not be walkable. Approach from this side only.
            intent = move(s, B.toward(p, s.hero.pos, math.max(100, item.range - 60)), 'Approach ' .. kind .. ' cast range')
        end
        offer(out, s, kind == 'sentry' and 'deward' or 'ward', desire, intent, nil, p, key('ward_' .. kind, nil, p))
    end
    local function wards(out, s)
        for _, w in pairs(s.wards or EMPTY) do
            if enemy(s, w) and wardKind(w) and quiet(s, w.pos) then
                offer(out, s, 'deward', 0.49, attack(s, w, 'Destroy a revealed enemy ward', 950), w)
                -- Only observed enemy wards justify a sentry, never hidden handles.
                if distance(s.hero.pos, w.pos) > (s.hero.range or 0) + 35 then plant(out, s, w.pos, 'sentry', 0.42) end
            end
        end
        if B.map and B.map.wardSpots then
            for _, spot in pairs(B.map.wardSpots(s) or EMPTY) do
                local p = spot.pos or spot
                local kind = spot.wardType or 'observer'
                if kind == 'observer' or kind == 'sentry' then plant(out, s, p, kind, 0.34) end
            end
        end
    end

    local function inBox(p, box, margin)
        margin = margin or 0
        return position(p) and box and position(box.min) and position(box.max)
            and p.x >= box.min.x - margin and p.x <= box.max.x + margin
            and p.y >= box.min.y - margin and p.y <= box.max.y + margin
    end
    local function validCamp(c)
        return c and c.index ~= nil and position(c.pos) and c.box
            and position(c.box.min) and position(c.box.max)
            and c.box.max.x > c.box.min.x and c.box.max.y > c.box.min.y
            and inBox(c.pos, c.box) and (c.type == 'small' or c.type == 'medium' or c.type == 'large')
    end
    local function campExit(s, c, toward)
        if not position(toward) or distance(c.pos, toward) < 1 then return nil end
        local dir = B.norm(B.sub(toward, c.pos))
        local tx, ty = math.huge, math.huge
        if math.abs(dir.x) > 0.001 then tx = ((dir.x > 0 and c.box.max.x or c.box.min.x) - c.pos.x) / dir.x end
        if math.abs(dir.y) > 0.001 then ty = ((dir.y > 0 and c.box.max.y or c.box.min.y) - c.pos.y) / dir.y end
        local p = B.add(c.pos, B.scale(dir, math.min(tx, ty) + 450))
        if not inBox(p, c.box, 150) and routeSafe(s, p) then return p end
    end
    local function campUnits(s, c)
        local list = {}
        for _, u in pairs(s.neutrals or EMPTY) do
            if attackable(u) and inBox(u.pos, c.box, 30) then list[#list + 1] = u end
        end
        return list
    end
    local function pullWave(s, c)
        local best, d = nil, 1000
        for _, u in pairs(s.creeps or EMPTY) do
            if alive(u) and u.team == s.hero.team and not u.attacking and not inBox(u.pos, c.box, 150)
                and distance(u.pos, c.pos) < d then best, d = u, distance(u.pos, c.pos) end
        end
        return best
    end
    local function campProposal(s, advance)
        local job = campJob
        if not job then return nil end
        local c = find(s.camps, job.camp)
        local u = find(s.neutrals, job.neutral)
        if not validCamp(c) or not observed(u) or hp(s.hero) < 0.6
            or enemiesNear(s, c.pos, 1100) > 0 or enemiesNear(s, s.hero.pos, 1000) > 0
            or not routeSafe(s, job.exit) then return nil end
        local now = clock(s)
        local phase = job.phase
        local aggro = targeting(u, s.hero) or (u.velocity and
            distance(u.pos,s.hero.pos)<850 and (u.velocity.x*(s.hero.pos.x-u.pos.x)+u.velocity.y*(s.hero.pos.y-u.pos.y))>20000)
        if phase == 'approach' and distance(s.hero.pos, u.pos) <= (s.hero.range or 0) + 35 then
            phase = 'aggro'
            if advance then job.phase, job.phaseAt = phase, now end
        end
        if phase == 'approach' then
            return move(s, B.toward(u.pos, s.hero.pos, math.max(80, (s.hero.range or 150) - 25)), 'Approach the observed camp')
        end
        if phase == 'aggro' then
            if aggro then
                phase = 'drag'
                if advance then job.phase, job.phaseAt = phase, now end
            else
                if now - job.phaseAt > 2.5 or gameTime(s) > job.latestAggro then
                    if B.log then B.log('modes.camp_aggro', 'Camp attempt expired without observed neutral aggro', 30) end
                    return nil
                end
                return attack(s, u, 'Draw neutral aggro before dragging', 750)
            end
        end
        if phase == 'drag' or phase == 'clear' then
            if job.name == 'pull' then
                local wave = find(s.creeps, job.wave)
                if not alive(wave) then return nil end
                if targeting(u, wave) or targeting(wave, u) then return nil end -- observed handoff completes the pull
            end
            -- No presumed success from an issued attack. Losing observed aggro
            -- aborts the job; do not run to an old exit or re-aggro indefinitely.
            if not aggro then return nil end
            local allOutside = not inBox(s.hero.pos, c.box, 80)
            for _, id in ipairs(job.members) do
                local n = find(s.neutrals, id)
                if not observed(n) or inBox(n.pos, c.box, 80) then allOutside = false end
            end
            if job.name == 'stack' and gameTime(s) >= job.spawnAt + 0.5 then return nil end
            if job.name == 'stack' and allOutside then
                if advance then job.phase = 'clear' end
                return move(s, job.exit, 'Keep the hero and observed neutrals outside the spawn box')
            end
            return move(s, job.exit, 'Lead aggroed neutrals outside the camp box')
        end
    end
    local function camps(out, s)
        if campJob then
            offer(out, s, campJob.name, 0.47, campProposal(s, false), nil, campJob.exit, campJob.key)
            return
        end
        if not number(s.hero.moveSpeed) or s.hero.moveSpeed <= 0 or not number(s.hero.range)
            or not number(s.hero.attackPoint) or s.hero.disarmed or hp(s.hero) < 0.65 then return end
        local t = gameTime(s)
        if t < 60 then return end
        local sec = t % 60
        for _, c in pairs(s.camps or EMPTY) do
            if validCamp(c) and distance(s.hero.pos, c.pos) < 1000 and quiet(s, c.pos) then
                local units = campUnits(s, c)
                local u = units[1]
                local free = u and u.index ~= nil
                for _, n in ipairs(units) do if n.attackTarget ~= nil then free = false end end
                if free then
                    local name, exit, wave, latest, spawnAt
                    if sec >= 48 and sec <= 55 then
                        exit = campExit(s, c, s.hero.pos)
                        local travel = exit and distance(c.pos, exit) / math.max(1, u.moveSpeed or 0)
                        if number(u.moveSpeed) and travel and travel < 8 then
                            local tagAt = math.floor(t / 60) * 60 + 60 - travel - 1.5
                            local approach = math.max(0, distance(s.hero.pos, u.pos) - s.hero.range) / s.hero.moveSpeed
                            local delay = hitDelay(s.hero, u)
                            if delay and t + approach + delay >= tagAt - 1 and t + approach + delay <= tagAt + 0.7 then
                                name, latest, spawnAt = 'stack', tagAt + 1, math.floor(t / 60) * 60 + 60
                            end
                        end
                    elseif isLane(s) and c.type == 'small' and ((sec >= 12 and sec <= 19) or (sec >= 42 and sec <= 47)) then
                        wave = pullWave(s, c)
                        local partner = core(s)
                        local tower = B.map and B.map.friendlyTower and B.map.friendlyTower(s, s.lane)
                        -- Pull only an advanced lane, with a healthy unpressured
                        -- partner nearby; real wave position decides the route.
                        if wave and partner and hp(partner) > 0.65 and distance(partner.pos, c.pos) < 1800
                            and (partner.recentDamage or 0) <= 8 and enemiesNear(s, partner.pos, 1000) == 0
                            and alive(tower) and distance(partner.pos, tower.pos) > 1300 then
                            exit = campExit(s, c, wave.pos)
                            if exit and distance(exit, wave.pos) < 550 then name, latest = 'pull', t + 3 end
                        end
                    end
                    if name and exit then
                        local k = key(name, c)
                        local intent = attack(s, u, 'Approach and tag the camp for a ' .. name, 1000)
                        offer(out, s, name, 0.41, intent, u, exit, k)
                        local candidate = out[#out]
                        if candidate and candidate.key == k then
                            local members = {}
                            for _, n in ipairs(units) do if n.index ~= nil then members[#members + 1] = n.index end end
                            candidate._camp = {name = name, key = k, camp = c.index, neutral = u.index,
                                wave = wave and wave.index, exit = exit, members = members, phase = 'approach',
                                phaseAt = clock(s), deadline = clock(s) + 13, latestAggro = latest, spawnAt = spawnAt}
                        end
                    end
                end
            end
        end
    end

    local function grouping(out, s)
        if isLane(s) then return end
        for _, a in pairs(s.allies or EMPTY) do
            if realAlly(s, a) and hp(a) > 0.45 then
                local count = 0
                for _, other in pairs(s.allies or EMPTY) do
                    if realAlly(s, other) and distance(other.pos, a.pos) < 1000 then count = count + 1 end
                end
                if count >= 2 or (core(s) and a.index == s.core.index) then
                    local p = rear(s, a.pos, 320)
                    local desire = distance(s.hero.pos, p) > 600 and 0.30 or 0.12
                    offer(out, s, 'group', desire, move(s, p, 'Stay in support range of the allied group'), a, p)
                end
            end
        end
    end
    local function buildings(out, s)
        for _, t in pairs(s.towers or EMPTY) do
            if observed(t) and distance(s.hero.pos, t.pos) < 2200 then
                if t.team == s.hero.team then
                    for _, u in pairs(s.enemies or EMPTY) do
                        if enemy(s, u) and not u.illusion and distance(u.pos, t.pos) < 950
                            and B.threat.safeEngage(s, u) then
                            offer(out, s, 'defend', 0.70, attack(s, u, 'Help defend the allied tower', 1300), u)
                        end
                    end
                    for _, u in pairs(s.creeps or EMPTY) do
                        if enemy(s, u) and distance(u.pos, t.pos) < 800
                            and (not isLane(s) or (canLastHit(s,u) and not coreCanTake(s,u))) then
                            offer(out, s, 'defend', 0.48, attack(s, u, 'Clear the wave threatening the allied tower', 1000), u)
                        end
                    end
                elseif enemy(s, t) and attackable(t) and not isLane(s) and hp(s.hero) > 0.6 then
                    local cover, allies = 0, 0
                    for _, u in pairs(s.creeps or EMPTY) do
                        if alive(u) and u.team == s.hero.team and hp(u) > 0.35
                            and distance(u.pos, t.pos) < (t.range or 700) then cover = cover + 1 end
                    end
                    for _, a in pairs(s.allies or EMPTY) do
                        if realAlly(s, a) and hp(a) > 0.5 and distance(a.pos, t.pos) < 1000 then allies = allies + 1 end
                    end
                    local tank = find(s.creeps, t.attackTarget)
                    if cover >= 3 and allies >= 1 and alive(tank) and tank.team == s.hero.team and hp(tank) > 0.4
                        and strength(s, t.pos, 1.4) and enemiesNear(s, t.pos, 1400) == 0 then
                        offer(out, s, 'push', 0.38, attack(s, t, 'Hit the tower behind allied creep cover', 1300, true), t)
                    end
                end
            end
        end
    end
    local function objectives(out, s)
        local seen = {}
        for _, list in ipairs({s.objectives or EMPTY, s.neutrals or EMPTY, s.structures or EMPTY}) do
            for _, u in pairs(list) do
                if observed(u) and u.index ~= nil and not seen[u.index] then
                    seen[u.index] = true
                    local name = string.lower(u.name or '')
                    local boss = name == 'npc_dota_roshan' and 'roshan'
                        or ((name:find('tormentor', 1, true) or name == 'npc_dota_miniboss') and 'tormentor')
                    if boss and attackable(u) and distance(s.hero.pos, u.pos) < 1600
                        and hp(s.hero) >= (boss == 'tormentor' and 0.7 or 0.6) and quiet(s, u.pos) then
                        local count, cores, attacking, dps = 0, 0, 0, 0
                        for _, a in pairs(s.allies or EMPTY) do
                            if realAlly(s, a) and hp(a) >= 0.6 and distance(a.pos, u.pos) < 900 then
                                count = count + 1
                                if a.role and a.role <= 3 then cores = cores + 1 end
                                if a.attacking and (targeting(a,u) or (distance(a.pos,u.pos)<(a.range or 150)+120
                                    and (u.recentDamage or 0)>20)) then attacking = attacking + 1 end
                                if number(a.damage) and number(a.attackPeriod) and a.attackPeriod > 0 then dps = dps + a.damage / a.attackPeriod end
                            end
                        end
                        if count >= (boss == 'tormentor' and 3 or 2) and cores >= 1 and attacking >= 2
                            and dps >= (boss == 'tormentor' and 250 or 160) then
                            offer(out, s, boss, 0.53, attack(s, u, 'Assist the healthy team already attacking ' .. boss, 1400), u)
                        end
                    elseif name:find('outpost', 1, true) and B.log then
                        B.log('modes.outpost', 'Outpost interaction disabled: capture API is undocumented', 60)
                    end
                end
            end
        end
    end
    local function farm(out, s)
        if gameTime(s) <= 600 or hp(s.hero) < 0.6 then return end
        for _, u in pairs(s.creeps or EMPTY) do
            if enemy(s, u) and attackable(u) and distance(s.hero.pos, u.pos) < 1300 and quiet(s, u.pos) then
                local reserved = false
                for _, a in pairs(s.allies or EMPTY) do
                    if realAlly(s, a) and (a.role == nil or a.role <= 3) and distance(a.pos, u.pos) < 1500 then reserved = true end
                end
                if not reserved then offer(out, s, 'farm', 0.18, attack(s, u, 'Take spare lane farm away from allied cores', 1300), u) end
            end
        end
        for _,u in pairs(s.neutrals or EMPTY) do
            if attackable(u) and distance(s.hero.pos,u.pos)<850 and quiet(s,u.pos)
                and not u.name:find('ancient') and not u.name:find('roshan') and not u.name:find('miniboss') then
                local reserved=false
                for _,a in ipairs(s.allies or EMPTY) do
                    if realAlly(s,a) and (a.role==nil or a.role<=3) and distance(a.pos,u.pos)<1500 then reserved=true end
                end
                if not reserved then offer(out,s,'farm',0.15,attack(s,u,'Take a nearby spare neutral camp',850),u) end
            end
        end
        local p=B.map.lanePoint(s,B.map.classify(s.hero.pos))
        offer(out,s,'lane',0.06,move(s,p,'Return toward the nearest lane while no team task is available'),nil,p,'late_lane')
    end
    function M.candidates(s)
        local out = {}
        if not sync(s) then return out end
        if s.hero.channeling or s.hero.casting or s.hero.stunned then return out end
        if B.threat and B.threat.safety then
            local emergency = B.threat.safety(s)
            if emergency then clearActive(s); return {emergency} end
        end
        combat(out, s)
        lane(out, s)
        runes(out, s)
        wards(out, s)
        camps(out, s)
        grouping(out, s)
        buildings(out, s)
        objectives(out, s)
        farm(out, s)
        if B.support then for _,m in ipairs(B.support.candidates(s)) do out[#out+1]=m end end
        if #out == 0 then offer(out, s, 'idle', 0.01, {kind = 'hold', reason = 'No safe observed task'}, nil, nil, 'idle') end
        return out
    end
    -- Optional scheduler hooks: call onExit(s, oldMode) whenever any other
    -- subsystem preempts modes (including OFF/emergency), even within 1.5s.
    -- onEnter(s, newMode) is optional; act detects ordinary mode/key switches.
    function M.onExit(s, mode)
        clearActive(s)
    end
    function M.onEnter(s, mode)
        if not mode or not active or active.key ~= (mode.key or mode.name) then clearActive(s) end
    end
    function M.act(s, mode)
        if not sync(s) or not mode or type(mode.name) ~= 'string' then clearActive(s); return nil end
        local k = mode.key or mode.name
        if active and active.key ~= k then clearActive(s) end
        local selected
        -- Rebuild, never execute mode.intent from an earlier snapshot. Expired
        -- entities, changed ownership, lost cover and consumed runes disappear.
        for _, current in ipairs(M.candidates(s)) do
            if current.name == mode.name and (not mode.key or current.key == mode.key) then selected = current; break end
        end
        if not selected then clearActive(s); return nil end
        local now = clock(s)
        if not active then active = {key = k, since = now} end
        local limited = selected.name == 'ward' or selected.name == 'deward' or selected.name == 'rune' or selected.name == 'outpost'
        if limited and now - active.since > 14 then blocked[selected.key or k] = now + 10; clearActive(s); return nil end
        lastAct = now
        if selected._camp and not campJob then campJob = selected._camp end
        local intent = selected.intent
        if campJob then
            intent = campProposal(s, true)
            if not intent then clearActive(s); return nil end
        end
        if selected.name == 'last_hit' and intent and intent.kind == 'attack' then lastLaneHit = now end
        return intent
    end
end
