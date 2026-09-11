param(
    [string]$Source = (Join-Path $PSScriptRoot 'NCM_Batch_Converter.ps1'),
    [string]$Output = (Join-Path $PSScriptRoot 'NCM一键批量转换_单文件版.cmd')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Source script not found: $Source"
}

$marker = '###BEGIN_NCM_BATCH_CONVERTER_POWERSHELL_PAYLOAD###'
$payload = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)

$header = @"
@echo off
setlocal
title NCM Batch Converter
set "SELF=%~f0"
set "TMPPS=%TEMP%\NCM_Batch_Converter_%RANDOM%_%RANDOM%.ps1"
set "ERRLOG=%TEMP%\NCM_Batch_Converter_error.log"

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo ERROR: powershell.exe was not found.
  pause
  exit /b 10
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "`$p=`$env:SELF;`$s=[IO.File]::ReadAllText(`$p,[Text.Encoding]::UTF8);`$m='$marker';`$i=`$s.LastIndexOf(`$m);if(`$i -lt 0){exit 3};`$x=`$s.Substring(`$i+`$m.Length).TrimStart([char]13,[char]10);[IO.File]::WriteAllText(`$env:TMPPS,`$x,(New-Object Text.UTF8Encoding(`$true)))"
if errorlevel 1 (
  echo ERROR: could not extract the embedded converter script.
  pause
  exit /b 13
)

powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%TMPPS%" %*
set "RC=%ERRORLEVEL%"
del /q "%TMPPS%" >nul 2>&1

if not "%RC%"=="0" (
  echo.
  echo Converter failed with error code %RC%.
  if exist "%ERRLOG%" (
    echo Error log: %ERRLOG%
    echo.
    type "%ERRLOG%"
  ) else (
    echo No error log was created.
  )
  echo.
  pause
)
endlocal & exit /b %RC%
exit /b
$marker
"@

$content = $header + $payload
[System.IO.File]::WriteAllText($Output, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Built: $Output"
