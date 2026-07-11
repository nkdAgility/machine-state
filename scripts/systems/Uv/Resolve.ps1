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

switch ($Stage) {
    "Export" {
        Install-ToolIfMissing -Command uv -WingetId astral-sh.uv -DisplayName "uv"
        New-DirectoryIfMissing -Path $Context.ExportPath

        $exportModel = [ordered]@{
            packageManager = "uv"
            packages       = @()
        }

        $rawJsonOutput = (& uv tool list --json 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $rawJsonOutput) {
            try {
                $parsed = $rawJsonOutput | ConvertFrom-Json
                foreach ($pkg in @($parsed)) {
                    $name = Get-ObjectValue -Object $pkg -Name "name"
                    $version = Get-ObjectValue -Object $pkg -Name "version"
                    if ($name) {
                        $exportModel.packages += [ordered]@{
                            id      = [string]$name
                            version = [string]$version
                        }
                    }
                }
            }
            catch {
                # Fall through to plain-text parser below.
            }
        }

        if ($exportModel.packages.Count -eq 0) {
            $rawText = (& uv tool list 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                throw "uv tool export failed. Command output: $rawText"
            }

            if ($rawText) {
                $lines = @($rawText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s*-' })
                foreach ($line in $lines) {
                    $token = ($line -split '\s+')[0]
                    if ($token -and $token -notmatch '^(tool|name)$') {
                        $exportModel.packages += [ordered]@{ id = [string]$token }
                    }
                }
            }
        }

        $exportModel.packages = @($exportModel.packages | Sort-Object id -Unique)

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.ExportPath "uv.tools.export.json"), "Export uv tools")) {
            $exportModel | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Context.ExportPath "uv.tools.export.json") -Encoding UTF8
        }

        Write-Host "$($exportModel.packages.Count) uv tool(s) installed"
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state file not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
        $uvPackages = @(Get-SectionPackages -StateObject $mergedState -SectionName "uv" -SourceName "uv")

        $names = @()
        foreach ($pkg in $uvPackages) {
            $id = Get-ObjectValue -Object $pkg -Name "id"
            if ($id) {
                $names += [string]$id
            }
        }
        $names = @($names | Sort-Object -Unique)

        $importModel = [ordered]@{
            packageManager = "uv"
            installScope   = "tool"
            packages       = @($names)
        }

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.BuildPath "uv.tools.import.json"), "Write uv tool import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Context.BuildPath "uv.tools.import.json") -Encoding UTF8
        }

        # Detect upgrades: compare installed versions against PyPI latest
        $upgradesPath = Join-Path $Context.BuildPath "uv.upgrades.json"
        $upgrades = @()

        $installedTools = @()
        $rawJson = & uv tool list --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $rawJson) {
            try { $installedTools = @($rawJson | ConvertFrom-Json) } catch { }
        }

        foreach ($name in $names) {
            $installed = $installedTools | Where-Object { $_.name -eq $name }
            if (-not $installed) { continue }
            try {
                $pypiData = Invoke-RestMethod -Uri "https://pypi.org/pypi/$name/json" -ErrorAction Stop
                $latest = $pypiData.info.version
                if ($latest -and $latest -ne $installed.version) {
                    $upgrades += [ordered]@{ id = $name; installed = $installed.version; available = $latest }
                }
            } catch { }
        }

        if ($upgrades.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($upgradesPath, "Write uv upgrades manifest")) {
                $upgrades | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $upgradesPath -Encoding UTF8
            }
            Write-Host "$($upgrades.Count) uv tool(s) have upgrades available"
        } elseif (Test-Path -LiteralPath $upgradesPath) {
            if ($PSCmdlet.ShouldProcess($upgradesPath, "Remove stale uv upgrades manifest")) {
                Remove-Item -LiteralPath $upgradesPath -Force
            }
        }
    }

    "Execute" {
        Install-ToolIfMissing -Command uv -WingetId astral-sh.uv -DisplayName "uv"

        if (-not (Test-Path -LiteralPath (Join-Path $Context.BuildPath "uv.tools.import.json"))) {
            throw "uv import manifest was not found at '$((Join-Path $Context.BuildPath "uv.tools.import.json"))'. Run build first."
        }

        $manifest = Get-Content -LiteralPath (Join-Path $Context.BuildPath "uv.tools.import.json") -Raw | ConvertFrom-Json
        $desiredPkgs = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            return
        }

        # Live check: query what's installed and what has upgrades
        Write-Host "Querying installed uv tools..."
        $installedIds = @()
        $rawJson = & uv tool list --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $rawJson) {
            try {
                $installedIds = @(($rawJson | ConvertFrom-Json) | ForEach-Object { [string]$_.name } | Where-Object { $_ })
            } catch {
                $rawText = & uv tool list 2>$null
                $installedIds = @($rawText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s*-' } | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -and $_ -notmatch '^(tool|name)$' })
            }
        }

        $upgradesPath = Join-Path $Context.BuildPath "uv.upgrades.json"
        $upgradeableIds = @()
        if (Test-Path -LiteralPath $upgradesPath) {
            $upgradeableIds = @((Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json) | ForEach-Object { $_.id })
        }

        $toInstall = @($desiredPkgs | Where-Object { $installedIds -notcontains $_ })
        $toUpgrade = @($upgradeableIds)

        if ($WhatIfPreference) {
            if ($toInstall.Count -eq 0 -and $toUpgrade.Count -eq 0) {
                Write-Host "All uv tools are installed and up to date"
            } else {
                if ($toInstall.Count -gt 0) {
                    Write-Host "Would install $($toInstall.Count) uv tool(s):"
                    foreach ($pkg in $toInstall) { Write-Host "  - $pkg" }
                }
                if ($toUpgrade.Count -gt 0) {
                    Write-Host "Would upgrade $($toUpgrade.Count) uv tool(s):"
                    foreach ($pkg in $toUpgrade) { Write-Host "  - $pkg" }
                }
            }
            return
        }

        $workList = @(
            @($toInstall  | ForEach-Object { [ordered]@{ action = "install"; id = $_ } }) +
            @($toUpgrade  | ForEach-Object { [ordered]@{ action = "upgrade"; id = $_ } })
        )

        $total   = $workList.Count
        $current = 0
        $failed  = @()

        if ($total -eq 0) {
            Write-Host "All uv tools are installed and up to date"
        } else {

        Write-Host ""
        Write-Host "==> $total uv tool operation(s) to perform"
        Write-Host ""

        foreach ($item in $workList) {
            $current++
            $tag = "[$current/$total]"
            $pct = [int](($current - 1) / $total * 100)
            $label = "$tag $($item.action.Substring(0,1).ToUpper() + $item.action.Substring(1))ing $($item.id)"

            Write-Progress -Activity "uv" -Status $label -PercentComplete $pct
            Write-Host $label

            if ($PSCmdlet.ShouldProcess($item.id, "uv tool $($item.action)")) {
                if ($item.action -eq "install") {
                    & uv tool install $item.id
                } else {
                    & uv tool upgrade $item.id
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$tag Failed to $($item.action) uv tool '$($item.id)' (exit code $LASTEXITCODE)"
                    $failed += $item.id
                } else {
                    Invoke-RefreshPath
                    Write-Host "$tag Done"
                }
            }

            Write-Host ""
        }

        Write-Progress -Activity "uv" -Completed

        $succeeded = $total - $failed.Count
        Write-Host "==> Completed: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"

        if ($failed.Count -gt 0) {
            Write-Warning "uv: $($failed.Count) tool(s) failed: $($failed -join ', ')"
        }

        } # end else ($total -gt 0)
    }
}
