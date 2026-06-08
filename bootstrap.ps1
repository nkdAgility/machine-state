#Requires -Version 5.1
$BootstrapVersion = "1.2.0"
<#
.SYNOPSIS
    Bootstrap a fresh Windows machine: install PowerShell 7, Git, clone machine-state, then apply.

.DESCRIPTION
    Designed to run under Windows PowerShell 5.1 (always present on Windows 10/11).
    Safe to re-run — each step checks before acting.

.EXAMPLE
    # One-liner from an elevated PowerShell prompt:
    irm https://raw.githubusercontent.com/nkdAgility/machine-state/main/bootstrap.ps1 | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "machine-state bootstrap v$BootstrapVersion" -ForegroundColor Green

$RepoUrl   = "https://github.com/nkdAgility/machine-state.git"
$CloneRoot = "$env:USERPROFILE\source\repos"
$RepoPath  = "$CloneRoot\machine-state"

function Write-Step ([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Winget ([string]$Id, [string]$Name) {
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null |
                 Select-String $Id
    if ($installed) {
        Write-Host "    $Name already installed — skipping." -ForegroundColor DarkGray
        return $false
    }
    Write-Host "    Installing $Name ..."
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
    return $true
}

# ── 1. Ensure winget is available ────────────────────────────────────────────
Write-Step "Checking winget"

function Install-WingetOnServer {
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = $os.Caption

    if ($caption -notmatch "Server") {
        Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then re-run." -ForegroundColor Red
        exit 1
    }

    if ($caption -match "2025") {
        Write-Host "Windows Server 2025 detected — winget should be pre-installed but was not found on PATH." -ForegroundColor Red
        Write-Host "Try: Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ForegroundColor Yellow
        exit 1
    }

    # Windows Server 2019 / 2022 — install winget and its dependencies manually
    Write-Host "    Windows Server detected ($caption) — installing winget and dependencies..." -ForegroundColor Yellow

    $tempDir = Join-Path $env:TEMP "winget-bootstrap"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        Write-Host "    Installing VCLibs..."
        Add-AppxPackage "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -ErrorAction Stop

        Write-Host "    Downloading Microsoft.UI.Xaml..."
        $uiXamlZip = Join-Path $tempDir "microsoft.ui.xaml.2.8.6.zip"
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6" -OutFile $uiXamlZip -UseBasicParsing
        Expand-Archive -Path $uiXamlZip -DestinationPath (Join-Path $tempDir "Microsoft.UI.Xaml.2.8.6") -Force
        Add-AppxPackage (Join-Path $tempDir "Microsoft.UI.Xaml.2.8.6\tools\AppX\x64\Release\Microsoft.UI.Xaml.2.8.appx") -ErrorAction Stop

        Write-Host "    Downloading winget..."
        $wingetBundle = Join-Path $tempDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
        Invoke-WebRequest -Uri "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $wingetBundle -UseBasicParsing
        Add-AppxPackage $wingetBundle -ErrorAction Stop

        # Fix permissions and add to PATH for this session
        $wingetDirs = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe" -ErrorAction SilentlyContinue
        if ($wingetDirs) {
            $wingetDir = $wingetDirs[-1].Path
            & takeown /F $wingetDir /R /A /D Y 2>$null | Out-Null
            & icacls $wingetDir /grant "Administrators:F" /T 2>$null | Out-Null
            $env:PATH += ";$wingetDir"
        }
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget installed but still not found on PATH. Open a new terminal and re-run." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "    winget installed successfully." -ForegroundColor Green
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Install-WingetOnServer
}

# ── 2. Install PowerShell 7 ───────────────────────────────────────────────────
Write-Step "PowerShell 7"
$pwshInstalled = Invoke-Winget "Microsoft.PowerShell" "PowerShell 7"

# Refresh PATH so pwsh is findable in this session
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    # Fallback to known install location
    $pwshExe = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshExe) {
        $env:PATH += ";$env:ProgramFiles\PowerShell\7"
    } else {
        Write-Host "pwsh not found on PATH after install. Open a new terminal and re-run." -ForegroundColor Yellow
        exit 0
    }
}

# ── 3. Install Git ────────────────────────────────────────────────────────────
Write-Step "Git"
$gitInstalled = Invoke-Winget "Git.Git" "Git"

# Refresh PATH
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $gitExe = "$env:ProgramFiles\Git\cmd"
    if (Test-Path $gitExe) {
        $env:PATH += ";$gitExe"
    } else {
        Write-Host "git not found on PATH after install. Open a new terminal and re-run." -ForegroundColor Yellow
        exit 0
    }
}

# ── 4. Clone or update the repo ───────────────────────────────────────────────
Write-Step "machine-state repo"
if (-not (Test-Path $CloneRoot)) {
    New-Item -ItemType Directory -Path $CloneRoot -Force | Out-Null
}

if (Test-Path "$RepoPath\.git") {
    Write-Host "    Repo exists — pulling latest ..."
    git -C $RepoPath pull --ff-only
} else {
    Write-Host "    Cloning $RepoUrl ..."
    git clone $RepoUrl $RepoPath
}

# ── 5. Ensure powershell-yaml is available under pwsh 7 ─────────────────────
Write-Step "powershell-yaml module"
pwsh -NoLogo -Command "if (-not (Get-Module -ListAvailable -Name powershell-yaml)) { Write-Host '    Installing powershell-yaml ...'; Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber } else { Write-Host '    powershell-yaml already installed - skipping.' }"

# ── 6. Hand off to machine-state.ps1 under pwsh 7 ────────────────────────────
Write-Step "Handing off to machine-state.ps1 (apply)"
pwsh -NoLogo -File "$RepoPath\machine-state.ps1" apply
