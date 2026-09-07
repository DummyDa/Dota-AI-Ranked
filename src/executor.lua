return function(B)
    local E={lastAt=-100,lockUntil=0,count=0} B.executor=E
    local function invoke(lib,method,...)
        if not B.libs[lib] or type(B.libs[lib][method])~='function' then
            B.log('executor.'..method,'Unavailable order: '..lib..'.'..method,30) return false
        end
        local ok,err=pcall(B.libs[lib][method],...)
        if not ok then B.log('executor.error',tostring(err),3) end
        return ok -- Umbrella orders return nil even when accepted.
    end
    local function valid(u)
        return u and u.handle and B.call('Entity','IsEntity',false,u.handle)
    end
    local function order(s,kind,target,pos,ability)
        local code=B.enum('UnitOrder',kind)
        local issuer=B.enum('PlayerOrderIssuer','DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY')
        if not code or not issuer then B.log('order_enum','Order enum unavailable: '..kind,30) return false end
        return invoke('Player','PrepareUnitOrders',s.player,code,target,pos and B.vec(pos) or B.vec(s.hero.pos),
            ability,issuer,s.hero.handle,false,false,false,false,'spirit_breaker_bot',true)
    end
    function E.reset() E.lastAt=-100 E.lockUntil=0 E.pending=nil E.lastKey=nil E.lastPos=nil E.lastIntent=nil E.quickbuyJob=nil B.chargeTarget=nil end
    function E.queueTick(s)
        local job=E.quickbuyJob
        if not job or s.now<job.nextAt then return end
        local name=job.names[job.index]
        if not invoke('Engine','SetQuickBuy',name:gsub('^item_',''),job.index==1 and job.reset or false) then
            E.quickbuyJob=nil B.items.reset() return false
        end
        B.log('quickbuy.'..job.index,'Quick-buy add '..name..' reset='..tostring(job.index==1 and job.reset or false),0)
        job.index=job.index+1 job.nextAt=s.now+0.25
        if job.index>#job.names then E.quickbuyJob=nil end
        return true
    end
    function E.poll(s)
        E.queueTick(s)
        local p=E.pending if not p then return end
        local a=p.name and ((p.item and s.items or s.abilities)[p.name])
        local done=false
        if p.kind=='cast' then
            done=(a and (a.cooldown>p.cooldown+0.05 or (a.charges and a.charges<p.charges))) or false
            if p.name=='spirit_breaker_charge_of_darkness' then done=B.charging(s) end
            if p.item and not a and not s.ownedItems[p.name] then done=true end
        elseif p.kind=='level' then done=a and a.level>p.level
        elseif p.kind=='rune' then done=B.find(s.runes,p.target)==nil end
        if done or s.now>p.expires then
            E.pending=nil
            E.lastResult={ok=done,reason=done and 'Observed action effect' or 'No confirmation before timeout',time=s.now}
            if p.sequence and B.api then B.api.finish(p.sequence,done,E.lastResult.reason) end
        end
    end
    function E.execute(s,intent)
        if not intent or not B.enabled or not s or not s.hero.alive or s.hero.illusion then return false end
        if s.hero.name~='npc_dota_hero_spirit_breaker' then return false end
        local kind=intent.kind
        if kind=='quickbuy' then
            if E.quickbuyJob then return false end
            local names=intent.itemNames or {intent.itemName}
            if #names==0 or #names>16 then return false end
            for _,name in ipairs(names) do if type(name)~='string' or not name:match('^[%w_]+$') then return false end end
            E.quickbuyJob={names=names,index=1,nextAt=s.now,reset=intent.reset~=false}
            return E.queueTick(s)~=false
        end
        local charging=B.charging(s)
        local chargeBulldoze=charging and kind=='cast' and intent.ability
            and intent.ability.name=='spirit_breaker_bulldoze' and intent.castType=='none'
        local locked=charging or s.hero.channeling or s.hero.casting or B.has(s.hero,'modifier_teleporting')
        if locked and not chargeBulldoze and not (intent.emergency and kind=='move') then return false end
        if s.now<E.lockUntil and not intent.emergency then return false end
        if E.pending and (kind=='cast' or kind=='rune' or kind=='level') then return false end
        if s.now-E.lastAt<(intent.emergency and 0.12 or 0.18) then return false end
        if s.hero.stunned then return false end
        if (kind=='move' or kind=='rune') and s.hero.rooted then return false end
        local target=intent.target
        if target then
            if not valid(target) then return false end
            if target.team~=nil and target.team~=s.hero.team then
                if B.call('Entity','IsDormant',true,target.handle) or not B.call('NPC','IsVisible',false,target.handle) then return false end
                if not B.call('Entity','IsAlive',false,target.handle) then return false end
            end
        end
        local key=kind..':'..tostring(target and target.index or '')..':'..tostring(intent.ability and intent.ability.name or '')
        if kind=='move' then
            local p=B.navigation.next(s,intent.pos,intent.allowTower,intent.emergency)
            if not p then return false end
            if E.lastKey==key and B.dist(p,E.lastPos)<55 and s.now-E.lastAt<0.55 then return false end
            if order(s,'DOTA_UNIT_ORDER_MOVE_TO_POSITION',nil,p,nil) then
                E.lastAt=s.now E.lastKey=key E.lastPos=p E.count=E.count+1 E.lastIntent=intent return true
            end
            return false
        end
        if kind=='hold' then
            if E.lastKey==key and s.now-E.lastAt<0.7 then return false end
            if not invoke('Player','HoldPosition',s.player,s.hero.handle,false,false,false,'spirit_breaker_bot') then return false end
        elseif kind=='attack' then
            if not target or not target.alive or target.invulnerable or target.attackImmune or s.hero.disarmed then return false end
            if target.team==s.hero.team then
                if not B.find(s.creeps,target.index) or target.hpPct>=0.5 then return false end
            elseif s.time<600 and B.find(s.creeps,target.index) then
                if B.modes.coreCanTake and B.modes.coreCanTake(s,target) then return false end
            end
            if B.dist(s.hero.pos,target.pos)>s.hero.range+55 then return false end
            if not intent.allowTower then
                for _,t in ipairs(s.towers) do
                    if t.team~=s.hero.team and B.dist(t.pos,s.hero.pos)<t.range+80 then return false end
                end
            end
            -- Never hand an unbounded chase to the engine. Range is checked again each refresh.
            if E.lastKey==key and s.now-E.lastAt<math.max(0.45,s.hero.attackPeriod*0.8) then return false end
            if not invoke('Player','AttackTarget',s.player,s.hero.handle,target.handle,false,false,false,'spirit_breaker_bot',true) then return false end
            E.lockUntil=s.now+s.hero.attackPoint+0.12
        elseif kind=='cast' then
            local a=intent.ability
            if not a or not a.handle or a.hidden or a.passive then return false end
            if a.item and s.hero.muted or not a.item and s.hero.silenced then return false end
            if not B.call('Ability','IsCastable',false,a.handle,s.hero.mana) then return false end
            if E.pending then return false end
            if a.name=='item_ward_dispenser' then B.log('dispenser','Ward dispenser selection unverified; refusing cast',30) return false end
            local bit=(intent.castType=='target' or intent.castType=='tree') and 8
                or (intent.castType=='position' and 16 or 4)
            if not B.flag(a.behavior,bit) then return false end
            if intent.castType=='target' or intent.castType=='tree' then
                if not target or target.invulnerable then return false end
                if intent.castType~='tree' and not B.flag(a.targetTeam,target.team==s.hero.team and 1 or 2) then return false end
                if target.index~=s.hero.index and not B.inCastRange(a,B.dist(s.hero.pos,target.pos),25) then
                    B.log('cast.range','Cast rejected by range: '..a.name..' range='..tostring(a.range),8)
                    return false
                end
                if a.name=='spirit_breaker_charge_of_darkness' and (s.hero.rooted or not B.threat.safeEngage(s,target)) then return false end
                if not invoke('Ability','CastTarget',a.handle,target.handle,false,false,false,'spirit_breaker_bot') then return false end
                if a.name=='spirit_breaker_charge_of_darkness' then
                    B.chargeTarget={index=target.index,issuedAt=s.now}
                end
            elseif intent.castType=='position' then
                if not intent.pos then return false end
                if a.name~='item_tpscroll' and (a.range<=0 or B.dist(s.hero.pos,intent.pos)>a.range+25) then return false end
                if not invoke('Ability','CastPosition',a.handle,B.vec(intent.pos),false,false,false,'spirit_breaker_bot',true) then return false end
            else
                if not invoke('Ability','CastNoTarget',a.handle,false,false,false,'spirit_breaker_bot') then return false end
            end
            E.lockUntil=s.now+math.max(0.25,a.castPoint+0.2)
            E.pending={kind=kind,name=a.name,item=a.item,cooldown=a.cooldown,charges=a.charges or 0,
                expires=s.now+math.max(2,a.castPoint+1),sequence=intent.sequence}
        elseif kind=='level' then
            local a=intent.ability
            if not a or not B.call('Ability','CanBeUpgraded',false,a.handle) then return false end
            if not order(s,'DOTA_UNIT_ORDER_TRAIN_ABILITY',nil,nil,a.handle) then return false end
            E.pending={kind=kind,name=a.name,level=a.level,expires=s.now+2,sequence=intent.sequence}
        elseif kind=='rune' then
            if not target or B.dist(s.hero.pos,target.pos)>200 then return false end
            if not order(s,'DOTA_UNIT_ORDER_PICKUP_RUNE',target.handle,target.pos,nil) then return false end
            E.pending={kind=kind,target=target.index,expires=s.now+2,sequence=intent.sequence}
        elseif kind=='interact' then
            B.log('unsupported_interaction','Outpost capture disabled: no verified safe interaction',30) return false
        else return false end
        E.lastAt=s.now E.lastKey=key E.lastPos=nil E.count=E.count+1 E.lastIntent=intent
        if B.support then B.support.issued(s,intent) end
        return true
    end
    function E.stop(s)
        if s and s.hero and s.hero.name=='npc_dota_hero_spirit_breaker' then
            invoke('Player','HoldPosition',s.player,s.hero.handle,false,false,false,'spirit_breaker_bot_off')
        end
        E.reset()
    end
end
