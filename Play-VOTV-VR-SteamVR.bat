@echo off
rem Voices of the Void VR, SteamVR (OpenVR) parallel test. One run only: OpenXR (Virtual Desktop) stays the default and is restored afterwards.
rem Start Virtual Desktop and connect the Quest 3 first; UEVR will start SteamVR. Extra options pass through.
echo Menus: use Virtual Desktop's desktop laser. Once your save has loaded, press F10 to switch to VR.
echo Leave this window open: it copies the logs and resets the VR settings after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" -Runtime OpenVR -LateInject %*
echo.
pause
