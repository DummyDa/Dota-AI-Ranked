-- Active support decisions. Goals are stable; the executor owns every order.
return function(B)
    local S={} B.support=S
    local patrol, trade, gank, lastGank, wardAttempt
    function S.reset() patrol=nil trade=nil gank=nil lastGank=-100 wardAttempt={} end
    S.reset()
    local function alive(u) return u and u.alive and not u.illusion end
    local function enemy(s,u) return alive(u) and u.visible and u.team~=s.hero.team and not u.invulnerable end
    local function towerDanger(s,p,margin)
        for _,t in ipairs(s.towers) do if t.alive and t.team~=s.hero.team and B.dist(t.pos,p)<t.range+(margin or 160) then return true end end
        return false
    end
    local function creepsAt(s,p)
        local n=0
        for _,c in ipairs(s.creeps) do if enemy(s,c) and B.dist(c.pos,p)<c.range+90 then n=n+1 end end
        return n
    end
    local function counts(s,p,r)
        local a=B.dist(s.hero.pos,p)<r and 1 or 0
        local e=0
        for _,u in ipairs(B.near(s.allies,p,r)) do if alive(u) then a=a+1 end end
        for _,u in ipairs(B.near(s.enemies,p,r)) do if enemy(s,u) then e=e+1 end end
        return a,e
    end
    local function move(s,p,reason)
        if not p or s.hero.rooted or B.dist(s.hero.pos,p)<65 or towerDanger(s,p) then return nil end
        local risk=B.threat.at(s,p)
        if risk>math.max(2.4,B.threat.at(s,s.hero.pos)+0.25) then return nil end
        if not B.call('GridNav','IsTraversable',false,B.vec(p)) then return nil end
        return {kind='move',pos=p,reason=reason}
    end
    local function offer(out,name,desire,intent,target,key)
        if intent then out[#out+1]={name=name,desire=desire,intent=intent,target=target,pos=intent.pos,
            reason=intent.reason,key=key or name..':'..tostring(target and target.index or '')} end
    end
    function S.coreDanger(s)
        local c=s.core
        if not alive(c) then return false end
        local _,foes=counts(s,c.pos,950)
        return foes>0 and (c.hpPct<0.65 or c.recentDamage>35 or c.stunned or foes>=2)
    end
    function S.localFight(s,e)
        if not enemy(s,e) or B.dist(s.hero.pos,e.pos)>1400 then return false end
        for _,a in ipairs(B.near(s.allies,e.pos,800)) do
            if alive(a) and (a.recentDamage>10 or a.attackTarget==e.index or e.attackTarget==a.index
                or (a.attacking and e.recentDamage>0 and B.dist(a.pos,e.pos)<a.range+150)
                or ((a.channeling or a.casting) and B.dist(a.pos,e.pos)<400)
                or (e.recentDamage>10 and B.dist(a.pos,e.pos)<600)
                or B.has(a,'modifier_juggernaut_blade_fury')) then return true end
        end
        return false
    end
    function S.localCharge(s,e)
        local a=s.abilities.spirit_breaker_charge_of_darkness
        if not S.localFight(s,e) then return nil,'no nearby allied fight' end
        if not a or a.level<1 or not a.castable then return nil,'Charge not ready' end
        if s.hero.rooted or s.hero.silenced or s.hero.hpPct<0.43 then return nil,'hero disabled or low health' end
        if e.magicImmune or B.has(e,'modifier_item_sphere_target') or B.has(e,'modifier_item_lotus_orb_active') then return nil,'protected target' end
        if not B.threat.safeEngage(s,e) then return nil,'unsafe local engagement' end
        local d=B.dist(s.hero.pos,e.pos)
        if d<math.max(220,s.hero.range+40) and not e.channeling then return nil,'already in attack range' end
        local steps=math.max(1,math.ceil(d/200))
        for n=1,steps do
            if towerDanger(s,B.add(s.hero.pos,B.scale(B.sub(e.pos,s.hero.pos),n/steps)),120) then return nil,'tower on Charge path' end
        end
        return {kind='cast',ability=a,castType='target',target=e,reason='Join nearby allied fight with Charge',priority=85}
    end
    local function laneTradeSetup(s,e)
        local c=s.core
        if s.time>=600 or not alive(c) or not enemy(s,e) then return false end
        if s.hero.hpPct<0.72 or c.hpPct<0.62 or s.hero.recentDamage>35 then return false end
        if B.dist(s.hero.pos,c.pos)>850 or B.dist(c.pos,e.pos)>700 or towerDanger(s,e.pos) then return false end
        local allies,foes=counts(s,e.pos,1000)
        local landing=B.toward(e.pos,s.hero.pos,math.max(90,s.hero.range-20))
        return allies>=foes and creepsAt(s,landing)<=2
    end
    local function patrolIntent(s)
        local anchor=B.map.coreOnLane(s,s.core) and B.toward(s.core.pos,B.map.home(s),260) or B.map.lanePoint(s,s.lane)
        if B.dist(s.hero.pos,anchor)>650 then return move(s,anchor,'Move into support range on the assigned lane') end
        if patrol and s.now<patrol.untilTime and B.dist(s.hero.pos,patrol.pos)>90 and B.dist(patrol.anchor,anchor)<250 then
            local i=move(s,patrol.pos,'Reposition along the safe side of the wave') if i then return i end
        end
        local rear=B.norm(B.sub(B.map.home(s),anchor))
        local side={x=-rear.y,y=rear.x,z=0}
        local best,score=nil,math.huge
        for _,sign in ipairs({-1,1}) do
            for _,back in ipairs({0,180}) do
                local p=B.add(B.add(anchor,B.scale(side,sign*230)),B.scale(rear,back))
                local d=B.dist(s.hero.pos,p)
                if d>120 and creepsAt(s,p)<3 and move(s,p,'patrol check') then
                    local risk=B.threat.at(s,p)*1000+d*0.15
                    if risk<score then best,score=p,risk end
                end
            end
        end
        if best then patrol={pos=best,anchor=anchor,untilTime=s.now+3.5}; return move(s,best,'Reposition along the safe side of the wave') end
    end
    local function trades(out,s)
        if trade then
            local target=B.find(s.enemies,trade.index)
            if not enemy(s,target) then trade=nil
            else
                local allies,foes=counts(s,target.pos,1000)
                local ownLoss=(trade.startHpPct or s.hero.hpPct)-s.hero.hpPct
                local enemyLoss=(trade.targetHpPct or target.hpPct)-target.hpPct
                local bad=s.now>=trade.expires or s.hero.hpPct<0.58 or s.hero.recentDamage>55
                    or foes>allies or creepsAt(s,s.hero.pos)>=3 or towerDanger(s,target.pos)
                    or (trade.hits>=1 and ownLoss>math.max(0.07,enemyLoss+0.04))
                    or trade.hits>=3
                if bad then
                    trade.resetUntil=trade.resetUntil or (s.now+1.25)
                    if s.now<trade.resetUntil then
                        offer(out,'trade_reset',0.74,move(s,B.threat.retreat(s),
                            'Disengage after completed or unfavorable lane trade'),target,'trade_reset:'..target.index)
                        return
                    end
                    trade=nil
                else
                    local d=B.dist(s.hero.pos,target.pos)
                    local i
                    if d<=s.hero.range+35 and not s.hero.disarmed then
                        i={kind='attack',target=target,reason='Continue profitable lane trade',tradeContinue=true}
                    elseif d<1100 then
                        local landing=B.toward(target.pos,s.hero.pos,math.max(90,s.hero.range-20))
                        i=move(s,landing,'Keep closing distance for the active lane trade')
                    end
                    if i then
                        i.tradeIndex=target.index
                        offer(out,'harass',0.66,i,target,'support_trade:'..target.index)
                        return
                    end
                    trade=nil
                end
            end
        end
        for _,e in ipairs(s.enemies) do
            local d=B.dist(s.hero.pos,e.pos)
            if enemy(s,e) and not e.attackImmune and d<1100 and s.hero.hpPct>0.48 and not s.hero.disarmed and not towerDanger(s,e.pos) then
                local allies,foes=counts(s,e.pos,1000)
                local c=s.core
                local protect=alive(c) and B.dist(c.pos,e.pos)<650 and (c.hpPct<0.65 or c.recentDamage>20)
                local participating=S.localFight(s,e)
                local setup=laneTradeSetup(s,e)
                local charge,why=S.localCharge(s,e)
                if charge then offer(out,'fight',0.8,charge,e,'local_fight:'..e.index)
                elseif participating then B.log('local_charge.block','Local Charge deferred: '..tostring(why),8) end
                local a,f=B.threat.balance(s,e.pos,1000)
                local landing=B.toward(e.pos,s.hero.pos,math.max(90,s.hero.range-20))
                if allies>=foes and a>=f*(protect and 0.8 or 0.95) and (participating or setup or creepsAt(s,landing)<3)
                    and (protect or participating or (s.hero.hpPct>0.65 and s.hero.recentDamage<45)) then
                    local i
                    if d<=s.hero.range+35 then i={kind='attack',target=e,reason=protect and 'Peel the attacker away from the core' or 'Start supported lane trade'}
                    else i=move(s,landing,protect and 'Approach to peel the core' or 'Close distance for a short trade') end
                    if i and setup and not protect and not participating then
                        i.tradeStart=true i.tradeIndex=e.index
                    end
                    offer(out,protect and 'protect_core' or participating and 'fight' or 'harass',protect and 0.86 or participating and 0.76 or setup and 0.58 or 0.5,i,e,'support_trade:'..e.index)
                end
            end
        end
    end
    function S.canGank(s,target)
        if s.hero.level<2 or s.hero.hpPct<0.72 or s.hero.recentDamage>35 or s.hero.rooted or s.hero.silenced
            or S.coreDanger(s) or not enemy(s,target) then return false end
        local charge=s.abilities.spirit_breaker_charge_of_darkness
        if not charge or not charge.castable or charge.level<1 or s.hero.mana<charge.manaCost+35 then return false end
        if s.now-lastGank<25 then return false end
        if B.map.classify(target.pos)==s.lane or B.dist(s.hero.pos,target.pos)>10000 then return false end
        if target.magicImmune or target.attackImmune or B.has(target,'modifier_item_sphere_target')
            or B.has(target,'modifier_item_lotus_orb_active') or not B.threat.safeEngage(s,target) then return false end
        local allyCount,setupCount=0,0
        for _,a in ipairs(B.near(s.allies,target.pos,1000)) do
            if alive(a) and a.hpPct>0.45 then
                setupCount=setupCount+1
                if a.attacking or a.recentDamage>10 or target.hpPct<0.8 or target.channeling then allyCount=allyCount+1 end
            end
        end
        -- Demonstration charges also start full-health ganks when a healthy ally
        -- is already in setup range and the local strength check is favourable.
        local friendly,hostile=B.threat.balance(s,target.pos,1100)
        if allyCount<1 and (setupCount<1 or friendly<hostile or target.hpPct<0.45) then return false end
        -- Charge bypasses GridNav. Check its straight corridor against known towers.
        local delta=B.sub(target.pos,s.hero.pos)
        local steps=math.max(1,math.ceil(B.dist(target.pos,s.hero.pos)/250))
        for n=1,steps do if towerDanger(s,B.add(s.hero.pos,B.scale(delta,n/steps)),120) then return false end end
        return true
    end
    local function ganks(out,s)
        if gank and s.now>gank.untilTime then gank=nil end
        for _,e in ipairs(s.enemies) do
            if S.canGank(s,e) then
                local bonus=gank and gank.index==e.index and 0.03 or 0
                offer(out,'gank',0.69+bonus+(1-e.hpPct)*0.05,{kind='cast',ability=s.abilities.spirit_breaker_charge_of_darkness,
                    castType='target',target=e,reason='Level 2+ rotation to a visible supported fight',gank=true},e,'gank:'..e.index)
            end
        end
    end
    local function wards(out,s)
        local item=s.items.item_ward_observer
        if not item or not item.castable or (item.charges or 0)<1 or S.coreDanger(s) or s.hero.hpPct<0.6 then return end
        for n,spot in ipairs(B.map.wardSpots(s)) do
            local p=spot.pos
            local dist=B.dist(s.hero.pos,p)
            if dist<1600 and (not wardAttempt[n] or s.now>wardAttempt[n]) then
                local covered=false
                for _,w in ipairs(s.wards) do if w.team==s.hero.team and w.name=='npc_dota_observer_wards' and B.dist(w.pos,p)<1300 then covered=true end end
                local threatened=false
                for _,e in ipairs(s.enemies) do if enemy(s,e) and B.dist(e.pos,p)<700 then threatened=true end end
                if not covered and not threatened and not towerDanger(s,p) then
                    local i
                    if dist<=item.range then i={kind='cast',ability=item,castType='position',pos=p,reason='Place lane vision from safe cast range',wardSpot=n}
                    else i=move(s,B.toward(p,s.hero.pos,math.max(100,item.range-60)),'Move into range to place lane vision') end
                    offer(out,'ward',0.46,i,nil,'support_ward:'..n)
                end
            end
        end
    end
    function S.candidates(s)
        local out={}
        if not s.hero.alive or s.hero.channeling or s.hero.casting or s.hero.stunned or B.charging(s) then return out end
        trades(out,s); ganks(out,s); wards(out,s)
        if s.time<600 then
            local i=patrolIntent(s)
            offer(out,'patrol',0.27,i,nil,'patrol')
            if not i and #out==0 and #B.near(s.enemies,s.hero.pos,1000)>0 then
                -- Escape/reposition must not require numerical superiority.
                offer(out,'reposition',0.33,move(s,B.threat.retreat(s),'Leave an unfavorable lane position'),nil,'reposition')
            end
        end
        return out
    end
    function S.issued(s,i)
        if i.tradeStart then
            local target=B.find(s.enemies,i.tradeIndex)
            if target and (not trade or trade.index~=i.tradeIndex) then
                trade={index=i.tradeIndex,expires=s.now+6,startHpPct=s.hero.hpPct,
                    targetHpPct=target.hpPct,hits=i.kind=='attack' and 1 or 0}
            elseif trade and i.kind=='attack' then trade.hits=trade.hits+1 end
        elseif i.tradeContinue and trade and trade.index==i.tradeIndex then
            trade.hits=trade.hits+1
        end
        if i.gank then lastGank=s.now; gank={index=i.target.index,untilTime=s.now+18} end
        if i.wardSpot then wardAttempt[i.wardSpot]=s.now+12 end
    end
end
