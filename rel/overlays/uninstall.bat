@echo off
setlocal enabledelayedexpansion

echo Uninstalling Scry2...

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set DATA_DIR=%APPDATA%\scry_2
set DB_FILE=%DATA_DIR%\scry_2.db

REM Stop the tray (it will stop the backend on exit)
taskkill /f /im scry2-tray.exe 2>nul
timeout /t 2 /nobreak >nul

REM Also stop backend directly in case tray was not running
if exist "%INSTALL_DIR%\bin\scry_2.bat" (
    call "%INSTALL_DIR%\bin\scry_2.bat" stop 2>nul
    timeout /t 2 /nobreak >nul
)

REM Remove autostart registry entry
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "Scry2" /f 2>nul

REM Remove the install directory only. Data dir (%APPDATA%\scry_2) is preserved.
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%"
    echo Removed install files from %INSTALL_DIR%
)

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
