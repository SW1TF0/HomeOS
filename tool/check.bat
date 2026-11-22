@echo off
rem What CI checks, on this computer: packages, analysis and every test. Add --build to also build the Windows app.
cd /d "%~dp0.."
call flutterw.bat pub get || exit /b 1
echo ==^> Analyze
call flutterw.bat analyze --no-fatal-infos || exit /b 1
echo ==^> Test
call flutterw.bat test || exit /b 1
if "%1"=="--build" (
  echo ==^> Build windows
  call flutterw.bat build windows --debug || exit /b 1
)
echo ==^> All good
