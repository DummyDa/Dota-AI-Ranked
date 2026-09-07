return function(B)
    B.version = '0.1.6-charge-travel-farm'
    B.config = {laningEnd=600, decisionInterval=0.12, modeHold=1.2,
        externalEnabled=false, bridgeEnabled=false, botEnabled=true, debug=true,
        lowHpChargeThreshold=0.25}
    B.enabled = true
    -- Umbrella's sandbox omits _G. Capture only the documented API tables.
    B.libs={Entity=Entity,NPC=NPC,Hero=Hero,Heroes=Heroes,Players=Players,Player=Player,
        NPCs=NPCs,Ability=Ability,Item=Item,Modifier=Modifier,Tower=Tower,Runes=Runes,Rune=Rune,
        Camps=Camps,Camp=Camp,Couriers=Couriers,LinearProjectiles=LinearProjectiles,
        GridNav=GridNav,GameRules=GameRules,Engine=Engine}
    B.logs, B.capabilities = {}, {}
    function B.log(key, message, interval)
        local now = B.state and B.state.now or (os and os.clock and os.clock() or 0)
        if B.logs[key] and now - B.logs[key] < (interval or 5) then return end
        B.logs[key] = now
        local line = '[SpiritBreaker ' .. B.version .. '] ' .. tostring(message)
        if Log and Log.Write then pcall(Log.Write, line) else print(line) end
    end
    function B.call(lib, method, fallback, ...)
        local obj = B.libs[lib]
        if not obj or type(obj[method]) ~= 'function' then
            B.capabilities[lib .. '.' .. method] = false
            B.log('missing.'..lib..'.'..method,'Capability unavailable: '..lib..'.'..method,60)
            return fallback
        end
        local ok, value = pcall(obj[method], ...)
        B.capabilities[lib .. '.' .. method] = ok
        if not ok then B.log(lib .. '.' .. method, lib .. '.' .. method .. ': ' .. tostring(value), 30) end
        if ok and value ~= nil then return value end
        return fallback
    end
    function B.enum(group, name)
        return Enum and Enum[group] and Enum[group][name]
    end
    function B.flag(value, flag)
        return type(value)=='number' and type(flag)=='number' and flag>0 and value % (flag*2) >= flag
    end
    function B.inCastRange(a,d,margin)
        if not a or type(a.range)~='number' then return false end
        -- Charge is global: the shipped ability KV uses AbilityCastRange=0.
        -- Do not interpret every other zero-range ability as global.
        if a.name=='spirit_breaker_charge_of_darkness' and a.range==0 then return true end
        return a.range>0 and d<=a.range+(margin or 0)
    end
    function B.pos(v)
        if not v then return nil end
        local ok,p=pcall(function() return {x=v.x,y=v.y,z=v.z or 0} end)
        if ok and type(p.x)=='number' and type(p.y)=='number' and p.x==p.x and p.y==p.y
            and math.abs(p.x)<40000 and math.abs(p.y)<40000 then return p end
    end
    function B.vec(p) return Vector(p.x,p.y,p.z or 0) end
    function B.clamp(v,l,h) return math.max(l,math.min(h,v)) end
    function B.dist(a,b) if not a or not b then return math.huge end return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
    function B.add(a,b) return {x=a.x+b.x,y=a.y+b.y,z=(a.z or 0)+(b.z or 0)} end
    function B.sub(a,b) return {x=a.x-b.x,y=a.y-b.y,z=(a.z or 0)-(b.z or 0)} end
    function B.scale(a,n) return {x=a.x*n,y=a.y*n,z=(a.z or 0)*n} end
    function B.norm(a) local n=math.sqrt(a.x*a.x+a.y*a.y) if n<0.001 then return {x=0,y=0,z=0} end return B.scale(a,1/n) end
    function B.toward(a,b,d) return B.add(a,B.scale(B.norm(B.sub(b,a)),d)) end
    function B.has(u,m) return u and u.mods and u.mods[m] == true end
    function B.near(list,p,r) local out={} for _,u in pairs(list or {}) do if u.pos and B.dist(u.pos,p)<=r then out[#out+1]=u end end return out end
    function B.find(list,i) for _,u in pairs(list or {}) do if u.index==i then return u end end end
    function B.charging(s) return s and (B.has(s.hero,'modifier_spirit_breaker_charge_of_darkness') or
        (s.abilities.spirit_breaker_charge_of_darkness and s.abilities.spirit_breaker_charge_of_darkness.inPhase)) end
    B.script={}
end
