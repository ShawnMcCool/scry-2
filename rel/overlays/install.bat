@echo off
setlocal enabledelayedexpansion

echo Installing Scry2...

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set SCRIPT_DIR=%~dp0

REM Guard: prevent running install.bat from inside the install directory
set SCRIPT_DIR_NORM=%SCRIPT_DIR:~0,-1%
if /i "%SCRIPT_DIR_NORM%"=="%INSTALL_DIR%" (
    echo ERROR: Cannot install from the install directory itself.
    echo Please run install.bat from the downloaded release folder.
    if not "%SCRY2_QUIET%"=="1" pause
    exit /b 1
)

REM Stop existing Scry2 processes
call :kill_scry2_processes
call :wait_processes_dead
if errorlevel 1 exit /b 1

REM Remove previous install
call :remove_install_dir
if errorlevel 1 exit /b 1

REM Copy release to AppData\Local\scry_2
echo Copying files to %INSTALL_DIR%...
mkdir "%INSTALL_DIR%"
if errorlevel 1 (
    echo ERROR: Could not create directory %INSTALL_DIR%
    if not "%SCRY2_QUIET%"=="1" pause
    exit /b 1
)
xcopy /e /i /q /h "%SCRIPT_DIR%." "%INSTALL_DIR%" >nul
if errorlevel 1 (
    echo ERROR: Failed to copy release files to %INSTALL_DIR%
    if not "%SCRY2_QUIET%"=="1" pause
    exit /b 1
)

REM Verify the runtime is functional before proceeding (skip in quiet/CI mode
REM because eval starts the full OTP app which may hang without Player.log)
if not "%SCRY2_QUIET%"=="1" (
    echo Verifying runtime...
    cmd /c ""%INSTALL_DIR%\bin\scry_2.bat" eval "IO.puts(:ok)"" >nul 2>&1
    if errorlevel 1 (
        echo.
        echo ERROR: The Erlang runtime failed to start.
        echo This usually means the Visual C++ Redistributable is missing.
        echo Download it from: https://aka.ms/vs/17/release/vc_redist.x64.exe
        echo.
        pause
        exit /b 1
    )
)

REM Register autostart on login — point to tray, not backend
echo Registering autostart...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "Scry2" /t REG_SZ /d "\"%INSTALL_DIR%\scry2-tray.exe\"" /f
echo Registry returned errorlevel: %errorlevel%

REM Start the tray (it will launch the backend and open the browser)
echo Starting Scry2...
start "" /B "%INSTALL_DIR%\scry2-tray.exe"

echo.
echo Scry2 installed successfully!
echo It will start automatically on each login.
echo Open http://localhost:6015 in your browser to view your stats.
echo.
echo To uninstall later, run: %INSTALL_DIR%\uninstall.bat
echo.
echo NOTE: Windows may ask you to allow "epmd" and "erlang" through the
echo firewall. These are part of the bundled runtime — allow both for
echo Scry2 to function.
echo.
if not "%SCRY2_QUIET%"=="1" pause
exit /b 0

REM === Subroutines ===

:kill_scry2_processes
echo Stopping Scry2...
REM Phase 1: Kill tray first to stop watchdog from respawning backend
powershell -NoProfile -Command ^
    "$d='%INSTALL_DIR%'; Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d,[System.StringComparison]::OrdinalIgnoreCase) -and $_.Name -eq 'scry2-tray' } | Stop-Process -Force" 2>nul
powershell -NoProfile -Command "Start-Sleep -Seconds 1" >nul 2>&1
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
    if not "%SCRY2_QUIET%"=="1" pause
    exit /b 1
)
powershell -NoProfile -Command "Start-Sleep -Seconds 1" >nul 2>&1
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
    if not "%SCRY2_QUIET%"=="1" pause
    exit /b 1
)
echo Waiting for file locks to release...
powershell -NoProfile -Command "Start-Sleep -Seconds 2" >nul 2>&1
goto :remove_retry
