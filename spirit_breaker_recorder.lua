-- Human gameplay recorder: autonomous update removed; external commands rejected.
---@diagnostic disable: undefined-global, param-type-mismatch, inject-field

-- Контроллер Spirit Breaker support/hard support для локального/приватного лобби.

local script = {}

local last_status = nil
-- AI execution remains implemented, but is intentionally not exposed in the UI
-- while we collect clean human-play data.
local ai_enabled = false
local recording_enabled = true
local ai_disabled_order_cancelled = false

local control = {
    action = "AUTO",
    params = {},
    sequence = 0,
    started_at = 0,
    expires_at = 0,
    last_order_time = 0,
    order_interval = 0.12,
    api_registered = false,
    api_error_logged = false,
    completed_sequence = 0,
    last_result = "idle",
    last_error = nil,
}

-- Runtime state for commands exposed to the future neural-network controller.
-- Keeping it in one table also avoids Lua's per-chunk local-variable limit.
local action_runtime = {
    camp = nil,
    rune = nil,
    support_target = nil,
    one_shot_sequence = -1,
}

local bridge = {
    enabled = true,
    url = "http://127.0.0.1:8765/v1/tick",
    interval = 0.08,
    timeout = 0.45,
    last_request_time = 0,
    request_started_at = 0,
    in_flight = false,
    connected = false,
    observe_only = true,
    latency_ms = 0,
    failures = 0,
    last_error = nil,
    json = nil,
    json_failed = false,
    last_command_id = nil,
    last_command_layer = nil,
    last_goal_id = nil,
    last_command_sequence = 0,
    macro_goal = nil,
    micro_action = nil,
    manual_sequence = 0,
    sent_manual_sequence = 0,
    pending_manual_order = nil,
    manual_orders = {},
    last_manual_input_time = 0,
    pending_input = nil,
    previous_manual_state = nil,
    right_mouse_held = false,
    last_right_cursor = nil,
    -- Continuous RMB is a movement trajectory, not a stream of independent
    -- decisions. Five samples/second is enough to preserve its shape without
    -- letting auto-repeat dominate the imitation dataset.
    held_right_interval = 0.20,
    held_right_min_distance = 55,
    last_manual_error = nil,
}

local farm = {
    scan_range = 1200,
    scan_interval = 0.05,
    last_scan_time = 0,
    active_target = nil,
    release_time = 0,
    health_samples = {},
    prediction_factor = 0.22,
    max_prediction_by_damage = 0.60,
    damage_safety_margin = 2,
    approach_distance = 250,
    approach_stop_margin = 35,
    approach_order_interval = 0.12,
    last_approach_order = 0,
    approach_active = false,
    position_scan_range = 1650,
    position_order_interval = 0.10,
    last_position_order = 0,
    focus_range_factor = 0.68,
    focus_min_distance = 120,
    focus_max_distance = 340,
    side_step = 70,
    strafe_side = 1,
    next_strafe_switch = 0,
    strafe_interval = 0.72,
    last_lane_direction = nil,
    early_aggro_end_time = 600,
    laning_end_time = 600,
    creep_aggro_count = 3,
    retreat_duration = 1.30,
    retreat_distance = 560,
    retreat_until = 0,
    retreat_position = nil,
    last_retreat_order = 0,
    retreat_order_interval = 0.10,
    selected_lane = nil,
    lane_choice_until = 0,
    lane_choice_interval = 2.0,
    lane_travel_order_interval = 0.30,
    last_lane_travel_order = 0,
    lane_follow_distance = 280,
    lane_arrival_distance = 180,
    last_logged_lane = nil,
    enemy_spacing_scan_extra = 350,
    enemy_spacing_trigger_margin = 60,
    enemy_spacing_target_margin = 30,
    enemy_spacing_extra_step = 35,
    enemy_spacing_min_step = 120,
    enemy_spacing_max_step = 480,
    enemy_spacing_release_delay = 0.28,
    enemy_spacing_until = 0,
    enemy_spacing_order_interval = 0.10,
    last_enemy_spacing_order = 0,
    support_core_follow_distance = 330,
    support_core_max_distance = 720,
    support_creep_safe_distance = 260,
    support_position_order_interval = 0.22,
    last_support_position_order = 0,
    tower_avoid_scan_range = 1400,
    tower_avoid_margin = 110,
    tower_escape_margin = 280,
    tower_escape_min_step = 180,
    tower_escape_max_step = 700,
    tower_escape_release_delay = 0.45,
    tower_escape_until = 0,
    tower_escape_order_interval = 0.08,
    last_tower_escape_order = 0,
    tower_attack_mode = false,
    tower_attack_target = nil,
    tower_attack_auto_target = false,
    tower_attack_search_range = 3000,
    tower_attack_order_interval = 0.22,
    last_tower_attack_order = 0,
    tower_api_available = true,
    tower_api_error_logged = false,
}

local button = {
    x = 40,
    y = 140,
    width = 180,
    height = 38,
    dragging = false,
    moved = false,
    offset_x = 0,
    offset_y = 0,
    press_x = 0,
    press_y = 0,
    mouse_was_down = false,
}

local button_font = Render.LoadFont("Arial", 18, 600)

local function status(message)
    if last_status == message then
        return
    end

    last_status = message
    Log.Write("[spirit_breaker_recorder] " .. message)
    Chat.Print("ConsoleChat", "[spirit_breaker_recorder] " .. message)
end

local function set_ai_mode(value)
    ai_enabled = false
    return false, "record_only"
end

local function set_recording_mode(value)
    recording_enabled = value
    bridge.pending_input = nil
    bridge.previous_manual_state = nil
    bridge.right_mouse_held = false
    bridge.last_right_cursor = nil
    status("recording " .. (value and "enabled" or "disabled"))
end

local function update_button()
    local mouse_x, mouse_y = Input.GetCursorPos()
    local mouse_down = Input.IsKeyDown(Enum.ButtonCode.KEY_MOUSE1)
    local cursor_on_button = Input.IsCursorInRect(
        button.x,
        button.y,
        button.width,
        button.height
    )

    local pressed_once = mouse_down and not button.mouse_was_down
    if mouse_down then
        if not button.dragging and cursor_on_button and pressed_once then
            button.dragging = true
            button.moved = false
            button.offset_x = mouse_x - button.x
            button.offset_y = mouse_y - button.y
            button.press_x = mouse_x
            button.press_y = mouse_y
            set_recording_mode(not recording_enabled)
        end

        if button.dragging then
            local old_x, old_y = button.x, button.y
            button.x = math.max(0, mouse_x - button.offset_x)
            button.y = math.max(0, mouse_y - button.offset_y)

            if math.abs(mouse_x - button.press_x) > 4 or math.abs(mouse_y - button.press_y) > 4 then
                button.moved = true
            end
        end
    elseif button.dragging then
        button.dragging = false
        button.moved = false
    end
    button.mouse_was_down = mouse_down
end

local function draw_button()
    local label = recording_enabled and "Recording: ON" or "Recording: OFF"
    local red, green, blue = 55, 170, 85
    if not recording_enabled then
        red, green, blue = 170, 65, 65
    end

    local start = Vec2(button.x, button.y)
    local finish = Vec2(button.x + button.width, button.y + button.height)

    Render.FilledRect(start + Vec2(3, 3), finish + Vec2(3, 3), Color(10, 10, 10, 210), 7)
    Render.FilledRect(start, finish, Color(red, green, blue, 235), 7)
    Render.Rect(start, finish, Color(255, 255, 255, 220), 7)

    local text_size = Render.TextSize(button_font, 18, label)
    Render.Text(
        button_font,
        18,
        label,
        Vec2(
            button.x + math.floor((button.width - text_size.x) / 2),
            button.y + math.floor((button.height - text_size.y) / 2)
        ),
        Color(255, 255, 255, 255)
    )
end

local function get_attack_damage(hero, target)
    local raw_damage = NPC.GetTrueDamage(hero) or 0
    local armor_multiplier = NPC.GetArmorDamageMultiplier(target) or 1
    return math.max(1, raw_damage * armor_multiplier)
end

local function get_attack_impact_delay(hero, target, distance)
    local delay = NPC.GetAttackAnimPoint(hero) or 0.3
    local projectile_speed = NPC.GetAttackProjectileSpeed(hero) or 0

    if projectile_speed > 0 then
        delay = delay + distance / projectile_speed
    end

    -- Небольшой запас на разворот, тик сервера и обработку приказа.
    return delay + 0.08
end

local function update_health_prediction(creep, now)
    local index = Entity.GetIndex(creep)
    local health = Entity.GetHealth(creep)
    local sample = farm.health_samples[index]

    if not sample then
        farm.health_samples[index] = { health = health, time = now, dps = 0 }
        return 0
    end

    local elapsed = now - sample.time
    if elapsed >= 0.03 then
        -- Урон в Dota приходит дискретными ударами. Ограничение не даёт
        -- одному удару выглядеть как огромный постоянный DPS.
        local observed_dps = math.min(350, math.max(0, sample.health - health) / elapsed)
        if observed_dps > 0 then
            sample.dps = sample.dps * 0.55 + observed_dps * 0.45
        else
            sample.dps = sample.dps * 0.82
        end

        sample.health = health
        sample.time = now
    end

    return sample.dps
end

local function classify_lane(position)
    local side_offset = position.x - position.y
    if side_offset > 1900 then
        return "bot"
    end
    if side_offset < -1900 then
        return "top"
    end
    return "mid"
end

local function get_enemy_tower_covering_position(hero, position, margin)
    if farm.tower_attack_mode then
        return nil, nil
    end

    local towers = NPCs.InRadius(
        position,
        farm.tower_avoid_scan_range,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}

    for _, tower in pairs(towers) do
        if Entity.IsAlive(tower)
            and NPC.IsTower(tower)
            and not Entity.IsSameTeam(hero, tower)
        then
            local attack_range = (NPC.GetAttackRange(tower) or 700)
                + (NPC.GetAttackRangeBonus(tower) or 0)
            local distance = (position - Entity.GetAbsOrigin(tower)):Length2D()
            if distance <= attack_range + (margin or farm.tower_avoid_margin) then
                return tower, attack_range
            end
        end
    end

    return nil, nil
end

local function make_tower_safe_destination(hero, destination)
    if not farm.tower_api_available then
        return destination
    end

    local ok, tower, attack_range = pcall(
        get_enemy_tower_covering_position,
        hero,
        destination,
        farm.tower_avoid_margin
    )
    if not ok then
        farm.tower_api_available = false
        if not farm.tower_api_error_logged then
            farm.tower_api_error_logged = true
            Log.Write("[spirit_breaker_recorder] tower destination API disabled: " .. tostring(tower))
        end
        return destination
    end

    if not tower then
        return destination
    end

    local tower_pos = Entity.GetAbsOrigin(tower)
    local away = Entity.GetAbsOrigin(hero) - tower_pos
    if away:Length2D() < 1 then
        away = Entity.GetTeamNum(hero) == Enum.TeamNum.TEAM_RADIANT
            and Vector(-1, -1, 0):Normalized()
            or Vector(1, 1, 0):Normalized()
    end

    return tower_pos + away:Normalized():Scaled(attack_range + farm.tower_avoid_margin + 70)
end

