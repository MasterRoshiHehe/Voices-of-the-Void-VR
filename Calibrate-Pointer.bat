@echo off
rem Laser-pointer calibration session (menu thread). Puts the pointer into calibration mode (no clicks), then
rem launches the game with the pointer (OpenXR). In the headset: at the warning screen, point at the flat screen's
rem corners in this order and pull the trigger at each: top-left, top-right, bottom-right, bottom-left.
rem The fitted screen is saved to the profile's scripts\votv_pointer.txt (clicking stays off until set ptr_click=1).
echo Leave this window open: it copies the logs and resets the VR settings after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:APPDATA 'UnrealVRMod\VotV-Win64-Shipping\scripts\votv_pointer.txt'; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Set-Content -Path $f -Encoding ascii -Value @('# calibration session', 'ptr_calibrate=1', 'ptr_click=0')"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" -Pointer -Feature pointer-calibration %*
echo.
pause
