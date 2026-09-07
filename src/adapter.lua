return function(B)
    local A, history, projectiles = {}, {}, {}
    B.adapter=A
    local function read(lib,method,h,default) return B.call(lib,method,default,h) end
    local function state(h,name)
        local e=B.enum('ModifierState',name)
        return e~=nil and B.call('NPC','HasState',false,h,e) or false
    end
    function A.role(player)
        local d=B.call('Player','GetTeamData',nil,player)
        local f=d and tonumber(d.lane_selection_flags) or 0
        -- Mapping retained from the approved plan; log raw bits for lobby validation.
        for i=1,5 do if f==2^(i-1) then return i end end
        return nil
    end
    function A.unit(h,team,now,isHero)
        if not h then return nil end
        local t=read('Entity','GetTeamNum',h,-1)
        local visible=not read('Entity','IsDormant',h,true) and read('NPC','IsVisible',h,false)
        -- Do not read enemies' positions, health, modifiers or abilities through fog.
        if t~=team and not visible then return nil end
        local p=B.pos(read('Entity','GetAbsOrigin',h,nil))
        local index=read('Entity','GetIndex',h,nil)
        if not p or not index then return nil end
        local hp=read('Entity','GetHealth',h,0)
        local maxHp=math.max(1,read('Entity','GetMaxHealth',h,1))
        local mana=read('NPC','GetMana',h,0)
        local maxMana=math.max(1,read('NPC','GetMaxMana',h,1))
        local u={handle=h,index=index,name=read('NPC','GetUnitName',h,''),team=t,pos=p,
            hp=hp,maxHp=maxHp,hpPct=hp/maxHp,mana=mana,maxMana=maxMana,manaPct=mana/maxMana,
            alive=read('Entity','IsAlive',h,false),visible=visible,illusion=read('NPC','IsIllusion',h,false),
            range=read('NPC','GetAttackRange',h,150)+read('NPC','GetAttackRangeBonus',h,0),
            damage=read('NPC','GetTrueDamage',h,0),armorFactor=read('NPC','GetArmorDamageMultiplier',h,1),
            moveSpeed=read('NPC','GetMoveSpeed',h,300),attackPoint=read('NPC','GetAttackAnimPoint',h,0.4),
            attackPeriod=B.call('NPC','GetSecondsPerAttack',1.7,h,false),projectileSpeed=read('NPC','GetAttackProjectileSpeed',h,0),
            attacking=read('NPC','IsAttacking',h,false),channeling=read('NPC','IsChannellingAbility',h,false),
            casting=false,level=read('NPC','GetCurrentLevel',h,1),mods={},recentDamage=0,healthLossRate=0,
            stunned=read('NPC','IsStunned',h,false),silenced=read('NPC','IsSilenced',h,false),
            rooted=state(h,'MODIFIER_STATE_ROOTED'),muted=state(h,'MODIFIER_STATE_MUTED'),
            disarmed=state(h,'MODIFIER_STATE_DISARMED'),invulnerable=state(h,'MODIFIER_STATE_INVULNERABLE'),
            attackImmune=state(h,'MODIFIER_STATE_ATTACK_IMMUNE'),magicImmune=state(h,'MODIFIER_STATE_MAGIC_IMMUNE')
                or state(h,'MODIFIER_STATE_DEBUFF_IMMUNE')}
        local forward=B.pos(B.call('Entity','GetForwardPosition',nil,h,100))
        if forward and B.dist(forward,p)>50 and B.dist(forward,p)<150 then u.facing=B.norm(B.sub(forward,p)) end
        for _,m in pairs(read('NPC','GetModifiers',h,{})) do local n=read('Modifier','GetName',m,nil) if n then u.mods[n]=true end end
        if read('NPC','IsTower',h,false) then
            local target=read('Tower','GetAttackTarget',h,nil)
            if target then u.attackTarget=read('Entity','GetIndex',target,nil) end
        end
        local old=history[index]
        if old and old.name==u.name and now>old.time and now-old.time<1 then
            local loss=math.max(0,old.hp-hp)
            u.healthLossRate=old.rate*0.7+loss/(now-old.time)*0.3
            u.recentDamage=old.damage*math.exp(-(now-old.time)/2)+loss
        end
        if u.healthLossRate<0.2 then u.healthLossRate=0 end
        if u.recentDamage<0.5 then u.recentDamage=0 end
        u.velocity=old and old.pos and now>old.time and B.scale(B.sub(p,old.pos),1/(now-old.time)) or {x=0,y=0,z=0}
        history[index]={hp=hp,time=now,rate=u.healthLossRate,damage=u.recentDamage,name=u.name,pos=p}
        return u
    end
    -- Query only values actually used, for their owning ability. Probing every
    -- possible name on every talent/item needlessly calls native error paths.
    local specialNames={item_force_staff={'push_length'},item_dust={'radius'},
        item_smoke_of_deceit={'application_radius'},spirit_breaker_planar_pocket={'radius'}}
    function A.ability(h,heroMana,isItem,slot)
        if not h then return nil end
        local a={handle=h,name=read('Ability','GetName',h,''),index=read('Entity','GetIndex',h,slot),slot=slot,
            level=read('Ability','GetLevel',h,0),maxLevel=read('Ability','GetMaxLevel',h,0),
            castable=B.call('Ability','IsCastable',false,h,heroMana),range=read('Ability','GetCastRange',h,0),
            castPoint=read('Ability','GetCastPoint',h,0.3),cooldown=read('Ability','GetCooldown',h,0),
            manaCost=read('Ability','GetManaCost',h,0),behavior=read('Ability','GetBehavior',h,0),
            targetTeam=read('Ability','GetTargetTeam',h,0),hidden=read('Ability','IsHidden',h,false),
            passive=read('Ability','IsPassive',h,false),inPhase=read('Ability','IsInAbilityPhase',h,false),
            damage=read('Ability','GetDamage',h,0),item=isItem,specials={}}
        if isItem then a.charges=read('Item','GetCurrentCharges',h,0) a.secondaryCharges=read('Item','GetSecondaryCharges',h,0) end
        for _,n in ipairs(specialNames[a.name] or {}) do a.specials[n]=B.call('Ability','GetLevelSpecialValueFor',nil,h,n) end
        return a
    end
    function A.refresh()
        local h=B.call('Heroes','GetLocal',nil)
        local player=B.call('Players','GetLocal',nil)
        if not h or not player then return nil end
        local name=read('NPC','GetUnitName',h,'')
        if name~='npc_dota_hero_spirit_breaker' then return nil end
        local now=B.call('GameRules','GetGameTime',0)
        local team=read('Entity','GetTeamNum',h,-1)
        local hero=A.unit(h,team,now,true)
        if not hero then return nil end
        local role=A.role(player) role=(role==4) and 4 or 5
        local s={now=now,time=B.call('GameRules','GetDOTATime',0,false,false),hero=hero,player=player,
            role=role,lane=(team==2) == (role==5) and 'bot' or 'top',
            allies={},enemies={},creeps={},neutrals={},towers={},structures={},wards={},objectives={},
            runes={},camps={},trees={},projectiles={},byIndex={[hero.index]=hero},abilities={},items={},ownedItems={}}
        for _,p in pairs(B.call('Players','GetAll',{})) do
            local ah=read('Player','GetAssignedHero',p,nil)
            if ah and ah~=h and read('Entity','GetTeamNum',ah,-1)==team then
                local u=A.unit(ah,team,now,true)
                if u and not u.illusion then u.role=A.role(p) s.allies[#s.allies+1]=u s.byIndex[u.index]=u end
            end
        end
        for _,npc in pairs(B.call('NPCs','GetAll',{})) do
            if npc~=h then
                local ix=read('Entity','GetIndex',npc,nil)
                if not s.byIndex[ix] then
                    local u=A.unit(npc,team,now,read('Entity','IsHero',npc,false))
                    if u and u.alive then
                        s.byIndex[u.index]=u
                        if read('Entity','IsHero',npc,false) then
                            if not u.illusion then local list=u.team==team and s.allies or s.enemies list[#list+1]=u end
                        elseif read('NPC','IsTower',npc,false) then s.towers[#s.towers+1]=u
                        elseif u.name:find('ward') then s.wards[#s.wards+1]=u
                        elseif u.name:find('roshan') or u.name:find('miniboss') or u.name:find('outpost') or u.name:find('watch_tower') then s.objectives[#s.objectives+1]=u
                        elseif read('NPC','IsLaneCreep',npc,false) then s.creeps[#s.creeps+1]=u
                        elseif read('NPC','IsNeutral',npc,false) then s.neutrals[#s.neutrals+1]=u
                        elseif read('NPC','IsStructure',npc,false) then s.structures[#s.structures+1]=u end
                    end
                end
            end
        end
        for slot=0,23 do
            local a=A.ability(B.call('NPC','GetAbilityByIndex',nil,h,slot),hero.mana,false,slot)
            if a and a.name~='' then s.abilities[a.name]=a hero.casting=hero.casting or a.inPhase end
        end
        local function inventory(owner,active)
            for slot=0,16 do
                local a=A.ability(B.call('NPC','GetItemByIndex',nil,owner,slot),hero.mana,true,slot)
                if a and a.name~='' then
                    s.ownedItems[a.name]=(s.ownedItems[a.name] or 0)+1
                    if active and (slot<=5 or slot>=15) then s.items[a.name]=a hero.casting=hero.casting or a.inPhase end
                end
            end
        end
        inventory(h,true)
        local courier=B.call('Couriers','GetLocal',nil) if courier then inventory(courier,false) end
        hero.abilityPoints=read('Hero','GetAbilityPoints',h,0)
        local teamData=B.call('Player','GetTeamData',nil,player)
        s.quickbuy=B.call('Player','GetQuickBuyInfo',nil,player)
        s.gold=B.call('Player','GetTotalGold',nil,player)
        s.laneSelectionFlags=teamData and teamData.lane_selection_flags
        s.roleSource=A.role(player) and 'lane_flags_mapping' or 'fallback_pos5'
        local best=math.huge
        for _,u in ipairs(s.allies) do
            if u.alive then
                local wanted=role==5 and 1 or 3
                local score=B.dist(hero.pos,u.pos)+(u.role==wanted and -10000 or 0)+(u.role and u.role>=4 and 10000 or 0)
                if score<best then best=score s.core=u end
            end
        end
        for _,r in pairs(B.call('Runes','GetAll',{})) do
            if not read('Entity','IsDormant',r,true) then
                local p=B.pos(read('Entity','GetAbsOrigin',r,nil))
                if p then s.runes[#s.runes+1]={handle=r,index=read('Entity','GetIndex',r,nil),pos=p,type=read('Rune','GetRuneType',r,-1)} end
            end
        end
        for i,c in pairs(B.call('Camps','GetAll',{})) do
            local box=read('Camp','GetCampBox',c,nil)
            local lo=box and B.pos(box.min) local hi=box and B.pos(box.max)
            local rawType=read('Camp','GetType',c,-1)
            local kind=({[0]='small',[1]='medium',[2]='large',[3]='ancient'})[rawType]
            if lo and hi then s.camps[#s.camps+1]={index=i,pos=B.scale(B.add(lo,hi),0.5),box={min=lo,max=hi},type=kind,rawType=rawType} end
        end
        for key,p in pairs(projectiles) do
            local source,target=s.byIndex[p.source],s.byIndex[p.target]
            if now>=p.expires then projectiles[key]=nil
            elseif source and target then
                s.projectiles[#s.projectiles+1]=p
                if p.isAttack then source.attackTarget=source.attackTarget or target.index end
            end
        end
        for _,tree in ipairs(B.call('Entity','GetTreesInRadius',{},h,700,true)) do
            local p=B.pos(read('Entity','GetAbsOrigin',tree,nil))
            if p then s.trees[#s.trees+1]={handle=tree,index=read('Entity','GetIndex',tree,nil),pos=p} end
        end
        for _,p in pairs(B.call('LinearProjectiles','GetAll',{})) do
            local source=p.source and s.byIndex[read('Entity','GetIndex',p.source,nil)]
            local pos=B.pos(p.position)
            if source and pos and source.visible then s.projectiles[#s.projectiles+1]={source=source.index,pos=pos,velocity=B.pos(p.velocity),linear=true} end
        end
        return s
    end
    function A.quick(s)
        if not s then return nil end
        local h=s.hero.handle
        s.now=B.call('GameRules','GetGameTime',s.now)
        s.time=B.call('GameRules','GetDOTATime',s.time,false,false)
        s.hero.pos=B.pos(read('Entity','GetAbsOrigin',h,nil)) or s.hero.pos
        s.hero.hp=read('Entity','GetHealth',h,0) s.hero.hpPct=s.hero.hp/s.hero.maxHp
        s.hero.alive=read('Entity','IsAlive',h,false)
        for _,t in ipairs(s.towers) do
            if t.team~=s.hero.team and not read('Entity','IsDormant',t.handle,true) then local target=read('Tower','GetAttackTarget',t.handle,nil) t.attackTarget=target and read('Entity','GetIndex',target,nil) end
        end
        return s
    end
    function A.projectile(p)
        if type(p)~='table' or not p.source or not p.target or not B.state then return end
        local source=B.state.byIndex[read('Entity','GetIndex',p.source,nil)]
        local target=B.state.byIndex[read('Entity','GetIndex',p.target,nil)]
        if not source or not target or not source.visible or not target.visible then return end
        local now=B.call('GameRules','GetGameTime',B.state.now)
        local delay=p.moveSpeed and p.moveSpeed>0 and B.dist(source.pos,target.pos)/p.moveSpeed or 0.5
        local k=p.handle or tostring(source.index)..':'..tostring(now)
        projectiles[k]={source=source.index,target=target.index,speed=p.moveSpeed,isAttack=p.isAttack==true,
            expires=now+math.min(4,delay+0.2),pos=source.pos}
    end
    function A.reset() history={} projectiles={} end
end
