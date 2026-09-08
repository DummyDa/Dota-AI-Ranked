return function(B)
    local nextDecision=0
    local greeted,greetingNext=false,0
    B.chatStatus='waiting' B.chatSent=false
    local function reset()
        B.adapter.reset() B.navigation.reset() B.arbiter.reset() B.executor.reset()
        B.items.reset() B.hero.reset() B.api.cancel() B.bridge.reset()
        if B.chatVoice then B.chatVoice.reset() end
        B.state=nil nextDecision=0 B.error=nil
        greeted,greetingNext=false,0
        B.chatStatus='waiting' B.chatSent=false
    end
    local function greet(s)
        if greeted or not s or type(s.time)~='number' or s.time<0
            or type(s.now)~='number' or s.now<greetingNext then return end
        greetingNext=s.now+2
        -- Chat.Say targets the dashboard/GC channel list, not Dota's live
        -- match chat. Umbrella exposes the same console path that Dota uses:
        -- `say` is all-chat and `say_team` is allied chat.
        if not B.libs.Engine or type(B.libs.Engine.ExecuteCommand)~='function' then
            B.chatStatus='Engine.ExecuteCommand unavailable' return
        end
        local ok,err=pcall(B.libs.Engine.ExecuteCommand,'say "Удачи и веселой игры"')
        if ok then
            greeted=true B.chatSent=true B.chatStatus='all-chat command sent'
            B.log('chat.greeting','Executed one all-chat greeting with Engine.ExecuteCommand',0)
        else
            B.chatStatus='send failed; retrying'
            B.log('chat.error','Engine.ExecuteCommand: '..tostring(err),5)
        end
    end
    function B.setEnabled(value)
        if B.enabled==value then return end
        if not value then B.executor.stop(B.state) end
        B.enabled=value B.config.botEnabled=value B.api.cancel() B.arbiter.reset() B.navigation.reset()
        B.items.reset()
        B.error=nil nextDecision=0
        B.log('toggle','Bot '..(value and 'ON' or 'OFF'),0)
    end
    local function tick()
        DotaAI=B.public
        B.ui.input()
        local now=B.call('GameRules','GetGameTime',0)
        if B.state and now<B.state.now then reset() end
        local localHero=B.call('Heroes','GetLocal',nil)
        if not localHero or B.call('NPC','GetUnitName','',localHero)~='npc_dota_hero_spirit_breaker' then
            if B.state then reset() end return
        end
        if B.state and not B.enabled then return end
        if B.state then B.adapter.quick(B.state) end
        local full=not B.state or now>=nextDecision
        if full then
            nextDecision=now+B.config.decisionInterval
            B.state=B.adapter.refresh()
        end
        local s=B.state
        if not s or not B.enabled then return end
        if B.chatVoice then B.chatVoice.tick(s) end
        if not s.hero.alive then return end
        greet(s)
        B.log('status','Active pos '..s.role..' ('..tostring(s.laneSelectionFlags)..') | orders '..B.executor.count,15)
        B.executor.poll(s)
        -- Small cached-state safety scan every callback. Full decisions at 8.3Hz.
        local emergency=B.threat.safety(s)
        if not full and not emergency then return end
        local mode=B.arbiter.choose(s,emergency)
        local proposal=B.arbiter.intent(s,mode)
        if full and proposal and proposal.pos then B.log('destination','Destination '..mode.name..' '..math.floor(proposal.pos.x)..','..math.floor(proposal.pos.y)..' | core '..tostring(mode.target and mode.target.index),15) end
        local item=B.items.consider(s,mode)
        local spell=B.hero.consider(s,mode)
        local micro=item
        if spell and (not micro or (spell.priority or 0)>(micro.priority or 0)) then micro=spell end
        -- Instant defensive casts can precede a retreat without allowing an
        -- offensive Charge to override a safety move.
        if micro and (not emergency or (micro.priority or 0)>=89 or micro.ability.name=='spirit_breaker_bulldoze') then
            if B.executor.execute(s,micro) then return end
        end
        if full and not emergency then
            local cleanup=B.items.cleanup(s)
            if cleanup and B.executor.execute(s,cleanup) then return end
            local purchase=B.items.purchase(s)
            if purchase then B.executor.execute(s,purchase) end
            if not B.executor.pending then
                local level=B.hero.level(s)
                if level and B.executor.execute(s,level) then return end
            end
        end
        if proposal then
            local accepted=B.executor.execute(s,proposal)
            if accepted and proposal.sequence and proposal.kind=='quickbuy' then B.api.finish(proposal.sequence,true,'Quick-buy command accepted') end
        end
        if full then B.bridge.tick(s) end
    end
    function B.script.OnUpdate()
        local ok,err=pcall(tick)
        if not ok then
            B.error=tostring(err) B.log('fatal',B.error,3)
            if B.enabled then B.executor.stop(B.state) end
            B.enabled=false -- Surface errors; do not keep sending corrupted orders.
        end
    end
    function B.script.OnDraw()
        local ok,err=pcall(B.ui.draw)
        if not ok then B.log('ui.error',tostring(err),10) end
    end
    function B.script.OnProjectile(p)
        if B.adapter.projectile then B.adapter.projectile(p) end
    end
    function B.script.OnPostReceivedNetMessage(msg)
        if B.chatVoice then return B.chatVoice.onNetMessage(msg) end
        return true
    end
    function B.script.OnGameStart() reset() B.enabled=B.config.botEnabled end
    function B.script.OnGameEnd() reset() end
    function B.script.OnScriptUnload() B.executor.stop(B.state) if B.chatVoice then B.chatVoice.reset() end if DotaAI==B.public then DotaAI=nil end end
    B.log('loaded','Loaded autonomous controller; recorder OFF, external OFF',0)
end
