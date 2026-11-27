-- VOTV VR live settings (UEVR Lua module, re-read every second by the votv_*.lua scripts).
-- Edit a value and save; it applies within a second. Missing keys use each script's safe default.
return {
    -- main menu (votv_menu_camera.lua)
    menu_2d = 1,                   -- 1 = main menu as a flat 2D screen (UEVR 2D screen mode), 0 = stereo
    menu_lock_view = 0,            -- 1 = lock the menu view to the face (experimental, off)
    menu_ipd_cm = 6.4,             -- eye separation while locked (cm)
    menu_eye_sign = 1,             -- -1 swaps the eyes while locked
    -- menu_map_pattern = "/game/menu%.menu",  -- one Lua pattern; unset = main menu + preLoad (warning screen)
    menu_unconstrain_aspect = 0,   -- 1 = turn off camera aspect constraints (didn't help; off)
    menu_beam = 0,                 -- 1 = experimental beam mesh on the right controller in flat menus
                                   -- (votv_menu_beam.lua; expected to show inside the flat picture only)
    menu_beam_len_cm = 200,        -- beam length (cm)
    menu_beam_thick_cm = 0.6,      -- beam diameter (cm)
    menu_hide_widgets = {},        -- staged for the menu test: { "BackgroundBlur_76", "BackgroundBlur" }
                                   -- (the flat copy of the scene); {} = hide nothing
}
