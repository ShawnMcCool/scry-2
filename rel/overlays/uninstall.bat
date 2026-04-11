@echo off
echo Uninstalling Scry2...

REM Stop the running instance
if exist "%LOCALAPPDATA%\scry_2\bin\scry_2.bat" (
    call "%LOCALAPPDATA%\scry_2\bin\scry_2.bat" stop 2>nul
    timeout /t 2 /nobreak >nul
)

REM Remove autostart registry entry
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "Scry2" /f 2>nul

REM Remove the installation directory
if exist "%LOCALAPPDATA%\scry_2" (
    rmdir /s /q "%LOCALAPPDATA%\scry_2"
    echo Scry2 removed from %LOCALAPPDATA%\scry_2
)

echo.
echo Your data and config have been preserved:
echo   Config: %APPDATA%\scry_2\config.toml
echo   Data:   %LOCALAPPDATA%\scry_2\  (removed with install files)
echo.
echo To also remove your data, delete: %APPDATA%\scry_2\
echo.
pause
