@echo off
rem Builds the experimental ARM64 NppMenuSearch.dll into NppMenuSearchin\ARM64\Release.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Arm64.ps1"
pause