local function find_last_hit_target(hero, now, selected_lane)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local hero_team = Entity.GetTeamNum(hero)
    local attack_range = (NPC.GetAttackRange(hero) or 150) + (NPC.GetAttackRangeBonus(hero) or 0) + 75
    local enemies = NPCs.InRadius(
        hero_pos,
        farm.scan_range,
        hero_team,
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    )

    local best_target = nil
    local best_predicted_health = math.huge
    local best_distance = nil

    for _, creep in pairs(enemies) do
        if Entity.IsAlive(creep)
            and NPC.IsLaneCreep(creep)
            and (not selected_lane or classify_lane(Entity.GetAbsOrigin(creep)) == selected_lane)
        then
            local creep_pos = Entity.GetAbsOrigin(creep)
            local distance = (creep_pos - hero_pos):Length2D()
            local incoming_dps = update_health_prediction(creep, now)

            if distance <= attack_range + farm.approach_distance then
                local walk_distance = math.max(0, distance - attack_range + farm.approach_stop_margin)
                local move_speed = math.max(1, NPC.GetMoveSpeed(hero) or 300)
                local impact_delay = get_attack_impact_delay(hero, creep, distance) + walk_distance / move_speed
                local our_damage = get_attack_damage(hero, creep)
                local predicted_incoming = math.min(
                    our_damage * farm.max_prediction_by_damage,
                    incoming_dps * impact_delay * farm.prediction_factor
                )
                local predicted_health = Entity.GetHealth(creep) - predicted_incoming
                local kill_threshold = math.max(1, our_damage - farm.damage_safety_margin)

                if predicted_health > 0 and predicted_health <= kill_threshold and predicted_health < best_predicted_health then
                    best_target = creep
                    best_predicted_health = predicted_health
                    best_distance = distance
                end
            end
        end
    end

    return best_target, best_distance, attack_range
end

local function approach_last_hit_target(hero, player, target, attack_range, now)
    if now - farm.last_approach_order < farm.approach_order_interval then
        return
    end

    local hero_pos = Entity.GetAbsOrigin(hero)
    local creep_pos = Entity.GetAbsOrigin(target)
    local direction_to_hero = (hero_pos - creep_pos):Normalized()
    local desired_distance = math.max(100, attack_range - farm.approach_stop_margin)
    local move_position = creep_pos + direction_to_hero:Scaled(desired_distance)
    move_position = make_tower_safe_destination(hero, move_position)

    Player.PrepareUnitOrders(
        player,
        Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        nil,
        move_position,
        nil,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
        hero,
        false,
        false,
        false,
        false,
        "last_hit_approach",
        true
    )

    farm.last_approach_order = now
    farm.approach_active = true
end

local function update_farming(hero, player, now, selected_lane)
    if farm.active_target then
        if now < farm.release_time then
            return true
        end

        -- Не продолжаем бесконтрольно автоатаковать после расчётного попадания.
        Player.HoldPosition(player, hero, false, false, false, "last_hit_release")
        farm.active_target = nil
    end

    if now - farm.last_scan_time < farm.scan_interval then
        return farm.approach_active
    end
    farm.last_scan_time = now

    local target, distance, attack_range = find_last_hit_target(hero, now, selected_lane)
    if not target then
        if farm.approach_active then
            Player.HoldPosition(player, hero, false, false, false, "last_hit_approach_cancel")
            farm.approach_active = false
        end
        return false
    end

    if distance > attack_range then
        approach_last_hit_target(hero, player, target, attack_range, now)
        return true
    end

    farm.approach_active = false
    local impact_delay = get_attack_impact_delay(hero, target, distance)

    Player.AttackTarget(
        player,
        hero,
        target,
        false,
        false,
        false,
        "ai_last_hit",
        true
    )

    farm.active_target = target
    farm.release_time = now + impact_delay + 0.12
    Log.Write("[spirit_breaker_recorder] last-hit target: " .. NPC.GetUnitName(target))
    return true
end

local function get_lane_creep_center(units, selected_lane)
    local sum = Vector(0, 0, 0)
    local count = 0

    for _, unit in pairs(units) do
        if Entity.IsAlive(unit)
            and NPC.IsLaneCreep(unit)
            and (not selected_lane or classify_lane(Entity.GetAbsOrigin(unit)) == selected_lane)
        then
            sum = sum + Entity.GetAbsOrigin(unit)
            count = count + 1
        end
    end

    if count == 0 then
        return nil
    end

    return sum / count
end

local function get_lowest_health_lane_creep(units, selected_lane)
    local target = nil
    local lowest_health = math.huge

    for _, unit in pairs(units) do
        if Entity.IsAlive(unit)
            and NPC.IsLaneCreep(unit)
            and (not selected_lane or classify_lane(Entity.GetAbsOrigin(unit)) == selected_lane)
        then
            local health = Entity.GetHealth(unit)
            if health > 0 and health < lowest_health then
                target = unit
                lowest_health = health
            end
        end
    end

    return target
end

local function get_default_lane_direction(hero)
    if farm.last_lane_direction then
        return farm.last_lane_direction
    end

    if Entity.GetTeamNum(hero) == Enum.TeamNum.TEAM_RADIANT then
        return Vector(1, 1, 0):Normalized()
    end

    return Vector(-1, -1, 0):Normalized()
end

local function is_valid_enemy_tower(hero, tower)
    return tower
        and Entity.IsNPC(tower)
        and NPC.IsTower(tower)
        and Entity.IsAlive(tower)
        and not Entity.IsSameTeam(hero, tower)
end

local function find_nearest_enemy_tower(hero, radius)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local towers = NPCs.InRadius(
        hero_pos,
        radius,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}
    local nearest = nil
    local nearest_distance = math.huge

    for _, tower in pairs(towers) do
        if is_valid_enemy_tower(hero, tower) then
            local distance = (Entity.GetAbsOrigin(tower) - hero_pos):Length2D()
            if distance < nearest_distance then
                nearest = tower
                nearest_distance = distance
            end
        end
    end

    return nearest
end


-- Публичная точка управления для будущей нейросети. Текущая логика сама её не вызывает.
-- target можно передать явно; без target будет выбрана ближайшая вражеская башня.
local function request_tower_attack(target)
    farm.tower_attack_mode = true
    farm.tower_attack_target = target
    farm.tower_attack_auto_target = target == nil
    Log.Write("[spirit_breaker_recorder] external tower attack requested")
end

local function cancel_tower_attack()
    farm.tower_attack_mode = false
    farm.tower_attack_target = nil
    farm.tower_attack_auto_target = false
    Log.Write("[spirit_breaker_recorder] external tower attack cancelled")
end

local function update_tower_attack(hero, player, now)
    if not farm.tower_attack_mode then
        return false
    end

    local target = farm.tower_attack_target
    if not is_valid_enemy_tower(hero, target) then
        if target and not farm.tower_attack_auto_target then
            cancel_tower_attack()
            return false
        end

        target = find_nearest_enemy_tower(hero, farm.tower_attack_search_range)
        farm.tower_attack_target = target
    end

    if not target then
        cancel_tower_attack()
        return false
    end

    farm.active_target = nil
    farm.release_time = 0
    farm.approach_active = false

    if now - farm.last_tower_attack_order >= farm.tower_attack_order_interval then
        Player.AttackTarget(
            player,
            hero,
            target,
            false,
            false,
            false,
            "external_attack_tower",
            true
        )
        farm.last_tower_attack_order = now
    end

    return true
end

local function update_enemy_tower_safety(hero, player, now)
    if farm.tower_attack_mode then
        farm.tower_escape_until = 0
        return false
    end

    local hero_pos = Entity.GetAbsOrigin(hero)
    local towers = NPCs.InRadius(
        hero_pos,
        farm.tower_avoid_scan_range,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}
    local danger_tower = nil
    local danger_distance = math.huge
    local danger_attack_range = 700
    local tower_is_attacking_hero = false

    for _, tower in pairs(towers) do
        if is_valid_enemy_tower(hero, tower) then
            local distance = (Entity.GetAbsOrigin(tower) - hero_pos):Length2D()
            local attack_range = (NPC.GetAttackRange(tower) or 700)
                + (NPC.GetAttackRangeBonus(tower) or 0)
            local attack_target = Tower.GetAttackTarget(tower)
            local attacks_hero = attack_target == hero
            local inside_avoid_zone = distance <= attack_range + farm.tower_avoid_margin

            if attacks_hero or inside_avoid_zone then
                if attacks_hero and not tower_is_attacking_hero
                    or attacks_hero == tower_is_attacking_hero and distance < danger_distance
                then
                    danger_tower = tower
                    danger_distance = distance
                    danger_attack_range = attack_range
                    tower_is_attacking_hero = attacks_hero
                end
            end
        end
    end

    if danger_tower then
        local tower_pos = Entity.GetAbsOrigin(danger_tower)
        local away = hero_pos - tower_pos
        if away:Length2D() < 1 then
            away = get_default_lane_direction(hero):Scaled(-1)
        end

        local margin = tower_is_attacking_hero
            and farm.tower_escape_margin
            or farm.tower_avoid_margin + 90
        local target_distance = danger_attack_range + margin
        local needed_step = target_distance - danger_distance + 70
        needed_step = math.max(
            farm.tower_escape_min_step,
            math.min(farm.tower_escape_max_step, needed_step)
        )
        local escape_position = hero_pos + away:Normalized():Scaled(needed_step)

        if now - farm.last_tower_escape_order >= farm.tower_escape_order_interval then
            Player.PrepareUnitOrders(
                player,
                Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
                nil,
                escape_position,
                nil,
                Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
                hero,
                false,
                false,
                false,
                false,
                tower_is_attacking_hero and "escape_tower_aggro" or "avoid_enemy_tower",
                true
            )
            farm.last_tower_escape_order = now
        end

        farm.tower_escape_until = now + farm.tower_escape_release_delay
        farm.active_target = nil
        farm.release_time = 0
        farm.approach_active = false
        return true
    end

    return now < farm.tower_escape_until
end

-- Spirit Breaker is melee, so ranged-hero spacing is wrong for him. In AUTO we
-- only keep him out of the middle of an enemy wave; explicit combat commands
-- are allowed to enter melee range.
function action_runtime.update_support_creep_safety(hero, player, now)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local enemies = NPCs.InRadius(
        hero_pos,
        farm.support_creep_safe_distance + 80,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}
    local repulsion = Vector(0, 0, 0)
    local close_count = 0
    for _, creep in pairs(enemies) do
        if Entity.IsAlive(creep) and NPC.IsLaneCreep(creep) then
            local away = hero_pos - Entity.GetAbsOrigin(creep)
            local distance = away:Length2D()
            if distance < farm.support_creep_safe_distance then
                close_count = close_count + 1
                if distance >= 1 then
                    repulsion = repulsion + away:Normalized():Scaled(
                        farm.support_creep_safe_distance - distance + 80
                    )
                end
            end
        end
    end
    if close_count < 2 then
        return false
    end
    if repulsion:Length2D() < 1 then
        repulsion = get_default_lane_direction(hero):Scaled(-1)
    end
    if now - farm.last_support_position_order >= farm.support_position_order_interval then
        local destination = hero_pos + repulsion:Normalized():Scaled(360)
        destination = make_tower_safe_destination(hero, destination)
        Player.PrepareUnitOrders(
            player,
            Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
            nil,
            destination,
            nil,
            Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
            hero,
            false,
            false,
            false,
            false,
            "support_leave_enemy_wave",
            true
        )
        farm.last_support_position_order = now
    end
    return true
end

local function get_early_creep_threat(hero)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local hero_team = Entity.GetTeamNum(hero)
    local enemies = NPCs.InRadius(
        hero_pos,
        750,
        hero_team,
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}

    local threatening_count = 0
    local position_sum = Vector(0, 0, 0)

    for _, creep in pairs(enemies) do
        if Entity.IsAlive(creep) and NPC.IsLaneCreep(creep) and NPC.IsAttacking(creep) then
            local creep_pos = Entity.GetAbsOrigin(creep)
            local distance = (creep_pos - hero_pos):Length2D()
            local creep_range = (NPC.GetAttackRange(creep) or 150)
                + (NPC.GetAttackRangeBonus(creep) or 0)
                + 140

            if distance <= creep_range then
                threatening_count = threatening_count + 1
                position_sum = position_sum + creep_pos
            end
        end
    end

    if threatening_count == 0 then
        return 0, nil
    end

    return threatening_count, position_sum / threatening_count
