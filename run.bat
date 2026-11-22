@echo off
rem Runs SmartHomeKJ on this Windows computer, setting everything up the first time.
rem Extra arguments go to "flutter run", e.g. run.bat --release
cd /d "%~dp0"
call "%~dp0flutterw.bat" run -d windows %*
if errorlevel 1 pause
