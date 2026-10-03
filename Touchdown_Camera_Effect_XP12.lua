--[[
X-Plane 12 Touchdown Camera Effect v1.11
FlyWithLua NG

Features:
- Touchdown camera effect with optional Light / Medium / Heavy sound (no smoke)
- Separate main gear and delayed nose gear contact detection
- Adjustable nose intensity and nose gear array index per ICAO
- onground_any fallback when individual contacts are unavailable
- Uses last airborne vertical speed
- Automatic per-aircraft multiplier via PLANE_ICAO
- Live tuning window
- Test buttons: -100 / -200 / -300 / -400 / -600 fpm
- Master strength, vertical movement, pitch movement and duration sliders
- Save current aircraft multiplier to a small config file
- Toggle window command:
  xbrief/touchdown_camera/toggle_settings

Install:
Resources/plugins/FlyWithLua/Scripts/Touchdown_Camera_Effect_XP12.lua

Notes:
- Intended for 3D cockpit view.
- Head-tracking / camera plugins may also write the same head datarefs.
  In that case both systems can compete for camera position.
--]]

if not SUPPORTS_FLOATING_WINDOWS then
    logMsg("[Touchdown Camera] Floating windows / ImGui not supported.")
    return
end

-- ============================================================
-- DATAREFS
-- ============================================================

local dr_on_ground = XPLMFindDataRef("sim/flightmodel/failures/onground_any")
local dr_vspeed    = XPLMFindDataRef("sim/flightmodel/position/vh_ind_fpm")
local dr_head_y    = XPLMFindDataRef("sim/graphics/view/pilots_head_y")
local dr_head_the  = XPLMFindDataRef("sim/graphics/view/pilots_head_the")

if dr_on_ground == nil or dr_vspeed == nil or dr_head_y == nil or dr_head_the == nil then
    logMsg("[Touchdown Camera] ERROR: Required X-Plane dataref not found.")
    return
end

-- ============================================================
-- USER SETTINGS
-- ============================================================

local enabled = true
local camera_mode = 1 -- 1 Auto, 2 X-Plane, 3 X-Camera
local xcamera_script_id = 767
local xc_refs = nil
local effect_backend = nil
local xc_owned = false
local xc_last_y = 0
local xc_last_pitch = 0
local camera_route_status = "X-Plane"

local nose_strength_profiles = {}
local nose_index_profiles = {}
local default_nose_strength = 0.35
local gear_contacts = nil
if type(dataref_table) == "function" and XPLMFindDataRef("sim/flightmodel2/gear/on_ground") ~= nil then
    gear_contacts = dataref_table("sim/flightmodel2/gear/on_ground")
end

-- Optional sound selection: 1 = Light, 2 = Medium, 3 = Heavy
local sound_enabled = true
local sound_choice = 2
local sound_volume = 0.65
local sound_names = { "Light", "Medium", "Heavy" }
local sound_handles = {}
local sound_status = ""

-- Active aircraft tuning
local master_strength   = 1.00
local max_vertical_move = 0.060   -- meters at maximum normalized impact
local max_pitch_move    = 0.30    -- degrees
local effect_duration   = 0.48    -- seconds

-- Touchdown processing
local min_touchdown_fpm = 40
local max_touchdown_fpm = 700
local response_curve    = 1.35

-- Per-aircraft multiplier.
-- Add/change ICAO codes here if desired.
local aircraft_strength = {
    B752 = 1.00,
    B753 = 0.95,
    B762 = 0.90,
    B763 = 0.88,
    B764 = 0.85,

    B738 = 1.05,
    B739 = 1.00,
    B744 = 0.75,
    B748 = 0.72,
    B772 = 0.78,
    B77W = 0.76,
    B788 = 0.80,
    B789 = 0.78,

    A319 = 1.05,
    A320 = 1.00,
    A321 = 0.95,
    A332 = 0.82,
    A333 = 0.80,
    A339 = 0.78,
    A343 = 0.78,
    A346 = 0.75,
    A359 = 0.76,
    A35K = 0.74,

    E170 = 1.10,
    E175 = 1.08,
    E190 = 1.05,
    E195 = 1.02,

    C172 = 1.30
}

local default_aircraft_strength = 1.00

-- ============================================================
-- CONFIG FILE
-- ============================================================

