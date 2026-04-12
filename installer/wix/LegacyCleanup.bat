@echo off
REM Removes legacy batch-file installation from %LOCALAPPDATA%\scry_2.
REM Called as a deferred custom action during MSI install.

set LEGACY_DIR=%LOCALAPPDATA%\scry_2
if not exist "%LEGACY_DIR%\scry2-tray.exe" exit /b 0

REM Kill legacy processes
powershell -NoProfile -Command ^
    "$d='%LEGACY_DIR%'; Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d,[System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force" 2>nul
timeout /t 3 /nobreak >nul

REM Remove legacy install directory (data in %APPDATA%\scry_2 is preserved)
rmdir /s /q "%LEGACY_DIR%" 2>nul
exit /b 0
