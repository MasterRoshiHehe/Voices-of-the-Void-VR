@echo off
rem VOTV VR hand tuner: sliders for the hand pose presets, finger bend and hand placement, live while the game runs.
start "" "%~dp0.venv\Scripts\pythonw.exe" -I "%~dp0scripts\hand_tuner.py"
