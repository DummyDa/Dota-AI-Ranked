-- Match-chat receiver and voice-reply transport. LLM/TTS stay outside Dota.
return function(B)
    local C={nextPoll=0,polling=false,listenUntil=0,recording=false,stopAt=0}
    B.chatVoice=C B.voiceStatus='idle'
    local protobuf
    local ok,loaded=pcall(require,'protobuf')
    if ok then protobuf=loaded end

    local function post(path,payload,callback)
        if not HTTP or type(HTTP.Request)~='function' then return false end
        local encoded,data=pcall(function() return B.json:encode(payload) end)
        if not encoded then return false end
        local sent=pcall(HTTP.Request,'POST','http://127.0.0.1:8765'..path,{data=data},callback or function() end)
        return sent
    end
    local function playerInfo(sourceId)
        local localPlayer=B.call('Players','GetLocal',nil)
        local localHero=localPlayer and B.call('Player','GetAssignedHero',nil,localPlayer)
        local localTeam=localHero and B.call('Entity','GetTeamNum',-1,localHero) or -1
        local localId=localPlayer and B.call('Player','GetPlayerID',-1,localPlayer) or -1
        local localName='OpenAI bot'
        if localPlayer then
            local named,name=pcall(function() return B.libs.Player.GetName(localPlayer) end)
            if named and type(name)=='string' and #name>0 then localName=name end
        end
        local info={sourcePlayerId=sourceId,isSelf=sourceId==localId,isAlly=false,
            sourceName='Player '..tostring(sourceId),sourceHero='unknown',localName=localName}
        for _,player in pairs(B.call('Players','GetAll',{})) do
            if B.call('Player','GetPlayerID',-2,player)==sourceId then
                local hero=B.call('Player','GetAssignedHero',nil,player)
                local team=hero and B.call('Entity','GetTeamNum',-2,hero) or -2
                local named,name=pcall(function() return B.libs.Player.GetName(player) end)
                if named and type(name)=='string' and #name>0 then info.sourceName=name end
                if hero then info.sourceHero=B.call('NPC','GetUnitName','unknown',hero) end
                info.isAlly=localTeam>=0 and team==localTeam
                break
            end
        end
        return info
    end
    function C.handleDecoded(message)
        if not B.enabled or type(message)~='table' then return true end
        local text=message.message_text
        local sourceId=tonumber(message.source_player_id)
        if type(text)~='string' or #text==0 or #text>1024 or not sourceId then return true end
        local info=playerInfo(sourceId)
        local lowered=text:lower()
        lowered=lowered:match('^%s*(.-)%s*$') or lowered
        local selfAddressed=info.isSelf and (lowered:find('бара',1,true)~=nil or
            lowered:find('bara',1,true)~=nil or lowered:find('spirit breaker',1,true)~=nil)
        local selfTest=info.isSelf and (lowered=='бара тест' or lowered=='bara test')
        if info.isSelf and not selfAddressed then return true end
        local payload={protocolVersion=1,messageText=text,channelType=tonumber(message.channel_type) or 0,
            gameTime=B.state and B.state.time or 0,sourcePlayerId=sourceId,sourceName=info.sourceName,
            sourceHero=info.sourceHero,isAlly=info.isAlly,isSelf=info.isSelf,
            selfAddressed=selfAddressed,selfTest=selfTest,
            localName=info.localName}
        C.listenUntil=(B.state and B.state.now or 0)+60
        B.voiceStatus='analyzing '..info.sourceName
        post('/v1/chat',payload,function(response)
            if not response or tostring(response.code)~='202' then
                B.voiceStatus='chat bridge offline'
                B.log('chat.voice.offline','Chat responder bridge unavailable',15)
            end
        end)
        return true
    end
    function C.onNetMessage(msg)
        if not msg or msg.message_id~=612 or not msg.msg_object then return true end
        if not protobuf or type(protobuf.decodeToJSONfromObject)~='function' then
            B.log('chat.protobuf','protobuf decoder unavailable for match chat',30) return true
        end
        local decoded,json=pcall(protobuf.decodeToJSONfromObject,msg.msg_object)
        if not decoded or type(json)~='string' then return true end
        local parsed,message=pcall(function() return B.json:decode(json) end)
        if parsed then return C.handleDecoded(message) end
        return true
    end
    local function startVoice(job,s)
        if C.recording or type(job.id)~='string' then return end
        local duration=math.max(0.2,math.min(15,tonumber(job.duration) or 2))
        local commandOk=pcall(B.libs.Engine.ExecuteCommand,'+voicerecord')
        if not commandOk then B.voiceStatus='voice command failed' return end
        C.recording=true C.stopAt=s.now+duration+0.9
        B.voiceStatus='speaking: '..tostring(job.text or '')
        post('/v1/voice/start',{id=job.id},function(response)
            if not response or tostring(response.code)~='200' then
                B.log('chat.voice.start','TTS playback did not start',10)
            end
        end)
    end
    function C.tick(s)
        if C.recording and s.now>=C.stopAt then
            pcall(B.libs.Engine.ExecuteCommand,'-voicerecord')
            C.recording=false B.voiceStatus='idle'
        end
        if C.recording or C.polling or s.now<C.nextPoll or s.now>C.listenUntil then return end
        C.nextPoll=s.now+0.35 C.polling=true
        local sent=post('/v1/voice/poll',{protocolVersion=1},function(response)
            C.polling=false
            if not response or tostring(response.code)~='200' or type(response.response)~='string' then return end
            local parsed,job=pcall(function() return B.json:decode(response.response) end)
            if parsed and type(job)=='table' and job.ready then startVoice(job,s) end
        end)
        if not sent then C.polling=false end
    end
    function C.reset()
        if C.recording and B.libs.Engine and type(B.libs.Engine.ExecuteCommand)=='function' then
            pcall(B.libs.Engine.ExecuteCommand,'-voicerecord')
        end
        C.nextPoll=0 C.polling=false C.listenUntil=0 C.recording=false C.stopAt=0
        B.voiceStatus='idle'
    end
end
