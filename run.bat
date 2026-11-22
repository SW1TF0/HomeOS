@echo off
rem Runs SmartHomeKJ on this Windows computer, setting everything up the first time.
rem   run.bat                 run it
rem   run.bat --as macos      run it looking and behaving like macOS (or android, ios, linux)
rem   run.bat --release       any other arguments go to "flutter run"
cd /d "%~dp0"
set "ARGS="
:loop
if "%~1"=="" goto run
if "%~1"=="--as" (
  set "ARGS=%ARGS% --dart-define=PRETEND_PLATFORM=%~2"
  shift
  shift
  goto loop
)
set "ARGS=%ARGS% %1"
shift
goto loop
:run
call "%~dp0flutterw.bat" run -d windows %ARGS%
if errorlevel 1 pause
