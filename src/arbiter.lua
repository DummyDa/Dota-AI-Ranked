return function(B)
    local A={desires={},since=0} B.arbiter=A
    function A.reset() A.active=nil A.desires={} A.since=0 A.recover=false B.modes.reset() end
    function A.choose(s,emergency)
        local candidates=emergency and {emergency} or B.modes.candidates(s)
        if not emergency then
            if s.hero.hpPct<0.3 or (s.hero.hpPct<0.55 and s.hero.manaPct<0.12) then A.recover=true end
            if s.hero.hpPct>0.82 and s.hero.manaPct>0.55 then A.recover=false end
            if A.recover then candidates[#candidates+1]={name='retreat',key='recover',desire=0.95,
                pos=B.map.home(s),reason='Recover health and mana at base'} end
            local external=B.api and B.api.candidate(s)
            if external then candidates[#candidates+1]=external end
        end
        local best,current
        A.desires={}
        for _,m in ipairs(candidates) do
            m.key=m.key or m.name
            A.desires[m.name]=math.max(A.desires[m.name] or 0,m.desire)
            if not best or m.desire>best.desire then best=m end
            if A.active and m.key==A.active.key then current=m end
        end
        if current and best and not emergency and best.desire<0.84 then
            if s.now-A.since<B.config.modeHold or best.desire<current.desire+0.09 then best=current end
        end
        if not best then best={name='idle',key='idle',desire=0,reason='Waiting for a safe task'} end
        if not A.active or A.active.key~=best.key then
            if A.active then B.modes.onExit(s,A.active) end
            A.since=s.now
            B.log('mode.'..best.key,best.name..': '..best.reason,1)
        end
        A.active=best
        return best
    end
    function A.intent(s,mode)
        if mode.name=='SAFETY' or mode.name=='retreat' then
            return {kind='move',pos=mode.pos,reason=mode.reason,emergency=mode.name=='SAFETY'}
        end
        if mode.external then return B.api.act(s,mode) end
        return B.modes.act(s,mode)
    end
end