local tuning_profiles = {}
local active_aircraft_code = nil
local capture_active_profile = nil
local baseline_tuning = nil
local profile_limits = {
    ENABLED = {0, 1, true}, MASTER = {0, 2}, VERTICAL = {0, 0.150},
    PITCH = {0, 5.00}, DURATION = {0.15, 2.00},
    SOUND_ENABLED = {0, 1, true}, SOUND_CHOICE = {1, 3, true}, SOUND_VOLUME = {0, 1},
    CAMERA_MODE = {1, 3, true}, XCAMERA_SCRIPT_ID = {1, 9999, true}
}

local save_status = ""
local config_file = SCRIPT_DIRECTORY .. "Touchdown_Camera_Effect_XP12.cfg"

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function load_aircraft_config()
    local f = io.open(config_file, "r")
    if not f then return end

    for line in f:lines() do
        local clean = trim(line)
        if clean ~= "" and string.sub(clean, 1, 1) ~= "#" then
            local icao, value = string.match(clean, "^([%w_%-]+)%s*=%s*([%d%.]+)$")
            if icao and value then
                local n = tonumber(value)
                if n then
                    local profile_code, field = icao:match("^PROFILE_([%w]+)_([%w_]+)$")
                    local nose_code = icao:match("^NOSE_STRENGTH_(.+)$")
                    local index_code = icao:match("^NOSE_INDEX_(.+)$")
                    if profile_code and profile_limits[field] then
                        local limits = profile_limits[field]
                        n = math.max(limits[1], math.min(limits[2], n))
                        if limits[3] then n = math.floor(n) end
                        tuning_profiles[profile_code] = tuning_profiles[profile_code] or {}
                        tuning_profiles[profile_code][field] = n
                    elseif nose_code then
                        nose_strength_profiles[nose_code] = math.max(0, math.min(1, n))
                    elseif index_code then
                        nose_index_profiles[index_code] = math.max(0, math.min(9, math.floor(n)))
                    elseif icao == "CAMERA_MODE" then
                        camera_mode = math.max(1, math.min(3, math.floor(n)))
                    elseif icao == "XCAMERA_SCRIPT_ID" then
                        xcamera_script_id = math.max(1, math.min(9999, math.floor(n)))
                    elseif icao == "SOUND_CHOICE" then
                        sound_choice = math.max(1, math.min(3, math.floor(n)))
                    elseif icao == "SOUND_VOLUME" then
                        sound_volume = math.max(0, math.min(1, n))
                    elseif icao == "SOUND_ENABLED" then
                        sound_enabled = n ~= 0
                    else
                        aircraft_strength[string.upper(icao)] = n
                    end
                end
            end
        end
    end

    f:close()
end

local function save_aircraft_config()
    if capture_active_profile then capture_active_profile() end
    local f = io.open(config_file, "w")
    if not f then
        logMsg("[Touchdown Camera] Could not write config file: " .. config_file)
        save_status = "Save failed: cannot open config for writing."
        return false
    end

    local write_error = nil
    local function write(text)
        if write_error then return end
        local ok, err = f:write(text)
        if not ok then write_error = tostring(err or "write error") end
    end

    write("# X-Plane 12 Touchdown Camera Effect - ICAO aircraft settings\n")
    write("# 1.00 = normal, 0.50 = half, 1.50 = 50% stronger\n\n")

    write(string.format("SOUND_CHOICE=%d\nSOUND_VOLUME=%.2f\nSOUND_ENABLED=%d\n\n",
        baseline_tuning.SOUND_CHOICE, baseline_tuning.SOUND_VOLUME, baseline_tuning.SOUND_ENABLED))

    write(string.format("CAMERA_MODE=%d\nXCAMERA_SCRIPT_ID=%d\n\n", baseline_tuning.CAMERA_MODE, baseline_tuning.XCAMERA_SCRIPT_ID))
    local keys = {}
    for icao, _ in pairs(aircraft_strength) do
        table.insert(keys, icao)
    end
    table.sort(keys)

    for _, icao in ipairs(keys) do
        write(string.format("%s=%.2f\n", icao, aircraft_strength[icao]))
    end

    for _, icao in ipairs(keys) do
        write(string.format("NOSE_STRENGTH_%s=%.2f\nNOSE_INDEX_%s=%d\n", icao,
            nose_strength_profiles[icao] or default_nose_strength, icao, nose_index_profiles[icao] or 0))
    end
    local profile_codes = {}
    for code in pairs(tuning_profiles) do table.insert(profile_codes, code) end
    table.sort(profile_codes)
    local fields = {}
    for field in pairs(profile_limits) do table.insert(fields, field) end
    table.sort(fields)
    for _, code in ipairs(profile_codes) do
        for _, field in ipairs(fields) do
            local value = tuning_profiles[code][field]
            if value ~= nil then
                write(string.format("PROFILE_%s_%s=%.6f\n", code, field, value))
            end
        end
    end
    local closed, close_error = f:close()
    if write_error or not closed then
        save_status = "Save failed: " .. tostring(write_error or close_error or "close error")
        logMsg("[Touchdown Camera] " .. save_status)
        return false
    end
    save_status = "Saved settings for " .. tostring(active_aircraft_code) .. "."
    return true
