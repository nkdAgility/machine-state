@echo off
setlocal

:: Bootstrap wrapper for machine-state.ps1
:: Ensures PowerShell 7+ and winget are available before running

:: Check for winget
where winget >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: winget is required but not found.
    echo Install App Installer from the Microsoft Store or update Windows.
    exit /b 1
)

:: Check for PowerShell 7+
where pwsh >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 7+ not found. Installing...
    winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
    if %errorlevel% neq 0 (
        echo ERROR: Failed to install PowerShell 7.
        exit /b 1
    )
    echo PowerShell 7 installed. You may need to restart your terminal.
)

:: Check for powershell-yaml module
pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable -Name powershell-yaml)) { Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber }"

:: Run machine-state.ps1 with all arguments
pwsh -NoProfile -File "%~dp0machine-state.ps1" %*
