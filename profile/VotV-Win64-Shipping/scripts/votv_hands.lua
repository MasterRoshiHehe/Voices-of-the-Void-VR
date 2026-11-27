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

local cfg = { hands_show = 1, hands_x = 0, hands_y = 0, hands_z = 0, hands_pitch = 0, hands_yaw = 0, hands_roll = 0, hands_source = 0, hands_preview = 0, hands_bounds = 20, hands_auto_yaw = 90, hands_curl_deg = 80, hands_mcp = 55, hands_pip = 70, hands_dip_ratio = 0.6, hands_relax = 0.1, hands_splay = 0, hands_thumb_opp = 0, hands_curl_axis = 0, hands_curl_sign = 1, hands_thumb_axis = 0, hands_relax_deg = 10, hands_seg1 = 0.8, hands_seg2 = 1.0, hands_seg3 = 0.67, hands_thumb_sign = 1, hands_f_thumb = 1, hands_f_index = 2, hands_f_middle = 3, hands_f_ring = 4, hands_r_yaw = -90, hands_r_roll = 90, hands_l_yaw = -90, hands_l_roll = -90, hands_style = 1, hands_scale = 1,
              flash_on = 1, flash_hand = 0, flash_x = 8, flash_y = 0, flash_z = 0, flash_model = 1, flash_model_yaw = 180, flash_intensity = 500, hands_force_mat = 0, flash_copy_game = 1, flash_lens_slot = -1, flash_model_x = -20 }
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

-- Hands, v3 (run 17:25, user: "white boxes ... only rendered in one eye ... nothing that resembles hands").
-- v2 used the first-person arms mesh, whose viewmodel material and helper bones don't suit a world-space copy.
-- v3 can copy the player's third-person body, but run 17:30 showed it has no arms (bones: lowlegs thighs pelvis
-- chest head head_end), so the default source is back to the first-person arms (hands_source=0), whose hands are
-- the game's own low-poly white gloves; the per-eye flicker is addressed with a larger bounds scale.
-- (Source 1: pawn.playermodel, else mesh_playerVisible), with its materials,
-- and keeps only one hand: the bone tree is read from the mesh, the hand bone is found by name, and every bone
-- outside that hand's subtree is shrunk to 1% and parked on the hand, so arms and body collapse inside it.
-- The hand bone sits at the component origin, which UEVR drives to the controller grip.
-- Live: hands_x/y/z (cm), hands_pitch/yaw/roll (deg), hands_show, hands_source (1 body, 0 first-person arms).
local COMP = 1   -- EBoneSpaces::ComponentSpace

local function source_mesh(pawn)
    local names = cfg.hands_source == 0 and { "arms" } or { "playermodel", "mesh_playerVisible", "arms" }
    for _, n in ipairs(names) do
        local c, m = nil, nil
        pcall(function() c = pawn[n]; m = c and c.SkeletalMesh end)
        if m ~= nil then return c, m, n end
    end
end

