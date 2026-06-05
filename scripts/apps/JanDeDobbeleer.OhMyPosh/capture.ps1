#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

if (-not (Get-Command oh-my-posh -ErrorAction SilentlyContinue)) {
    Write-Warning "  [ohmyposh] oh-my-posh not found on PATH - skipping capture."
    return
}

$configDest = Join-Path $Context.RepositoryRoot "state\config\JanDeDobbeleer.OhMyPosh\ohmyposh.nkdagility.json"

Write-Host "  [ohmyposh] Capture: exporting current Oh My Posh config to repo..."

New-DirectoryIfMissing -Path (Split-Path -Parent $configDest)

if ($PSCmdlet.ShouldProcess($configDest, "Export Oh My Posh config")) {
    & oh-my-posh config export --output $configDest
    if ($LASTEXITCODE -ne 0) {
        throw "  [ohmyposh] oh-my-posh config export failed (exit $LASTEXITCODE)"
    }
    Write-Host "  [ohmyposh] Config saved: '$configDest'"
}
