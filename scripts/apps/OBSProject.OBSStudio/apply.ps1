#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$OBSScenesPath  = Join-Path $env:APPDATA "obs-studio\basic\scenes"
$StateScenePath = Join-Path $Context.RepositoryRoot "state\config\OBSProject.OBSStudio\scenes"

Write-Host "  [obs] Apply: restoring OBS scene collections..."

if (-not (Test-Path $StateScenePath)) {
    Write-Host "  [obs] No scenes found at '$StateScenePath' - run capture first."
    return
}

$scenes = Get-ChildItem -Path $StateScenePath -Filter "*.json" -ErrorAction SilentlyContinue
if (-not $scenes) {
    Write-Warning "  [obs] No scene collection JSON files found in state - nothing to restore."
    return
}

New-DirectoryIfMissing -Path $OBSScenesPath

foreach ($scene in $scenes) {
    $dest = Join-Path $OBSScenesPath $scene.Name
    if ($PSCmdlet.ShouldProcess($dest, "Restore OBS scene collection")) {
        Copy-Item -Path $scene.FullName -Destination $dest -Force
        Write-Host "  [obs] Restored: $($scene.Name)"
    }
}

Write-Host "  [obs] Scene restore complete. Restart OBS to apply."
