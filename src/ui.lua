return function(B)
    local U={x=40,y=145,w=154,h=40,down=false} B.ui=U
    function U.input()
        if not Input or not Enum or not Enum.ButtonCode then return end
        local x,y=Input.GetCursorPos()
        if type(x)~='number' or type(y)~='number' then return end
        local down=Input.IsKeyDown(Enum.ButtonCode.KEY_MOUSE1)
        local inside=x>=U.x and x<=U.x+U.w and y>=U.y and y<=U.y+U.h
        if down and not U.down and inside then U.press={x=x,y=y,ox=U.x,oy=U.y} U.drag=false end
        if down and U.press then
            local dx,dy=x-U.press.x,y-U.press.y
            if dx*dx+dy*dy>25 then U.drag=true end
            if U.drag then U.x=math.max(0,U.press.ox+dx) U.y=math.max(0,U.press.oy+dy) end
        elseif not down and U.down and U.press then
            if not U.drag and inside then B.setEnabled(not B.enabled) end
            U.press=nil U.drag=false
        end
        U.down=down
    end
    function U.draw()
        if not Render or not Vec2 or not Color then return end
        if not U.font then U.font=Render.LoadFont('Arial',18,600) end
        local a,b=Vec2(U.x,U.y),Vec2(U.x+U.w,U.y+U.h)
        Render.FilledRect(a,b,B.enabled and Color(37,153,75,235) or Color(162,52,52,235),7)
        Render.Rect(a,b,Color(255,255,255,235),7)
        local label=B.enabled and 'Bot: ON' or 'Bot: OFF'
        local size=Render.TextSize(U.font,18,label)
        Render.Text(U.font,18,label,Vec2(U.x+(U.w-size.x)/2,U.y+10),Color(255,255,255))
        local status=B.error and 'ERROR: '..B.error or not B.state and 'Spirit Breaker only | '..B.version
            or ('pos '..B.state.role..' | lv '..B.state.hero.level..' | '..(B.arbiter.active and B.arbiter.active.name or 'ready'))
        Render.Text(U.font,12,status,Vec2(U.x,U.y+44),Color(240,240,240))
        if B.state then Render.Text(U.font,12,'Shop: '..(B.items.status or 'waiting'),Vec2(U.x,U.y+59),Color(240,220,160)) end
        if B.state and not B.chatSent then
            Render.Text(U.font,12,'Chat: '..(B.chatStatus or 'waiting'),Vec2(U.x,U.y+74),Color(220,220,240))
        end
    end
end
