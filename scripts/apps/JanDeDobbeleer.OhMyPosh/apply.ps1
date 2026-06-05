#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

if (-not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    Write-Warning "oh-my-posh not found on PATH - skipping configuration"
    return
}

$configSource = Join-Path $Context.RepositoryRoot "state\config\JanDeDobbeleer.OhMyPosh\ohmyposh.nkdagility.json"
$configDest   = Join-Path $env:USERPROFILE ".config\ohmyposh\nkdagility.omp.json"
$profileInit  = "oh-my-posh init pwsh --config `"$configDest`" | Invoke-Expression"

$catalog = @(

    @{
        Id            = "ohmyposh-config-file"
        Name          = "Oh My Posh config file (~/.config/ohmyposh/nkdagility.omp.json)"
        RequiresAdmin = $false
        Check         = {
            Test-Path -LiteralPath $configDest
        }.GetNewClosure()
        Apply         = {
            $dir = Split-Path -Parent $configDest
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Copy-Item -LiteralPath $configSource -Destination $configDest -Force
        }.GetNewClosure()
    }

    @{
        Id            = "ohmyposh-font-meslo"
        Name          = "Oh My Posh Meslo Nerd Font"
        RequiresAdmin = $true
        Check         = {
            $fonts = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" -ErrorAction SilentlyContinue
            $fonts.PSObject.Properties.Name | Where-Object { $_ -like "MesloLGM Nerd Font*" } | Select-Object -First 1
        }
        Apply         = {
            & oh-my-posh font install meslo
        }
    }

    @{
        Id            = "ohmyposh-profile"
        Name          = "Oh My Posh init in PowerShell profile"
        RequiresAdmin = $false
        Check         = {
            if (-not (Test-Path -LiteralPath $PROFILE)) { return $false }
            (Get-Content -LiteralPath $PROFILE -Raw) -match "oh-my-posh init pwsh"
        }.GetNewClosure()
        Apply         = {
            if (-not (Test-Path -LiteralPath $PROFILE)) {
                New-Item -ItemType File -Path $PROFILE -Force | Out-Null
            }
            Add-Content -LiteralPath $PROFILE -Value "`n$profileInit" -Encoding UTF8
        }.GetNewClosure()
    }

)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "ohmyposh" -Catalog $catalog
