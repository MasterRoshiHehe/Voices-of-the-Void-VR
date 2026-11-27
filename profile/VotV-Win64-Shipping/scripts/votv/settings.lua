-- VOTV VR live settings (UEVR Lua module, re-read every second by the votv_*.lua scripts).
-- Edit a value and save; it applies within a second. Missing keys use each script's safe default.
return {
    -- main menu (votv_menu_camera.lua)
    menu_lock_view = 0,            -- 1 = lock the menu view to the face (experimental, off)
    menu_ipd_cm = 6.4,             -- eye separation while locked (cm)
    menu_eye_sign = 1,             -- -1 swaps the eyes while locked
    menu_map_pattern = "/game/menu%.menu",  -- Lua pattern for the menu world's name (lowercased)
    menu_unconstrain_aspect = 0,   -- 1 = turn off camera aspect constraints (didn't help; off)
    menu_hide_widgets = {},        -- staged for the menu test: { "BackgroundBlur_76", "BackgroundBlur" }
                                   -- (the flat copy of the scene); {} = hide nothing
    -- graphics probe (votv_graphics.lua): probe only while gfx_override_enable = 0
    gfx_log_interval_s = 10,       -- cvar dump + frame-time summary every N seconds
    gfx_reapply_interval_s = 2,    -- override check / re-apply interval (seconds)
    gfx_override_enable = 0,       -- 1 = apply gfx_set below
    gfx_set = {},                  -- cvar -> number, e.g. { ["r.MotionBlurQuality"] = 0 }
}
