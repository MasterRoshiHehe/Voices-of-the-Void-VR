@echo off
rem Voices of the Void VR: motion-controller test run (controls thread). Same as Play-VOTV-VR.bat plus the
rem controller plugin (votv_controls.dll), which is removed again when the game closes.
rem Start Virtual Desktop and connect the Quest 3 first. On the PC: click Proceed and load a save, then put the headset on.
echo Leave this window open: it copies the logs and removes the controller plugin after the game closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-vr.ps1" -Controls -Pointer -Feature controls-b1 %*
echo.
pause
