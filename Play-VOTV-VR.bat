@echo off
rem Voices of the Void VR (stage A): launches the game with -d3d11, injects UEVR (OpenXR), copies logs when the game exits.
rem Start Virtual Desktop and connect the Quest 3 first. Extra options pass through, e.g. Play-VOTV-VR.bat -InjectDelaySeconds 30
echo Leave this window open: it copies the logs and resets the VR settings after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" %*
echo.
pause
