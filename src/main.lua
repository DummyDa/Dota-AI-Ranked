return function(B)
    local nextDecision=0
    local greeted,greetingNext,greetingAttempts=false,0,0
    B.chatStatus='waiting' B.chatSent=false
    local function reset()
        B.adapter.reset() B.navigation.reset() B.arbiter.reset() B.executor.reset()
        B.items.reset() B.hero.reset() B.api.cancel() B.bridge.reset()
        B.state=nil nextDecision=0 B.error=nil
        greeted,greetingNext,greetingAttempts=false,0,0
        B.chatStatus='waiting' B.chatSent=false
    end
    local function greet(s)
        if greeted or not s or type(s.time)~='number' or s.time<0
            or type(s.now)~='number' or s.now<greetingNext then return end
        greetingNext=s.now+2
        greetingAttempts=greetingAttempts+1
        local channels=B.call('Chat','GetChannels',{})
        local selected
        local names={}
        for _,channel in pairs(channels or {}) do
            if type(channel)=='string' then
                names[#names+1]=channel
                local name=channel:lower():gsub('[%s_%-]','')
                if name=='all' or name=='allchat' or name=='global' or name=='public'
                    or name=='общий' or name=='всем' then selected=channel; break end
            end
        end
        if not selected then
            -- GetChannels is observed to stay empty in a live private lobby.
            -- Chat.Say accepts a channel name directly, so use the standard
            -- all-chat name instead of waiting forever for discovery metadata.
            selected='All'
            B.log('chat.channel','Channel list empty; trying direct All channel',5)
        end
        if not B.libs.Chat or type(B.libs.Chat.Say)~='function' then
            B.chatStatus='Chat.Say unavailable' return
        end
        local ok,err=pcall(B.libs.Chat.Say,selected,'Удачи и веселой игры')
        if ok then
            greeted=true B.chatSent=true B.chatStatus='sent to '..selected
            B.log('chat.greeting','Sent one all-chat greeting to '..selected,0)
        else
            B.chatStatus='send failed; retrying'
            B.log('chat.error','Chat.Say: '..tostring(err),5)
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
        if not s or not s.hero.alive or not B.enabled then return end
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
    function B.script.OnGameStart() reset() B.enabled=B.config.botEnabled end
    function B.script.OnGameEnd() reset() end
    function B.script.OnScriptUnload() B.executor.stop(B.state) if DotaAI==B.public then DotaAI=nil end end
    B.log('loaded','Loaded autonomous controller; recorder OFF, external OFF',0)
end
