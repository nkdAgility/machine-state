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

Write-Host "  [obs] Capture: saving current OBS scene collections to repo..."

if (-not (Test-Path $OBSScenesPath)) {
    Write-Warning "  [obs] OBS scenes folder not found at '$OBSScenesPath' - skipping."
    return
}

New-DirectoryIfMissing -Path $StateScenePath

$scenes = Get-ChildItem -Path $OBSScenesPath -Filter "*.json"
foreach ($scene in $scenes) {
    $dest = Join-Path $StateScenePath $scene.Name
    if ($PSCmdlet.ShouldProcess($dest, "Capture OBS scene collection")) {
        Copy-Item -Path $scene.FullName -Destination $dest -Force
        Write-Host "  [obs] Captured: $($scene.Name)"
    }
}

Write-Host "  [obs] Capture complete. Commit state/config/OBSProject.OBSStudio/scenes/ to save changes."
