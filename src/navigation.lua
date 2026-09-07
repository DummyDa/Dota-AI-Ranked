return function(B)
    local N={route={},nextPlan=0} B.navigation=N
    function N.reset() N.route={} N.goal=nil N.nextPlan=0 end
    local function path(a,b)
        local raw=B.call('GridNav','BuildPath',nil,B.vec(a),B.vec(b),false)
        if type(raw)~='table' or #raw==0 then return nil end
        local out={}
        for _,p in ipairs(raw) do local q=B.pos(p) if q then out[#out+1]=q end end
        if #out==0 or B.dist(out[#out],b)>220 then return nil end
        return out
    end
    local function score(s,points,allowTower,escape)
        local cost,prev=0,s.hero.pos
        local initial=B.threat.at(s,prev)
        for _,p in ipairs(points) do
            local length=B.dist(prev,p)
            local count=math.max(1,math.ceil(length/180))
            for i=1,count do
                local q=B.add(prev,B.scale(B.sub(p,prev),i/count))
                local risk=B.threat.at(s,q)
                if not allowTower then
                    for _,t in ipairs(s.towers) do
                        if t.team~=s.hero.team and B.dist(t.pos,q)<t.range+130 then
                            if not escape or B.dist(t.pos,q)<B.dist(t.pos,s.hero.pos)-10 then return math.huge end
                        end
                    end
                end
                cost=cost+length/count*(1+risk*(escape and 0.5 or 1.7))
                if escape and risk>initial+2 then cost=cost+500 end
            end
            prev=p
        end
        return cost
    end
    function N.next(s,destination,allowTower,emergency)
        if not destination or B.dist(s.hero.pos,destination)<70 then N.route={} return nil end
        if s.now>=N.nextPlan or B.dist(destination,N.goal)>180 then
            N.nextPlan=s.now+0.65 N.goal=destination
            local best=path(s.hero.pos,destination)
            local bestScore=best and score(s,best,allowTower,emergency) or math.huge
            if bestScore==math.huge or bestScore>B.dist(s.hero.pos,destination)*2 then
                local dir=B.norm(B.sub(destination,s.hero.pos))
                for _,side in ipairs({-1,1}) do
                    local mid=B.add(B.toward(s.hero.pos,destination,math.min(700,B.dist(s.hero.pos,destination)*0.5)),{x=-dir.y*650*side,y=dir.x*650*side,z=0})
                    local first,second=path(s.hero.pos,mid),path(mid,destination)
                    if first and second then
                        for _,p in ipairs(second) do first[#first+1]=p end
                        local value=score(s,first,allowTower,emergency)
                        if value<bestScore then best,bestScore=first,value end
                    end
                end
            end
            N.route=bestScore<math.huge and best or {}
            if #N.route==0 then B.log('no_route','No safe path; destination deferred',5) end
        end
        while #N.route>0 and B.dist(s.hero.pos,N.route[1])<85 do table.remove(N.route,1) end
        local nextPoint=N.route[1]
        -- Re-evaluate the next segment even when using a cached path.
        if nextPoint and score(s,{nextPoint},allowTower,emergency)<math.huge then return nextPoint end
        return nil
    end
end
