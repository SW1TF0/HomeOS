@echo off
rem Installs everything SmartHomeKJ needs on Windows (double-click it).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\setup.ps1" %*
pause
