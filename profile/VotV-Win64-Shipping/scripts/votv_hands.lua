-- VOTV VR: visible hands and a hand-held flashlight (UEVR Lua). Controls thread, 2026-11-27.
--
-- User 2026-11-27 02:07: "hands aren't in the game yet" and "if the game has a 3d model of a flash light I would
-- like that to show as well when I turn it on"; 02:33: "my flash light ... is just stuck to where I am looking".
--
-- Hands: one copy of the game's own first-person arms mesh (the pawn's `arms` SkeletalMesh, FP_arms, bones
-- shoulder/upperarm/forearm/hand per side, no fingers) per controller, the other side's arm hidden by bone, placed
-- so its hand bone sits on the controller (offset measured from the mesh once after attaching, plus live
-- settings). Collision off, no shadow. The game's own arms (tool animations) are left alone.
-- Flashlight: the player's light (`light_R` SpotLight on the pawn) is driven by a controller (left by default),
-- and a copy of the game's flashlight mesh (/Game/meshes/flashlight/flashlight) is held there, visible only while
-- the light is on. Each part has an on/off setting.
--
-- Settings come from scripts\votv_controls.txt via the controls plugin ("votv_cfg" Lua events; UEVR 1.05 Lua has
-- no file access): hands_show, hands_x/y/z (extra cm), flash_on, flash_hand (0 left, 1 right), flash_x/y/z (cm),
-- flash_model. Idle until the controls plugin is seen. Log lines: "[votv-hands]".

local function log(s) pcall(function() uevr.params.functions.log_info("[votv-hands] " .. tostring(s)) end) end

local cfg = { hands_show = 0, hands_x = 0, hands_y = 0, hands_z = 0,
              flash_on = 1, flash_hand = 0, flash_x = 8, flash_y = 0, flash_z = 0, flash_model = 1, flash_model_yaw = 180 }
local active = false

local function parse_cfg(text)
    for k, v in string.gmatch(text, "([%w_]+)%s*=%s*(%-?[%d%.]+)") do
        if cfg[k] ~= nil then
            local n = tonumber(v)
            if n ~= nil and cfg[k] ~= n then cfg[k] = n; log("setting " .. k .. "=" .. v); cfg._dirty = true end
        end
    end
end

pcall(function()
    uevr.sdk.callbacks.on_lua_event(function(name, data)
        if name == "votv_cfg" then parse_cfg(tostring(data)); active = true
        elseif name == "votv_ctl" then active = true end
    end)
end)

local api = uevr.api
local function find(path)
    local ok, o = pcall(function() return api:find_uobject(path) end)
    return ok and o or nil
end
local function struct(path) local c = find(path); return c and StructObject.new(c) or nil end
local function vec(x, y, z) local v = struct("ScriptStruct /Script/CoreUObject.Vector"); v.X = x; v.Y = y; v.Z = z; return v end
local function rot(p, y, r) local v = struct("ScriptStruct /Script/CoreUObject.Rotator"); v.Pitch = p; v.Yaw = y; v.Roll = r; return v end

local kml, ksl = nil, nil
local function libs()
    if kml == nil then local c = find("Class /Script/Engine.KismetMathLibrary"); if c then pcall(function() kml = c:get_class_default_object() end) end end
    if ksl == nil then local c = find("Class /Script/Engine.KismetStringLibrary"); if c then pcall(function() ksl = c:get_class_default_object() end) end end
    return kml ~= nil and ksl ~= nil
end
local function fname(s) return ksl:Conv_StringToName(s) end
local function identity() return kml:MakeTransform(vec(0, 0, 0), rot(0, 0, 0), vec(1, 1, 1)) end

local function mc_state(comp, hand)
    local s = UEVR_UObjectHook.get_or_add_motion_controller_state(comp)
    if s == nil then return nil end
    s:set_hand(hand)
    if not pcall(function() s:set_permanent(true) end) then pcall(function() s:set_permanant(true) end) end
    return s
end
local function set_offset(s, x, y, z)
    pcall(function() s:set_location_offset(Vector3f.new(x, y, z)) end)
end

local st = { pawn = nil, hands = {}, hand_states = {}, hand_base = {}, calibrated = {}, light = nil, light_state = nil,
             torch = nil, torch_state = nil, torch_vis = nil, t = 0, retry = 0, fails = 0 }

local function add_comp(pawn, class_path)
    local cls = find(class_path)
    if cls == nil then return nil end
    return pawn:AddComponentByClass(cls, true, identity(), false)
end

