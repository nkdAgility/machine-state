#Requires -Version 5.1
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

# ── 1. Verify winget is available ────────────────────────────────────────────
Write-Step "Checking winget"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then re-run." -ForegroundColor Red
    exit 1
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
pwsh -NoLogo -Command {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "    Installing powershell-yaml ..."
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Host "    powershell-yaml already installed — skipping." -ForegroundColor DarkGray
    }
}

# ── 6. Hand off to machine-state.ps1 under pwsh 7 ────────────────────────────
Write-Step "Handing off to machine-state.ps1 (apply)"
pwsh -NoLogo -File "$RepoPath\machine-state.ps1" apply
