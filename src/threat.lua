return function(B)
    local T={} B.threat=T
    local function strength(u) return (0.4+u.hpPct*0.6)*(1+u.level*0.07) end
    function T.balance(s,p,r)
        local ally=B.dist(s.hero.pos,p)<=r and strength(s.hero) or 0
        local enemy=0
        for _,u in ipairs(B.near(s.allies,p,r)) do if u.alive then ally=ally+strength(u) end end
        for _,u in ipairs(B.near(s.enemies,p,r)) do if u.alive then enemy=enemy+strength(u) end end
        -- A friendly tower changes a short defensive trade, not distant fights.
        for _,t in ipairs(s.towers) do
            if t.alive and t.team==s.hero.team and B.dist(t.pos,p)<t.range then ally=ally+0.75 end
        end
        return ally,enemy
    end
    function T.at(s,p)
        local risk=0
        for _,t in ipairs(s.towers) do
            if t.team~=s.hero.team and t.alive and B.dist(t.pos,p)<t.range+160 then risk=risk+5 end
        end
        local a,e=T.balance(s,p,1100)
        risk=risk+math.max(0,e-a)*2
        for _,eUnit in ipairs(s.enemies) do
            if B.dist(p,eUnit.pos)<eUnit.range+200 then risk=risk+0.65 end
        end
        for _,c in ipairs(s.creeps) do
            if c.team~=s.hero.team and B.dist(p,c.pos)<c.range+100 then risk=risk+(s.time<600 and 0.28 or 0.08) end
        end
        -- Unseen route portions are uncertain, never treated as confirmed empty.
        local lit=B.dist(s.hero.pos,p)<650
        for _,u in ipairs(s.allies) do if u.alive and B.dist(u.pos,p)<650 then lit=true end end
        for _,u in ipairs(s.creeps) do if u.team==s.hero.team and B.dist(u.pos,p)<450 then lit=true end end
        if not lit then risk=risk+0.45 end
        return risk
    end
    function T.safeEngage(s,target)
        if not target or not target.alive or not target.visible or target.invulnerable then return false end
        if s.hero.hpPct<0.43 then return false end
        local a,e=T.balance(s,target.pos,1150)
        -- Do not count an arriving long-distance Charge as a full healthy ally twice.
        if B.dist(s.hero.pos,target.pos)>1150 then a=a+strength(s.hero)*0.75 end
        if e>a*1.08 then return false end
        for _,t in ipairs(s.towers) do
            if t.team~=s.hero.team and B.dist(t.pos,target.pos)<t.range+220 then return false end
        end
        local supporting=0
        for _,u in ipairs(B.near(s.allies,target.pos,900)) do if u.alive and u.hpPct>0.4 then supporting=supporting+1 end end
        -- Several enemies in a matched team fight are not equivalent to being
        -- surrounded alone; numerical/health balance and tower checks still apply.
        return T.at(s,target.pos)<3+math.min(1.5,supporting*0.4)
    end
    function T.retreat(s)
        local origin=s.hero.pos
        local choices={B.toward(origin,B.map.home(s),650)}
        for _,a in ipairs(s.allies) do if a.alive and a.hpPct>0.5 and B.dist(a.pos,origin)<2200 then choices[#choices+1]=B.toward(origin,a.pos,550) end end
        for i=0,7 do local angle=i*math.pi/4 choices[#choices+1]={x=origin.x+math.cos(angle)*650,y=origin.y+math.sin(angle)*650,z=origin.z} end
        local best,score=choices[1],math.huge
        for _,p in ipairs(choices) do
            local walk=B.call('GridNav','IsTraversable',false,B.vec(p))
            if walk then
                local n=T.at(s,p)*1000+B.dist(p,B.map.home(s))*0.02
                for _,t in ipairs(s.towers) do if t.attackTarget==s.hero.index and t.team~=s.hero.team then n=n+math.max(0,t.range+220-B.dist(t.pos,p))*10 end end
                if n<score then best,score=p,n end
            end
        end
        return best
    end
    function T.safety(s)
        if not s.hero.alive then return nil end
        local reason
        for _,t in ipairs(s.towers) do
            if t.team~=s.hero.team and t.attackTarget==s.hero.index and B.dist(t.pos,s.hero.pos)<t.range+300 then reason='Enemy tower targeting hero' break end
        end
        local aggro=0
        for _,c in ipairs(s.creeps) do
            if c.team~=s.hero.team and c.alive and (c.attackTarget==s.hero.index or
                (c.attacking and B.dist(c.pos,s.hero.pos)<c.range+65 and s.hero.recentDamage>20)) then aggro=aggro+1 end
        end
        if s.time<600 and aggro>=3 then reason='Early creep aggro: '..aggro end
        local a,e=T.balance(s,s.hero.pos,900)
        if (s.hero.hpPct<0.27 and e>0) or (e>a*1.55 and s.hero.hpPct<0.65) then reason='Outnumbered / low health' end
        if s.hero.recentDamage>s.hero.maxHp*0.25 and e>0 then reason='Heavy recent damage' end
        if reason then return {name='SAFETY',desire=1.5,reason=reason,pos=T.retreat(s),emergency=true} end
    end
end
