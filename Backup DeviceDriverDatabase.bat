@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem  Backup DeviceDriverDatabase
rem  1. Closes it_pos_app.exe if it is running
rem  2. Copies DeviceDriverDatabase.mdf + _Log.ldf to C:\My-Mx files
rem  3. Starts it_pos_app.exe again
rem  Schedule this file with Windows Task Scheduler at the hour you want.
rem ============================================================

set "APP_NAME=it_pos_app.exe"
rem Fallback path, only used if the running path can't be detected. Adjust if needed.
set "APP_PATH_FALLBACK="

set "SRC_DIR=C:\ProgramData\Fast and Fluid Management\DriversAndTools\IDD4"
set "DEST_DIR=C:\My-Mx files"
set "FILE_MDF=DeviceDriverDatabase.mdf"
set "FILE_LDF=DeviceDriverDatabase_Log.ldf"
set "LOG=%DEST_DIR%\backup_log.txt"

rem Seconds to wait for a normal close before forcing it
set "CLOSE_TIMEOUT=30"

if not exist "%DEST_DIR%" mkdir "%DEST_DIR%"
call :log "===== Backup started ====="

rem ---- 1. Is the app running? Remember its path so we can restart it ----
set "WAS_RUNNING=0"
set "APP_PATH="
tasklist /FI "IMAGENAME eq %APP_NAME%" 2>nul | find /I "%APP_NAME%" >nul
if %errorlevel%==0 (
    set "WAS_RUNNING=1"
    for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "(Get-Process -Name '%APP_NAME:.exe=%' -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1).Path"`) do set "APP_PATH=%%P"
)
if not defined APP_PATH set "APP_PATH=%APP_PATH_FALLBACK%"

if "%WAS_RUNNING%"=="0" (
    call :log "%APP_NAME% is not running."
    goto :copy
)
call :log "%APP_NAME% is running (!APP_PATH!). Closing it..."

rem ---- 2. Close it: first gracefully, then force if needed ----
taskkill /IM "%APP_NAME%" >nul 2>&1
set /a WAITED=0
:wait_close
tasklist /FI "IMAGENAME eq %APP_NAME%" 2>nul | find /I "%APP_NAME%" >nul
if errorlevel 1 goto :closed
if !WAITED! geq %CLOSE_TIMEOUT% (
    call :log "Did not close within %CLOSE_TIMEOUT%s, forcing..."
    taskkill /F /IM "%APP_NAME%" >nul 2>&1
    ping -n 4 127.0.0.1 >nul
    tasklist /FI "IMAGENAME eq %APP_NAME%" 2>nul | find /I "%APP_NAME%" >nul
    if not errorlevel 1 (
        call :log "ERROR: could not stop %APP_NAME%. Backup aborted."
        exit /b 1
    )
    goto :closed
)
ping -n 2 127.0.0.1 >nul
set /a WAITED+=1
goto :wait_close

:closed
call :log "%APP_NAME% is closed."
rem Give the database engine a few seconds to release the files
ping -n 6 127.0.0.1 >nul

rem ---- 3. Copy the database files (retries if a file is still locked) ----
:copy
robocopy "%SRC_DIR%" "%DEST_DIR%" "%FILE_MDF%" "%FILE_LDF%" /IS /IT /R:10 /W:5 /NP /NJH /NJS >> "%LOG%"
set "RC=%errorlevel%"
if %RC% geq 8 (
    call :log "ERROR: copy failed (robocopy code %RC%)."
    set "COPY_OK=0"
) else (
    call :log "Copy completed."
    set "COPY_OK=1"
)

rem ---- 4. Start the app again ----
if "%WAS_RUNNING%"=="1" (
    if defined APP_PATH (
        call :log "Starting %APP_NAME% again..."
        for %%I in ("%APP_PATH%") do set "APP_DIR=%%~dpI"
        start "" /D "!APP_DIR!" "%APP_PATH%"
    ) else (
        call :log "ERROR: path of %APP_NAME% unknown, set APP_PATH_FALLBACK in this script."
    )
)

call :log "===== Backup finished ====="
if "%COPY_OK%"=="1" (exit /b 0) else (exit /b 2)

:log
echo [%date% %time%] %~1
echo [%date% %time%] %~1>> "%LOG%"
exit /b 0