end

load_aircraft_config()
baseline_tuning = {
    ENABLED = 1, MASTER = master_strength, VERTICAL = max_vertical_move,
    PITCH = max_pitch_move, DURATION = effect_duration,
    SOUND_ENABLED = sound_enabled and 1 or 0, SOUND_CHOICE = sound_choice, SOUND_VOLUME = sound_volume,
    CAMERA_MODE = camera_mode, XCAMERA_SCRIPT_ID = xcamera_script_id
}

-- FlyWithLua owns loaded sound resources and cleans them up on script reload.
-- Check file presence before calling load_WAV_file: a missing sound must
-- never quarantine the camera script.
local function load_touchdown_sounds()
    if type(load_WAV_file) ~= "function" or type(play_sound) ~= "function"
        or type(set_sound_gain) ~= "function" then
        sound_status = "Sound API unavailable; camera effect still works."
        return
    end
    local missing = {}
    for i, name in ipairs(sound_names) do
        local path = SCRIPT_DIRECTORY .. "Touchdown_Camera_Sounds/" .. string.lower(name) .. ".wav"
        local file = io.open(path, "rb")
        if file then
            file:close()
            local ok, handle = pcall(load_WAV_file, path)
            if ok and type(handle) == "number" and handle >= 0 then
                sound_handles[i] = handle
            else
                table.insert(missing, name)
            end
        else
            table.insert(missing, name)
        end
    end
    if #missing > 0 then
        sound_status = "Sounds unavailable: " .. table.concat(missing, ", ")
        logMsg("[Touchdown Camera] " .. sound_status)
    else
        sound_status = "Light / Medium / Heavy ready"
    end
end

local function stop_touchdown_sounds()
    if type(stop_sound) == "function" then
        for _, handle in pairs(sound_handles) do stop_sound(handle) end
    end
end

local function play_touchdown_sound(gain_scale)
    if not sound_enabled or sound_volume <= 0 then return end
    local handle = sound_handles[sound_choice]
    if handle == nil then return end
    stop_touchdown_sounds()
    set_sound_gain(handle, sound_volume * (gain_scale or 1))
    play_sound(handle)
end

load_touchdown_sounds()

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local last_airborne_vs = 0
local last_touchdown_vs = 0
local last_effect_strength = 0

local effect_active = false
local effect_elapsed = 0

-- Offset applied by THIS script on the previous frame.
-- Removing it first means external head movement can continue.
local last_applied_y = 0
local last_applied_pitch = 0

local settings_wnd = nil
local airborne_time = 0
local landing_armed = false
local main_landed = false
local nose_pending = false
local main_impact_strength = 0
local previous_nose_ground = nil
local last_event = "None"
local test_nose_delay = nil

-- ============================================================
-- HELPERS
-- ============================================================

local function current_icao()
    local code = PLANE_ICAO or "UNKNOWN"
    code = tostring(code)
    if code == "" then code = "UNKNOWN" end
    return string.upper(code)
end

local function get_aircraft_strength()
    local icao = current_icao()
    return aircraft_strength[icao] or default_aircraft_strength
end

local function set_aircraft_strength(value)
    local icao = current_icao()
    aircraft_strength[icao] = value
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function calculate_touchdown_strength(vs)
    local sinkrate = math.abs(vs)

    if sinkrate < min_touchdown_fpm then
        return 0
    end

    sinkrate = clamp(sinkrate, min_touchdown_fpm, max_touchdown_fpm)

    local normalized =
        (sinkrate - min_touchdown_fpm) /
        (max_touchdown_fpm - min_touchdown_fpm)

    normalized = normalized ^ response_curve

    return normalized * master_strength * get_aircraft_strength()
end

-- Documented X-Camera Offset Method. Optional refs are never created here.
-- Cache valid handles, and allow manual refresh if X-Camera was loaded later.
function td_camera_scan_xcamera()
    local refs = {}
    local names = {
        status = "overall_status", id = "effect_script_id",
        y = "effect_script_y_offset", pitch = "effect_script_pitch_offset"
    }
    for key, suffix in pairs(names) do
        refs[key] = XPLMFindDataRef("SRS/X-Camera/integration/" .. suffix)
        if refs[key] == nil then xc_refs = nil; return end
    end
    xc_refs = refs
