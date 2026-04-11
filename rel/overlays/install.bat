@echo off
setlocal enabledelayedexpansion

echo Installing Scry2...

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set SCRIPT_DIR=%~dp0

REM Stop existing tray and backend if running
taskkill /f /im scry2-tray.exe 2>nul
if exist "%INSTALL_DIR%\bin\scry_2.bat" (
    call "%INSTALL_DIR%\bin\scry_2.bat" stop 2>nul
)
timeout /t 2 /nobreak >nul

REM Remove previous install
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%"
)

REM Copy release to AppData\Local\scry_2
echo Copying files to %INSTALL_DIR%...
mkdir "%INSTALL_DIR%"
xcopy /e /i /q /h "%SCRIPT_DIR%." "%INSTALL_DIR%" >nul

REM Register autostart on login — point to tray, not backend
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" ^
    /v "Scry2" ^
    /t REG_SZ ^
    /d "\"%INSTALL_DIR%\scry2-tray.exe\"" ^
    /f >nul

REM Start the tray (it will launch the backend and open the browser)
echo Starting Scry2...
start "" /B "%INSTALL_DIR%\scry2-tray.exe"

echo.
echo Scry2 installed successfully!
echo It will start automatically on each login.
echo Open http://localhost:6015 in your browser to view your stats.
echo.
pause