-- Run 17:46: on kerfurOmega_KelSkin the plain hand_R/hand_L were found but nothing showed: that rig has control
-- bones (hand_R) and deform bones (hand_FK_R ...). Pick the hand bone whose subtree holds the finger bones.
local function find_hand_bone(comp, side)
    local nb = comp:GetNumBones()
    local names, parent = {}, {}
    for i = 0, nb - 1 do names[i] = comp:GetBoneName(i):to_string() end
    for i = 0, nb - 1 do parent[names[i]] = comp:GetParentBone(fname(names[i])):to_string() end
    local function under(b, anc) local p = parent[b]; local n = 0
        while p ~= nil and p ~= "None" and n < 64 do if p == anc then return true end; p = parent[p]; n = n + 1 end
        return false end
    local cands = {}
    for i = 0, nb - 1 do
        local b = names[i]; local l = b:lower()
        local is_hand = l:find("hand") ~= nil and not l:find("ik") and not l:find("twist") and not l:find("pole") and not l:find("end") and not l:find("layer")
        local right = l:find("_r$") or l:find("%.r$") or l:find("right") or l:find("^r_")
        local left = l:find("_l$") or l:find("%.l$") or l:find("left") or l:find("^l_")
        if is_hand and ((side == 1 and right) or (side == 0 and left)) then cands[#cands + 1] = b end
    end
    local best, best_f = nil, -1
    for _, c in ipairs(cands) do
        local f = 0
        for i = 0, nb - 1 do local l = names[i]:lower(); if (l:find("finger") or l:find("thumb") or l:find("index")) and under(names[i], c) then f = f + 1 end end
        if f > best_f or (f == best_f and best and #c < #best) then best, best_f = c, f end
    end
    if best ~= nil then log(string.format("hands: hand bone candidates %s -> %s (%d finger bones under it)", table.concat(cands, ","), best, best_f)) end
    return best, nb, cands
end

local function pose_hand(side)
    local comp = st.hands[side]
    local keep = st.hand_bone[side]
    if comp == nil or keep == nil then return end
    local nb = comp:GetNumBones()
    -- the hand subtree: bones whose parent chain reaches the hand bone
    -- Run 17:51: hand_R sat exactly on the controller, visible, even with the glove material, yet nothing showed:
    -- the skin is probably weighted to the deform chain (hand_FK_*) while hand_R carries control bones. Keep every
    -- hand candidate's subtree (hand_R and hand_FK_R) and put each candidate on the controller.
    local seeds = { keep }
    for _, c in ipairs((st.hand_cands and st.hand_cands[side]) or {}) do if c ~= keep then seeds[#seeds + 1] = c end end
    local keepset = {}
    for _, sd in ipairs(seeds) do keepset[sd] = true end
    local names = {}
    for i = 0, nb - 1 do names[i] = comp:GetBoneName(i):to_string() end
    for i = 0, nb - 1 do   -- parents come before children in UE bone order
        local n = names[i]
        local p = comp:GetParentBone(fname(n)):to_string()
        if keepset[p] then keepset[n] = true end
    end
    -- Run 17:56 (user): "tiiny dots that are following my hands": the hand draws but far too small. Rigs exported
    -- with an armature scale carry a bone scale in the reference pose, so forcing scale 1 shrinks the skin.
    -- Read each kept hand bone's own component-space scale once (before any change) and put that back, times
    -- hands_scale (live).
    st.ref_scale = st.ref_scale or {}
    st.ref_scale[side] = st.ref_scale[side] or {}
    for _, sd in ipairs(seeds) do
        if st.ref_scale[side][sd] == nil then
            local ok, v = pcall(function() return comp:GetBoneScaleByName(fname(sd), COMP) end)
            st.ref_scale[side][sd] = (ok and v) and { X = v.X, Y = v.Y, Z = v.Z } or { X = 1, Y = 1, Z = 1 }
            log(string.format("hands: %s reference scale (%.3f %.3f %.3f)", sd, st.ref_scale[side][sd].X, st.ref_scale[side][sd].Y, st.ref_scale[side][sd].Z))
        end
    end
    -- Run 18:09 (user: "fix the position of the hands"): rotation now starts from the hand bone's own
    -- reference-pose rotation (the rig's T/A pose: fingers out to the side), turned hands_auto_yaw (live, default
    -- 90; right hand -, left hand +) so the fingers point forward, then the live hands_pitch/yaw/roll on top.
    st.ref_rot = st.ref_rot or {}
    st.ref_rot[side] = st.ref_rot[side] or {}
    for _, sd in ipairs(seeds) do
        if st.ref_rot[side][sd] == nil then
            local ok, r = pcall(function() return comp:GetBoneRotationByName(fname(sd), COMP) end)
            st.ref_rot[side][sd] = (ok and r) and { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } or { Pitch = 0, Yaw = 0, Roll = 0 }
            log(string.format("hands: %s reference rotation p%.1f y%.1f r%.1f", sd, st.ref_rot[side][sd].Pitch, st.ref_rot[side][sd].Yaw, st.ref_rot[side][sd].Roll))
        end
    end
    local tiny, zero = vec(0.01, 0.01, 0.01), vec(0, 0, 0)
    for i = 0, nb - 1 do
        local n = names[i]
        if not keepset[n] then
            pcall(function() local f = fname(n); comp:SetBoneLocationByName(f, zero, COMP); comp:SetBoneScaleByName(f, tiny, COMP) end)
        end
    end
    for _, sd in ipairs(seeds) do
        local ok, err = pcall(function()
            local f = fname(sd)
            local mx = side == 1 and 1 or -1
            comp:SetBoneLocationByName(f, vec(cfg.hands_x, mx * cfg.hands_y, cfg.hands_z), COMP)
            local r0 = st.ref_rot[side][sd]
            local base = kml:ComposeRotators(rot(r0.Pitch, r0.Yaw, r0.Roll), rot(0, -mx * cfg.hands_auto_yaw, 0))
            local final = kml:ComposeRotators(base, rot(cfg.hands_pitch, mx * cfg.hands_yaw, mx * cfg.hands_roll))
            -- Mark 18:11 (first working vr.jpg, controllers held upright): both hands lay flat, palms down,
            -- fingers along the controllers' right axis. Per-hand turn in the controller frame, yaw then roll:
            -- right yaw -90 roll 180, left yaw -90 roll 0 (fingers along the controller, palms facing inward).
            local py = side == 1 and cfg.hands_r_yaw or cfg.hands_l_yaw
            local pr = side == 1 and cfg.hands_r_roll or cfg.hands_l_roll
            final = kml:ComposeRotators(final, rot(0, py, 0))
            final = kml:ComposeRotators(final, rot(0, 0, pr))
            comp:SetBoneRotationByName(f, final, COMP)
            local r, k = st.ref_scale[side][sd], cfg.hands_scale
            comp:SetBoneScaleByName(f, vec(r.X * k, r.Y * k, r.Z * k), COMP)
        end)
        if not ok then log("hands: posing " .. sd .. " failed: " .. tostring(err)) end
    end
end

local function make_hand(pawn, side)
    local src, mesh, src_name = source_mesh(pawn)
    if mesh == nil then log("hands: no player mesh found"); return end
    local comp = add_comp(pawn, "Class /Script/Engine.PoseableMeshComponent")
    if comp == nil then log("hands: AddComponentByClass(PoseableMeshComponent) failed"); return end
    comp:SetSkeletalMesh(mesh, true)
    pcall(function() local n = src:GetNumMaterials(); for i = 0, n - 1 do comp:SetMaterial(i, src:GetMaterial(i)) end end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetBoundsScale(cfg.hands_bounds) end)   -- the shrunk pose is far from the ref pose; avoid per-eye culling
    st.hands[side] = comp
    st.hand_states[side] = mc_state(comp, side)
    st.calibrated[side] = true
    local hb, nb = find_hand_bone(comp, side)
    st.hand_bone[side] = hb
    log(string.format("hands: %s hand from %s (%d bones), hand bone %s", side == 1 and "right" or "left", src_name, nb or -1, tostring(hb)))
    if hb == nil then
        local list = {}
        for i = 0, math.min((nb or 0), 80) - 1 do list[#list + 1] = comp:GetBoneName(i):to_string() end
        log("hands: no hand bone found; bones: " .. table.concat(list, " "))
        comp:SetVisibility(false, false)
        return
    end
    pose_hand(side)
end

-- Hands, v4 "built" style (run 17:34, user: the game's first-person hands look "more like broken wii remotes").
-- The game has no proper hand model (its body mesh has no arms; the first-person arms are blocky with no fingers),
-- so each hand is built from the engine's always-loaded cube: a palm, four fingers in two segments and a thumb,
-- under a frame that UEVR drives to the controller grip. Using separate finger parts also lets fingers curl
-- later (grip/trigger, then physical button presses). Material: the game arms' own material, so the colour
-- matches the game. Live: hands_style (1 built, 0 game arms), hands_scale, hands_x/y/z, hands_pitch/yaw/roll.
local FINGERS = { -- y offset (cm, right hand), length of the two segments (cm)
    { y = -2.7, a = 4.2, b = 3.2 }, { y = -0.9, a = 4.6, b = 3.4 }, { y = 0.9, a = 4.4, b = 3.2 }, { y = 2.7, a = 3.6, b = 2.6 } }
local cube = nil
local function part(pawn, parent, mat, x, y, z, sx, sy, sz, yaw)
    local c = add_comp(pawn, "Class /Script/Engine.StaticMeshComponent")
    if c == nil then return nil end
    c:SetStaticMesh(cube)
    if mat ~= nil then pcall(function() c:SetMaterial(0, mat) end) end
    pcall(function() c:SetCollisionEnabled(0) end)
    pcall(function() c:SetCastShadow(false) end)
    local h = struct("ScriptStruct /Script/Engine.HitResult")
    c:K2_AttachToComponent(parent, fname("None"), 0, 0, 0, false)
    c:K2_SetRelativeLocation(vec(x, y, z), false, h, false)
    c:K2_SetRelativeRotation(rot(0, yaw or 0, 0), false, h, false)
    c:SetRelativeScale3D(vec(sx / 100, sy / 100, sz / 100))
    return c
end

local function make_built_hand(pawn, side)
    -- Run 17:42: /Engine/BasicShapes/Cube isn't loaded in the shipping game; try other always-present cubes.
    for _, path in ipairs({ "StaticMesh /Engine/BasicShapes/Cube.Cube", "StaticMesh /Engine/EngineMeshes/Cube.Cube",
                            "StaticMesh /Engine/EditorMeshes/EditorCube.EditorCube", "StaticMesh /Engine/EngineMeshes/Sphere.Sphere" }) do
        if cube == nil then cube = find(path); if cube ~= nil then log("hands: built hands use " .. path) end end
    end
    if cube == nil then log("hands: engine cube mesh not loaded"); return end
    local mat = nil
    pcall(function() mat = pawn.arms:GetMaterial(0) end)
    local root = add_comp(pawn, "Class /Script/Engine.SceneComponent")
    local frame = add_comp(pawn, "Class /Script/Engine.SceneComponent")
    if root == nil or frame == nil then log("hands: AddComponentByClass(SceneComponent) failed"); return end
    st.hand_states[side] = mc_state(root, side)
    frame:K2_AttachToComponent(root, fname("None"), 0, 0, 0, false)
    local m = side == 1 and 1 or -1
    local parts = {}
    -- palm: 9 x 8 x 2.4 cm, centred a little forward of and below the grip point
    parts[#parts + 1] = part(pawn, frame, mat, 1.5, 0, -2.5, 9, 8, 2.4)
    for _, f in ipairs(FINGERS) do
        parts[#parts + 1] = part(pawn, frame, mat, 6 + f.a / 2, m * f.y, -2.5, f.a, 1.6, 1.6)
        parts[#parts + 1] = part(pawn, frame, mat, 6 + f.a + f.b / 2 + 0.2, m * f.y, -2.5, f.b, 1.5, 1.5)
    end
    -- thumb on the inner side, angled forward
    parts[#parts + 1] = part(pawn, frame, mat, 2.5, -m * 5.2, -2.0, 5.5, 1.8, 1.8, -m * 35)
    st.hands[side] = frame
    st.hand_parts = st.hand_parts or {}
    st.hand_parts[side] = parts
    st.calibrated[side] = true
    log(string.format("hands: built %s hand (%d parts) on the controller", side == 1 and "right" or "left", #parts))
end

local function pose_built(side)
    local frame = st.hands[side]
    if frame == nil then return end
    local m = side == 1 and 1 or -1
    local h = struct("ScriptStruct /Script/Engine.HitResult")
    pcall(function()
        frame:K2_SetRelativeLocation(vec(cfg.hands_x, m * cfg.hands_y, cfg.hands_z), false, h, false)
        frame:K2_SetRelativeRotation(rot(cfg.hands_pitch, m * cfg.hands_yaw, m * cfg.hands_roll), false, h, false)
        frame:SetRelativeScale3D(vec(cfg.hands_scale, cfg.hands_scale, cfg.hands_scale))
    end)
end


-- Hands, v5 "mannequin" style (user 16:40: "try this first"): Epic's UE4 mannequin ships inside the game's pak
-- (DynamicGravityCharacter plugin content) with fully rigged fingers, but the game never loads it. Try to get it:
-- (1) already in memory, (2) KismetSystemLibrary soft-path load, then pose a copy as in v3 (one hand subtree kept).
-- Every attempt is logged; if none works the built hands are used instead.
local MANNEQUIN = "/DynamicGravityCharacter/Mannequin/Character/Mesh/SK_Mannequin.SK_Mannequin"
local mannequin, mannequin_tried = nil, false
local function load_mannequin()
    if mannequin_tried then return mannequin end
    mannequin_tried = true
    mannequin = find("SkeletalMesh " .. MANNEQUIN)
    log("mannequin: in memory: " .. tostring(mannequin ~= nil))
    if mannequin ~= nil then return mannequin end
    local kslib = nil
    local c = find("Class /Script/Engine.KismetSystemLibrary")
    if c ~= nil then pcall(function() kslib = c:get_class_default_object() end) end
    if kslib == nil then log("mannequin: KismetSystemLibrary not found"); return nil end
    local ok, err = pcall(function()
        local sp = kslib:MakeSoftObjectPath(MANNEQUIN)
        log("mannequin: MakeSoftObjectPath ok")
        local ref = kslib:Conv_SoftObjPathToSoftObjRef(sp)
        log("mannequin: soft reference ok")
        local o = nil
        if not pcall(function() o = kslib:LoadAsset_Blocking(ref) end) then log("mannequin: LoadAsset_Blocking not available") end
        if o == nil then o = kslib:Conv_SoftObjectReferenceToObject(ref) end
        mannequin = o
    end)
    log("mannequin: soft-path load " .. (ok and (mannequin ~= nil and "succeeded" or "returned nothing") or ("failed: " .. tostring(err))))
    if mannequin == nil then mannequin = find("SkeletalMesh " .. MANNEQUIN) end
    return mannequin
end

local function make_mannequin_hand(pawn, side, mesh)
    local comp = add_comp(pawn, "Class /Script/Engine.PoseableMeshComponent")
    if comp == nil then return false end
    comp:SetSkeletalMesh(mesh, true)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetBoundsScale(cfg.hands_bounds) end)
    -- Run 17:48: KelSkin hand found (16 finger bones) but nothing visible, while the same posing showed the game
    -- arms. Log its materials; hands_force_mat=1 (live) swaps in the game arms' material to tell a material
    -- problem apart from a geometry/placement one.
    pcall(function()
        local n, list = comp:GetNumMaterials(), {}
        for i = 0, n - 1 do local m = comp:GetMaterial(i); list[#list + 1] = i .. "=" .. (m and m:get_fname():to_string() or "nil") end
        log("hands: mesh materials " .. table.concat(list, " "))
        if cfg.hands_force_mat ~= 0 then
            local am = pawn.arms:GetMaterial(0)
            for i = 0, n - 1 do comp:SetMaterial(i, am) end
            log("hands: materials replaced with the game arms' material (hands_force_mat=1)")
        end
    end)
    st.hands[side] = comp
    st.hand_states[side] = mc_state(comp, side)
    st.calibrated[side] = true
    local hb, nb, cands = find_hand_bone(comp, side)
    st.hand_bone[side] = hb
    st.hand_cands = st.hand_cands or {}
    st.hand_cands[side] = cands
    log(string.format("hands: %s mannequin hand (%d bones), hand bone %s", side == 1 and "right" or "left", nb or -1, tostring(hb)))
    if hb == nil then comp:SetVisibility(false, false); return false end
    pose_hand(side)
    return true
end

local function calibrate_hand(side) end   -- v1 leftover, nothing to measure in v2
local function apply_hand_offsets() st.finger_rest = nil; st.curl_force = true; for side = 0, 1 do if st.hand_bone and st.hand_bone[side] then pose_hand(side) else pose_built(side) end end end

-- Run 16:55 (user): "my player body is stuck to my left hand" with only the flashlight attached, so moving the
-- game's own light_R drags other parts of the player with it. The game's light stays where it is (dark: its
-- intensity is moved to ours each tick) and our own SpotLight on the controller shines instead.
local function make_flashlight(pawn)
    local light = nil
    pcall(function() light = pawn.light_R end)
    if light == nil then log("flashlight: pawn.light_R not found"); return end
    -- Run 17:51 (user): good from a distance, keypad washes out close up. The game's light probably isn't
    -- inverse-squared (intensity 0.2 only works that way), and that flag only applies before the light registers,
    -- so the light is added deferred, its falloff copied, then finished.
    local mine = nil
    pcall(function()
        mine = pawn:AddComponentByClass(find("Class /Script/Engine.SpotLightComponent"), true, identity(), true)
        mine.bUseInverseSquaredFalloff = light.bUseInverseSquaredFalloff
        mine.LightFalloffExponent = light.LightFalloffExponent
        pawn:FinishAddComponent(mine, true, identity())
        log(string.format("flashlight: falloff copied: inverse-squared %s exponent %s", tostring(mine.bUseInverseSquaredFalloff), tostring(mine.LightFalloffExponent)))
    end)
    if mine == nil then mine = add_comp(pawn, "Class /Script/Engine.SpotLightComponent") end
    if mine == nil then log("flashlight: AddComponentByClass(SpotLightComponent) failed"); return end
    -- Run 16:59: our light gave no light. Runtime-added lights must be Movable, and the game's light may use
    -- light units and an IES profile (Narrow10000 is referenced by the player), so copy those too.
    pcall(function() mine:SetMobility(2) end)
    pcall(function() mine.IntensityUnits = light.IntensityUnits end)
    pcall(function() mine:SetIESTexture(light.IESTexture) end)
    -- Run 17:19: the game light reads intensity 0.2 (unitless) with an IES profile; copying that gave no
    -- visible light. Our light uses its own brightness instead: flash_intensity (live), IES brightness off.
    -- flash_copy_game=1 (user 16:45: "can't you just copy the games default brightness?"): copy the game light's
    -- IES brightness setup exactly (property writes plus setters), then log what our light ended up with.
    if cfg.flash_copy_game ~= 0 then
        pcall(function() mine.bUseIESBrightness = light.bUseIESBrightness end)
        pcall(function() mine:SetUseIESBrightness(light.bUseIESBrightness) end)
        pcall(function() mine.IESBrightnessScale = light.IESBrightnessScale end)
        pcall(function() mine:SetIESBrightnessScale(light.IESBrightnessScale) end)
    else
        pcall(function() mine:SetUseIESBrightness(false) end)
    end
    pcall(function() mine:SetSourceRadius(light.SourceRadius) end)
    pcall(function() mine:SetIntensity(cfg.flash_copy_game ~= 0 and light.Intensity or cfg.flash_intensity) end)
    pcall(function()
        log(string.format("flashlight: game light IESbright %s scale %s IES %s | ours IESbright %s scale %s IES %s intensity %s units %s",
            tostring(light.bUseIESBrightness), tostring(light.IESBrightnessScale), tostring(light.IESTexture and light.IESTexture:get_fname():to_string()),
            tostring(mine.bUseIESBrightness), tostring(mine.IESBrightnessScale), tostring(mine.IESTexture and mine.IESTexture:get_fname():to_string()),
            tostring(mine.Intensity), tostring(mine.IntensityUnits)))
    end)
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
    if gi ~= nil and gi > 0 then st.game_int = gi; g:SetIntensity(0) end
    if on ~= st.light_on then st.light_on = on; m:SetVisibility(on, false); log("flashlight light " .. (on and "on" or "off")) end
    -- copy the game's intensity only when our light got the game's falloff mode too; otherwise it would be dark
    local same_falloff = false
    pcall(function() same_falloff = m.bUseInverseSquaredFalloff == g.bUseInverseSquaredFalloff end)
    local want = (cfg.flash_copy_game ~= 0 and same_falloff and st.game_int) or cfg.flash_intensity
    if want ~= nil and m.Intensity ~= want then m:SetIntensity(want) end
end

local function make_torch_model(pawn)
    local mesh = find("StaticMesh /Game/meshes/flashlight/flashlight.flashlight")
    if mesh == nil then return false end   -- not loaded yet; retried
    local comp = add_comp(pawn, "Class /Script/Engine.StaticMeshComponent")
    if comp == nil then log("flashlight: AddComponentByClass(StaticMeshComponent) failed"); return true end
    comp:SetStaticMesh(mesh)
    pcall(function()
        local n, list = comp:GetNumMaterials(), {}
        for i = 0, n - 1 do local m = comp:GetMaterial(i); list[#list + 1] = i .. "=" .. (m and m:get_fname():to_string() or "nil") end
        log("flashlight model materials: " .. table.concat(list, " "))
    end)
    if cfg.flash_lens_slot >= 0 then pcall(function() comp:SetMaterial(cfg.flash_lens_slot, comp:GetMaterial(0)) end) end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    comp:SetVisibility(false, false)
    st.torch = comp
    -- Run 16:49 (user): the model pointed back at the player. It now hangs off the light itself (which UEVR
    -- drives from the controller), turned by flash_model_yaw (live, default 180 degrees).
    if st.light ~= nil then
        comp:K2_AttachToComponent(st.light, fname("None"), 0, 0, 0, false)   -- keep relative location/rotation/scale
        comp:K2_SetRelativeRotation(rot(0, cfg.flash_model_yaw, 0), false, struct("ScriptStruct /Script/Engine.HitResult"), false)
        -- Run 17:30: the model's top rendered white. Its only material is the normal inst_flashlight, so the
        -- likely cause is our light sitting inside the model and blowing it out. Keep the model behind the light.
        comp:K2_SetRelativeLocation(vec(cfg.flash_model_x, 0, 0), false, struct("ScriptStruct /Script/Engine.HitResult"), false)
    else
        st.torch_state = mc_state(comp, cfg.flash_hand)
    end
    log("flashlight: model attached to the light, turned " .. cfg.flash_model_yaw .. " deg")
    return true
end

local function setup(pawn)
    log(string.format("setup: finger bend mcp %s pip %s dip_ratio %s relax %s axis %s; flash_intensity %s",
        tostring(cfg.hands_mcp), tostring(cfg.hands_pip), tostring(cfg.hands_dip_ratio), tostring(cfg.hands_relax),
        tostring(cfg.hands_curl_axis), tostring(cfg.flash_intensity)))
    st.pawn = pawn
    st.hands, st.hand_states, st.hand_base, st.calibrated, st.hand_bone = {}, {}, {}, {}, {}
    st.light, st.light_state, st.torch, st.torch_state, st.torch_vis = nil, nil, nil, nil, nil
    st.game_light, st.light_on, st.light_int = nil, nil, 0
    if not libs() then log("setup: Kismet libraries not found"); return end
    if cfg.hands_show ~= 0 then
        -- Style 3 (2026-11-27 pak search for the user): the game has no rigged Dr. Kel with fingers (his models
        -- are posed static meshes, kel3Pose_stand etc., and the player body kel_lmao has 6 bones), but the player
        -- Blueprint references kerfurOmega_KelSkin, a Kel-skinned Kerfur Omega with finger bones, so it's loaded.
        local mm = nil
        if cfg.hands_style == 3 then
            mm = find("SkeletalMesh /Game/meshes/kerfurAnthro/sk/kerfurOmega_KelSkin.kerfurOmega_KelSkin")
            log("hands: kerfurOmega_KelSkin in memory: " .. tostring(mm ~= nil))
        end
        if mm == nil and cfg.hands_style >= 2 then mm = load_mannequin() end
        if mm ~= nil then make_mannequin_hand(pawn, 1, mm); make_mannequin_hand(pawn, 0, mm); st.finger_rest = nil; st.curl_force = true
        elseif cfg.hands_style >= 1 then make_built_hand(pawn, 1); make_built_hand(pawn, 0); apply_hand_offsets()
        else make_hand(pawn, 1); make_hand(pawn, 0) end
    end
    if cfg.flash_on ~= 0 then make_flashlight(pawn) end
end



-- Finger curl (user 2026-11-27 18:30): curls arrive from the controls plugin as "votv_fingers" events
-- ("L t i m r p R t i m r p", 0..1; source: SteamVR skeletal summary on Index/Knuckles, else grip/trigger/face
-- buttons). The Kel-skin rig has four fingers, finger_N_1..3_<side>; hands_f_thumb/index/middle/ring pick N for
-- thumb, index, middle and ring+pinky (pinky drives the ring finger's chain too: the max of the two). Each segment
-- turns hands_curl_deg * curl about hands_curl_axis (1 pitch, 2 yaw, 3 roll) * hands_curl_sign, applied in the
-- bone's own frame on top of its rest pose (rest captured once after the hand is posed).
local curls = { [0] = { 0, 0, 0, 0, 0 }, [1] = { 0, 0, 0, 0, 0 } }
local curl_dirty = false
-- The game's own finger poses (2026-11-27 20:30): bone-local rotations relative to the reference pose, read by
-- tools/animread from the Kerfur's animations (open = givePaper frame 12, fist = idle). Lines
-- "bone ox oy oz ow fx fy fz fw" arrive from the plugin as "votv_game_poses". Curl c slerps open -> fist.
local game_poses = nil
pcall(function()
    uevr.sdk.callbacks.on_lua_event(function(name, data)
        if name ~= "votv_game_poses" or game_poses ~= nil then return end
        local gp = {}
        for line in tostring(data):gmatch("[^\n]+") do
            local v, bone = {}, line:match("^(%S+)")
            for n in line:gmatch("%s(%-?[%d%.]+)") do v[#v + 1] = tonumber(n) end
            if bone and #v == 8 then gp[bone] = { open = { v[1], v[2], v[3], v[4] }, fist = { v[5], v[6], v[7], v[8] } } end
        end
        game_poses = gp; st.curl_force = true; curl_dirty = true
        log("fingers: game poses loaded")
    end)
end)

local function slerp(a, b, t)
    local d = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    local s = d < 0 and -1 or 1
    d = math.abs(d)
    local wa, wb = 1 - t, t
    if d < 0.9995 then
        local th = math.acos(d); local sn = math.sin(th)
        wa, wb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
    end
    local q = {}
    for i = 1, 4 do q[i] = wa * a[i] + wb * s * b[i] end
    local n = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    for i = 1, 4 do q[i] = q[i] / n end
    return q
end

local function quat_to_rot(q)   -- FQuat::Rotator()
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local sing = z * x - w * y
    local yaw = math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
    if sing < -0.4999995 then
        return rot(-90, yaw, -yaw - 2 * math.deg(math.atan(x, w)))
    elseif sing > 0.4999995 then
        return rot(90, yaw, yaw - 2 * math.deg(math.atan(x, w)))
    end
    return rot(math.deg(math.asin(2 * sing)), yaw, math.deg(math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y))))
end

pcall(function()
    uevr.sdk.callbacks.on_lua_event(function(name, data)
        if name ~= "votv_fingers" then return end
        local v = {}
        for n in tostring(data):gmatch("%-?[%d%.]+") do v[#v + 1] = tonumber(n) end
        if #v >= 10 and not st.manual then
            for f = 1, 5 do curls[0][f] = v[f]; curls[1][f] = v[5 + f] end
            curl_dirty = true
        end
    end)
end)

local function finger_chain(side, n)
    local sfx = side == 1 and "R" or "L"
    return { string.format("finger_%d_1_%s", n, sfx), string.format("finger_%d_2_%s", n, sfx), string.format("finger_%d_3_%s", n, sfx) }
end

-- Curl axes from the rig itself (2026-11-27, after marks 18:45 looked "run over by a bulldozer"): computed offline
-- from kerfurOmegaV1_Skeleton's reference pose (scratch script geo.py): for every finger joint, axis =
-- cross(bone direction, palm normal), sign chosen so +angle moves the finger toward the palm, expressed in the
-- bone's own frame. Every joint comes out at about local +X for both hands. Offline stick-figure renders of open,
-- fist, point and thumb-rest with these axes looked like a hand. hands_curl_axis=0 uses this table (default);
-- 1/2/3 still force pitch/yaw/roll for experiments.
local CURL_AXES = {
    ["finger_1_1_L"] = { 0.986, -0.0, -0.1669 },
    ["finger_1_1_R"] = { 0.986, -0.0, 0.1669 },
    ["finger_1_2_L"] = { 0.9993, 0.0, 0.0386 },
    ["finger_1_2_R"] = { 0.9993, -0.0, -0.0386 },
    ["finger_1_3_L"] = { 0.9991, 0.0164, 0.0397 },
    ["finger_1_3_R"] = { 0.9991, -0.0164, -0.0397 },
    ["finger_2_1_L"] = { 0.9998, 0.0, -0.0198 },
    ["finger_2_1_R"] = { 0.9998, -0.0, 0.0198 },
    ["finger_2_2_L"] = { 1.0, -0.0, -0.0009 },
    ["finger_2_2_R"] = { 1.0, 0.0, 0.0009 },
    ["finger_2_3_L"] = { 1.0, 0.0028, 0.0012 },
    ["finger_2_3_R"] = { 1.0, -0.0028, -0.0012 },
    ["finger_3_1_L"] = { 0.9999, -0.0, -0.0171 },
    ["finger_3_1_R"] = { 0.9999, 0.0, 0.0171 },
    ["finger_3_2_L"] = { 1.0, 0.0, -0.0004 },
    ["finger_3_2_R"] = { 1.0, -0.0, 0.0004 },
    ["finger_3_3_L"] = { 1.0, -0.0, 0.0014 },
    ["finger_3_3_R"] = { 1.0, 0.0, -0.0014 },
    ["finger_4_1_L"] = { 0.9999, 0.0, -0.0167 },
    ["finger_4_1_R"] = { 0.9999, -0.0, 0.0167 },
    ["finger_4_2_L"] = { 1.0, 0.0, 0.0039 },
    ["finger_4_2_R"] = { 1.0, -0.0, -0.0039 },
    ["finger_4_3_L"] = { 1.0, -0.0088, 0.0003 },
    ["finger_4_3_R"] = { 1.0, 0.0088, -0.0003 },
}

local function curl_rot(deg, thumb, bone)
    local ax = thumb and cfg.hands_thumb_axis or cfg.hands_curl_axis
    local sign = thumb and cfg.hands_thumb_sign or cfg.hands_curl_sign
    if ax == 0 and CURL_AXES[bone] then
        local a = CURL_AXES[bone]
        return kml:RotatorFromAxisAndAngle(vec(a[1], a[2], a[3]), deg * sign)
    end
    local d = deg * sign
    if ax == 2 then return rot(0, d, 0) elseif ax == 3 then return rot(0, 0, d) end
    return rot(d, 0, 0)
end

local function apply_fingers(side)
    local comp = st.hands[side]
    if comp == nil or st.hand_bone == nil or st.hand_bone[side] == nil then return end
    st.finger_rest = st.finger_rest or {}
    local fmap = { cfg.hands_f_thumb, cfg.hands_f_index, cfg.hands_f_middle, cfg.hands_f_ring }
    local c = curls[side]
    local amount = { c[1], c[2], c[3], math.max(c[4], c[5]) }
    for i = 1, 4 do
        local chain = finger_chain(side, fmap[i])
        local key = side .. ":" .. chain[1]
        local ok, err = pcall(function()
            local parent = comp:GetParentBone(fname(chain[1]))
            if st.finger_rest[key] == nil then   -- rest local transforms, once (the hand is already posed)
                local rest, pt = {}, comp:GetBoneTransformByName(parent, COMP)
                for k = 1, 3 do   -- from the reference pose: a re-capture after a curl would stack the curl
                    pcall(function() comp:ResetBoneTransformByName(fname(chain[k])) end)
                end
                for k = 1, 3 do
                    local tk = comp:GetBoneTransformByName(fname(chain[k]), COMP)
                    rest[k] = kml:MakeRelativeTransform(tk, pt)
                    pt = tk
                end
                st.finger_rest[key] = rest
            end
            local rest = st.finger_rest[key]
            local pt = comp:GetBoneTransformByName(parent, COMP)
            -- Marks 18:41: with the pitch axis the fingers fanned sideways in the palm plane, so that axis is the
            -- palm normal; the curl axis is yaw (hands_curl_axis=2). Joint ratios: knuckle 0.8, middle 1.0,
            -- fingertip 0.67 of the middle joint; a relaxed open hand keeps hands_relax_deg of curl.
            -- Anatomical curl (research doc "VR hand animation research", 2026-11-27): knuckle (MCP) up to
            -- hands_mcp deg, middle joint (PIP) up to hands_pip, fingertip (DIP) = hands_dip_ratio * PIP and lagging
            -- (curl^1.5); the open hand stays relaxed (hands_relax of the way closed); ring+pinky close a little
            -- earlier and further; fingers converge toward the middle finger as they close (hands_splay deg about
            -- the palm-normal axis, which is pitch on this rig); the thumb also opposes toward the palm
            -- (hands_thumb_opp deg on its first joint).
            local thumb = i == 1
            local c = amount[i]
            if game_poses ~= nil and game_poses[chain[1]] ~= nil then
                for k = 1, 3 do
                    local g = game_poses[chain[k]]
                    -- open = the rig's straight reference pose: the givePaper frame fans the fingers into a claw (marks 20:09)
                    local curlT = kml:MakeTransform(vec(0, 0, 0), quat_to_rot(slerp({ 0, 0, 0, 1 }, g.fist, c)), vec(1, 1, 1))
                    local newc = kml:ComposeTransforms(kml:ComposeTransforms(curlT, rest[k]), pt)
                    comp:SetBoneTransformByName(fname(chain[k]), newc, COMP)
                    pt = newc
                end
                return
            end
            if i == 4 then c = math.min(1, (c ^ 0.85) * 1.1) end
            local e = cfg.hands_relax + (1 - cfg.hands_relax) * c                 -- effective closing 0..1
            local mcp, pip = cfg.hands_mcp * e, cfg.hands_pip * e
            local dip = cfg.hands_dip_ratio * cfg.hands_pip * (cfg.hands_relax + (1 - cfg.hands_relax) * (c ^ 1.5))
            local seg = { mcp, pip, dip }
            local spread = ({ 0, 1, 0, -1 })[i] * cfg.hands_splay * c * (side == 1 and 1 or -1)
            for k = 1, 3 do
                local r = curl_rot(seg[k], thumb, chain[k])
                if k == 1 and spread ~= 0 then r = kml:ComposeRotators(r, rot(spread, 0, 0)) end
                if k == 1 and thumb and cfg.hands_thumb_opp ~= 0 then r = kml:ComposeRotators(r, rot(cfg.hands_thumb_opp * e, 0, 0)) end
                local curlT = kml:MakeTransform(vec(0, 0, 0), r, vec(1, 1, 1))
                local newc = kml:ComposeTransforms(kml:ComposeTransforms(curlT, rest[k]), pt)
                comp:SetBoneTransformByName(fname(chain[k]), newc, COMP)
                pt = newc
            end
        end)
        if not ok and not st.finger_err then st.finger_err = true; log("fingers: " .. tostring(err)) end
    end
end

-- Pose presets per button state (user 19:19). The controls plugin owns them (it reads the buttons and keeps
-- votv_hand_presets.txt); it sends them here as "votv_presets" events, and the panel edits them and saves by
-- logging "PRESETS SAVE ..." (Lua can't write files; the plugin picks the line up within a second and writes the file).
local PRESET_NAMES = { "open", "trigger", "grip", "fist", "thumb_rest", "thumb_press" }
local PRESET_LABELS = { "open hand (nothing pressed)", "trigger pulled", "grip held", "grip + trigger (fist)",
                        "thumb resting on a button", "thumb pressing a button" }
local presets = {}
local preset_sel, preview = 1, false
pcall(function()
    uevr.sdk.callbacks.on_lua_event(function(name, data)
        if name ~= "votv_presets" then return end
        for line in tostring(data):gmatch("[^\n]+") do
            local k, rest = line:match("^(%w+_?%w*)=(.*)$")
            if k then
                local v = {}
                for n in rest:gmatch("%-?[%d%.]+") do v[#v + 1] = tonumber(n) end
                if #v == 5 and (not preview or presets[k] == nil) then presets[k] = v end
            end
        end
    end)
end)
local function show_preview()
    local p = presets[PRESET_NAMES[preset_sel]]
    if p == nil then return end
    for side = 0, 1 do for f = 1, 5 do curls[side][f] = p[f] end end
    st.curl_force = true
end


local diag_t = 0
local function hand_diag(delta)
    diag_t = diag_t + delta
    if diag_t < 3 then return end
    diag_t = 0
    for side = 0, 1 do
        local c, b = st.hands[side], st.hand_bone and st.hand_bone[side]
        if c ~= nil and b ~= nil then
            pcall(function()
                local cl = c:K2_GetComponentLocation()
                local bl = c:GetBoneLocationByName(fname(b), 0)   -- world space
                local bo = c.Bounds
                log(string.format("hands diag %s: visible %s, comp (%.0f %.0f %.0f), bone %s (%.0f %.0f %.0f) %.1f cm from comp, bounds r %.0f",
                    side == 1 and "R" or "L", tostring(c:IsVisible()), cl.X, cl.Y, cl.Z, b, bl.X, bl.Y, bl.Z,
                    math.sqrt((bl.X - cl.X) ^ 2 + (bl.Y - cl.Y) ^ 2 + (bl.Z - cl.Z) ^ 2), bo and bo.SphereRadius or -1))
            end)
        end
    end
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
            if st.torch and st.torch_state == nil then pcall(function()
                st.torch:K2_SetRelativeRotation(rot(0, cfg.flash_model_yaw, 0), false, struct("ScriptStruct /Script/Engine.HitResult"), false)
                st.torch:K2_SetRelativeLocation(vec(cfg.flash_model_x, 0, 0), false, struct("ScriptStruct /Script/Engine.HitResult"), false)
            end) end
            for side = 0, 1 do if st.hands[side] then pcall(function() st.hands[side]:SetVisibility(cfg.hands_show ~= 0, true) end) end end
        end
        -- flashlight model: create once the mesh is loaded, then show it only while the light is on
        if cfg.flash_on ~= 0 and cfg.flash_model ~= 0 and st.torch == nil and st.t - st.retry > 3 then
            st.retry = st.t
            make_torch_model(pawn)
        end
        pcall(sync_light)
        pcall(hand_diag, delta)
        -- Hand-Tuner preview (hands_preview 1..6): show that preset on both hands instead of the buttons
        if cfg.hands_preview ~= nil and cfg.hands_preview >= 1 then
            local pz = presets[PRESET_NAMES[math.floor(cfg.hands_preview)]]
            if pz then
                st.manual = true
                for side = 0, 1 do for f = 1, 5 do if curls[side][f] ~= pz[f] then curls[side][f] = pz[f]; st.curl_force = true end end end
            end
        elseif st.manual and not preview then st.manual = false end
        if curl_dirty or st.curl_force then curl_dirty = false; st.curl_force = false; for side = 0, 1 do apply_fingers(side) end end
        if st.torch ~= nil and st.game_light ~= nil then
            local on = cfg.flash_model ~= 0 and st.game_light:IsVisible()
            if on ~= st.torch_vis then st.torch_vis = on; st.torch:SetVisibility(on, false); log("flashlight model " .. (on and "shown" or "hidden")) end
        end
    end)
    if not ok then st.fails = st.fails + 1; if st.fails <= 5 then log("tick error " .. tostring(err)) end end
end)



-- Hand debug panel (user 2026-11-27 19:17: "an ingame debug menu where I could set the hand poses myself", as in
-- the Sims 4 VR mod). Drawn in UEVR's own menu (open it in VR with both stick clicks, or Insert on the keyboard;
-- the panel is under the Lua scripts section). Every slider applies at once. "Manual pose" freezes the fingers on
-- the sliders below instead of buttons/tracking. UEVR 1.05 Lua can't write files, so "Log values" writes all
-- current values to the UEVR log as one line; tell Claude, and they go into scripts/votv_controls.txt.
local ui_ok = imgui ~= nil and pcall(function()
    uevr.sdk.callbacks.on_draw_ui(function()
        local function fslider(label, key, lo, hi, place)
            local changed, v = imgui.slider_float(label, cfg[key], lo, hi)
            if changed then cfg[key] = v; if place then cfg._dirty = true else st.curl_force = true end end
        end
        local function islider(label, key, lo, hi, place)
            local changed, v = imgui.slider_int(label, cfg[key], lo, hi)
            if changed then cfg[key] = v; if place then cfg._dirty = true else st.curl_force = true end end
        end
        imgui.text("VOTV hands")
        local c, v = imgui.checkbox("Manual pose (sliders below drive the fingers)", st.manual == true)
        if c then st.manual = v; st.curl_force = true end
        if st.manual then
            local names = { "thumb", "index", "middle", "ring", "pinky" }
            for side = 1, 0, -1 do
                imgui.text(side == 1 and "Right hand" or "Left hand")
                for f = 1, 5 do
                    local ch, nv = imgui.slider_float((side == 1 and "R " or "L ") .. names[f], curls[side][f], 0, 1)
                    if ch then curls[side][f] = nv; st.curl_force = true end
                end
            end
        end
        imgui.text("Pose presets per button state")
        local cp, nv = imgui.checkbox("Preview / edit preset (shows it on both hands)", preview)
        if cp then preview = nv; st.manual = nv; if nv then show_preview() end end
        local cs, sel = imgui.slider_int("preset", preset_sel, 1, #PRESET_NAMES)
        if cs then preset_sel = sel; if preview then show_preview() end end
        imgui.text("  " .. PRESET_LABELS[preset_sel])
        local p = presets[PRESET_NAMES[preset_sel]]
        if p ~= nil then
            local fn = { "thumb", "index", "middle", "ring", "pinky" }
            for f = 1, 5 do
                local ch, v2 = imgui.slider_float("preset " .. fn[f], p[f], 0, 1)
                if ch then p[f] = v2; if preview then show_preview() end end
            end
            if imgui.button("Save presets") then
                local parts = {}
                for _, n in ipairs(PRESET_NAMES) do
                    local q = presets[n]
                    if q then parts[#parts + 1] = string.format("%s=%.2f %.2f %.2f %.2f %.2f", n, q[1], q[2], q[3], q[4], q[5]) end
                end
                log("PRESETS SAVE " .. table.concat(parts, ";"))
            end
        else
            imgui.text("  (waiting for the presets from the controls plugin)")
        end
        imgui.text("Bend (degrees at full curl)")
        fslider("knuckle (MCP)", "hands_mcp", 0, 130)
        fslider("middle joint (PIP)", "hands_pip", 0, 130)
        fslider("tip / middle ratio (DIP)", "hands_dip_ratio", 0, 1.5)
        fslider("relaxed open hand", "hands_relax", 0, 0.6)
        islider("bend direction (+1 / -1)", "hands_curl_sign", -1, 1)
        islider("thumb bend direction", "hands_thumb_sign", -1, 1)
        islider("bend axis (0 computed, 1 pitch, 2 yaw, 3 roll)", "hands_curl_axis", 0, 3)
        islider("thumb axis (0 computed, 1-3)", "hands_thumb_axis", 0, 3)
        imgui.text("Hand placement")
        fslider("forward (cm)", "hands_x", -25, 25, true)
        fslider("sideways (cm)", "hands_y", -25, 25, true)
        fslider("up (cm)", "hands_z", -25, 25, true)
        fslider("pitch", "hands_pitch", -180, 180, true)
        fslider("yaw", "hands_yaw", -180, 180, true)
        fslider("roll", "hands_roll", -180, 180, true)
        fslider("right hand turn", "hands_r_yaw", -180, 180, true)
        fslider("right hand roll", "hands_r_roll", -180, 180, true)
        fslider("left hand turn", "hands_l_yaw", -180, 180, true)
        fslider("left hand roll", "hands_l_roll", -180, 180, true)
        fslider("hand size", "hands_scale", 0.5, 2, true)
        if imgui.button("Log values") then
            local keys = {}
            for k, val in pairs(cfg) do if type(val) == "number" and k:sub(1, 6) == "hands_" then keys[#keys + 1] = k .. "=" .. string.format("%.3f", val) end end
            table.sort(keys)
            local pose = ""
            if st.manual then for side = 0, 1 do for f = 1, 5 do pose = pose .. string.format(" %s%d=%.2f", side == 1 and "R" or "L", f, curls[side][f]) end end end
            log("PANEL VALUES: " .. table.concat(keys, " ") .. (pose ~= "" and (" | manual pose" .. pose) or ""))
        end
    end)
end)
log("debug panel " .. (ui_ok and "registered in the UEVR menu" or "not available (UEVR 1.05 scripts have no imgui; use Hand-Tuner.bat on the desktop)"))

log("loaded (idle until the controls plugin is seen)")
