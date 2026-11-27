@echo off
rem Voices of the Void VR, SteamVR (OpenVR) parallel test, one run only; OpenXR stays the default and is restored afterwards.
rem Start Virtual Desktop and connect the Quest 3 first. Loads the menu laser pointer (votv_pointer.dll) and the motion controls (votv_controls.dll + hand aim); both are removed when the game closes.
echo Main menu: flat screen in front of you; point the right controller at it, trigger = click, stick = scroll.
echo Leave this window open: it copies the logs and resets the VR settings after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" -Runtime OpenVR -Controls -Pointer %*
echo.
pause