end

td_camera_scan_xcamera()

local function xc_matching()
    return xc_refs ~= nil and XPLMGetDatai(xc_refs.status) ~= 0
        and XPLMGetDatai(xc_refs.id) == xcamera_script_id
end

local function choose_camera_backend()
    if camera_mode == 2 then camera_route_status = "X-Plane (manual)"; return "xp" end
    if xc_matching() then camera_route_status = "X-Camera / ID " .. xcamera_script_id; return "xc" end
    if camera_mode == 3 then
        camera_route_status = "X-Camera waiting: enable Lua Script / ID " .. xcamera_script_id
        return nil
    end
    if xc_refs ~= nil and XPLMGetDatai(xc_refs.status) ~= 0 then
        camera_route_status = "X-Camera active: select Lua Script / ID " .. xcamera_script_id
        return nil -- Never compete with a different script/camera in Auto mode.
    end
    camera_route_status = "X-Plane (Auto)"
    return "xp"
end

local function clear_xcamera_offset()
    if not xc_owned then return end
    -- Shared channels: do not erase offsets supplied by another script after
    -- a camera/ID switch. Clear only our matching values while selected.
    if xc_matching() then
        if math.abs(XPLMGetDataf(xc_refs.y) - xc_last_y) < 0.000001 then XPLMSetDataf(xc_refs.y, 0) end
        if math.abs(XPLMGetDataf(xc_refs.pitch) - xc_last_pitch) < 0.000001 then XPLMSetDataf(xc_refs.pitch, 0) end
    end
    xc_owned = false
    xc_last_y = 0
    xc_last_pitch = 0
end

local function remove_previous_camera_offset()
    clear_xcamera_offset()
    if math.abs(last_applied_y) > 0.000001 or math.abs(last_applied_pitch) > 0.000001 then
        local current_y = XPLMGetDataf(dr_head_y)
        local current_pitch = XPLMGetDataf(dr_head_the)

        XPLMSetDataf(dr_head_y, current_y - last_applied_y)
        XPLMSetDataf(dr_head_the, current_pitch - last_applied_pitch)

        last_applied_y = 0
        last_applied_pitch = 0
    end
end

capture_active_profile = function()
    if active_aircraft_code == nil then return end
    tuning_profiles[active_aircraft_code] = {
        ENABLED = enabled and 1 or 0, MASTER = master_strength, VERTICAL = max_vertical_move,
        PITCH = max_pitch_move, DURATION = effect_duration,
        SOUND_ENABLED = sound_enabled and 1 or 0, SOUND_CHOICE = sound_choice, SOUND_VOLUME = sound_volume,
        CAMERA_MODE = camera_mode, XCAMERA_SCRIPT_ID = xcamera_script_id
    }
    if aircraft_strength[active_aircraft_code] == nil then
        aircraft_strength[active_aircraft_code] = default_aircraft_strength
    end
end

local function apply_aircraft_tuning(code)
    local profile = tuning_profiles[code] or {}
    local function value(field)
        if profile[field] ~= nil then return profile[field] end
        return baseline_tuning[field]
    end
    enabled = value("ENABLED") ~= 0
    master_strength = value("MASTER")
    max_vertical_move = value("VERTICAL")
    max_pitch_move = value("PITCH")
    effect_duration = value("DURATION")
    sound_enabled = value("SOUND_ENABLED") ~= 0
    sound_choice = value("SOUND_CHOICE")
    sound_volume = value("SOUND_VOLUME")
    camera_mode = value("CAMERA_MODE")
    xcamera_script_id = value("XCAMERA_SCRIPT_ID")
end

local function sync_aircraft_profile()
    local code = current_icao()
    if code == active_aircraft_code then return end
    remove_previous_camera_offset() -- clear using the OLD script ID first
    effect_active = false
    test_nose_delay = nil
    stop_touchdown_sounds()
    capture_active_profile()
    active_aircraft_code = code
    apply_aircraft_tuning(code)
    airborne_time = 0
    landing_armed = false
    main_landed = false
    nose_pending = false
    previous_nose_ground = nil
end

sync_aircraft_profile()

-- ============================================================
-- CAMERA EFFECT
-- ============================================================

local function nose_strength()
    return nose_strength_profiles[current_icao()] or default_nose_strength
end
local function nose_index()
    return nose_index_profiles[current_icao()] or 0
end