-- One arms copy per hand; side 1 = right (hide the left arm), 0 = left (hide the right arm).
local function make_hand(pawn, side)
    local mesh = nil
    pcall(function() mesh = pawn.arms.SkeletalMesh end)
    if mesh == nil then log("hands: pawn.arms has no SkeletalMesh"); return end
    local comp = add_comp(pawn, "Class /Script/Engine.SkeletalMeshComponent")
    if comp == nil then log("hands: AddComponentByClass(SkeletalMeshComponent) failed"); return end
    comp:SetSkeletalMesh(mesh, true)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:HideBoneByName(fname(side == 1 and "shoulder_L" or "shoulder_R"), 0) end)
    st.hands[side] = comp
    st.hand_states[side] = mc_state(comp, side)
    st.calibrated[side] = false
    log("hands: " .. (side == 1 and "right" or "left") .. " arm copy attached to the controller")
end

-- After UEVR has placed the copy once: measure where the hand bone sits in the component's own space and shift
-- the copy so the bone lands on the controller (plus the live extra offset).
local function calibrate_hand(side)
    local comp, s = st.hands[side], st.hand_states[side]
    if comp == nil or s == nil then return end
    local ok, err = pcall(function()
        local bone = comp:GetSocketLocation(fname(side == 1 and "hand_R" or "hand_L"))
        local local_pos = kml:InverseTransformLocation(comp:K2_GetComponentToWorld(), bone)
        st.hand_base[side] = { X = -local_pos.X, Y = -local_pos.Y, Z = -local_pos.Z }
        st.calibrated[side] = true
        log(string.format("hands: %s hand bone at (%.1f, %.1f, %.1f) cm in the mesh; offset applied",
            side == 1 and "right" or "left", local_pos.X, local_pos.Y, local_pos.Z))
    end)
    if not ok then st.calibrated[side] = true; log("hands: calibrate failed (using no offset): " .. tostring(err)) end
end

local function apply_hand_offsets()
    for side = 0, 1 do
        local s, b = st.hand_states[side], st.hand_base[side]
        if s ~= nil and b ~= nil then
            local mx = side == 1 and 1 or -1   -- extra Y offset mirrored for the left hand
            set_offset(s, b.X + cfg.hands_x, b.Y + mx * cfg.hands_y, b.Z + cfg.hands_z)
        end
    end
end

-- Run 16:55 (user): "my player body is stuck to my left hand" with only the flashlight attached, so moving the
-- game's own light_R drags other parts of the player with it. The game's light stays where it is (dark: its
-- intensity is moved to ours each tick) and our own SpotLight on the controller shines instead.
local function make_flashlight(pawn)
    local light = nil
    pcall(function() light = pawn.light_R end)
    if light == nil then log("flashlight: pawn.light_R not found"); return end
    local mine = add_comp(pawn, "Class /Script/Engine.SpotLightComponent")
    if mine == nil then log("flashlight: AddComponentByClass(SpotLightComponent) failed"); return end
    -- Run 16:59: our light gave no light. Runtime-added lights must be Movable, and the game's light may use
    -- light units and an IES profile (Narrow10000 is referenced by the player), so copy those too.
    pcall(function() mine:SetMobility(2) end)
    pcall(function() mine.IntensityUnits = light.IntensityUnits end)
    pcall(function() mine:SetIESTexture(light.IESTexture) end)
    pcall(function() mine:SetUseIESBrightness(light.bUseIESBrightness) end)
    pcall(function() mine:SetIESBrightnessScale(light.IESBrightnessScale) end)
    pcall(function() mine:SetSourceRadius(light.SourceRadius) end)
    pcall(function() mine:SetIntensity(light.Intensity) end)
    pcall(function() mine:SetAttenuationRadius(light.AttenuationRadius) end)
    pcall(function() mine:SetOuterConeAngle(light.OuterConeAngle) end)
    pcall(function() mine:SetInnerConeAngle(light.InnerConeAngle) end)
    pcall(function() mine:SetLightColor(light:GetLightColor(), true) end)
    pcall(function() mine:SetCastShadows(light.CastShadows) end)
    st.game_light, st.light, st.light_int = light, mine, 0
    pcall(function()
        log(string.format("flashlight: game light intensity %s units %s radius %s cones %s/%s IES %s mobility %s",
            tostring(light.Intensity), tostring(light.IntensityUnits), tostring(light.AttenuationRadius),
            tostring(light.InnerConeAngle), tostring(light.OuterConeAngle), tostring(light.IESTexture ~= nil), tostring(light.Mobility)))
    end)
    st.light_state = mc_state(mine, cfg.flash_hand)
    set_offset(st.light_state, cfg.flash_x, cfg.flash_y, cfg.flash_z)
    log("flashlight: own light on the " .. (cfg.flash_hand == 1 and "right" or "left") .. " controller (game light left in place, dimmed)")
end