end

local function update_early_creep_retreat(hero, player, dota_time, now)
    if dota_time > farm.early_aggro_end_time then
        farm.retreat_until = 0
        farm.retreat_position = nil
        return false
    end

    local threatening_count, creep_center = get_early_creep_threat(hero)
    local recent_damage = Hero.GetRecentDamage(hero) or 0

    if threatening_count >= farm.creep_aggro_count and recent_damage > 0 and creep_center then
        local hero_pos = Entity.GetAbsOrigin(hero)
        local away = hero_pos - creep_center
        if away:Length2D() < 1 then
            away = get_default_lane_direction(hero):Scaled(-1)
        else
            away = away:Normalized()
        end

        farm.retreat_position = hero_pos + away:Scaled(farm.retreat_distance)
        farm.retreat_until = now + farm.retreat_duration
        farm.active_target = nil
        farm.approach_active = false
    end

    if now >= farm.retreat_until or not farm.retreat_position then
        return false
    end

    if now - farm.last_retreat_order >= farm.retreat_order_interval then
        Player.PrepareUnitOrders(
            player,
            Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
            nil,
            farm.retreat_position,
            nil,
            Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
            hero,
            false,
            false,
            false,
            false,
            "early_creep_aggro_retreat",
            true
        )
        farm.last_retreat_order = now
    end

    return true
end

local function role_lane_from_player(hero, player)
    local team_data = Player.GetTeamData(player)
    local role_flags = team_data and team_data.lane_selection_flags or 0
    local team = Entity.GetTeamNum(hero)
    local safe_lane = team == Enum.TeamNum.TEAM_RADIANT and "bot" or "top"
    local off_lane = team == Enum.TeamNum.TEAM_RADIANT and "top" or "bot"

    -- Ranked Roles: 1 safe, 2 off, 4 mid, 8 pos 4, 16 pos 5.
    if role_flags == 4 then
        return "mid", "ranked role"
    elseif role_flags == 1 or role_flags == 16 then
        return safe_lane, "ranked role"
    elseif role_flags == 2 or role_flags == 8 then
        return off_lane, "ranked role"
    end

    -- В обычном лобби роль часто не задана, но выбранная на экране
    -- стратегии линия сохраняется как bottom=1, mid=2, top=3.
    local team_player = Player.GetTeamPlayer(player)
    local starting_position = team_player and team_player.starting_position or 0
    if starting_position == 1 then
        return "bot", "starting position"
    elseif starting_position == 2 then
        return "mid", "starting position"
    elseif starting_position == 3 then
        return "top", "starting position"
    end

    -- Spirit Breaker defaults to position 5 when a lobby does not expose roles.
    return safe_lane, "hard support fallback"
end

