#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$configSource = Join-Path $env:USERPROFILE ".config\ohmyposh\nkdagility.omp.json"
$configDest   = Join-Path $Context.RepositoryRoot "state\config\JanDeDobbeleer.OhMyPosh\ohmyposh.nkdagility.json"

Write-Host "  [ohmyposh] Capture: saving current Oh My Posh config to repo..."

if (-not (Test-Path -LiteralPath $configSource)) {
    Write-Warning "  [ohmyposh] Config not found at '$configSource' - skipping."
    return
}

New-DirectoryIfMissing -Path (Split-Path -Parent $configDest)

if ($PSCmdlet.ShouldProcess($configDest, "Capture Oh My Posh config")) {
    Copy-Item -LiteralPath $configSource -Destination $configDest -Force
    Write-Host "  [ohmyposh] Config saved: '$configDest'"
}