function td_camera_trigger(vs, multiplier, event_name)
    if not enabled then return end

    local backend = choose_camera_backend()
    if backend == nil then return end
    local strength = calculate_touchdown_strength(vs) * (multiplier or 1)
    if strength <= 0 then return end

    -- Stop any existing effect cleanly before starting another one.
    remove_previous_camera_offset()

    effect_backend = backend
    effect_elapsed = 0
    effect_active = true

    last_touchdown_vs = vs
    last_effect_strength = strength
    last_event = event_name or "Main gear / test"
    play_touchdown_sound(multiplier)

    logMsg(string.format(
        "[Touchdown Camera] %s | %.0f fpm | aircraft %.2f | final %.2f",
        current_icao(),
        vs,
        get_aircraft_strength(),
        strength
    ))
end

local function update_camera_effect()
    if not effect_active then return end
    if choose_camera_backend() ~= effect_backend then
        remove_previous_camera_offset()
        effect_active = false
        test_nose_delay = nil
        return
    end

    -- Remove our previous-frame displacement while preserving any
    -- camera movement made by the user or another system.
    remove_previous_camera_offset()

    -- SIM_PERIOD is provided by X-Plane/FlyWithLua during frame callbacks.
    local dt = SIM_PERIOD or 0.016
    if dt < 0 then dt = 0 end
    if dt > 0.1 then dt = 0.1 end

    effect_elapsed = effect_elapsed + dt

    local duration = math.max(effect_duration, 0.10)
    local t = effect_elapsed / duration

    if t >= 1.0 then
        effect_active = false
        return
    end

    -- Damped suspension/body impulse:
    -- starts quickly, reverses once, then settles.
    local damping = math.exp(-5.2 * t)
    local wave = math.sin(t * math.pi * 4.2)

    -- First part should feel like the body/head is pushed down on impact.
    local vertical_offset =
        (-wave) * damping * max_vertical_move * last_effect_strength

    -- Very small pitch component to avoid an artificial "earthquake" feeling.
    local pitch_offset =
        wave * damping * max_pitch_move * last_effect_strength

    if effect_backend == "xc" then
        XPLMSetDataf(xc_refs.y, vertical_offset)
        XPLMSetDataf(xc_refs.pitch, pitch_offset)
        xc_last_y = vertical_offset
        xc_last_pitch = pitch_offset
        xc_owned = true
        return
    end
    local base_y = XPLMGetDataf(dr_head_y)
    local base_pitch = XPLMGetDataf(dr_head_the)

    XPLMSetDataf(dr_head_y, base_y + vertical_offset)
    XPLMSetDataf(dr_head_the, base_pitch + pitch_offset)

    last_applied_y = vertical_offset
    last_applied_pitch = pitch_offset
end

-- ============================================================
-- REAL TOUCHDOWN DETECTION
-- ============================================================

local function trigger_nose_effect()
    -- Body VSI tends toward zero after main gear touchdown. Reuse the main
    -- landing intensity as a tuning reference, rather than calling it nose VSI.
    td_camera_trigger(last_airborne_vs, nose_strength(), "Nose gear")
end

function td_camera_test_nose()
    td_camera_trigger(-200, nose_strength(), "Nose gear test")
end

function td_camera_test_landing()
    td_camera_trigger(-200, 1, "Main gear test")
    test_nose_delay = 1.5
end

local function check_touchdown(dt)
    local on_ground = XPLMGetDatai(dr_on_ground)
    local vs = XPLMGetDataf(dr_vspeed)
    local nose_ground = nil
    local main_ground = false
    if gear_contacts then
        nose_ground = (tonumber(gear_contacts[nose_index()]) or 0) > 0
        for i = 0, 9 do
            if i ~= nose_index() and (tonumber(gear_contacts[i]) or 0) > 0 then
                main_ground = true
            end
        end
    else
        main_ground = on_ground == 1
    end

    if on_ground == 0 then
        airborne_time = airborne_time + dt
        -- Require sustained flight to arm; short landing bounces do not
        -- reset the once-per-landing main/nose flags.
        if airborne_time >= 2.0 then
            landing_armed = true
            main_landed = false
            nose_pending = false
        end
        if not main_landed then last_airborne_vs = vs end
    else
        airborne_time = 0
    end

    if landing_armed and not main_landed and main_ground then
        main_landed = true
        nose_pending = gear_contacts ~= nil and not nose_ground
        main_impact_strength = last_airborne_vs < -min_touchdown_fpm and calculate_touchdown_strength(last_airborne_vs) or 0
        if last_airborne_vs < -min_touchdown_fpm then
            td_camera_trigger(last_airborne_vs, 1, "Main gear")
        end
    elseif main_landed and nose_pending and nose_ground
        and previous_nose_ground == false then
        nose_pending = false
        if main_impact_strength > 0 then trigger_nose_effect() end
    end
    previous_nose_ground = nose_ground
