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
        Install-ToolIfMissing -Command npm -WingetId OpenJS.NodeJS.LTS -DisplayName "Node.js"
        New-DirectoryIfMissing -Path $Context.ExportPath

        $raw = & npm list -g --depth=0 --json 2>$null
        # npm exits non-zero when the global prefix directory doesn't exist yet; treat as empty
        if ($LASTEXITCODE -ne 0) {
            $raw = '{"dependencies":{}}'
        }

        $parsed = $raw | ConvertFrom-Json
        $deps = @()
        if ($parsed.dependencies) {
            foreach ($prop in $parsed.dependencies.PSObject.Properties) {
                $deps += [ordered]@{
                    id      = [string]$prop.Name
                    version = [string]$prop.Value.version
                }
            }
        }

        $exportModel = [ordered]@{ packages = @($deps | Sort-Object id) }

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.ExportPath "node.npm.export.json"), "Export npm global packages")) {
            $exportModel | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Context.ExportPath "node.npm.export.json") -Encoding UTF8
        }
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state file not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
        $npmPackages = @(Get-SectionPackages -StateObject $mergedState -SectionName "node" -SourceName "npm")

        $names = @()
        foreach ($pkg in $npmPackages) {
            $id = Get-ObjectValue -Object $pkg -Name "id"
            if ($id) {
                $names += [string]$id
            }
        }
        $names = @($names | Sort-Object -Unique)

        $importModel = [ordered]@{
            packageManager = "npm"
            installScope   = "global"
            packages       = @($names)
        }

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.BuildPath "node.npm.import.json"), "Write npm import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Context.BuildPath "node.npm.import.json") -Encoding UTF8
        }

        # Detect outdated npm packages (filtered to desired packages) - skip if npm not available yet
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Host "Checking for npm updates..."
            $upgradesPath = Join-Path $Context.BuildPath "node.upgrades.json"
            $outdatedRaw = & npm outdated -g --json 2>$null
            $upgrades = @()

            if ($outdatedRaw) {
                try {
                    $outdatedParsed = $outdatedRaw | ConvertFrom-Json
                    foreach ($prop in $outdatedParsed.PSObject.Properties) {
                        $pkgId = [string]$prop.Name
                        if ($names -contains $pkgId) {
                            $upgrades += [ordered]@{
                                id        = $pkgId
                                installed = [string]$prop.Value.current
                                available = [string]$prop.Value.latest
                            }
                        }
                    }
                }
                catch {
                    # npm outdated returns non-JSON when no outdated packages
                }
            }

            if ($upgrades.Count -gt 0) {
                if ($PSCmdlet.ShouldProcess($upgradesPath, "Write npm upgrades manifest")) {
                    $upgrades | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $upgradesPath -Encoding UTF8
                }
                Write-Host "$($upgrades.Count) npm package(s) have upgrades available"
            }
            elseif (Test-Path -LiteralPath $upgradesPath) {
                if ($PSCmdlet.ShouldProcess($upgradesPath, "Remove stale npm upgrades manifest")) {
                    Remove-Item -LiteralPath $upgradesPath -Force
                }
            }
        }
        else {
            Write-Host "npm not available - skipping upgrade check"
        }
    }

    "Execute" {
        Install-ToolIfMissing -Command npm -WingetId OpenJS.NodeJS.LTS -DisplayName "Node.js"

        if (-not (Test-Path -LiteralPath (Join-Path $Context.BuildPath "node.npm.import.json"))) {
            throw "npm import manifest was not found at '$((Join-Path $Context.BuildPath "node.npm.import.json"))'. Run build first."
        }

        $manifest = Get-Content -LiteralPath (Join-Path $Context.BuildPath "node.npm.import.json") -Raw | ConvertFrom-Json
        $desiredPkgs = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            return
        }

        if ($WhatIfPreference) {
            $installedPkgs = @()
            if (Test-Path -LiteralPath (Join-Path $Context.ExportPath "node.npm.export.json")) {
                $exportDoc = Get-Content -LiteralPath (Join-Path $Context.ExportPath "node.npm.export.json") -Raw | ConvertFrom-Json
                $installedPkgs = @($exportDoc.packages | ForEach-Object { $_.id })
            }

            $missingPkgs = @($desiredPkgs | Where-Object { $installedPkgs -notcontains $_ } | Sort-Object)

            $upgradesPath = Join-Path $Context.BuildPath "node.upgrades.json"
            $upgradeablePkgs = @()
            if (Test-Path -LiteralPath $upgradesPath) {
                $upgradeablePkgs = @(Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json)
            }

            $hasWork = $missingPkgs.Count -gt 0 -or $upgradeablePkgs.Count -gt 0

            if (-not $hasWork) {
                Write-Host "All npm packages are installed and up to date"
            }
            else {
                if ($missingPkgs.Count -gt 0) {
                    Write-Host "Would install $($missingPkgs.Count) npm package(s):"
                    foreach ($pkg in $missingPkgs) { Write-Host "  - $pkg" }
                }
                if ($upgradeablePkgs.Count -gt 0) {
                    Write-Host "Would upgrade $($upgradeablePkgs.Count) npm package(s):"
                    foreach ($pkg in $upgradeablePkgs | Sort-Object { $_.id }) {
                        Write-Host "  - $($pkg.id): $($pkg.installed) -> $($pkg.available)"
                    }
                }
            }
            return
        }

        $total   = $desiredPkgs.Count
        $current = 0
        $failed  = @()

        Write-Host ""
        Write-Host "==> $total npm global package(s) to install/upgrade"
        Write-Host ""

        foreach ($pkg in $desiredPkgs) {
            $current++
            $tag = "[$current/$total]"
            $pct = [int](($current - 1) / $total * 100)

            Write-Progress -Activity "npm" -Status "$tag Installing $pkg" -PercentComplete $pct
            Write-Host "$tag Installing $pkg"

            if ($PSCmdlet.ShouldProcess($pkg, "npm install -g")) {
                & npm install -g $pkg
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$tag Failed to install npm package '$pkg' (exit code $LASTEXITCODE)"
                    $failed += $pkg
                }
                else {
                    Invoke-RefreshPath
                    Write-Host "$tag Done"
                }
            }

            Write-Host ""
        }

        Write-Progress -Activity "npm" -Completed

        $succeeded = $total - $failed.Count
        Write-Host "==> Completed: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"

        if ($failed.Count -gt 0) {
            Write-Warning "npm: $($failed.Count) package(s) failed to install: $($failed -join ', ')"
        }
    }
}
