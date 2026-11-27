@echo off
rem One SteamVR run that records both eyes every 3 s (menu, then gameplay) for the menu stereo analysis.
rem Also the SteamVR baseline run for the runtime matrix (-Feature baseline). OpenXR stays the default afterwards.
echo Leave this window open: it copies the logs and resets the VR settings after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" -Runtime OpenVR -Feature baseline -EyeCaptureFirstDelaySeconds 5 -EyeCaptureEverySeconds 3 -EyeCaptureMax 100 %*
echo.
pause
