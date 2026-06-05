#Requires -Version 7.0
# Shared engine for setup resolver scripts.
# Dot-source this file and define $settings, then call Invoke-SetupStage.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-EnabledSettings {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][array]$Catalog
    )

    # If no merged state yet, return the full catalog
    if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
        return $Catalog
    }

    $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
    $setupNode   = $mergedState.PSObject.Properties['setup']
    if (-not $setupNode) { return $Catalog }

    $topicNode = $setupNode.Value.PSObject.Properties[$Topic.ToLowerInvariant()]
    if (-not $topicNode) { return $Catalog }

    $enabledIds = @($topicNode.Value | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($enabledIds.Count -eq 0) { return $Catalog }

    return @($Catalog | Where-Object {
        $id = if ($_ -is [System.Collections.IDictionary]) { $_['Id'] ?? $_['id'] } else { $_.PSObject.Properties['Id']?.Value ?? $_.PSObject.Properties['id']?.Value }
        $enabledIds -contains $id
    })
}

function Invoke-SetupStage {
    param(
        [Parameter(Mandatory)][ValidateSet("Export","Build","Execute")][string]$Stage,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][array]$Catalog
    )

    $Settings = @(Get-EnabledSettings -Context $Context -Topic $Topic -Catalog $Catalog)

    $exportPath = Join-Path $Context.ExportPath "$Topic.setup.json"

    switch ($Stage) {

        "Export" {
            New-DirectoryIfMissing -Path $Context.ExportPath

            $state = @()
            foreach ($setting in $Settings) {
                Write-Host "  Checking: $($setting.Name)..."
                try   { $configured = [bool](& $setting.Check) }
                catch { $configured = $false }
                $state += [ordered]@{ name = $setting.Name; configured = $configured }
            }

            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $exportPath -Encoding UTF8

            $needed = @($state | Where-Object { -not $_.configured }).Count
            if ($needed -eq 0) {
                Write-Host "$Topic setup: all $($Settings.Count) setting(s) already configured"
            }
            else {
                Write-Host "$Topic setup: $needed/$($Settings.Count) setting(s) need applying"
            }
        }

        "Build" {
            # Nothing to build — settings are self-contained in each script
        }

        "Execute" {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

            # Load Add-ManualAction if not already available (dot-sourced via Resolver-Common)
            $addManualFn = Get-Command Add-ManualAction -ErrorAction SilentlyContinue

            $applied = @()
            $skipped = @()
            $failed  = @()
            $total   = $Settings.Count
            $current = 0

            Write-Host ""
            Write-Host "==> $Topic setup ($total setting(s))"
            Write-Host ""

            foreach ($setting in $Settings) {
                $current++
                $tag = "[$current/$total]"

                try   { $configured = [bool](& $setting.Check) }
                catch { $configured = $false }

                if ($configured) {
                    Write-Host "$tag OK       $($setting.Name)"
                    continue
                }

                if ($setting.RequiresAdmin -and -not $isAdmin) {
                    Write-Warning "$tag SKIPPED  $($setting.Name) (requires admin)"
                    $skipped += $setting.Name
                    if ($addManualFn) {
                        Add-ManualAction -Context $Context -Category "$Topic-setup" -Description "$($setting.Name)" -Command "Re-run machine-state.ps1 as administrator" -Reason "requires elevation"
                    }
                    continue
                }

                Write-Host "$tag Applying  $($setting.Name)..."

                try {
                    & $setting.Apply
                    Write-Host "$tag Done"
                    $applied += $setting.Name
                    # Fire optional OnApplied callback (e.g. to register reboot-required actions)
                    if ($setting.OnApplied -and $addManualFn) {
                        & $setting.OnApplied
                    }
                }
                catch {
                    Write-Warning "$tag FAILED   $($setting.Name): $_"
                    $failed += $setting.Name
                }
            }

            $alreadyOk = $total - $applied.Count - $skipped.Count - $failed.Count
            Write-Host ""
            Write-Host "==> $Topic setup: $($applied.Count) applied, $alreadyOk already OK$(if ($skipped.Count -gt 0) { ", $($skipped.Count) skipped (need admin)" })$(if ($failed.Count -gt 0) { ", $($failed.Count) failed" })"
        }
    }
}
