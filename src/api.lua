return function(B)
    local A={sequence=0,completed=0,result='idle'} B.api=A
    local names={'AUTO','STOP','HOLD_SAFE','MOVE_TO','ATTACK_MOVE','RETREAT','GO_FOUNTAIN','GO_TO_LANE',
        'FARM_LANE','PUSH_LANE','DEFEND_LANE','FARM_NEAREST_CAMP','FARM_CAMP','PICKUP_RUNE','SECURE_RUNE',
        'FOLLOW_CORE','GROUP_WITH_TEAM','PLACE_WARD','DEWARD','CONTEST_OBJECTIVE','ATTACK_UNIT','ATTACK_HERO',
        'HARASS_HERO','ATTACK_TOWER','CAST_ABILITY_TARGET','CAST_ABILITY_POSITION','CAST_ABILITY_NO_TARGET',
        'USE_ITEM_TARGET','USE_ITEM_POSITION','USE_ITEM_NO_TARGET','LEVEL_ABILITY','SET_QUICKBUY',
        'CHARGE_HERO','BULLDOZE','NETHER_STRIKE','PLANAR_POCKET','PULL','STACK','ROSHAN','TORMENTOR','OUTPOST'}
    A.allowed={} for _,name in ipairs(names) do A.allowed[name]=true end
    local function idx(v)
        if type(v)=='number' then return v end
        if type(v)=='table' and v.index then return v.index end
        if v then return B.call('Entity','GetIndex',nil,v) end
    end
    function A.finish(seq,ok,reason)
        if seq~=A.sequence then return end
        A.completed=seq A.result=ok and 'success' or 'failed' A.error=not ok and reason or nil
        A.lastReason=reason A.command=nil
    end
    function A.commandAction(action,params,duration)
        if not B.config.externalEnabled then return false,'external_control_disabled' end
        action=type(action)=='string' and action:upper() or ''
        if not A.allowed[action] then return false,'unknown_action' end
        if params~=nil and type(params)~='table' then return false,'params_must_be_table' end
        params=params or {}
        if duration~=nil and (type(duration)~='number' or duration~=duration or duration<0) then return false,'invalid_duration' end
        local clean={}
        for k,v in pairs(params) do clean[k]=v end
        if params.target or params.targetIndex then clean.targetIndex=idx(params.targetIndex or params.target) clean.target=nil end
        if params.position then clean.position=B.pos(params.position) if not clean.position then return false,'invalid_position' end end
        A.sequence=A.sequence+1
        A.command={action=action,params=clean,sequence=A.sequence,
            expires=(B.state and B.state.now or 0)+(duration and duration>0 and math.min(duration,300) or 15)}
        A.result='running' A.error=nil
        if action=='AUTO' then A.finish(A.sequence,true,'Autonomous rules resumed') end
        return true,A.sequence
    end
    function A.cancel() if A.command then A.finish(A.sequence,false,'cancelled') end end
    function A.candidate(s)
        local c=A.command
        if not B.config.externalEnabled or not c then return nil end
        if s.now>=c.expires then A.finish(c.sequence,false,'goal_expired') return nil end
        return {name='external',key='external:'..c.sequence,desire=0.57,reason=c.action,
            external=true,target=s.byIndex[c.params.targetIndex],pos=c.params.position}
    end
    local function move(s,p,reason)
        if not p then return nil end
        if B.dist(s.hero.pos,p)<100 then return {kind='hold',reason=reason} end
        return {kind='move',pos=p,reason=reason}
    end
    local function attack(s,u,reason,allowTower)
        if not u or not u.alive or not u.visible then return nil end
        if u.team==s.hero.team and (not u.name:find('creep') or u.hpPct>=0.5) then return nil end
        if B.dist(s.hero.pos,u.pos)>s.hero.range+35 then
            local i=move(s,B.toward(u.pos,s.hero.pos,math.max(80,s.hero.range-20)),reason)
            if i then i.allowTower=allowTower end return i
        end
        return {kind='attack',target=u,reason=reason,allowTower=allowTower}
    end
    function A.act(s,mode)
        local c=A.command if not c then return nil end
        local a,p=c.action,c.params local t=s.byIndex[p.targetIndex]
        local intent
        if a=='OUTPOST' then A.finish(c.sequence,false,'outpost_capture_unverified') return nil
        elseif a=='STOP' or a=='HOLD_SAFE' then intent={kind='hold',reason=a}
        elseif a=='MOVE_TO' or a=='RETREAT' or a=='GO_FOUNTAIN' then
            local pos=a=='GO_FOUNTAIN' and B.map.home(s) or p.position or (a=='RETREAT' and B.threat.retreat(s))
            if pos and B.dist(pos,s.hero.pos)<120 then A.finish(c.sequence,true,'destination_reached') return nil end
            intent=move(s,pos,a)
        elseif a=='GO_TO_LANE' then intent=move(s,B.map.lanePoint(s,p.lane),a)
        elseif a=='FOLLOW_CORE' or a=='GROUP_WITH_TEAM' then
            t=t or s.core
            -- This is a macro destination, not a forced move-only loop. Local
            -- protection, combat, items and safety preempt it in the coordinator.
            if t and t.team==s.hero.team and t.alive then intent=move(s,B.toward(t.pos,B.map.home(s),280),a) end
        elseif a=='PICKUP_RUNE' or a=='SECURE_RUNE' then
            t=B.find(s.runes,p.targetIndex)
            if not t then for _,r in ipairs(s.runes) do if not t or B.dist(r.pos,s.hero.pos)<B.dist(t.pos,s.hero.pos) then t=r end end end
            if t then intent=B.dist(t.pos,s.hero.pos)<180 and {kind='rune',target=t,reason=a} or move(s,t.pos,a)
            elseif p.position then intent=move(s,p.position,a) end
        elseif a=='SET_QUICKBUY' then intent={kind='quickbuy',itemName=p.itemName or p.name,reset=p.reset,reason=a}
        elseif a=='PLACE_WARD' then
            local w=s.items['item_ward_'..(p.wardType=='sentry' and 'sentry' or 'observer')]
            if w and p.position then
                if B.dist(s.hero.pos,p.position)>w.range then intent=move(s,B.toward(p.position,s.hero.pos,math.max(90,w.range-40)),a)
                else intent={kind='cast',ability=w,castType='position',pos=p.position,reason=a} end
            end
        elseif a:find('CAST_')==1 or a:find('USE_ITEM')==1 or a=='LEVEL_ABILITY' or a=='CHARGE_HERO' or a=='BULLDOZE' or a=='NETHER_STRIKE' or a=='PLANAR_POCKET' then
            local aliases={CHARGE_HERO='spirit_breaker_charge_of_darkness',BULLDOZE='spirit_breaker_bulldoze',
                NETHER_STRIKE='spirit_breaker_nether_strike',PLANAR_POCKET='spirit_breaker_planar_pocket'}
            local n=aliases[a] or p.abilityName or p.itemName or p.name
            local spell=n and (s.abilities[n] or s.items[n])
            if not spell and (p.abilityIndex or p.itemIndex) then
                for _,v in pairs(p.itemIndex and s.items or s.abilities) do if v.slot==(p.itemIndex or p.abilityIndex) then spell=v break end end
            end
            local kind=(a=='CHARGE_HERO' or a=='NETHER_STRIKE' or a:match('_TARGET$') and not a:match('_NO_TARGET$')) and 'target'
                or a:match('_POSITION$') and 'position' or 'none'
            if spell then intent={kind=a=='LEVEL_ABILITY' and 'level' or 'cast',ability=spell,castType=kind,target=t,pos=p.position,reason=a} end
        elseif a=='ATTACK_UNIT' or a=='ATTACK_HERO' or a=='HARASS_HERO' or a=='DEWARD' or a=='ATTACK_TOWER' or a=='CONTEST_OBJECTIVE' then
            if t and s.time<600 and t.team~=s.hero.team and B.find(s.creeps,t.index) then
                -- External macro cannot bypass support core farm protection.
                for _,v in ipairs(B.modes.candidates(s)) do if v.name=='last_hit' and v.target.index==t.index then intent=v.intent end end
            else intent=attack(s,t,a,a=='ATTACK_TOWER') end
            if not t and p.position then intent=move(s,p.position,a) end
        else
            local mapping={PUSH_LANE={'push','farm'},FARM_LANE={'farm'},DEFEND_LANE={'defend'},
                ROSHAN={'roshan'},TORMENTOR={'tormentor'},PULL={'pull'},STACK={'stack'},ATTACK_MOVE={'fight','farm'}}
            if mapping[a] then
                local best
                for _,m in ipairs(B.modes.candidates(s)) do
                    for _,n in ipairs(mapping[a]) do if m.name==n and (not best or m.desire>best.desire) then best=m end end
                end
                if best then intent=B.modes.act(s,best)
                else intent=move(s,p.position or B.map.lanePoint(s,p.lane),a) end
            elseif a=='FARM_CAMP' or a=='FARM_NEAREST_CAMP' then
                if s.time>=600 then
                    local camp=B.find(s.camps,p.campIndex or p.camp)
                    if not camp then for _,v in ipairs(s.camps) do if not camp or B.dist(v.pos,s.hero.pos)<B.dist(camp.pos,s.hero.pos) then camp=v end end end
                    if camp then
                        for _,n in ipairs(B.near(s.neutrals,camp.pos,500)) do if not t or n.hp<t.hp then t=n end end
                        intent=t and attack(s,t,a) or move(s,camp.pos,a)
                    end
                end
            end
        end
        if intent then intent.sequence=c.sequence return intent end
        A.finish(c.sequence,false,'no_valid_target_or_capability')
    end
    local function clean(value,depth)
        if depth>10 then return nil end
        if type(value)=='number' or type(value)=='boolean' or type(value)=='string' then return value end
        if type(value)~='table' then return nil end
        local out={}
        for k,v in pairs(value) do if k~='handle' and k~='player' and k~='byIndex' and k~='mods' then out[k]=clean(v,depth+1) end end
        return out
    end
    function A.observation()
        local s=B.state
        local out=s and clean(s,0) or {ready=false}
        out.ready=s~=nil out.botEnabled=B.enabled out.aiEnabled=B.enabled out.recordingEnabled=false
        out.action=A.command and A.command.action or 'AUTO' out.actionSequence=A.sequence out.sequence=A.sequence
        out.completedSequence=A.completed out.lastResult=A.result out.lastError=A.error
        out.activeMode=B.arbiter.active and B.arbiter.active.name or 'waiting'
        out.modeDesires=B.arbiter.desires out.decisionReason=B.arbiter.active and B.arbiter.active.reason
        out.targetIndex=B.arbiter.active and B.arbiter.active.target and B.arbiter.active.target.index
        out.route=clean(B.navigation.route,0) out.version=B.version out.externalEnabled=B.config.externalEnabled
        out.capabilities=clean(B.capabilities,0) out.orders=B.executor.count
        out.purchaseStatus=B.items.status
        if s then
            out.hero.position=out.hero.pos out.hero.health=out.hero.hp out.hero.maxHealth=out.hero.maxHp
            out.hero.healthPercent=out.hero.hpPct out.hero.attackRange=out.hero.range
            out.gameTime=s.time
        end
        return out
    end
    local api={Command=A.commandAction,Cancel=A.cancel,GetObservation=A.observation}
    function api.SetExternalEnabled(enabled) B.config.externalEnabled=enabled==true if not B.config.externalEnabled then A.cancel() end end
    function api.SetEnabled(enabled) B.setEnabled(enabled==true) end
    local wrappers={MoveTo={'MOVE_TO','position'},AttackMove={'ATTACK_MOVE','position'},FarmLane={'FARM_LANE','lane'},
        GoToLane={'GO_TO_LANE','lane'},PushLane={'PUSH_LANE','lane'},DefendLane={'DEFEND_LANE','lane'},
        FarmCamp={'FARM_CAMP','campIndex'},PickupRune={'PICKUP_RUNE','target'},FollowCore={'FOLLOW_CORE','target'},
        GroupWithTeam={'GROUP_WITH_TEAM','target'},Deward={'DEWARD','target'},Retreat={'RETREAT','position'},
        AttackHero={'ATTACK_HERO','target'},AttackUnit={'ATTACK_UNIT','target'},HarassHero={'HARASS_HERO','target'},
        AttackTower={'ATTACK_TOWER','target'},ChargeHero={'CHARGE_HERO','target'},NetherStrike={'NETHER_STRIKE','target'},
        LevelAbility={'LEVEL_ABILITY','name'}}
    for method,def in pairs(wrappers) do local action,key=def[1],def[2] api[method]=function(value,duration) return A.commandAction(action,{[key]=value},duration) end end
    for method,action in pairs({FarmNearestCamp='FARM_NEAREST_CAMP',GoFountain='GO_FOUNTAIN',HoldSafe='HOLD_SAFE',Bulldoze='BULLDOZE',PlanarPocket='PLANAR_POCKET'}) do
        local a=action api[method]=function(duration) return A.commandAction(a,{},duration) end
    end
    for method,action in pairs({CastAbilityTarget='CAST_ABILITY_TARGET',CastAbilityPosition='CAST_ABILITY_POSITION',CastAbilityNoTarget='CAST_ABILITY_NO_TARGET',
        UseItemTarget='USE_ITEM_TARGET',UseItemPosition='USE_ITEM_POSITION',UseItemNoTarget='USE_ITEM_NO_TARGET'}) do
        local a=action api[method]=function(name,value) return A.commandAction(a,{name=name,target=a:match('_TARGET$') and not a:match('_NO_TARGET$') and value or nil,position=a:match('_POSITION$') and value or nil},5) end
    end
    function api.PlaceWard(pos,kind) return A.commandAction('PLACE_WARD',{position=pos,wardType=kind},15) end
    function api.SetQuickBuy(name,reset) return A.commandAction('SET_QUICKBUY',{itemName=name,reset=reset},5) end
    function api.SecureRune(target,pos,duration) return A.commandAction('SECURE_RUNE',{target=target,position=pos},duration) end
    function api.ContestObjective(target,pos,duration) return A.commandAction('CONTEST_OBJECTIVE',{target=target,position=pos},duration) end
    B.public=api
    DotaAI=api
end
