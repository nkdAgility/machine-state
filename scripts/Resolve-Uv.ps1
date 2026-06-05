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

function Invoke-RefreshPath {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Install-UvIfMissing {
    if (Get-Command uv -ErrorAction SilentlyContinue) { return }

    Write-Host "uv not found - installing via winget..."
    & winget install --id astral-sh.uv --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install uv via winget (exit code $LASTEXITCODE)."
    }

    Invoke-RefreshPath

    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw "uv still not found on PATH after installing. Open a new terminal and re-run."
    }
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-SectionPackages {
    param(
        [Parameter(Mandatory)][object]$StateObject,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][string]$SourceName
    )

    $sectionNode = Get-ObjectValue -Object $StateObject -Name $SectionName
    $packagesNode = Get-ObjectValue -Object $sectionNode -Name "packages"
    $sourceNode = Get-ObjectValue -Object $packagesNode -Name $SourceName
    if (-not $sourceNode) {
        return @()
    }

    return @($sourceNode)
}

switch ($Stage) {
    "Export" {
        Install-UvIfMissing
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

        if ($PSCmdlet.ShouldProcess($Context.UvExportPath, "Export uv tools")) {
            $exportModel | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Context.UvExportPath -Encoding UTF8
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

        if ($PSCmdlet.ShouldProcess($Context.UvImportPath, "Write uv tool import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Context.UvImportPath -Encoding UTF8
        }
    }

    "Execute" {
        Install-UvIfMissing

        if (-not (Test-Path -LiteralPath $Context.UvImportPath)) {
            throw "uv import manifest was not found at '$($Context.UvImportPath)'. Run build first."
        }

        $manifest = Get-Content -LiteralPath $Context.UvImportPath -Raw | ConvertFrom-Json
        $desiredPkgs = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            return
        }

        if ($WhatIfPreference) {
            $installedPkgs = @()
            if (Test-Path -LiteralPath $Context.UvExportPath) {
                $exportDoc = Get-Content -LiteralPath $Context.UvExportPath -Raw | ConvertFrom-Json
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
                & uv tool install --upgrade $pkg
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
