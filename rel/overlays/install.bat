@echo off
setlocal enabledelayedexpansion

echo Installing Scry2...

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set SCRIPT_DIR=%~dp0

REM Remove previous install if present
if exist "%INSTALL_DIR%" (
    echo Stopping previous installation...
    if exist "%INSTALL_DIR%\bin\scry_2.bat" (
        call "%INSTALL_DIR%\bin\scry_2.bat" stop 2>nul
    )
    timeout /t 2 /nobreak >nul
    rmdir /s /q "%INSTALL_DIR%"
)

REM Copy release to AppData\Local\scry_2
echo Copying files to %INSTALL_DIR%...
mkdir "%INSTALL_DIR%"
xcopy /e /i /q /h "%SCRIPT_DIR%." "%INSTALL_DIR%" >nul

REM Register autostart on login
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" ^
    /v "Scry2" ^
    /t REG_SZ ^
    /d "\"%INSTALL_DIR%\bin\scry_2.bat\" start" ^
    /f >nul

REM Start the app
echo Starting Scry2...
start "" /B "%INSTALL_DIR%\bin\scry_2.bat" start

REM Open browser after the app has time to boot
timeout /t 4 /nobreak >nul
start "" http://localhost:4002

echo.
echo Scry2 installed successfully!
echo It will start automatically on each login.
echo Open http://localhost:4002 in your browser to view your stats.
echo.
pause