local function get_all_lane_creeps()
    local result = {}
    for _, npc in pairs(NPCs.GetAll() or {}) do
        if Entity.IsAlive(npc) and NPC.IsLaneCreep(npc) then
            result[#result + 1] = npc
        end
    end
    return result
end

local function nearest_lane_to_hero(hero)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local nearest_lane = nil
    local nearest_distance = math.huge

    for _, creep in pairs(get_all_lane_creeps()) do
        if Entity.IsSameTeam(hero, creep) then
            local creep_pos = Entity.GetAbsOrigin(creep)
            local distance = (creep_pos - hero_pos):Length2D()
            if distance < nearest_distance then
                nearest_distance = distance
                nearest_lane = classify_lane(creep_pos)
            end
        end
    end

    return nearest_lane
end

local function choose_lane(hero, player, dota_time, now)
    local lane
    local source

    if dota_time <= farm.early_aggro_end_time then
        lane, source = role_lane_from_player(hero, player)
        farm.selected_lane = lane
        farm.lane_choice_until = now + farm.lane_choice_interval
    elseif now >= farm.lane_choice_until or not farm.selected_lane then
        lane = nearest_lane_to_hero(hero)
        farm.selected_lane = lane or farm.selected_lane or "mid"
        farm.lane_choice_until = now + farm.lane_choice_interval
        source = lane and "nearest wave" or "fallback"
    end

    if farm.last_logged_lane ~= farm.selected_lane then
        farm.last_logged_lane = farm.selected_lane
        Log.Write(
            "[spirit_breaker_recorder] selected lane: "
                .. tostring(farm.selected_lane)
                .. " ("
                .. tostring(source or "cached")
                .. ")"
        )
    end

    return farm.selected_lane
end

local function find_friendly_lane_front(hero, selected_lane)
    local team = Entity.GetTeamNum(hero)
    local best_creep = nil
    local best_progress = team == Enum.TeamNum.TEAM_RADIANT and -math.huge or math.huge

    for _, creep in pairs(get_all_lane_creeps()) do
        if Entity.IsSameTeam(hero, creep) then
            local position = Entity.GetAbsOrigin(creep)
            if classify_lane(position) == selected_lane then
                local progress = position.x + position.y
                local is_further = team == Enum.TeamNum.TEAM_RADIANT
                    and progress > best_progress
                    or team ~= Enum.TeamNum.TEAM_RADIANT and progress < best_progress

                if is_further then
                    best_progress = progress
                    best_creep = creep
                end
            end
        end
    end

    return best_creep
end

local function find_friendly_lane_tower(hero, selected_lane)
    local prefix = Entity.GetTeamNum(hero) == Enum.TeamNum.TEAM_RADIANT
        and "npc_dota_goodguys_tower"
        or "npc_dota_badguys_tower"

    for tier = 1, 3 do
        local wanted_name = prefix .. tostring(tier) .. "_" .. selected_lane
        for _, npc in pairs(NPCs.GetAll() or {}) do
            if Entity.IsAlive(npc) and NPC.GetUnitName(npc) == wanted_name then
                return npc
            end
        end
    end

    return nil
end

local function update_lane_travel(hero, player, selected_lane, now)
    if now - farm.last_lane_travel_order < farm.lane_travel_order_interval then
        return
    end

    local hero_pos = Entity.GetAbsOrigin(hero)
    local destination = nil
    local lane_front = find_friendly_lane_front(hero, selected_lane)

    if lane_front then
        destination = Entity.GetForwardPosition(lane_front, -farm.lane_follow_distance)
    else
        local tower = find_friendly_lane_tower(hero, selected_lane)
        if tower then
            local tower_pos = Entity.GetAbsOrigin(tower)
            local toward_hero = hero_pos - tower_pos
            if toward_hero:Length2D() >= 1 then
                destination = tower_pos + toward_hero:Normalized():Scaled(220)
            else
                destination = tower_pos
            end
        end
    end

    if destination then
        destination = make_tower_safe_destination(hero, destination)
    end

    if not destination or (destination - hero_pos):Length2D() <= farm.lane_arrival_distance then
        return
    end

    Player.PrepareUnitOrders(
        player,
        Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        nil,
        destination,
        nil,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
        hero,
        false,
        false,
        false,
        false,
        "move_to_selected_lane",
        true
    )
    farm.last_lane_travel_order = now
end

local function update_lane_positioning(hero, player, now, selected_lane)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local hero_team = Entity.GetTeamNum(hero)
    local allies = NPCs.InRadius(
        hero_pos,
        farm.position_scan_range,
        hero_team,
        Enum.TeamType.TEAM_FRIEND,
        true,
        true
    ) or {}
    local allied_center = get_lane_creep_center(allies, selected_lane)
    local toward_enemy = get_default_lane_direction(hero)
    local core = nil
    local core_distance = math.huge
    for _, ally in pairs(Entity.GetHeroesInRadius(
        hero,
        farm.position_scan_range,
        Enum.TeamType.TEAM_FRIEND,
        true,
        true
    ) or {}) do
        if ally ~= hero and Entity.IsAlive(ally) then
            local distance = (Entity.GetAbsOrigin(ally) - hero_pos):Length2D()
            if distance < core_distance then
                core = ally
                core_distance = distance
            end
        end
    end

    local base_position = nil
    if core then
        -- Position 5 follows the lane core but stays on the safe side of them.
        base_position = Entity.GetAbsOrigin(core)
            - toward_enemy:Scaled(farm.support_core_follow_distance)
    elseif allied_center then
        base_position = allied_center - toward_enemy:Scaled(330)
    else
        return false
    end

    local sideways = Vector(-toward_enemy.y, toward_enemy.x, 0)
    local desired_position = base_position + sideways:Scaled(120)
    local distance_to_position = (desired_position - hero_pos):Length2D()
    if distance_to_position < 100 then
        return true
    end
    if now - farm.last_support_position_order < farm.support_position_order_interval then
        return true
    end

    desired_position = make_tower_safe_destination(hero, desired_position)

    Player.PrepareUnitOrders(
        player,
        Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        nil,
        desired_position,
        nil,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
        hero,
        false,
        false,
        false,
        false,
        "support_follow_lane_core",
        true
    )

    farm.last_support_position_order = now
    return true
end

local function normalize_lane(lane)
    if lane == "top" or lane == "mid" or lane == "bot" then
        return lane
    end
    return nil
end

local function resolve_entity(value)
    if type(value) == "number" then
        return Entity.Get(value)
    end
    return value
end

local function to_vector(value)
    if not value then
        return nil
    end
    if type(value) == "table" and value.x and value.y then
        return Vector(value.x, value.y, value.z or 0)
    end
    return value
end

action_runtime.allowed = {
    AUTO = true,
    STOP = true,
    HOLD_SAFE = true,
    MOVE_TO = true,
    ATTACK_MOVE = true,
    RETREAT = true,
    GO_FOUNTAIN = true,
    GO_TO_LANE = true,
    FARM_LANE = true,
    PUSH_LANE = true,
    DEFEND_LANE = true,
    FARM_NEAREST_CAMP = true,
    FARM_CAMP = true,
    PICKUP_RUNE = true,
    SECURE_RUNE = true,
    FOLLOW_CORE = true,
    GROUP_WITH_TEAM = true,
    PLACE_WARD = true,
    DEWARD = true,
    CONTEST_OBJECTIVE = true,
    ATTACK_UNIT = true,
    ATTACK_HERO = true,
    HARASS_HERO = true,
    ATTACK_TOWER = true,
    CAST_ABILITY_TARGET = true,
    CAST_ABILITY_POSITION = true,
    CAST_ABILITY_NO_TARGET = true,
    USE_ITEM_TARGET = true,
    USE_ITEM_POSITION = true,
    USE_ITEM_NO_TARGET = true,
    LEVEL_ABILITY = true,
    SET_QUICKBUY = true,
    CHARGE_HERO = true,
    BULLDOZE = true,
    NETHER_STRIKE = true,
}

local function reset_external_action()
    control.action = "AUTO"
    control.params = {}
    control.started_at = 0
    control.expires_at = 0
    if farm.tower_attack_mode then
        cancel_tower_attack()
    end
end

local function set_external_action(action, params, duration)
    return false, "record_only"
end

local function external_action_expired(now)
    return control.expires_at > 0 and now >= control.expires_at
end

local function issue_move_action(hero, player, position, identifier, now)
    if not position then
        return false
    end
    if now - control.last_order_time < control.order_interval then
        return true
    end

    position = make_tower_safe_destination(hero, position)
    Player.PrepareUnitOrders(
        player,
        Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION,
        nil,
        position,
        nil,
        Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
        hero,
        false,
        false,
        false,
        false,
        identifier,
        true
    )
    control.last_order_time = now
    return true
end

function action_runtime.finish(success, message)
    control.completed_sequence = control.sequence
    reset_external_action()
    control.last_result = success and (message or "completed") or "failed"
    control.last_error = success and nil or (message or "action failed")
end

function action_runtime.fountain_position(hero)
    if Entity.GetTeamNum(hero) == Enum.TeamNum.TEAM_RADIANT then
        return Vector(-7170, -6650, 384)
    end
    return Vector(7060, 6540, 384)
end

function action_runtime.resolve_ability(hero, params)
    if params.ability and type(params.ability) ~= "string" and type(params.ability) ~= "number"
        and Entity.IsAbility(params.ability)
    then
        return params.ability
    end
    if type(params.ability) == "string" then
        return NPC.GetAbility(hero, params.ability)
    end
    if type(params.name) == "string" then
        return NPC.GetAbility(hero, params.name)
    end
    if type(params.abilityIndex) == "number" then
        return NPC.GetAbilityByIndex(hero, params.abilityIndex)
    end
    return nil
end

function action_runtime.resolve_item(hero, params)
    if params.item and type(params.item) ~= "string" and type(params.item) ~= "number"
        and Entity.IsAbility(params.item)
    then
        return params.item
    end
    local name = params.itemName or params.name
    if type(name) == "string" then
        return NPC.GetItem(hero, name, true)
    end
    if type(params.itemIndex) == "number" then
        return NPC.GetItemByIndex(hero, params.itemIndex)
    end
    return nil
end

function action_runtime.camp_center(camp)
    if not camp then
        return nil
    end
    local box = Camp.GetCampBox(camp)
    if not box or not box.min or not box.max then
        return Entity.GetAbsOrigin(camp)
    end
    return (box.min + box.max) / 2
end

function action_runtime.neutrals_near(position, radius)
    local result = {}
    if not position then
        return result
    end
    for _, npc in pairs(NPCs.GetAll() or {}) do
        if Entity.IsAlive(npc) and NPC.IsNeutral(npc) and NPC.IsVisible(npc) then
            if (Entity.GetAbsOrigin(npc) - position):Length2D() <= radius then
                result[#result + 1] = npc
            end
        end
    end
    return result
end

function action_runtime.select_camp(hero, params)
    if params.camp and type(params.camp) ~= "number" then
        return params.camp
    end
    if type(params.campIndex) == "number" then
        return Camps.Get(params.campIndex)
    end
    if type(params.camp) == "number" then
        return Camps.Get(params.camp)
    end

    local hero_pos = Entity.GetAbsOrigin(hero)
    local best, best_distance = nil, math.huge
    local empty_best, empty_distance = nil, math.huge
    for _, camp in pairs(Camps.GetAll() or {}) do
        local center = action_runtime.camp_center(camp)
        if center then
            local distance = (center - hero_pos):Length2D()
            if distance < empty_distance then
                empty_best, empty_distance = camp, distance
            end
            if #action_runtime.neutrals_near(center, 700) > 0 and distance < best_distance then
                best, best_distance = camp, distance
            end
        end
    end
    return best or empty_best
end

function action_runtime.update_camp(hero, player, now)
    if not action_runtime.camp then
        action_runtime.camp = action_runtime.select_camp(hero, control.params)
    end
    local center = action_runtime.camp_center(action_runtime.camp)
    if not center then
        action_runtime.finish(false, "neutral camp not found")
        return true
    end

    local hero_pos = Entity.GetAbsOrigin(hero)
    local neutrals = action_runtime.neutrals_near(center, 850)
    local target, lowest_health = nil, math.huge
    for _, neutral in pairs(neutrals) do
        local health = Entity.GetHealth(neutral) or 0
        if health > 0 and health < lowest_health then
            target, lowest_health = neutral, health
        end
    end

    if target then
        if now - control.last_order_time >= 0.22 then
            Player.AttackTarget(player, hero, target, false, false, false, "api_farm_camp", true)
            control.last_order_time = now
        end
        return true
    end
    if (center - hero_pos):Length2D() <= 180 then
        if now - control.last_order_time >= 0.35 then
            Player.HoldPosition(player, hero, false, false, false, "api_wait_camp")
            control.last_order_time = now
        end
        return true
    end
    return issue_move_action(hero, player, center, "api_go_camp", now)
end

function action_runtime.select_rune(hero, params)
    local specified = resolve_entity(params.target or params.targetIndex)
    if specified then
        return specified
    end
    local hero_pos = Entity.GetAbsOrigin(hero)
    local best, best_distance = nil, math.huge
    for _, rune in pairs(Runes.GetAll() or {}) do
        local distance = (Entity.GetAbsOrigin(rune) - hero_pos):Length2D()
        if distance < best_distance then
            best, best_distance = rune, distance
        end
    end
    return best
end

function action_runtime.update_rune(hero, player, now)
    action_runtime.rune = action_runtime.rune or action_runtime.select_rune(hero, control.params)
    local rune = action_runtime.rune
    if not rune or not Entity.IsEntity(rune) then
        action_runtime.finish(false, "rune not found")
        return true
    end
    local position = Entity.GetAbsOrigin(rune)
    if (position - Entity.GetAbsOrigin(hero)):Length2D() > 170 then
        return issue_move_action(hero, player, position, "api_go_rune", now)
    end
    if now - control.last_order_time >= 0.25 then
        Player.PrepareUnitOrders(
            player,
            Enum.UnitOrder.DOTA_UNIT_ORDER_PICKUP_RUNE,
            rune,
            position,
            nil,
            Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
            hero,
            false,
            false,
            false,
            false,
            "api_pickup_rune",
            true
        )
        control.last_order_time = now
        action_runtime.finish(true, "rune pickup order sent")
    end
    return true
end

function action_runtime.find_friendly_hero(hero, params)
    local specified = resolve_entity(params.target or params.targetIndex)
    if specified
        and specified ~= hero
        and Entity.IsHero(specified)
        and Entity.IsAlive(specified)
        and Entity.IsSameTeam(hero, specified)
    then
        return specified
    end
    local nearest, nearest_distance = nil, math.huge
    for _, ally in pairs(Entity.GetHeroesInRadius(
        hero,
        20000,
        Enum.TeamType.TEAM_FRIEND,
        true,
        true
    ) or {}) do
        if ally ~= hero and Entity.IsAlive(ally) then
            local distance = (Entity.GetAbsOrigin(ally) - Entity.GetAbsOrigin(hero)):Length2D()
            if distance < nearest_distance then
                nearest, nearest_distance = ally, distance
            end
        end
    end
    return nearest
end

function action_runtime.update_follow_core(hero, player, now)
    action_runtime.support_target = action_runtime.support_target
        or action_runtime.find_friendly_hero(hero, control.params)
    local target = action_runtime.support_target
    if not target or not Entity.IsAlive(target) then
        action_runtime.finish(false, "friendly core not found")
        return true
    end
    local target_pos = Entity.GetAbsOrigin(target)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local distance = (target_pos - hero_pos):Length2D()
    local desired = math.max(180, tonumber(control.params.distance) or farm.support_core_follow_distance)
    if distance <= desired + 120 then
        return true
    end
    local toward_hero = (hero_pos - target_pos):Normalized()
    return issue_move_action(
        hero,
        player,
        target_pos + toward_hero:Scaled(desired),
        "api_follow_core",
        now
    )
end

function action_runtime.update_secure_rune(hero, player, now)
    if not action_runtime.rune then
        action_runtime.rune = action_runtime.select_rune(hero, control.params)
    end
    if action_runtime.rune then
        return action_runtime.update_rune(hero, player, now)
    end
    local position = to_vector(control.params.position)
    if not position then
        action_runtime.finish(false, "rune or rune position is required")
        return true
    end
    if (position - Entity.GetAbsOrigin(hero)):Length2D() > 180 then
        return issue_move_action(hero, player, position, "api_secure_rune", now)
    end
    return true
end

function action_runtime.execute_support_one_shot(hero, player, action)
    if action_runtime.one_shot_sequence == control.sequence then
        return true
    end
    action_runtime.one_shot_sequence = control.sequence
    local params = control.params
    if action == "PLACE_WARD" then
        local position = to_vector(params.position)
        if not position then
            action_runtime.finish(false, "ward position is required")
            return true
        end
        local sentry = params.wardType == "sentry" or params.type == "sentry"
        local item = NPC.GetItem(hero, sentry and "item_ward_sentry" or "item_ward_observer", true)
            or NPC.GetItem(hero, "item_ward_dispenser", true)
        if not item or not Ability.IsCastable(item, NPC.GetMana(hero)) then
            action_runtime.finish(false, "requested ward is not castable")
            return true
        end
        Ability.CastPosition(item, position, false, false, false, "api_place_ward", true)
        action_runtime.finish(true, "ward placement order sent")
        return true
    end

    local ability_name = action == "CHARGE_HERO" and "spirit_breaker_charge_of_darkness"
        or action == "BULLDOZE" and "spirit_breaker_bulldoze"
        or "spirit_breaker_nether_strike"
    local ability = NPC.GetAbility(hero, ability_name)
    if not ability or not Ability.IsCastable(ability, NPC.GetMana(hero)) then
        action_runtime.finish(false, ability_name .. " is not castable")
        return true
    end
    if action == "BULLDOZE" then
        Ability.CastNoTarget(ability, false, false, false, "api_bulldoze")
    else
        local target = resolve_entity(params.target or params.targetIndex)
        if not target or not Entity.IsHero(target) or not Entity.IsAlive(target)
            or Entity.IsSameTeam(hero, target)
        then
            action_runtime.finish(false, "enemy hero target is required")
            return true
        end
        Ability.CastTarget(ability, target, false, false, false, "api_spirit_breaker_target")
    end
    action_runtime.finish(true, "Spirit Breaker ability order sent")
    return true
end

function action_runtime.enemy_lane_creeps(hero, lane, radius)
    local result = {}
    for _, unit in pairs(NPCs.InRadius(
        Entity.GetAbsOrigin(hero),
        radius,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}) do
        if Entity.IsAlive(unit)
            and NPC.IsLaneCreep(unit)
            and (not lane or classify_lane(Entity.GetAbsOrigin(unit)) == lane)
        then
            result[#result + 1] = unit
        end
    end
    return result
end

function action_runtime.update_push_lane(hero, player, now)
    local lane = normalize_lane(control.params.lane) or farm.selected_lane
    local creeps = action_runtime.enemy_lane_creeps(hero, lane, 1250)
    if #creeps == 0 then
        update_lane_travel(hero, player, lane or role_lane_from_player(hero, player), now)
        return true
    end

    if update_farming(hero, player, now, lane) then
        return true
    end
    local target = get_lowest_health_lane_creep(creeps, lane)
    if target and now - control.last_order_time >= 0.24 then
        Player.AttackTarget(player, hero, target, false, false, false, "api_push_creep", true)
        control.last_order_time = now
    end
    return true
end

function action_runtime.execute_one_shot(hero, player, action)
    if action_runtime.one_shot_sequence == control.sequence then
        return true
    end
    action_runtime.one_shot_sequence = control.sequence
    local params = control.params
    local ability
    if string.sub(action, 1, 4) == "CAST" or action == "LEVEL_ABILITY" then
        ability = action_runtime.resolve_ability(hero, params)
    else
        ability = action_runtime.resolve_item(hero, params)
    end
    if action == "SET_QUICKBUY" then
        local name = params.itemName or params.name
        if type(name) ~= "string" or name == "" then
            action_runtime.finish(false, "itemName is required")
            return true
        end
        name = string.gsub(name, "^item_", "")
        Engine.SetQuickBuy(name, params.reset ~= false)
        action_runtime.finish(true, "quickbuy updated")
        return true
    end
    if not ability then
        action_runtime.finish(false, action == "LEVEL_ABILITY" and "ability not found" or "ability/item not found")
        return true
    end
    if action == "LEVEL_ABILITY" then
        if (Hero.GetAbilityPoints(hero) or 0) <= 0 or not Ability.CanBeUpgraded(ability) then
            action_runtime.finish(false, "ability cannot be upgraded")
            return true
        end
        Player.PrepareUnitOrders(
            player,
            Enum.UnitOrder.DOTA_UNIT_ORDER_TRAIN_ABILITY,
            nil,
            Entity.GetAbsOrigin(hero),
            ability,
            Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
            hero,
            false,
            false,
            false,
            false,
            "api_level_ability",
            true
        )
        action_runtime.finish(true, "level order sent")
        return true
    end
    if not Ability.IsCastable(ability, NPC.GetMana(hero)) then
        action_runtime.finish(false, "ability/item is not castable")
        return true
    end
    if string.find(action, "_TARGET$", 1, false) then
        local target = resolve_entity(params.target or params.targetIndex)
        if not target then
            action_runtime.finish(false, "target is required")
            return true
        end
        Ability.CastTarget(ability, target, false, false, false, "api_cast_target")
    elseif string.find(action, "_POSITION$", 1, false) then
        local position = to_vector(params.position)
        if not position then
            action_runtime.finish(false, "position is required")
            return true
        end
        Ability.CastPosition(ability, position, false, false, false, "api_cast_position", true)
    else
        Ability.CastNoTarget(ability, false, false, false, "api_cast_no_target")
    end
    action_runtime.finish(true, "cast order sent")
    return true
end

local function update_external_action(hero, player, now)
    if external_action_expired(now) then
        reset_external_action()
        return false
    end

    local action = control.action
    if action == "AUTO" or action == "GO_TO_LANE" then
        return false
    end

    local dota_time = GameRules.GetDOTATime(false, false) or 0
    if dota_time < farm.laning_end_time and (action == "PUSH_LANE" or action == "FARM_LANE") then
        action_runtime.finish(false, "support does not farm lane creeps before 10:00")
        return true
    end
    if action == "FARM_LANE" then
        return false
    end

    if action == "STOP" or action == "HOLD_SAFE" then
        if now - control.last_order_time >= 0.30 then
            Player.HoldPosition(player, hero, false, false, false, "api_hold_safe")
            control.last_order_time = now
        end
        return true
    end

    if action == "RETREAT" then
        local position = to_vector(control.params.position)
        if not position then
            reset_external_action()
            return false
        end
        if (position - Entity.GetAbsOrigin(hero)):Length2D() <= 90 then
            Player.HoldPosition(player, hero, false, false, false, "api_retreat_arrived")
            return true
        end
        return issue_move_action(hero, player, position, "api_retreat", now)
    end

    if action == "MOVE_TO" or action == "GO_FOUNTAIN" then
        local position = action == "GO_FOUNTAIN"
            and action_runtime.fountain_position(hero)
            or to_vector(control.params.position)
        if not position then
            action_runtime.finish(false, "position is required")
            return true
        end
        if (position - Entity.GetAbsOrigin(hero)):Length2D() <= 100 then
            action_runtime.finish(true, "destination reached")
            return true
        end
        return issue_move_action(hero, player, position, "api_move_to", now)
    end

    if action == "ATTACK_MOVE" then
        local position = to_vector(control.params.position)
        if not position then
            action_runtime.finish(false, "position is required")
            return true
        end
        if now - control.last_order_time >= control.order_interval then
            Player.PrepareUnitOrders(
                player,
                Enum.UnitOrder.DOTA_UNIT_ORDER_ATTACK_MOVE,
                nil,
                make_tower_safe_destination(hero, position),
                nil,
                Enum.PlayerOrderIssuer.DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY,
                hero,
                false,
                false,
                false,
                false,
                "api_attack_move",
                true
            )
            control.last_order_time = now
        end
        return true
    end

    if action == "FARM_NEAREST_CAMP" or action == "FARM_CAMP" then
        return action_runtime.update_camp(hero, player, now)
    end

    if action == "PICKUP_RUNE" then
        return action_runtime.update_rune(hero, player, now)
    end

    if action == "SECURE_RUNE" then
        return action_runtime.update_secure_rune(hero, player, now)
    end

    if action == "FOLLOW_CORE" or action == "GROUP_WITH_TEAM" then
        return action_runtime.update_follow_core(hero, player, now)
    end

    if action == "PLACE_WARD"
        or action == "CHARGE_HERO"
        or action == "BULLDOZE"
        or action == "NETHER_STRIKE"
    then
        return action_runtime.execute_support_one_shot(hero, player, action)
    end

    if action == "CONTEST_OBJECTIVE" then
        local target = resolve_entity(control.params.target or control.params.targetIndex)
        if target and Entity.IsNPC(target) and Entity.IsAlive(target) and not Entity.IsSameTeam(hero, target) then
            if now - control.last_order_time >= control.order_interval then
                Player.AttackTarget(player, hero, target, false, false, false, "api_contest_objective", true)
                control.last_order_time = now
            end
            return true
        end
        local position = to_vector(control.params.position)
        if position then
            return issue_move_action(hero, player, position, "api_contest_objective", now)
        end
        action_runtime.finish(false, "objective target or position is required")
        return true
    end

    if action == "PUSH_LANE" then
        return action_runtime.update_push_lane(hero, player, now)
    end

    if action == "DEFEND_LANE" then
        local lane = normalize_lane(control.params.lane) or farm.selected_lane or "mid"
        if dota_time >= farm.laning_end_time and update_farming(hero, player, now, lane) then
            return true
        end
        if update_lane_positioning(hero, player, now, lane) then
            return true
        end
        update_lane_travel(hero, player, lane, now)
        return true
    end

    if action == "CAST_ABILITY_TARGET"
        or action == "CAST_ABILITY_POSITION"
        or action == "CAST_ABILITY_NO_TARGET"
        or action == "USE_ITEM_TARGET"
        or action == "USE_ITEM_POSITION"
        or action == "USE_ITEM_NO_TARGET"
        or action == "LEVEL_ABILITY"
        or action == "SET_QUICKBUY"
    then
        return action_runtime.execute_one_shot(hero, player, action)
    end

    if action == "ATTACK_UNIT" or action == "ATTACK_HERO" or action == "HARASS_HERO" or action == "DEWARD" then
        local target = resolve_entity(control.params.target or control.params.targetIndex)
        if not target
            or not Entity.IsNPC(target)
            or not Entity.IsAlive(target)
            or Entity.IsSameTeam(hero, target)
            or ((action == "ATTACK_HERO" or action == "HARASS_HERO") and not Entity.IsHero(target))
        then
            action_runtime.finish(false, "invalid attack target")
            return true
        end

        if now - control.last_order_time >= control.order_interval then
            Player.AttackTarget(
                player,
                hero,
                target,
                false,
                false,
                false,
                action == "HARASS_HERO" and "api_harass_hero" or "api_attack_target",
                true
            )
            control.last_order_time = now
        end
        return true
    end

    return false
end

local function get_external_lane_override()
    if control.action ~= "GO_TO_LANE"
        and control.action ~= "FARM_LANE"
        and control.action ~= "PUSH_LANE"
        and control.action ~= "DEFEND_LANE"
    then
        return nil
    end
    return normalize_lane(control.params.lane)
end

local function safe_read(callback, fallback)
    local ok, value = pcall(callback)
    if ok and value ~= nil then
        return value
    end
    return fallback
end

local function vector_snapshot(position)
    if not position then
        return nil
    end
    return { x = position.x, y = position.y, z = position.z }
end

local function unit_snapshot(hero, unit)
    local position = Entity.GetAbsOrigin(unit)
    local hero_position = Entity.GetAbsOrigin(hero)
    local health = Entity.GetHealth(unit) or 0
    local max_health = Entity.GetMaxHealth(unit) or 0
    return {
        index = Entity.GetIndex(unit),
        name = NPC.GetUnitName(unit),
        position = vector_snapshot(position),
        distance = (position - hero_position):Length2D(),
        health = health,
        maxHealth = max_health,
        healthPercent = max_health > 0 and health / max_health or 0,
        team = Entity.GetTeamNum(unit),
        isHero = Entity.IsHero(unit),
        isLaneCreep = safe_read(function() return NPC.IsLaneCreep(unit) end, false),
        isNeutral = safe_read(function() return NPC.IsNeutral(unit) end, false),
        isTower = safe_read(function() return NPC.IsTower(unit) end, false),
    }
end

function action_runtime.ability_snapshots(hero)
    local result = {}
    for index = 0, 23 do
        local ability = safe_read(function() return NPC.GetAbilityByIndex(hero, index) end, nil)
        if ability then
            local name = safe_read(function() return Ability.GetName(ability) end, "")
            if name ~= "" then
                result[#result + 1] = {
                    index = index,
                    name = name,
                    level = safe_read(function() return Ability.GetLevel(ability) end, 0),
                    maxLevel = safe_read(function() return Ability.GetMaxLevel(ability) end, 0),
                    manaCost = safe_read(function() return Ability.GetManaCost(ability) end, 0),
                    cooldown = safe_read(function() return Ability.GetCooldown(ability) end, 0),
                    castable = safe_read(function()
                        return Ability.IsCastable(ability, NPC.GetMana(hero))
                    end, false),
                }
            end
        end
    end
    return result
end

function action_runtime.item_snapshots(hero)
    local result = {}
    for index = 0, 16 do
        local item = safe_read(function() return NPC.GetItemByIndex(hero, index) end, nil)
        if item then
            result[#result + 1] = {
                index = index,
                name = safe_read(function() return Ability.GetName(item) end, ""),
                charges = safe_read(function() return Item.GetCurrentCharges(item) end, 0),
                cooldown = safe_read(function() return Ability.GetCooldown(item) end, 0),
                castable = safe_read(function()
                    return Ability.IsCastable(item, NPC.GetMana(hero))
                end, false),
            }
        end
    end
    return result
end

function action_runtime.map_snapshots(hero)
    local hero_pos = Entity.GetAbsOrigin(hero)
    local camps, runes, towers = {}, {}, {}
    for index, camp in pairs(Camps.GetAll() or {}) do
        local position = action_runtime.camp_center(camp)
        if position then
            camps[#camps + 1] = {
                index = index,
                type = safe_read(function() return Camp.GetType(camp) end, -1),
                position = vector_snapshot(position),
                distance = (position - hero_pos):Length2D(),
            }
        end
    end
    for _, rune in pairs(Runes.GetAll() or {}) do
        local position = Entity.GetAbsOrigin(rune)
        runes[#runes + 1] = {
            index = Entity.GetIndex(rune),
            type = safe_read(function() return Rune.GetRuneType(rune) end, -1),
            position = vector_snapshot(position),
            distance = (position - hero_pos):Length2D(),
        }
    end
    for _, npc in pairs(NPCs.InRadius(
        hero_pos,
        2200,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_BOTH,
        true,
        true
    ) or {}) do
        if Entity.IsAlive(npc) and NPC.IsTower(npc) then
            towers[#towers + 1] = unit_snapshot(hero, npc)
        end
    end
    return camps, runes, towers
end

local function build_observation()
    local hero = Heroes.GetLocal()
    local player = Players.GetLocal()
    if not hero or not player then
        return { ready = false, action = control.action, sequence = control.sequence }
    end

    local position = Entity.GetAbsOrigin(hero)
    local health = Entity.GetHealth(hero) or 0
    local max_health = Entity.GetMaxHealth(hero) or 0
    local enemies = Entity.GetHeroesInRadius(
        hero,
        2200,
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}
    local enemy_snapshots = {}
    for _, enemy in pairs(enemies) do
        enemy_snapshots[#enemy_snapshots + 1] = unit_snapshot(hero, enemy)
    end
    local ally_snapshots = {}
    for _, ally in pairs(Entity.GetHeroesInRadius(
        hero,
        2200,
        Enum.TeamType.TEAM_FRIEND,
        true,
        true
    ) or {}) do
        if ally ~= hero and Entity.IsAlive(ally) then
            ally_snapshots[#ally_snapshots + 1] = unit_snapshot(hero, ally)
        end
    end

    local nearby_enemy_creeps = 0
    local nearby_friendly_creeps = 0
    local nearby_unit_snapshots = {}
    local nearby_friends = NPCs.InRadius(
        position,
        1200,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_FRIEND,
        true,
        true
    ) or {}
    local nearby_enemies = NPCs.InRadius(
        position,
        1200,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_ENEMY,
        true,
        true
    ) or {}

    for _, unit in pairs(nearby_friends) do
        if Entity.IsAlive(unit) and NPC.IsLaneCreep(unit) then
            nearby_friendly_creeps = nearby_friendly_creeps + 1
            nearby_unit_snapshots[#nearby_unit_snapshots + 1] = unit_snapshot(hero, unit)
        end
    end
    for _, unit in pairs(nearby_enemies) do
        if Entity.IsAlive(unit) and NPC.IsLaneCreep(unit) then
            nearby_enemy_creeps = nearby_enemy_creeps + 1
            nearby_unit_snapshots[#nearby_unit_snapshots + 1] = unit_snapshot(hero, unit)
        end
    end

    local camp_snapshots, rune_snapshots, tower_snapshots = action_runtime.map_snapshots(hero)

    return {
        ready = true,
        gameTime = GameRules.GetDOTATime(false, false),
        action = control.action,
        actionSequence = control.sequence,
        bridgeCommandId = bridge.last_command_id,
        bridgeCommandLayer = bridge.last_command_layer,
        bridgeGoalId = bridge.last_goal_id,
        bridgeCommandSequence = bridge.last_command_sequence,
        macroGoal = bridge.macro_goal,
        actionStartedAt = control.started_at,
        actionExpiresAt = control.expires_at,
        completedSequence = control.completed_sequence,
        lastResult = control.last_result,
        lastError = control.last_error,
        lane = get_external_lane_override() or farm.selected_lane,
        hero = {
            index = Entity.GetIndex(hero),
            name = NPC.GetUnitName(hero),
            team = Entity.GetTeamNum(hero),
            position = vector_snapshot(position),
            health = health,
            maxHealth = max_health,
            healthPercent = max_health > 0 and health / max_health or 0,
            mana = safe_read(function() return NPC.GetMana(hero) end, 0),
            maxMana = safe_read(function() return NPC.GetMaxMana(hero) end, 0),
            attackRange = (NPC.GetAttackRange(hero) or 0) + (NPC.GetAttackRangeBonus(hero) or 0),
            moveSpeed = NPC.GetMoveSpeed(hero) or 0,
            recentDamage = Hero.GetRecentDamage(hero) or 0,
            gold = Player.GetTotalGold(player) or 0,
            level = safe_read(function() return NPC.GetCurrentLevel(hero) end, 0),
            abilityPoints = safe_read(function() return Hero.GetAbilityPoints(hero) end, 0),
        },
        nearbyEnemyCreeps = nearby_enemy_creeps,
        nearbyFriendlyCreeps = nearby_friendly_creeps,
        visibleEnemyHeroes = enemy_snapshots,
        nearbyAlliedHeroes = ally_snapshots,
        nearbyLaneCreeps = nearby_unit_snapshots,
        abilities = action_runtime.ability_snapshots(hero),
        items = action_runtime.item_snapshots(hero),
        camps = camp_snapshots,
        runes = rune_snapshots,
        nearbyTowers = tower_snapshots,
        towerAttackMode = farm.tower_attack_mode,
        towerSafetyAvailable = farm.tower_api_available,
        availableActions = {
            "AUTO",
            "STOP",
            "HOLD_SAFE",
            "MOVE_TO",
            "ATTACK_MOVE",
            "RETREAT",
            "GO_FOUNTAIN",
            "GO_TO_LANE",
            "FARM_LANE",
            "PUSH_LANE",
            "DEFEND_LANE",
            "FARM_NEAREST_CAMP",
            "FARM_CAMP",
            "PICKUP_RUNE",
            "SECURE_RUNE",
            "FOLLOW_CORE",
            "GROUP_WITH_TEAM",
            "PLACE_WARD",
            "DEWARD",
            "CONTEST_OBJECTIVE",
            "ATTACK_UNIT",
            "ATTACK_HERO",
            "HARASS_HERO",
            "ATTACK_TOWER",
            "CAST_ABILITY_TARGET",
            "CAST_ABILITY_POSITION",
            "CAST_ABILITY_NO_TARGET",
            "USE_ITEM_TARGET",
            "USE_ITEM_POSITION",
            "USE_ITEM_NO_TARGET",
            "LEVEL_ABILITY",
            "SET_QUICKBUY",
            "CHARGE_HERO",
            "BULLDOZE",
            "NETHER_STRIKE",
        },
    }
end

local neural_api = {}

function neural_api.Command(action, params, duration)
    return set_external_action(action, params, duration)
end

function neural_api.Cancel()
    reset_external_action()
    return true
end

function neural_api.GetObservation()
    local ok, observation = pcall(build_observation)
    if ok then
        return observation
    end
    return {
        ready = false,
        action = control.action,
        sequence = control.sequence,
        error = tostring(observation),
    }
end

function neural_api.MoveTo(position, duration)
    return set_external_action("MOVE_TO", { position = position }, duration or 6)
end

function neural_api.AttackMove(position, duration)
    return set_external_action("ATTACK_MOVE", { position = position }, duration or 6)
end

function neural_api.FarmLane(lane, duration)
    return set_external_action("FARM_LANE", { lane = lane }, duration or 8)
end

function neural_api.GoToLane(lane, duration)
    return set_external_action("GO_TO_LANE", { lane = lane }, duration or 8)
end

function neural_api.PushLane(lane, duration)
    return set_external_action("PUSH_LANE", { lane = lane }, duration or 10)
end

function neural_api.DefendLane(lane, duration)
    return set_external_action("DEFEND_LANE", { lane = lane }, duration or 10)
end

function neural_api.FarmNearestCamp(duration)
    return set_external_action("FARM_NEAREST_CAMP", {}, duration or 18)
end

function neural_api.FarmCamp(campIndex, duration)
    return set_external_action("FARM_CAMP", { campIndex = campIndex }, duration or 18)
end

function neural_api.PickupRune(target, duration)
    return set_external_action("PICKUP_RUNE", { target = target }, duration or 8)
end

function neural_api.SecureRune(target, position, duration)
    return set_external_action("SECURE_RUNE", { target = target, position = position }, duration or 12)
end

function neural_api.FollowCore(target, duration)
    return set_external_action("FOLLOW_CORE", { target = target }, duration or 12)
end

function neural_api.GroupWithTeam(target, duration)
    return set_external_action("GROUP_WITH_TEAM", { target = target }, duration or 12)
end

function neural_api.PlaceWard(position, wardType)
    return set_external_action("PLACE_WARD", { position = position, wardType = wardType }, 1)
end

function neural_api.Deward(target, duration)
    return set_external_action("DEWARD", { target = target }, duration or 3)
end

function neural_api.ContestObjective(target, position, duration)
    return set_external_action("CONTEST_OBJECTIVE", { target = target, position = position }, duration or 12)
end

function neural_api.GoFountain(duration)
    return set_external_action("GO_FOUNTAIN", {}, duration or 12)
end

function neural_api.Retreat(position, duration)
    return set_external_action("RETREAT", { position = position }, duration or 3)
end

function neural_api.HoldSafe(duration)
    return set_external_action("HOLD_SAFE", {}, duration or 1)
end

function neural_api.AttackHero(target, duration)
    return set_external_action("ATTACK_HERO", { target = target }, duration or 2)
end

function neural_api.AttackUnit(target, duration)
    return set_external_action("ATTACK_UNIT", { target = target }, duration or 2)
end

function neural_api.HarassHero(target, duration)
    return set_external_action("HARASS_HERO", { target = target }, duration or 1.2)
end

function neural_api.AttackTower(target, duration)
    return set_external_action("ATTACK_TOWER", { target = target }, duration or 5)
end

function neural_api.ChargeHero(target)
    return set_external_action("CHARGE_HERO", { target = target }, 1)
end

function neural_api.Bulldoze()
    return set_external_action("BULLDOZE", {}, 1)
end

function neural_api.NetherStrike(target)
    return set_external_action("NETHER_STRIKE", { target = target }, 1)
end

function neural_api.CastAbilityTarget(name, target)
    return set_external_action("CAST_ABILITY_TARGET", { name = name, target = target }, 1)
end

function neural_api.CastAbilityPosition(name, position)
    return set_external_action("CAST_ABILITY_POSITION", { name = name, position = position }, 1)
end

function neural_api.CastAbilityNoTarget(name)
    return set_external_action("CAST_ABILITY_NO_TARGET", { name = name }, 1)
end

function neural_api.UseItemTarget(name, target)
    return set_external_action("USE_ITEM_TARGET", { name = name, target = target }, 1)
end

function neural_api.UseItemPosition(name, position)
    return set_external_action("USE_ITEM_POSITION", { name = name, position = position }, 1)
end

function neural_api.UseItemNoTarget(name)
    return set_external_action("USE_ITEM_NO_TARGET", { name = name }, 1)
end

function neural_api.LevelAbility(name)
    return set_external_action("LEVEL_ABILITY", { name = name }, 1)
end

function neural_api.SetQuickBuy(itemName, reset)
    return set_external_action("SET_QUICKBUY", { itemName = itemName, reset = reset }, 1)
end

function action_runtime.json_escape(value)
    return string.gsub(value, '[%z\1-\31\\"]', function(character)
        local replacements = {
            ['"'] = '\\"',
            ['\\'] = '\\\\',
            ['\b'] = '\\b',
            ['\f'] = '\\f',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
        }
        return replacements[character] or string.format("\\u%04x", string.byte(character))
    end)
end

function action_runtime.json_encode(value, stack)
    local value_type = type(value)
    if value == nil then
        return "null"
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    elseif value_type == "string" then
        return '"' .. action_runtime.json_escape(value) .. '"'
    elseif value_type ~= "table" then
        return '"' .. action_runtime.json_escape(tostring(value)) .. '"'
    end

    stack = stack or {}
    if stack[value] then
        error("circular table in JSON")
    end
    stack[value] = true
    local is_array = true
    local max_index = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            is_array = false
            break
        end
        max_index = math.max(max_index, key)
    end
    local parts = {}
    if is_array then
        for index = 1, max_index do
            parts[#parts + 1] = action_runtime.json_encode(value[index], stack)
        end
        stack[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
        if type(key) == "string" then
            parts[#parts + 1] = '"' .. action_runtime.json_escape(key) .. '":'
                .. action_runtime.json_encode(item, stack)
        end
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function action_runtime.json_decode(text)
    local position = 1
    local length = #text
    local parse_value

    local function skip_space()
        while position <= length and string.match(string.sub(text, position, position), "%s") do
            position = position + 1
        end
    end

    local function parse_string()
        position = position + 1
        local parts = {}
        while position <= length do
            local character = string.sub(text, position, position)
            if character == '"' then
                position = position + 1
                return table.concat(parts)
            elseif character == "\\" then
                local escaped = string.sub(text, position + 1, position + 1)
                local replacements = {
                    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
                }
                if escaped == "u" then
                    local code = tonumber(string.sub(text, position + 2, position + 5), 16)
                    if not code then error("invalid JSON unicode escape") end
                    parts[#parts + 1] = code < 128 and string.char(code) or "?"
                    position = position + 6
                else
                    parts[#parts + 1] = replacements[escaped] or escaped
                    position = position + 2
                end
            else
                parts[#parts + 1] = character
                position = position + 1
            end
        end
        error("unterminated JSON string")
    end

    local function parse_number()
        local start = position
        while position <= length and string.match(string.sub(text, position, position), "[%d%+%-%eE%.]") do
            position = position + 1
        end
        local number = tonumber(string.sub(text, start, position - 1))
        if number == nil then error("invalid JSON number") end
        return number
    end

    local function parse_array()
        position = position + 1
        local result = {}
        skip_space()
        if string.sub(text, position, position) == "]" then
            position = position + 1
            return result
        end
        while true do
            result[#result + 1] = parse_value()
            skip_space()
            local character = string.sub(text, position, position)
            if character == "]" then
                position = position + 1
                return result
            elseif character ~= "," then
                error("invalid JSON array")
            end
            position = position + 1
        end
    end

    local function parse_object()
        position = position + 1
        local result = {}
        skip_space()
        if string.sub(text, position, position) == "}" then
            position = position + 1
            return result
        end
        while true do
            skip_space()
            if string.sub(text, position, position) ~= '"' then error("invalid JSON object key") end
            local key = parse_string()
            skip_space()
            if string.sub(text, position, position) ~= ":" then error("missing JSON colon") end
            position = position + 1
            result[key] = parse_value()
            skip_space()
            local character = string.sub(text, position, position)
            if character == "}" then
                position = position + 1
                return result
            elseif character ~= "," then
                error("invalid JSON object")
            end
            position = position + 1
        end
    end

    parse_value = function()
        skip_space()
        local character = string.sub(text, position, position)
        if character == '"' then return parse_string() end
        if character == "{" then return parse_object() end
        if character == "[" then return parse_array() end
        if string.sub(text, position, position + 3) == "true" then position = position + 4; return true end
        if string.sub(text, position, position + 4) == "false" then position = position + 5; return false end
        if string.sub(text, position, position + 3) == "null" then position = position + 4; return nil end
        return parse_number()
    end

    local result = parse_value()
    skip_space()
    if position <= length then error("trailing JSON data") end
    return result
end

function action_runtime.ensure_json()
    if bridge.json or bridge.json_failed then
        return bridge.json
    end
    local ok, json = pcall(require, "assets.JSON")
    if ok and json then
        bridge.json = json
    else
        bridge.json = {
            encode = function(_, value) return action_runtime.json_encode(value) end,
            decode = function(_, value) return action_runtime.json_decode(value) end,
        }
        bridge.last_error = nil
        Log.Write("[spirit_breaker_recorder] using embedded JSON codec: " .. tostring(json))
    end
    return bridge.json
end

function action_runtime.bridge_response(response)
    bridge.in_flight = false
    bridge.latency_ms = math.max(0, math.floor(((GameRules.GetGameTime() or 0) - bridge.request_started_at) * 1000))
    if not response or tostring(response.code) ~= "200" then
        bridge.connected = false
        bridge.failures = bridge.failures + 1
        bridge.last_error = response and (response.error_message or ("HTTP " .. tostring(response.code))) or "empty HTTP response"
        return
    end
    local json = action_runtime.ensure_json()
    if not json then
        return
    end
    local ok, payload = pcall(function() return json:decode(response.response or "") end)
    if not ok or type(payload) ~= "table" then
        bridge.connected = false
        bridge.failures = bridge.failures + 1
        bridge.last_error = "response JSON decode failed"
        return
    end
    bridge.connected = true
    bridge.failures = 0
    bridge.last_error = nil
    bridge.observe_only = payload.observeOnly ~= false
    bridge.macro_goal = payload.macroGoal
    bridge.micro_action = payload.microAction
    if bridge.pending_manual_order and bridge.sent_manual_sequence == bridge.pending_manual_order.sequence then
        if bridge.manual_orders[1]
            and bridge.manual_orders[1].sequence == bridge.sent_manual_sequence
        then
            table.remove(bridge.manual_orders, 1)
        end
        bridge.pending_manual_order = bridge.manual_orders[1]
    end
    local command = payload.command
    if not bridge.observe_only
        and ai_enabled
        and type(command) == "table"
        and command.id
        and command.id ~= bridge.last_command_id
    then
        bridge.last_command_id = command.id
        bridge.last_command_layer = command.layer
        bridge.last_goal_id = command.goalId
        local command_ok, command_result = set_external_action(
            command.action,
            command.params or {},
            tonumber(command.duration) or 1
        )
        if command_ok then
            bridge.last_command_sequence = tonumber(command_result) or control.sequence
        else
            Log.Write("[spirit_breaker_recorder] bridge command rejected: " .. tostring(command_result))
        end
    end
end

function action_runtime.update_bridge()
    if not bridge.enabled then
        return
    end
    local now = GameRules.GetGameTime() or 0
    if bridge.in_flight and now - bridge.request_started_at > bridge.timeout + 0.75 then
        bridge.in_flight = false
        bridge.connected = false
    end
    if bridge.in_flight then
        return
    end
    if now - bridge.last_request_time < bridge.interval then
        return
    end
    local json = action_runtime.ensure_json()
    if not json then
        return
    end
    local observation = neural_api.GetObservation()
    bridge.pending_manual_order = bridge.manual_orders[1]
    local payload = {
        protocolVersion = 1,
        clientTime = now,
        aiEnabled = ai_enabled,
        recordingEnabled = recording_enabled or #bridge.manual_orders > 0,
        lastLatencyMs = bridge.latency_ms,
        observation = observation,
        manualOrder = bridge.pending_manual_order,
    }
    local ok, encoded = pcall(function() return json:encode(payload) end)
    if not ok then
        bridge.failures = bridge.failures + 1
        bridge.last_error = "request JSON encode failed: " .. tostring(encoded)
        return
    end
    bridge.last_request_time = now
    bridge.request_started_at = now
    bridge.in_flight = true
    bridge.sent_manual_sequence = bridge.pending_manual_order
        and bridge.pending_manual_order.sequence
        or 0
    local sent = HTTP.Request(
        "POST",
        bridge.url,
        {
            data = encoded,
        },
        action_runtime.bridge_response
    )
    if not sent then
        bridge.in_flight = false
        bridge.connected = false
        bridge.failures = bridge.failures + 1
        bridge.last_error = "HTTP.Request returned false"
    end
end

function action_runtime.enqueue_manual_order(order)
    bridge.manual_sequence = bridge.manual_sequence + 1
    order.sequence = bridge.manual_sequence
    order.gameTime = order.gameTime or GameRules.GetDOTATime(false, false)
    order.stateBefore = order.stateBefore or neural_api.GetObservation()
    bridge.manual_orders[#bridge.manual_orders + 1] = order
    -- Avoid unbounded memory use if the bridge disappears during a match.
    if #bridge.manual_orders > 256 then
        table.remove(bridge.manual_orders, 1)
    end
    bridge.pending_manual_order = bridge.manual_orders[1]
end

function action_runtime.capture_manual_order(data)
    if not recording_enabled or ai_enabled or not data then
        return
    end
    local local_player = Players.GetLocal()
    local hero = Heroes.GetLocal()
    if not local_player or not hero or data.player ~= local_player or data.npc ~= hero then
        return
    end
    action_runtime.enqueue_manual_order({
        gameTime = GameRules.GetDOTATime(false, false),
        order = data.order,
        queue = data.queue == true,
        position = vector_snapshot(data.position),
        targetIndex = data.target and Entity.GetIndex(data.target) or nil,
        targetName = data.target and Entity.GetUnitName(data.target) or nil,
        abilityName = data.ability and Ability.GetName(data.ability) or nil,
        source = "prepare_unit_orders",
        stateBefore = neural_api.GetObservation(),
    })
    if bridge.pending_input and bridge.pending_input.kind == "item" and data.ability then
        local callback_name = safe_read(function() return Ability.GetName(data.ability) end, nil)
        if callback_name and callback_name == bridge.pending_input.name then
            bridge.pending_input = nil
        end
    end
end

local ability_hotkeys = {
    { key = "KEY_Q", index = 0 },
    { key = "KEY_W", index = 1 },
    { key = "KEY_E", index = 2 },
    { key = "KEY_D", index = 3 },
    { key = "KEY_F", index = 4 },
    { key = "KEY_R", index = 5 },
}

local item_hotkeys = {
    { key = "KEY_Z", index = 0 },
    { key = "KEY_X", index = 1 },
    { key = "KEY_C", index = 2 },
    { key = "KEY_V", index = 3 },
    { key = "KEY_B", index = 4 },
    { key = "KEY_N", index = 5 },
}

local no_target_abilities = {
    spirit_breaker_bulldoze = true,
}

local no_target_items = {
    item_power_treads = true,
    item_phase_boots = true,
    item_magic_stick = true,
    item_magic_wand = true,
    item_black_king_bar = true,
    item_mask_of_madness = true,
    item_manta = true,
    item_satanic = true,
    item_shadow_blade = true,
    item_silver_edge = true,
    item_dust = true,
    item_smoke_of_deceit = true,
}

local position_abilities = {
}

local target_abilities = {
    spirit_breaker_charge_of_darkness = true,
    spirit_breaker_nether_strike = true,
}

local function key_pressed(name)
    local key = Enum.ButtonCode[name]
    return key ~= nil and Input.IsKeyDownOnce(key)
end

local function unit_near_cursor(hero, cursor, radius)
    local nearest, nearest_distance = nil, radius
    for _, unit in pairs(NPCs.InRadius(
        cursor,
        radius + 30,
        Entity.GetTeamNum(hero),
        Enum.TeamType.TEAM_BOTH,
        true,
        true
    ) or {}) do
        if unit ~= hero and Entity.IsAlive(unit) then
            local distance = (Entity.GetAbsOrigin(unit) - cursor):Length2D()
            if distance < nearest_distance then
                nearest, nearest_distance = unit, distance
            end
        end
    end
    return nearest
end

local function input_order_from_intent(hero, intent, cursor)
    local nearest = unit_near_cursor(hero, cursor, 150)
    local order = Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_POSITION
    if intent.kind == "attack_move" then
        order = nearest and not Entity.IsSameTeam(hero, nearest)
            and Enum.UnitOrder.DOTA_UNIT_ORDER_ATTACK_TARGET
            or Enum.UnitOrder.DOTA_UNIT_ORDER_ATTACK_MOVE
    elseif target_abilities[intent.name] or (nearest and not position_abilities[intent.name]) then
        order = Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_TARGET
    end
    return order, nearest
end

local function remember_input_intent(kind, name, handle, now, key)
    bridge.pending_input = {
        kind = kind,
        name = name,
        handle = handle,
        key = key,
        startedAt = now,
        cursor = vector_snapshot(Input.GetWorldCursorPos()),
        cooldown = handle and (Ability.GetCooldown(handle) or 0) or 0,
        charges = handle and safe_read(function() return Item.GetCurrentCharges(handle) end, nil) or nil,
        mana = safe_read(function() return NPC.GetMana(Heroes.GetLocal()) end, 0),
        stateBefore = neural_api.GetObservation(),
    }
end

local function record_immediate_order(order, source, state_before)
    action_runtime.enqueue_manual_order({
        order = order,
        queue = false,
        source = source,
        stateBefore = state_before or neural_api.GetObservation(),
    })
end

local function detect_manual_state_changes(hero, player)
    local current = {
        observation = neural_api.GetObservation(),
        abilityLevels = {},
        items = {},
        goldSpentItems = 0,
    }
    for index = 0, 20 do
        local ability = NPC.GetAbilityByIndex(hero, index)
        if ability then
            current.abilityLevels[Ability.GetName(ability)] = Ability.GetLevel(ability) or 0
        end
        local item = NPC.GetItemByIndex(hero, index)
        if item then
            local name = Ability.GetName(item)
            current.items[name] = (current.items[name] or 0) + 1
        end
    end
    local team_player = safe_read(function() return Player.GetTeamPlayer(player) end, nil)
    if team_player then
        current.goldSpentItems = team_player.gold_spent_on_items or 0
    end

    local previous = bridge.previous_manual_state
    bridge.previous_manual_state = current
    if not previous then
        return
    end

    for name, level in pairs(current.abilityLevels) do
        local old_level = previous.abilityLevels[name] or 0
        if level > old_level then
            action_runtime.enqueue_manual_order({
                order = Enum.UnitOrder.DOTA_UNIT_ORDER_TRAIN_ABILITY,
                abilityName = name,
                levelBefore = old_level,
                levelAfter = level,
                source = "observed_ability_level",
                stateBefore = previous.observation,
            })
        end
    end

    if current.goldSpentItems > previous.goldSpentItems then
        local additions = {}
        for name, count in pairs(current.items) do
            local added = count - (previous.items[name] or 0)
            for _ = 1, math.max(0, added) do
                additions[#additions + 1] = name
            end
        end
        if #additions == 0 then
            additions[1] = "unknown_item"
        end
        for _, name in pairs(additions) do
            action_runtime.enqueue_manual_order({
                order = Enum.UnitOrder.DOTA_UNIT_ORDER_PURCHASE_ITEM,
                itemName = name,
                abilityName = name ~= "unknown_item" and name or nil,
                goldSpentDelta = current.goldSpentItems - previous.goldSpentItems,
                source = "observed_purchase",
                stateBefore = previous.observation,
            })
        end
    end
end

-- OnPrepareUnitOrders receives only script-pushed orders in current Umbrella
-- builds. Record normal play from input plus observable game-state changes.
function action_runtime.capture_manual_input()
    if not recording_enabled or ai_enabled then
        bridge.pending_input = nil
        bridge.previous_manual_state = nil
        bridge.right_mouse_held = false
        bridge.last_right_cursor = nil
        return
    end

    local hero = Heroes.GetLocal()
    local player = Players.GetLocal()
    if not hero or not player or not Entity.IsAlive(hero) then
        return
    end

    detect_manual_state_changes(hero, player)
    local now = GameRules.GetGameTime() or 0
    local captured = safe_read(function() return Input.IsInputCaptured() end, false)
    if captured then
        return
    end

    local state_before = neural_api.GetObservation()
    if key_pressed("KEY_S") then
        record_immediate_order(Enum.UnitOrder.DOTA_UNIT_ORDER_STOP, "keyboard_stop", state_before)
        bridge.pending_input = nil
    elseif key_pressed("KEY_H") then
        record_immediate_order(Enum.UnitOrder.DOTA_UNIT_ORDER_HOLD_POSITION, "keyboard_hold", state_before)
        bridge.pending_input = nil
    elseif key_pressed("KEY_A") then
        remember_input_intent("attack_move", nil, nil, now, "A")
    end

    for _, binding in pairs(ability_hotkeys) do
        if key_pressed(binding.key) then
            local ability = NPC.GetAbilityByIndex(hero, binding.index)
            if ability and Ability.GetLevel(ability) > 0 then
                local name = Ability.GetName(ability)
                if no_target_abilities[name] then
                    action_runtime.enqueue_manual_order({
                        order = Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_NO_TARGET,
                        abilityName = name,
                        inputKey = binding.key,
                        source = "keyboard_ability",
                        stateBefore = state_before,
                    })
                    bridge.pending_input = nil
                else
                    remember_input_intent("ability", name, ability, now, binding.key)
                end
            end
        end
    end

    for _, binding in pairs(item_hotkeys) do
        if key_pressed(binding.key) then
            local item = NPC.GetItemByIndex(hero, binding.index)
            if item then
                local name = Ability.GetName(item)
                if no_target_items[name] then
                    action_runtime.enqueue_manual_order({
                        order = Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_NO_TARGET,
                        abilityName = name,
                        inputKey = binding.key,
                        source = "keyboard_item",
                        stateBefore = state_before,
                    })
                    bridge.pending_input = nil
                else
                    remember_input_intent("item", name, item, now, binding.key)
                end
            end
        end
    end
    if key_pressed("KEY_T") then
        local teleport = NPC.GetItem(hero, "item_tpscroll", true)
        if teleport then
            remember_input_intent("item", "item_tpscroll", teleport, now, "KEY_T")
        end
    end

    local cursor = Input.GetWorldCursorPos()
    if key_pressed("KEY_MOUSE1") and bridge.pending_input and cursor then
        local intent = bridge.pending_input
        local order, nearest = input_order_from_intent(hero, intent, cursor)
        local clicked = {
            order = order,
            queue = false,
            position = vector_snapshot(cursor),
            targetIndex = nearest and Entity.GetIndex(nearest) or nil,
            targetName = nearest and Entity.GetUnitName(nearest) or nil,
            abilityName = intent.name,
            inputKey = intent.key,
            source = "keyboard_then_left_click",
            stateBefore = intent.stateBefore,
        }
        if intent.kind == "item" then
            -- Executed item casts normally arrive through OnPrepareUnitOrders
            -- with the exact target type. Keep this only as a delayed fallback.
            intent.clicked = clicked
            intent.clickedAt = now
        else
            action_runtime.enqueue_manual_order(clicked)
            bridge.pending_input = nil
        end
    end

    local right_down = Input.IsKeyDown(Enum.ButtonCode.KEY_MOUSE2)
    local right_once = right_down and not bridge.right_mouse_held
    local held_cursor_distance = math.huge
    if cursor and bridge.last_right_cursor then
        local dx = cursor.x - bridge.last_right_cursor.x
        local dy = cursor.y - bridge.last_right_cursor.y
        held_cursor_distance = math.sqrt(dx * dx + dy * dy)
    end
    local sample_held_right = right_down
        and bridge.right_mouse_held
        and now - bridge.last_manual_input_time >= bridge.held_right_interval
        and held_cursor_distance >= bridge.held_right_min_distance

    if (right_once or sample_held_right) and cursor then
        local nearest = unit_near_cursor(hero, cursor, 150)
        local order = Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_POSITION
        if nearest then
            order = Entity.IsSameTeam(hero, nearest)
                and Enum.UnitOrder.DOTA_UNIT_ORDER_MOVE_TO_TARGET
                or Enum.UnitOrder.DOTA_UNIT_ORDER_ATTACK_TARGET
        end
        bridge.last_manual_input_time = now
        bridge.last_right_cursor = vector_snapshot(cursor)
        action_runtime.enqueue_manual_order({
            order = order,
            queue = false,
            position = vector_snapshot(cursor),
            targetIndex = nearest and Entity.GetIndex(nearest) or nil,
            targetName = nearest and Entity.GetUnitName(nearest) or nil,
            source = right_once and "inferred_right_click" or "sampled_held_right_click",
            stateBefore = state_before,
        })
        bridge.pending_input = nil
    end
    bridge.right_mouse_held = right_down
    if not right_down then
        bridge.last_right_cursor = nil
    end

    local intent = bridge.pending_input
    if intent and intent.handle then
        local cooldown = safe_read(function() return Ability.GetCooldown(intent.handle) end, intent.cooldown)
        local charges = safe_read(function() return Item.GetCurrentCharges(intent.handle) end, intent.charges)
        local mana = NPC.GetMana(hero) or intent.mana
        local spent_mana = intent.kind == "ability" and mana < intent.mana - 1
        local spent_charge = intent.charges ~= nil and charges ~= nil and charges < intent.charges
        if intent.clicked and now - intent.clickedAt >= 0.35 then
            action_runtime.enqueue_manual_order(intent.clicked)
            bridge.pending_input = nil
        elseif not intent.clicked and (cooldown > intent.cooldown + 0.03 or spent_mana or spent_charge) then
            local order = position_abilities[intent.name]
                and Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_POSITION
                or target_abilities[intent.name]
                    and Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_TARGET
                    or Enum.UnitOrder.DOTA_UNIT_ORDER_CAST_NO_TARGET
            action_runtime.enqueue_manual_order({
                order = order,
                position = intent.cursor,
                abilityName = intent.name,
                inputKey = intent.key,
                source = "observed_quickcast",
                stateBefore = intent.stateBefore,
            })
            bridge.pending_input = nil
        elseif now - intent.startedAt > 1.5 then
            bridge.pending_input = nil
        end
    elseif intent and now - intent.startedAt > 1.5 then
        bridge.pending_input = nil
    end
end

local function ensure_neural_api_registered()
    if control.api_registered or control.api_error_logged then
        return
    end

    local ok, err = pcall(function()
        DotaAI = neural_api
    end)
    if ok then
        control.api_registered = true
        Log.Write("[spirit_breaker_recorder] neural API registered as DotaAI")
    else
        control.api_error_logged = true
        Log.Write("[spirit_breaker_recorder] neural API registration failed: " .. tostring(err))
    end
end

function script.OnUpdate()
    ensure_neural_api_registered()
    local manual_ok, manual_error = pcall(action_runtime.capture_manual_input)
    if not manual_ok then
        bridge.last_error = "manual input error: " .. tostring(manual_error)
        if bridge.last_manual_error ~= tostring(manual_error) then
            bridge.last_manual_error = tostring(manual_error)
            Log.Write("[spirit_breaker_recorder] manual input error: " .. tostring(manual_error))
        end
    else
        bridge.last_manual_error = nil
    end

    local bridge_ok, bridge_error = pcall(action_runtime.update_bridge)
    if not bridge_ok then
        bridge.in_flight = false
        bridge.connected = false
        bridge.failures = bridge.failures + 1
        bridge.last_error = "bridge error: " .. tostring(bridge_error)
        if bridge.failures == 1 then
            Log.Write("[spirit_breaker_recorder] bridge isolated error: " .. tostring(bridge_error))
        end
    end

end

function script.OnDraw()
    update_button()
    draw_button()

    local bridge_label = bridge.connected
        and (recording_enabled
            and (bridge.observe_only and "bridge: REC" or "bridge: LIVE")
            or (#bridge.manual_orders > 0 and "bridge: FLUSHING" or "bridge: PAUSED"))
        or "bridge: offline"
    local bridge_color = bridge.connected and Color(220, 255, 220, 240) or Color(255, 190, 190, 230)
    Render.Text(
        button_font,
        13,
        bridge_label .. (bridge.connected and (
            "  " .. tostring(bridge.latency_ms) .. "ms"
            .. "  orders:" .. tostring(bridge.manual_sequence)
            .. "  q:" .. tostring(#bridge.manual_orders)
        ) or ""),
        Vec2(button.x + 4, button.y + button.height + 4),
        bridge_color
    )
    if bridge.last_error then
        Render.Text(
            button_font,
            12,
            string.sub(bridge.last_error, 1, 72),
            Vec2(button.x + 4, button.y + button.height + 20),
            Color(255, 170, 170, 235)
        )
    end
end

function script.OnPrepareUnitOrders(data)
    local ok, err = pcall(action_runtime.capture_manual_order, data)
    if not ok then
        Log.Write("[spirit_breaker_recorder] manual recorder error: " .. tostring(err))
    end
    return true
end

return script
