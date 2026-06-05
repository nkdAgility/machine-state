#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Export", "Build", "Execute")]
    [string]$Stage,

    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$OBSScenesPath = Join-Path $env:APPDATA "obs-studio\basic\scenes"
$StateScenePath = Join-Path $Context.RepositoryRoot "state\config\OBSProject.OBSStudio\scenes"

switch ($Stage) {

    "Export" {
        Write-Host "  [obs] Export: capturing current OBS scene collections..."

        if (-not (Test-Path $OBSScenesPath)) {
            Write-Warning "  [obs] OBS scenes folder not found at '$OBSScenesPath' - skipping export."
            return
        }

        New-DirectoryIfMissing -Path $StateScenePath

        $scenes = Get-ChildItem -Path $OBSScenesPath -Filter "*.json"
        foreach ($scene in $scenes) {
            $dest = Join-Path $StateScenePath $scene.Name
            if ($PSCmdlet.ShouldProcess($dest, "Export OBS scene collection")) {
                Copy-Item -Path $scene.FullName -Destination $dest -Force
                Write-Host "  [obs] Exported: $($scene.Name)"
            }
        }

        Write-Host "  [obs] Export complete. Commit state/config/OBSProject.OBSStudio/scenes/ to save changes."
    }

    "Build" {
        Write-Host "  [obs] Build: no build step required."
    }

    "Execute" {
        Write-Host "  [obs] Execute: restoring OBS scene collections..."

        if (-not (Test-Path $StateScenePath)) {
            throw "OBS scenes not found at '$StateScenePath'. Run export first to generate them."
        }

        New-DirectoryIfMissing -Path $OBSScenesPath

        $scenes = Get-ChildItem -Path $StateScenePath -Filter "*.json"
        if (-not $scenes) {
            Write-Warning "  [obs] No scene collection JSON files found in state - nothing to restore."
            return
        }

        foreach ($scene in $scenes) {
            $dest = Join-Path $OBSScenesPath $scene.Name
            if ($PSCmdlet.ShouldProcess($dest, "Restore OBS scene collection")) {
                Copy-Item -Path $scene.FullName -Destination $dest -Force
                Write-Host "  [obs] Restored: $($scene.Name)"
            }
        }

        Write-Host "  [obs] Scene restore complete. Restart OBS to apply."
    }
}