end

function td_camera_main_loop()
    sync_aircraft_profile()
    local dt = math.max(0, math.min(SIM_PERIOD or 0.016, 0.1))
    check_touchdown(dt)
    if test_nose_delay ~= nil then
        test_nose_delay = test_nose_delay - dt
        if test_nose_delay <= 0 then
            test_nose_delay = nil
            td_camera_test_nose()
        end
    end
    update_camera_effect()
end

do_every_frame("td_camera_main_loop()")

-- ============================================================
-- SETTINGS WINDOW
-- ============================================================

-- Short help for each settings item, including its visible label.
local help_text = {
    ["XP12 Touchdown Camera Effect"] = "Camera movement and sound on landing.",
    ["Settings stored per ICAO aircraft type"] = "Each aircraft type has its own saved settings.",
    ["Auto"] = "Select X-Camera or the X-Plane camera automatically.",
    ["X-Plane"] = "Use the X-Plane camera with X-Camera disabled.",
    ["X-Camera"] = "Use X-Camera Lua effect offsets.",
    ["X-Camera Script ID (type here)"] = "Match the ID in X-Camera. Reuse it for all X-Touchdown cameras.",
    ["Refresh X-Camera"] = "Detect X-Camera again after loading it.",
    ["Effect enabled"] = "Turn touchdown movement and sound on or off.",
    ["Master strength"] = "Scale the overall camera movement.",
    ["Vertical movement"] = "Up and down camera movement in meters.",
    ["Pitch movement"] = "Camera tilt in degrees, scaled by impact and damping. Zero disables tilt.",
    ["Duration"] = "Time for the camera impulse to settle, in seconds.",
    ["Nose gear strength"] = "Scale the nose-wheel impulse. Zero disables it.",
    ["Nose gear index (0-9)"] = "Select the aircraft's nose-wheel contact index.",
    ["Gear contacts unavailable: main effect only"] = "Separate nose-wheel contact is unavailable.",
    ["Touchdown sound"] = "Enable the selected landing sound.",
    ["Light"] = "Select the light impact sound.",
    ["Medium"] = "Select the medium impact sound.",
    ["Heavy"] = "Select the heavy impact sound.",
    ["Sound volume"] = "Set landing sound volume. Zero mutes it.",
    ["TEST TOUCHDOWN (camera + selected sound)"] = "Preview a landing without touching down.",
    ["TEST NOSE GEAR"] = "Preview only the softer nose-wheel impulse.",
    ["TEST MAIN + NOSE"] = "Preview main wheels, then nose wheels after 1.5 seconds.",
    ["Save aircraft settings"] = "Save this aircraft's settings for the next load.",
    ["Reset current aircraft"] = "Restore this aircraft's defaults. Save to keep them.",
    ["Retry settings"] = "Try drawing the settings again after an error."
}
local function item_help(label)
    if type(imgui.IsItemHovered) ~= "function" or type(imgui.SetTooltip) ~= "function" then return end
    local key = label:gsub("##.*$", ""):gsub("^%[", ""):gsub("%]$", "")
    local text = help_text[key]
    if not text then
        if key:match("^Aircraft:") then text = "ICAO type used for this aircraft's settings."
        elseif key:match("^Aircraft strength") then text = "Adjust movement strength for this aircraft type."
        elseif key:match("^Camera:") then text = "Current camera output or reason it is waiting."
        elseif key:match("^Last event:") then text = "Most recent landing or test event."
        elseif key:match("^Last touchdown/test:") then text = "Sink rate in feet per minute and calculated impact strength."
        elseif key:match("^Nose contact:") then text = "Contact state of the selected nose wheel."
        elseif key:match("^Sound:") then text = "The currently selected impact sound."
        elseif key:match("^%-[0-9]+ fpm$") then text = "Preview landing at this sink rate in feet per minute."
        elseif key:match("^Config:") then text = "Settings file stored beside the Lua script."
        elseif key:match("^Saved settings") then text = "These settings were written successfully."
        elseif key:match("^Save failed:") then text = "Saving failed. Check the file location and write access."
        elseif key:find("Settings error", 1, true) then text = "The settings window encountered an error."
        elseif key:find("ready", 1, true) or key:find("unavailable", 1, true) then text = "Availability of the included landing sounds."
        else text = "Details of the current settings error."
        end
    end
    if imgui.IsItemHovered(0) then imgui.SetTooltip(text) end
