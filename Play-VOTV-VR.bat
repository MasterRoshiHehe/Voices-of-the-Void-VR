@echo off
rem Voices of the Void VR: launches the game with -d3d11, injects UEVR (OpenXR, Virtual Desktop), copies logs when the game exits.
rem Start Virtual Desktop and connect the Quest 3 first. Loads the menu laser pointer (votv_pointer.dll) and the motion controls (votv_controls.dll + hand aim); both are removed when the game closes.
echo Main menu: flat screen in front of you; point the right controller at it, trigger = click, stick = scroll.
echo Leave this window open: it copies the logs and resets the VR settings after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" -Controls -Pointer %*
echo.
pause
