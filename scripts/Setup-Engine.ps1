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

function Invoke-SetupStage {
    param(
        [Parameter(Mandatory)][ValidateSet("Export","Build","Execute")][string]$Stage,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][array]$Settings
    )

    $exportPath = Join-Path $Context.ExportPath "$Topic.setup.json"

    switch ($Stage) {

        "Export" {
            New-DirectoryIfMissing -Path $Context.ExportPath

            $state = @()
            foreach ($setting in $Settings) {
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
                    continue
                }

                Write-Host "$tag Applying  $($setting.Name)..."

                try {
                    & $setting.Apply
                    Write-Host "$tag Done"
                    $applied += $setting.Name
                }
                catch {
                    Write-Warning "$tag FAILED   $($setting.Name): $_"
                    $failed += $setting.Name
                }
            }

            $alreadyOk = $total - $applied.Count - $skipped.Count - $failed.Count
            Write-Host ""
            Write-Host "==> $Topic setup: $($applied.Count) applied, $alreadyOk already OK$(if ($skipped.Count -gt 0) { ", $($skipped.Count) skipped (need admin)" })$(if ($failed.Count -gt 0) { ", $($failed.Count) failed" })"

            if ($skipped.Count -gt 0) {
                Write-Host ""
                Write-Warning "Re-run as administrator to apply:"
                foreach ($s in $skipped) { Write-Host "  - $s" }
            }

            $rebootNeeded = @($applied | Where-Object { $_ -match "WSL|Hyper-V|Virtual Machine" })
            if ($rebootNeeded.Count -gt 0) {
                Write-Host ""
                Write-Warning "Reboot required to complete: $($rebootNeeded -join ', ')"
            }
        }
    }
}
