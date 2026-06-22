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

# Foundry Local models. Declared per-machine under a `foundry.packages.foundry`
# section because the right model set differs by hardware (a 24GB-GPU desktop and
# a Snapdragon laptop want very different models). The data is merged by the engine
# like any other package source; this resolver downloads the desired models into
# the local Foundry cache. Models are pinned by alias — Foundry resolves the alias
# to the correct hardware variant (CUDA / NPU / CPU) at download time, so the same
# YAML alias is portable across machines.
#
# Catalog / cache shape: { "models": [ { "alias": "...", "cached": true, ... } ] }
#   foundry model list  -o json   → full catalog (everything downloadable)
#   foundry cache list  -o json   → only models already downloaded on this machine
#   foundry model download <alias>             → download one model (non-interactive)

function Get-CachedFoundryAliases {
    # Returns the aliases of models already present in the local Foundry cache.
    $raw = & foundry cache list -o json 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        return @()
    }
    $models = Get-ObjectValue -Object $parsed -Name "models"
    if (-not $models) { return @() }
    return @(
        @($models) | ForEach-Object {
            $alias = Get-ObjectValue -Object $_ -Name "alias"
            if ($alias) { [string]$alias }
        } | Where-Object { $_ }
    )
}

switch ($Stage) {
    "Export" {
        Install-ToolIfMissing -Command foundry -WingetId Microsoft.Foundry -DisplayName "Foundry Local"
        New-DirectoryIfMissing -Path $Context.ExportPath

        $exportModel = [ordered]@{
            packageManager = "foundry"
            models         = @(Get-CachedFoundryAliases | Sort-Object -Unique)
        }

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.ExportPath "foundry.models.export.json"), "Export Foundry models")) {
            $exportModel | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Context.ExportPath "foundry.models.export.json") -Encoding UTF8
        }
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state file not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
        $foundryModels = @(Get-SectionPackages -StateObject $mergedState -SectionName "foundry" -SourceName "foundry")

        $names = @()
        foreach ($model in $foundryModels) {
            $id = Get-ObjectValue -Object $model -Name "id"
            if ($id) {
                $names += [string]$id
            }
        }
        $names = @($names | Sort-Object -Unique)

        $importModel = [ordered]@{
            packageManager = "foundry"
            installScope   = "cache"
            models         = @($names)
        }

        if ($PSCmdlet.ShouldProcess((Join-Path $Context.BuildPath "foundry.models.import.json"), "Write Foundry import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Context.BuildPath "foundry.models.import.json") -Encoding UTF8
        }
    }

    "Execute" {
        $manifestPath = Join-Path $Context.BuildPath "foundry.models.import.json"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Foundry import manifest was not found at '$manifestPath'. Run build first."
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $desiredModels = @($manifest.models)

        if ($desiredModels.Count -eq 0) {
            return
        }

        Install-ToolIfMissing -Command foundry -WingetId Microsoft.Foundry -DisplayName "Foundry Local"

        # Live check: which desired models are not yet in the local cache.
        Write-Host "Querying cached Foundry models..."
        $cachedAliases = @(Get-CachedFoundryAliases)
        $toInstall = @($desiredModels | Where-Object { $cachedAliases -notcontains $_ })

        if ($WhatIfPreference) {
            if ($toInstall.Count -eq 0) {
                Write-Host "All Foundry models are already downloaded"
            } else {
                Write-Host "Would download $($toInstall.Count) Foundry model(s):"
                foreach ($model in $toInstall) { Write-Host "  - $model" }
            }
            return
        }

        if ($toInstall.Count -eq 0) {
            Write-Host "All Foundry models are already downloaded"
            return
        }

        $total   = $toInstall.Count
        $current = 0
        $failed  = @()

        Write-Host ""
        Write-Host "==> $total Foundry model(s) to download"
        Write-Host ""

        foreach ($model in $toInstall) {
            $current++
            $tag = "[$current/$total]"
            $pct = [int](($current - 1) / $total * 100)

            Write-Progress -Activity "foundry" -Status "$tag Downloading $model" -PercentComplete $pct
            Write-Host "$tag Downloading $model"

            if ($PSCmdlet.ShouldProcess($model, "foundry model download")) {
                # Run raw (no pipe) — foundry's download progress uses Spectre Console,
                # which deadlocks if stdout is redirected.
                & foundry model download $model
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$tag Failed to download Foundry model '$model' (exit code $LASTEXITCODE)"
                    $failed += $model
                } else {
                    Write-Host "$tag Done"
                }
            }

            Write-Host ""
        }

        Write-Progress -Activity "foundry" -Completed

        $succeeded = $total - $failed.Count
        Write-Host "==> Completed: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"

        if ($failed.Count -gt 0) {
            Write-Warning "foundry: $($failed.Count) model(s) failed to download: $($failed -join ', ')"
        }
    }
}
