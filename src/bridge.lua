-- Optional future macro transport. No recorder; never required by autonomy.
return function(B)
    local T={nextAt=0,generation=0,connected=false} B.bridge=T
    function B.public.SetBridgeEnabled(enabled)
        B.config.bridgeEnabled=enabled==true T.generation=T.generation+1 T.inFlight=false
        if not enabled then T.connected=false end
    end
    function T.tick(s)
        if not B.config.bridgeEnabled or not B.config.externalEnabled or not B.enabled then return end
        if T.inFlight and s.now-T.started>4 then T.inFlight=false T.generation=T.generation+1 end
        if T.inFlight or s.now<T.nextAt then return end
        T.nextAt=s.now+1
        if not T.json then
            T.json=B.json
        end
        local obs=B.api.observation()
        obs.bridgeCommandId=T.commandId obs.bridgeCommandSequence=T.sequence
        obs.bridgeGoalId=T.goalId obs.bridgeCommandLayer='macro'
        local ok,data=pcall(function() return T.json:encode({protocolVersion=1,clientTime=s.now,
            aiEnabled=true,recordingEnabled=false,observation=obs}) end)
        if not ok then B.log('bridge.encode','Optional bridge encoding failed',30) return end
        if not HTTP or not HTTP.Request then B.log('bridge.http','Optional HTTP transport unavailable',30) return end
        T.inFlight=true T.started=s.now
        local generation=T.generation
        local sent,err=pcall(HTTP.Request,'POST','http://127.0.0.1:8765/v1/tick',{data=data},function(response)
            if generation~=T.generation then return end
            T.inFlight=false
            if not B.config.bridgeEnabled or not B.config.externalEnabled or not B.enabled then return end
            if not response or tostring(response.code)~='200' then T.connected=false B.log('bridge.offline','Optional bridge offline; continuing autonomous rules',15) return end
            if type(response.response)~='string' or #response.response>131072 then T.connected=false return end
            local parsed,payload=pcall(function() return T.json:decode(response.response) end)
            if not parsed or type(payload)~='table' then T.connected=false return end
            T.connected=true
            local c=payload.command
            -- External service owns only macro goals. Micro remains local even
            -- if a legacy bridge attempts to send its old micro command layer.
            if payload.observeOnly==false and type(c)=='table' and c.layer=='macro' and c.id and c.id~=T.commandId then
                local accepted,sequence=B.api.commandAction(c.action,c.params,tonumber(c.duration) or 10)
                if accepted then T.commandId=c.id T.sequence=sequence T.goalId=c.goalId end
            end
        end)
        if not sent or err==false then T.inFlight=false T.connected=false B.log('bridge.send','Optional HTTP request failed',15) end
    end
    function T.reset() T.inFlight=false T.nextAt=0 T.generation=T.generation+1 T.commandId=nil T.connected=false end
end
