@echo off
rem Builds the ARM64 DLL and installs it into C:\Program Files\Notepad++\plugins\NppMenuSearch.
rem Run as administrator (right-click, Run as administrator).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Arm64.ps1" -Install
pause