end
local help_ui = {}
for _, name in ipairs({"TextUnformatted", "Button", "Checkbox", "SliderFloat", "SliderInt", "InputInt"}) do
    local method = name
    help_ui[method] = function(label, ...)
        local a, b = imgui[method](label, ...)
        item_help(label)
        return a, b
    end
end

local function test_button(label, fpm, width)
    if help_ui.Button(label, width or 86, 30) then
        td_camera_trigger(fpm)
    end
end

local function build_settings_content(wnd, x, y)
    sync_aircraft_profile()
    help_ui.TextUnformatted("XP12 Touchdown Camera Effect")
    imgui.Separator()

    choose_camera_backend()
    help_ui.TextUnformatted("Aircraft: " .. current_icao())
    help_ui.TextUnformatted("Camera: " .. camera_route_status)
    help_ui.TextUnformatted("Settings stored per ICAO aircraft type")
    help_ui.TextUnformatted("Last event: " .. last_event)
    help_ui.TextUnformatted(string.format(
        "Last touchdown/test: %.0f fpm   Final strength: %.2f",
        last_touchdown_vs,
        last_effect_strength
    ))

    imgui.Separator()

    local changed, value

    for i, label in ipairs({"Auto", "X-Plane", "X-Camera"}) do
        if i > 1 then imgui.SameLine() end
        if help_ui.Button((camera_mode == i and "[" .. label .. "]" or label) .. "##td_backend_" .. i, 100, 26) then
            remove_previous_camera_offset()
            effect_active = false
            test_nose_delay = nil
            camera_mode = i
        end
    end
    changed, value = help_ui.InputInt("X-Camera Script ID (type here)", xcamera_script_id, 1, 100, 0)
    if changed then
        remove_previous_camera_offset()
        effect_active = false
        test_nose_delay = nil
        xcamera_script_id = math.max(1, math.min(9999, math.floor(value)))
    end
    if help_ui.Button("Refresh X-Camera", 160, 26) then
        remove_previous_camera_offset()
        effect_active = false
        td_camera_scan_xcamera()
    end
    imgui.Separator()
    changed, value = help_ui.Checkbox("Effect enabled", enabled)
    if changed then
        enabled = value
        if not enabled then
            remove_previous_camera_offset()
            effect_active = false
            stop_touchdown_sounds()
            test_nose_delay = nil
        end
    end

    changed, value = help_ui.SliderFloat(
        "Master strength",
        master_strength,
        0.00,
        2.00,
        "%.2f"
    )
    if changed then master_strength = value end

    local ac_strength = get_aircraft_strength()
    changed, value = help_ui.SliderFloat(
        "Aircraft strength (" .. current_icao() .. ")",
        ac_strength,
        0.00,
        2.00,
        "%.2f"
    )
    if changed then
        set_aircraft_strength(value)
    end

    changed, value = help_ui.SliderFloat(
        "Vertical movement",
        max_vertical_move,
        0.000,
        0.150,
        "%.3f m"
    )
    if changed then max_vertical_move = value end

    changed, value = help_ui.SliderFloat(
        "Pitch movement",
        max_pitch_move,
        0.00,
        5.00,
        "%.2f deg"
    )
    if changed then max_pitch_move = value end

    changed, value = help_ui.SliderFloat(
        "Duration",
        effect_duration,
        0.15,
        2.00,
        "%.2f s"
    )
    if changed then effect_duration = value end

    imgui.Separator()
    changed, value = help_ui.SliderFloat("Nose gear strength", nose_strength(), 0.00, 1.00, "%.2f")
    if changed then nose_strength_profiles[current_icao()] = value end
    changed, value = help_ui.SliderInt("Nose gear index (0-9)", nose_index(), 0, 9, "%d")
    if changed then
        nose_index_profiles[current_icao()] = value
        previous_nose_ground = nil
        nose_pending = false
    end
    if gear_contacts then
        help_ui.TextUnformatted("Nose contact: " .. ((tonumber(gear_contacts[nose_index()]) or 0) > 0 and "GROUND" or "AIR"))
    else
        help_ui.TextUnformatted("Gear contacts unavailable: main effect only")
    end
    changed, value = help_ui.Checkbox("Touchdown sound", sound_enabled)
    if changed then
        sound_enabled = value
        if not sound_enabled then stop_touchdown_sounds() end
    end
    help_ui.TextUnformatted("Sound: " .. sound_names[sound_choice])
    for i, name in ipairs(sound_names) do
        if i > 1 then imgui.SameLine() end
        if help_ui.Button((sound_choice == i and "[" .. name .. "]" or name) .. "##td_sound_" .. i, 100, 26) then
            sound_choice = i
        end
    end
    changed, value = help_ui.SliderFloat("Sound volume", sound_volume, 0.00, 1.00, "%.2f")
    if changed then sound_volume = value end
    help_ui.TextUnformatted(sound_status)
    imgui.Separator()
    help_ui.TextUnformatted("TEST TOUCHDOWN (camera + selected sound)")

    test_button("-100 fpm", -100, 88)
    imgui.SameLine()
    test_button("-200 fpm", -200, 88)
    imgui.SameLine()
    test_button("-300 fpm", -300, 88)

    test_button("-400 fpm", -400, 88)
    imgui.SameLine()
    test_button("-600 fpm", -600, 88)

    if help_ui.Button("TEST NOSE GEAR", 160, 28) then td_camera_test_nose() end
    imgui.SameLine()
    if help_ui.Button("TEST MAIN + NOSE", 180, 28) then td_camera_test_landing() end
    imgui.Separator()

    if help_ui.Button("Save aircraft settings", 190, 28) then
        if save_aircraft_config() then
            logMsg("[Touchdown Camera] Aircraft settings saved.")
        end
    end

    imgui.SameLine()

    if help_ui.Button("Reset current aircraft", 170, 28) then
        remove_previous_camera_offset()
        effect_active = false
        test_nose_delay = nil
        stop_touchdown_sounds()
        local code = current_icao()
        tuning_profiles[code] = nil
        nose_strength_profiles[code] = default_nose_strength
        nose_index_profiles[code] = 0
        aircraft_strength[code] = default_aircraft_strength
        apply_aircraft_tuning(code)
    end

    if save_status ~= "" then help_ui.TextUnformatted(save_status) end
    help_ui.TextUnformatted(
        "Config: Touchdown_Camera_Effect_XP12.cfg"
    )
