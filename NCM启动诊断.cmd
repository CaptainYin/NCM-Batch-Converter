@echo off
setlocal
title NCM Batch Converter - Diagnostics
echo ============================================================
echo NCM Batch Converter diagnostics
echo ============================================================
echo.
echo OS:
ver
echo.
echo PowerShell:
where powershell.exe
powershell.exe -NoLogo -NoProfile -Command "$PSVersionTable | Out-String"
echo.
echo Folder:
echo %~dp0
echo.
echo Files:
dir /b "%~dp0"
echo.
echo Running PowerShell parser check...
set "PSFILE=%~dp0NCM_Batch_Converter.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:PSFILE; if(!(Test-Path -LiteralPath $p)){Write-Host 'MISSING PS1'; exit 11}; $tokens=$null; $errs=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errs); if($errs.Count){$errs | Format-List *; exit 12}else{Write-Host 'Parser check: OK'}"
echo.
echo Exit code: %ERRORLEVEL%
echo.
pause
