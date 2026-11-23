@echo off
rem Flutter, at the version this repo uses (pubspec.yaml), from .sdk\flutter. Sets it up the first time.
rem   flutterw.bat run -d windows      flutterw.bat test      flutterw.bat build windows
if not exist "%~dp0.sdk\flutter\bin\flutter.bat" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\setup.ps1" || exit /b 1
if exist "%~dp0.sdk\jdk\bin\java.exe" set "JAVA_HOME=%~dp0.sdk\jdk"
rem The Firebase API key is not in the code: run and build take it from firebase.local.json when it is there.
if exist "%~dp0firebase.local.json" if /i "%~1"=="run" goto withkey
if exist "%~dp0firebase.local.json" if /i "%~1"=="build" goto withkey
call "%~dp0.sdk\flutter\bin\flutter.bat" %*
exit /b %errorlevel%
:withkey
set "CMD=%~1"
shift
if /i "%CMD%"=="build" (set "CMD=build %~1" & shift)
set "REST="
:rest
if "%~1"=="" goto go
set "REST=%REST% %1"
shift
goto rest
:go
call "%~dp0.sdk\flutter\bin\flutter.bat" %CMD% --dart-define-from-file="%~dp0firebase.local.json"%REST%
