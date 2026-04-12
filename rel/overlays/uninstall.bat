@echo off
setlocal enabledelayedexpansion

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set DATA_DIR=%APPDATA%\scry_2
set DB_FILE=%DATA_DIR%\scry_2.db

REM If running from inside the install dir, relocate to %TEMP% first
set TEMP_UNINSTALL=%TEMP%\scry2_uninstall_%RANDOM%.bat
echo %~f0 | findstr /i /c:"%INSTALL_DIR%" >nul
if %errorlevel%==0 (
    echo Relocating uninstaller...
    copy /y "%~f0" "%TEMP_UNINSTALL%" >nul
    start "" cmd /c ""%TEMP_UNINSTALL%" --relocated"
    exit /b 0
)
if "%~1"=="--relocated" shift
pushd "%TEMP%"

echo Uninstalling Scry2...

REM Stop existing Scry2 processes
call :kill_scry2_processes
call :wait_processes_dead
if errorlevel 1 exit /b 1

REM Remove autostart registry entry
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "Scry2" /f 2>nul

REM Remove the install directory only. Data dir (%APPDATA%\scry_2) is preserved.
call :remove_install_dir
if errorlevel 1 exit /b 1

echo.
echo Scry2 has been uninstalled.
echo.
echo Your database has NOT been deleted.
echo.

if exist "%DB_FILE%" (
    for %%A in ("%DB_FILE%") do set DB_SIZE=%%~zA
    echo   Database: %DB_FILE%
    echo   Size:     !DB_SIZE! bytes
) else (
    echo   Database: %DB_FILE% ^(not found^)
)

echo   Config:   %DATA_DIR%\config.toml
echo.
echo If you want to delete your database and config, run:
echo   rmdir /s /q "%DATA_DIR%"
echo.
pause
exit /b 0

REM === Subroutines ===

:kill_scry2_processes
echo Stopping Scry2...
REM Phase 1: Kill tray first to stop watchdog from respawning backend
powershell -NoProfile -Command ^
    "$d='%INSTALL_DIR%'; Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d,[System.StringComparison]::OrdinalIgnoreCase) -and $_.Name -eq 'scry2-tray' } | Stop-Process -Force" 2>nul
timeout /t 1 /nobreak >nul
REM Phase 2: Kill everything else under the install dir (erl, epmd, werl, etc.)
powershell -NoProfile -Command ^
    "$d='%INSTALL_DIR%'; Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d,[System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force" 2>nul
if errorlevel 1 (
    REM Fallback: blunt kill if PowerShell failed
    taskkill /f /im scry2-tray.exe 2>nul
    taskkill /f /im erl.exe 2>nul
    taskkill /f /im epmd.exe 2>nul
)
goto :eof

:wait_processes_dead
set WAIT_COUNT=0
:wait_loop
set PROC_COUNT=
for /f %%P in (
    'powershell -NoProfile -Command "$d='%INSTALL_DIR%'; @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d,[System.StringComparison]::OrdinalIgnoreCase) }).Count" 2^>nul'
) do set PROC_COUNT=%%P
if not defined PROC_COUNT set PROC_COUNT=0
if "%PROC_COUNT%"=="0" goto :eof
set /a WAIT_COUNT+=1
if %WAIT_COUNT% geq 15 (
    echo ERROR: Could not stop all Scry2 processes after 15 seconds.
    echo Please close Scry2 manually and try again.
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto :wait_loop

:remove_install_dir
if not exist "%INSTALL_DIR%" goto :eof
set DEL_ATTEMPTS=0
:remove_retry
rmdir /s /q "%INSTALL_DIR%" 2>nul
if not exist "%INSTALL_DIR%" goto :eof
set /a DEL_ATTEMPTS+=1
if %DEL_ATTEMPTS% geq 5 (
    echo ERROR: Could not remove %INSTALL_DIR%
    echo Some files may still be locked. Please close any programs
    echo using files in that directory and try again.
    pause
    exit /b 1
)
echo Waiting for file locks to release...
timeout /t 2 /nobreak >nul
goto :remove_retry
