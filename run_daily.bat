@echo off
REM ============================================================
REM run_daily.bat
REM Regenerates team_dashboards.html from the previous day's
REM D1 women's basketball games, saves a dated copy to Google Drive,
REM and automatically pushes index.html to GitHub Pages.
REM Schedule this with Windows Task Scheduler to run every morning.
REM
REM Requires build_dashboards.R AND dashboard_template.html to
REM both be present in this same folder.
REM ============================================================

setlocal EnableDelayedExpansion
cd /d "%~dp0"

set LOGFILE=%~dp0build_log_%date:~-4,4%%date:~-10,2%%date:~-7,2%.txt

echo Running WBB dashboard pipeline... > "%LOGFILE%"
echo Started: %date% %time% >> "%LOGFILE%"

Rscript build_dashboards.R >> "%LOGFILE%" 2>&1

if %ERRORLEVEL% NEQ 0 (
    echo Pipeline FAILED - see %LOGFILE% for details.
    type "%LOGFILE%"
    pause
    exit /b 1
)

echo Finished: %date% %time% >> "%LOGFILE%"
echo Done. Dashboard updated: team_dashboards.html

REM ---- Create index.html for GitHub Pages ----------------------------
copy /Y "team_dashboards.html" "index.html" >> "%LOGFILE%" 2>&1

REM ---- Push to GitHub Pages -----------------------------------------
echo Syncing to GitHub Pages... >> "%LOGFILE%"
git add . >> "%LOGFILE%" 2>&1
git commit -m "Automated daily update: %date% %time%" >> "%LOGFILE%" 2>&1
git push origin main >> "%LOGFILE%" 2>&1

if !ERRORLEVEL! NEQ 0 (
    echo WARNING: Push to GitHub failed - see %LOGFILE%.
) else (
    echo Successfully updated GitHub Pages repository.
)

REM ---- also save a dated copy to Google Drive --------------------------
REM MMDDYYYY (e.g. 09202026), built via PowerShell rather than parsing
REM %date% directly -- %date%'s format changes with Windows' regional
REM settings (day-first, year-first, etc.) and silently produces a wrong
REM filename on any machine not set to US English, whereas Get-Date with
REM an explicit format string is the same on every machine.
set DRIVE_DIR=G:\My Drive\WNCAA\2026
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "Get-Date -Format MMddyyyy"`) do set TODAY=%%i
set DRIVE_FILE=%DRIVE_DIR%\%TODAY%_WBBDashboard.html

if not exist "%DRIVE_DIR%" (
    echo Drive folder missing, creating %DRIVE_DIR% ... >> "%LOGFILE%"
    mkdir "%DRIVE_DIR%" 2>>"%LOGFILE%"
)

if exist "%DRIVE_DIR%" (
    copy /Y "index.html" "%DRIVE_FILE%" >> "%LOGFILE%" 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo WARNING: copy to Google Drive failed - see %LOGFILE%. Local file is still fine.
    ) else (
        echo Also saved to %DRIVE_FILE%
    )
) else (
    echo WARNING: could not reach %DRIVE_DIR% >> "%LOGFILE%"
    echo WARNING: could not reach %DRIVE_DIR% - is Google Drive for Desktop running and signed in, and mapped to G:? Skipped the Drive copy; local file is still fine.
)

REM Comment out the next line if you don't want it to auto-open every morning.
start "" "team_dashboards.html"

endlocal