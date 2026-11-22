@echo off
rem Flutter, at the version this repo uses (pubspec.yaml), from .sdk\flutter. Sets it up the first time.
rem   flutterw.bat run -d windows      flutterw.bat test      flutterw.bat build windows
if not exist "%~dp0.sdk\flutter\bin\flutter.bat" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\setup.ps1" || exit /b 1
if exist "%~dp0.sdk\jdk\bin\java.exe" set "JAVA_HOME=%~dp0.sdk\jdk"
call "%~dp0.sdk\flutter\bin\flutter.bat" %*
