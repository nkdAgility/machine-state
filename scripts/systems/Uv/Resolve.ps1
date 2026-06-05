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

        if ($WhatIfPreference) {
            $installedPkgs = @()
            if (Test-Path -LiteralPath (Join-Path $Context.ExportPath "uv.tools.export.json")) {
                $exportDoc = Get-Content -LiteralPath (Join-Path $Context.ExportPath "uv.tools.export.json") -Raw | ConvertFrom-Json
                $installedPkgs = @($exportDoc.packages | ForEach-Object { $_.id })
            }

            $missingPkgs = @($desiredPkgs | Where-Object { $installedPkgs -notcontains $_ } | Sort-Object)

            if ($missingPkgs.Count -eq 0) {
                Write-Host "All uv tools are already installed"
            }
            else {
                Write-Host "Would install $($missingPkgs.Count) uv tool(s):"
                foreach ($pkg in $missingPkgs) { Write-Host "  - $pkg" }
            }
            return
        }

        $total   = $desiredPkgs.Count
        $current = 0
        $failed  = @()

        Write-Host ""
        Write-Host "==> $total uv tool(s) to install/upgrade"
        Write-Host ""

        foreach ($pkg in $desiredPkgs) {
            $current++
            $tag = "[$current/$total]"
            $pct = [int](($current - 1) / $total * 100)

            Write-Progress -Activity "uv" -Status "$tag Installing $pkg" -PercentComplete $pct
            Write-Host "$tag Installing $pkg"

            if ($PSCmdlet.ShouldProcess($pkg, "Install/upgrade uv tool")) {
                & uv tool install --upgrade --force $pkg
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$tag Failed to install uv tool '$pkg' (exit code $LASTEXITCODE)"
                    $failed += $pkg
                }
                else {
                    Write-Host "$tag Done"
                }
            }

            Write-Host ""
        }

        Write-Progress -Activity "uv" -Completed

        $succeeded = $total - $failed.Count
        Write-Host "==> Completed: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"

        if ($failed.Count -gt 0) {
            Write-Warning "uv: $($failed.Count) tool(s) failed to install: $($failed -join ', ')"
        }
    }
}
