@echo off
setlocal
title NCM Batch Converter Launcher

set "SCRIPT=%~dp0NCM_Batch_Converter.ps1"
set "ERRLOG=%TEMP%\NCM_Batch_Converter_error.log"

echo [NCM Batch Converter] Starting...
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: powershell.exe was not found.
    echo This tool requires Windows PowerShell.
    echo.
    pause
    exit /b 10
)

if not exist "%SCRIPT%" (
    echo ERROR: NCM_Batch_Converter.ps1 is missing.
    echo.
    echo Please EXTRACT THE WHOLE ZIP first, then run this CMD from the extracted folder.
    echo Do not double-click the CMD while it is still inside the ZIP preview.
    echo.
    pause
    exit /b 11
)

if exist "%ERRLOG%" del /q "%ERRLOG%" >nul 2>&1

powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo ------------------------------------------------------------
    echo The converter exited with error code %RC%.
    if exist "%ERRLOG%" (
        echo Error log:
        echo %ERRLOG%
        echo.
        type "%ERRLOG%"
    ) else (
        echo No crash log was created. This may be a PowerShell parse/startup error.
    )
    echo ------------------------------------------------------------
    echo.
    echo Please send a screenshot of this window, or send the error log above.
    pause
)

endlocal & exit /b %RC%
