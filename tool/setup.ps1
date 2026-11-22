# Sets up everything needed to run and build SmartHomeKJ on Windows, inside this repo.
#
#   powershell -ExecutionPolicy Bypass -File tool\setup.ps1            Flutter, Visual Studio's C++ tools, packages
#   powershell -ExecutionPolicy Bypass -File tool\setup.ps1 -Android   the same, plus Java and the Android SDK
#
# Or just double-click setup.bat in the repo folder.
#
# Flutter goes into .sdk\flutter (ignored by Git), at exactly the version in pubspec.yaml, so it never clashes with
# another Flutter on this computer and Windows builds with the same Flutter as the Mac. Run it again any time: it
# only does what is missing.
param([switch]$Android)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = Split-Path -Parent $PSScriptRoot
$Sdk = Join-Path $Root '.sdk'
$FlutterDir = Join-Path $Sdk 'flutter'
$Flutter = Join-Path $FlutterDir 'bin\flutter.bat'
$Version = (Select-String -Path (Join-Path $Root 'pubspec.yaml') -Pattern '^\s{2}flutter:\s*([0-9.]+)').Matches[0].Groups[1].Value

function Say($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!   $m" -ForegroundColor Yellow }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

if (-not $Version) { throw "No 'flutter:' version under environment in pubspec.yaml" }

# ---- Git --------------------------------------------------------------------------------------------------------
if (-not (Have git)) {
  Say 'Installing Git'
  if (-not (Have winget)) { throw 'Install Git from https://git-scm.com and run this again (winget is not available).' }
  winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
  Refresh-Path
}

# ---- Visual Studio C++ build tools (needed to build the Windows app) --------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCpp = (Test-Path $vswhere) -and
  (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $hasCpp) {
  Say 'Installing the Visual Studio C++ build tools (a few GB, takes a while)'
  if (Have winget) {
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --silent --accept-package-agreements --accept-source-agreements `
      --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
  } else {
    Warn 'Install "Build Tools for Visual Studio 2022" with "Desktop development with C++" from https://visualstudio.microsoft.com/downloads/'
  }
} else {
  Say 'Visual Studio C++ build tools are installed'
}

# ---- Developer Mode (Flutter plugins need symlinks on Windows) --------------------------------------------------
$dev = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
if (-not $dev -or $dev.AllowDevelopmentWithoutDevLicense -ne 1) {
  Warn 'Windows Developer Mode is off. Flutter needs it to build apps with plugins.'
  Warn 'Turn on "Developer Mode" in the Settings window that opens, then run this again if building fails.'
  Start-Process 'ms-settings:developers'
}

# ---- Flutter, at the version in pubspec.yaml --------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Sdk | Out-Null
$current = if (Test-Path $Flutter) { (git -C $FlutterDir describe --tags 2>$null) } else { $null }
if ($current -eq $Version) {
  Say "Flutter $Version is already in .sdk\flutter"
} else {
  Say "Downloading Flutter $Version into .sdk\flutter"
  if (Test-Path $FlutterDir) { Remove-Item -Recurse -Force $FlutterDir }
  # Long paths inside the Flutter SDK go past Windows' old 260-character limit.
  git config --global core.longpaths true
  # The official release archive: the stable channel at exactly this version.
  $zip = Join-Path $env:TEMP "flutter_windows_$Version-stable.zip"
  Invoke-WebRequest "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$Version-stable.zip" -OutFile $zip
  Expand-Archive $zip $Sdk -Force
  Remove-Item $zip
  git config --global --add safe.directory ($FlutterDir -replace '\\', '/')
}
$env:Path = (Join-Path $FlutterDir 'bin') + ';' + $env:Path
& $Flutter config --no-analytics | Out-Null
& $Flutter --disable-analytics | Out-Null

# ---- Android (only with -Android) -------------------------------------------------------------------------------
if ($Android) {
  Say 'Android: Java 17 and the Android SDK into .sdk'
  $Jdk = Join-Path $Sdk 'jdk'
  if (-not (Test-Path (Join-Path $Jdk 'bin\java.exe'))) {
    $zip = Join-Path $env:TEMP 'jdk17.zip'
    Invoke-WebRequest 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse' -OutFile $zip
    $tmp = Join-Path $env:TEMP 'jdk17'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive $zip $tmp
    Move-Item (Get-ChildItem $tmp | Select-Object -First 1).FullName $Jdk
  }
  $env:JAVA_HOME = $Jdk
  $Asdk = Join-Path $Sdk 'android'
  $sdkmanager = Join-Path $Asdk 'cmdline-tools\latest\bin\sdkmanager.bat'
  if (-not (Test-Path $sdkmanager)) {
    $zip = Join-Path $env:TEMP 'android-tools.zip'
    Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile $zip
    $tmp = Join-Path $env:TEMP 'android-tools'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive $zip $tmp
    New-Item -ItemType Directory -Force -Path (Join-Path $Asdk 'cmdline-tools') | Out-Null
    Move-Item (Join-Path $tmp 'cmdline-tools') (Join-Path $Asdk 'cmdline-tools\latest')
  }
  1..20 | ForEach-Object { 'y' } | & $sdkmanager --sdk_root=$Asdk --licenses | Out-Null
  & $sdkmanager --sdk_root=$Asdk 'platform-tools' 'platforms;android-35' 'build-tools;35.0.0'
  & $Flutter config --android-sdk $Asdk --jdk-dir $Jdk
}

# ---- The app ---------------------------------------------------------------------------------------------------
Say "Getting the app's packages"
Push-Location $Root
& $Flutter precache --universal --windows
& $Flutter pub get
Say 'What Flutter can build on this computer'
& $Flutter doctor
Pop-Location

Write-Host @"

Done. From the repo folder:
  run.bat              run the app on this computer
  tool\check.bat       analyze and run every test (what CI runs)
  flutterw.bat <args>  any Flutter command with this repo's Flutter, e.g. flutterw.bat build windows
"@
