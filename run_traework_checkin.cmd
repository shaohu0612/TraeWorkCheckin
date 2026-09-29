@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: ============================================
:: TraeWorkCheckin Daily Runner
:: ============================================

set "SCRIPT_PATH=%~dp0checkin.js"
set "EXIT_CODE=0"

:: 1. Check if Node.js is installed and meets modern API requirements (fetch & crypto.subtle)
where node >nul 2>nul
if %errorlevel% equ 0 (
  node -e "if(typeof fetch!=='function'||!require('crypto').subtle)process.exit(1)" >nul 2>nul
  if !errorlevel! equ 0 (
    node "%SCRIPT_PATH%" %*
    set "EXIT_CODE=!errorlevel!"
    goto :END
  )
)

:: 2. Auto-detect any installed Trae executable across standard paths and Windows Registry
set "FOUND_EXE="

:: 2.1 Check LocalAppData
for /d %%D in ("%LOCALAPPDATA%\Programs\*trae*") do (
  for %%F in ("%%D\*trae*.exe") do (
    if not defined FOUND_EXE if exist "%%F" set "FOUND_EXE=%%F"
  )
)

:: 2.2 Check Program Files (64-bit and 32-bit)
if not defined FOUND_EXE (
  for /d %%D in ("%ProgramFiles%\*trae*" "%ProgramFiles(x86)%\*trae*" "%ProgramW6432%\*trae*") do (
    for %%F in ("%%D\*trae*.exe") do (
      if not defined FOUND_EXE if exist "%%F" set "FOUND_EXE=%%F"
    )
  )
)

:: 2.3 Query Windows Registry (Locates Trae installed on ANY custom drive or path)
if not defined FOUND_EXE (
  for %%K in ("HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall" "HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall" "HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall") do (
    if not defined FOUND_EXE (
      for /f "tokens=2*" %%A in ('reg query %%K /s /v DisplayIcon 2^>nul ^| findstr /i /c:"trae"') do (
        set "REG_PATH=%%B"
        set "REG_PATH=!REG_PATH:,0=!"
        set "REG_PATH=!REG_PATH:"=!"
        if not defined FOUND_EXE if exist "!REG_PATH!" set "FOUND_EXE=!REG_PATH!"
      )
    )
  )
)

:: 2.4 Check user-specific directories across common drives
if not defined FOUND_EXE (
  for %%D in (C D E F G) do (
    if not defined FOUND_EXE if exist "%%D:\Users\%USERNAME%\AppData\Local\Programs\TRAE SOLO CN\TRAE SOLO CN.exe" (
      set "FOUND_EXE=%%D:\Users\%USERNAME%\AppData\Local\Programs\TRAE SOLO CN\TRAE SOLO CN.exe"
    )
    if not defined FOUND_EXE if exist "%%D:\Users\%USERNAME%\AppData\Local\Programs\Trae CN\Trae CN.exe" (
      set "FOUND_EXE=%%D:\Users\%USERNAME%\AppData\Local\Programs\Trae CN\Trae CN.exe"
    )
  )
)

:: 2.5 Check PATH for trae executables
if not defined FOUND_EXE (
  for %%I in (trae.exe "Trae CN.exe" "TRAE SOLO CN.exe" "Trae.exe") do (
    if not defined FOUND_EXE if "%%~$PATH:I" neq "" set "FOUND_EXE=%%~$PATH:I"
  )
)

:: 3. Execute with detected Trae runtime if found
if defined FOUND_EXE (
  set ELECTRON_RUN_AS_NODE=1
  set VSCODE_DEV=
  "!FOUND_EXE!" "%SCRIPT_PATH%" %*
  set "EXIT_CODE=!errorlevel!"
  goto :END
)

echo [ERROR] No suitable runtime (modern Node.js 18+ or Trae executable) found!
echo -------------------------------------------------------------------------
echo [Notice] Neither Node.js 18+ nor Trae client installation was detected.
echo Troubleshooting:
echo   1. If Trae is installed, open Trae once and run this script again;
echo   2. Or install Node.js (LTS version recommended) from https://nodejs.org
echo -------------------------------------------------------------------------
echo.
set "EXIT_CODE=1"

:END
:: If launched with --silent or -s, exit immediately (for scheduled tasks)
if /i "%~1"=="--silent" goto :EXIT
if /i "%~1"=="-s" goto :EXIT

echo.
pause

:EXIT
endlocal & exit /b %EXIT_CODE%