end

-- FlyWithLua requires the format argument for both SliderFloat and SliderInt.
-- Catch Lua callback errors within the callback instead of unwinding through
-- the native floating-window renderer. This does not catch native crashes.
local window_error = nil
function td_camera_build_window(wnd, x, y)
    if window_error == nil then
        local ok, err = pcall(build_settings_content, wnd, x, y)
        if not ok then
            window_error = tostring(err)
            logMsg("[Touchdown Camera] Settings error: " .. window_error)
        end
    end
    if window_error ~= nil then
        help_ui.TextUnformatted("Touchdown Camera Effect v1.11 - Settings error")
        help_ui.TextUnformatted(window_error)
        if help_ui.Button("Retry settings", 160, 28) then window_error = nil end
    end
end

function td_camera_window_closed(wnd)
    settings_wnd = nil
end

function td_camera_open_window()
    if settings_wnd ~= nil then
        return
    end

    settings_wnd = float_wnd_create(680, 830, 1, true)
    float_wnd_set_title(settings_wnd, "Touchdown Camera Effect v1.11")
    float_wnd_set_imgui_builder(settings_wnd, "td_camera_build_window")
    float_wnd_set_onclose(settings_wnd, "td_camera_window_closed")
end

function td_camera_toggle_window()
    if settings_wnd == nil then
        td_camera_open_window()
    else
        float_wnd_destroy(settings_wnd)
        settings_wnd = nil
    end
end

create_command(
    "xbrief/touchdown_camera/toggle_settings",
    "Toggle Touchdown Camera Effect settings",
    "td_camera_toggle_window()",
    "",
    ""
)

-- FlyWithLua > FlyWithLua Macros menu: one-shot open entry avoids a stale
-- check mark if the user closes the window with its X button.
add_macro("Touchdown Camera Effect - Open settings", "td_camera_open_window()")

create_command(
    "xbrief/touchdown_camera/open_settings",
    "Open Touchdown Camera Effect settings",
    "td_camera_open_window()",
    "",
    ""
)

-- Open settings explicitly from the FlyWithLua menu or the open command.
-- Avoid building the window during script reload/startup.

function td_camera_cleanup()
    remove_previous_camera_offset()
    effect_active = false
    test_nose_delay = nil
    stop_touchdown_sounds()
end
if type(do_on_exit) == "function" then do_on_exit("td_camera_cleanup()") end

logMsg("[Touchdown Camera] Loaded for X-Plane 12 / FlyWithLua. Aircraft: " .. current_icao())
