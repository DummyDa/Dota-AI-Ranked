return function(B)
    local M={} B.map=M
    function M.classify(p)
        if math.abs(p.x-p.y)<1400 then return 'mid' end
        return p.y>p.x and 'top' or 'bot'
    end
    function M.home(s)
        for _,u in ipairs(s.structures) do if u.team==s.hero.team and u.name:find('fountain') then return u.pos end end
        -- Static map geometry is public information; never a target at origin.
        return s.hero.team==2 and {x=-7100,y=-6600,z=512} or {x=6900,y=6400,z=512}
    end
    function M.friendlyTower(s,lane)
        local best,score=nil,math.huge
        for _,t in ipairs(s.towers) do
            if t.team==s.hero.team and t.alive and (not lane or M.towerLane(t)==lane) then
                local d=B.dist(s.hero.pos,t.pos)
                if d<score then score=d best=t end
            end
        end
        return best
    end
    function M.towerLane(t)
        return (t.name or ''):match('_tower%d+_(%a+)$') or M.classify(t.pos)
    end
    function M.laneTower(s,lane)
        local best,rank=nil,math.huge
        for _,t in ipairs(s.towers) do
            if t.team==s.hero.team and t.alive and M.towerLane(t)==lane then
                local tier=tonumber((t.name or ''):match('_tower(%d+)_'))
                -- Outer surviving tower, never the nearest tower to the hero.
                local r=tier and tier*100000 or 900000-B.dist(t.pos,M.home(s))
                if r<rank then best,rank=t,r end
            end
        end
        return best
    end
    function M.coreOnLane(s,c)
        return c and c.alive and B.dist(c.pos,M.home(s))>3500
            and M.classify(c.pos)==s.lane
    end
    function M.lanePoint(s,lane)
        lane=lane or s.lane
        local tower=M.laneTower(s,lane)
        local home=M.home(s)
        local baseline=tower and B.dist(tower.pos,home) or 3500
        local best,score=nil,-math.huge
        for _,c in ipairs(s.creeps) do
            if c.team==s.hero.team and c.alive and M.classify(c.pos)==lane then
                local progress=B.dist(c.pos,home)
                -- Fresh waves at the base cannot pull the bot backwards.
                if progress>math.max(3500,baseline-300) and progress>score then score=progress best=c end
            end
        end
        if best then return B.toward(best.pos,M.home(s),420) end
        if tower and (tonumber((tower.name or ''):match('_tower(%d+)_')) or 3)<3 then
            return B.toward(tower.pos,home,180)
        end
        local radiant=s.hero.team==2
        local points=radiant and {top={x=-5700,y=2200,z=256},mid={x=-1700,y=-1400,z=256},bot={x=2500,y=-5800,z=256}}
            or {top={x=-2400,y=5800,z=256},mid={x=1700,y=1400,z=256},bot={x=5700,y=-2000,z=256}}
        return points[lane] or points.mid
    end
    -- Candidate coordinates adapted from OpenHyperAI FunLib/aba_ward_utility.lua (MIT).
    -- Placements still require a safe approach and an available standalone observer.
    function M.wardSpots(s)
        local spots=s.hero.team==2 and {
            {x=-2606,y=1702,z=256},{x=1067,y=-2554,z=256},{x=1824,y=-3358,z=256},{x=-3311,y=4315,z=256},
            {x=5365,y=-4870,z=256},{x=5870,y=-7174,z=256},{x=-6309,y=5671,z=256}}
            or {{x=2255,y=-1892,z=256},{x=-416,y=224,z=256},{x=3097,y=-4069,z=256},{x=-6726,y=3244,z=256},
                {x=-6309,y=5671,z=256},{x=5365,y=-4870,z=256}}
        local out={}
        for _,p in ipairs(spots) do out[#out+1]={pos=p,lane=M.classify(p)} end
        return out
    end
end