-- Each tick: our light is on when the game's is, and takes over its intensity (the game may change it: battery,
-- hold-F beam modes); the game's light is kept at 0 so only ours shines.
local function sync_light()
    local g, m = st.game_light, st.light
    if g == nil or m == nil then return end
    local on = g:IsVisible()
    local gi = g.Intensity
    if gi ~= nil and gi > 0 then st.light_int = gi; g:SetIntensity(0) end
    if on ~= st.light_on then st.light_on = on; m:SetVisibility(on, false) end
    if st.light_int > 0 and m.Intensity ~= st.light_int then m:SetIntensity(st.light_int); log("flashlight: our light intensity " .. tostring(st.light_int)) end
end

local function make_torch_model(pawn)
    local mesh = find("StaticMesh /Game/meshes/flashlight/flashlight.flashlight")
    if mesh == nil then return false end   -- not loaded yet; retried
    local comp = add_comp(pawn, "Class /Script/Engine.StaticMeshComponent")
    if comp == nil then log("flashlight: AddComponentByClass(StaticMeshComponent) failed"); return true end
    comp:SetStaticMesh(mesh)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    comp:SetVisibility(false, false)
    st.torch = comp
    -- Run 16:49 (user): the model pointed back at the player. It now hangs off the light itself (which UEVR
    -- drives from the controller), turned by flash_model_yaw (live, default 180 degrees).
    if st.light ~= nil then
        comp:K2_AttachToComponent(st.light, fname("None"), 0, 0, 0, false)   -- keep relative location/rotation/scale
        comp:K2_SetRelativeRotation(rot(0, cfg.flash_model_yaw, 0), false, struct("ScriptStruct /Script/Engine.HitResult"), false)
    else
        st.torch_state = mc_state(comp, cfg.flash_hand)
    end
    log("flashlight: model attached to the light, turned " .. cfg.flash_model_yaw .. " deg")
    return true
end

local function setup(pawn)
    st.pawn = pawn
    st.hands, st.hand_states, st.hand_base, st.calibrated = {}, {}, {}, {}
    st.light, st.light_state, st.torch, st.torch_state, st.torch_vis = nil, nil, nil, nil, nil
    st.game_light, st.light_on, st.light_int = nil, nil, 0
    if not libs() then log("setup: Kismet libraries not found"); return end
    if cfg.hands_show ~= 0 then make_hand(pawn, 1); make_hand(pawn, 0) end
    if cfg.flash_on ~= 0 then make_flashlight(pawn) end
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    if not active then return end
    local ok, err = pcall(function()
        local pawn = api:get_local_pawn(0)
        if pawn == nil or not pawn:get_full_name():find("mainPlayer") then return end
        if pawn ~= st.pawn or not UEVR_UObjectHook.exists(st.pawn) then setup(pawn) end
        -- drop references to anything destroyed (level change, respawn) before using it
        local function gone(o) return o ~= nil and not UEVR_UObjectHook.exists(o) end
        if gone(st.light) or gone(st.game_light) or gone(st.torch) or gone(st.hands[0]) or gone(st.hands[1]) then setup(pawn) end
        st.t = st.t + delta
        -- calibrate each hand copy on the first tick after UEVR placed it
        for side = 0, 1 do
            if st.hands[side] ~= nil and not st.calibrated[side] and st.t > 0.5 then calibrate_hand(side); cfg._dirty = true end
        end
        if cfg._dirty then cfg._dirty = false; apply_hand_offsets()
            if st.light_state then st.light_state:set_hand(cfg.flash_hand); set_offset(st.light_state, cfg.flash_x, cfg.flash_y, cfg.flash_z) end
            if st.torch_state then st.torch_state:set_hand(cfg.flash_hand) end
            if st.torch and st.torch_state == nil then pcall(function() st.torch:K2_SetRelativeRotation(rot(0, cfg.flash_model_yaw, 0), false, struct("ScriptStruct /Script/Engine.HitResult"), false) end) end
            for side = 0, 1 do if st.hands[side] then pcall(function() st.hands[side]:SetVisibility(cfg.hands_show ~= 0, false) end) end end
        end
        -- flashlight model: create once the mesh is loaded, then show it only while the light is on
        if cfg.flash_on ~= 0 and cfg.flash_model ~= 0 and st.torch == nil and st.t - st.retry > 3 then
            st.retry = st.t
            make_torch_model(pawn)
        end
        pcall(sync_light)
        if st.torch ~= nil and st.game_light ~= nil then
            local on = cfg.flash_model ~= 0 and st.game_light:IsVisible()
            if on ~= st.torch_vis then st.torch_vis = on; st.torch:SetVisibility(on, false); log("flashlight model " .. (on and "shown" or "hidden")) end
        end
    end)
    if not ok then st.fails = st.fails + 1; if st.fails <= 5 then log("tick error " .. tostring(err)) end end
end)

log("loaded (idle until the controls plugin is seen)")
