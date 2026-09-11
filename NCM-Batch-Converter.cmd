@echo off
setlocal
set "SCRIPT=%~dp0NCM_Batch_Converter.ps1"
set "ERRLOG=%TEMP%\NCM_Batch_Converter_error.log"

if not exist "%SCRIPT%" (
    echo ERROR: NCM_Batch_Converter.ps1 is missing.
    echo Please download/extract the whole repository first.
    echo.
    pause
    exit /b 11
)

if exist "%ERRLOG%" del /q "%ERRLOG%" >nul 2>&1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Converter failed with error code %RC%.
    if exist "%ERRLOG%" (
        echo Error log: %ERRLOG%
        echo.
        type "%ERRLOG%"
    )
    echo.
    pause
)

endlocal & exit /b %RC%
