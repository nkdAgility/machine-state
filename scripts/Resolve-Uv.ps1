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

function Assert-UvAvailable {
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw "uv was not found on PATH. Install uv before running stage '$Stage'."
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
        Assert-UvAvailable
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
        Assert-UvAvailable

        if (-not (Test-Path -LiteralPath $Context.UvImportPath)) {
            throw "uv import manifest was not found at '$($Context.UvImportPath)'. Run build first."
        }

        $manifest = Get-Content -LiteralPath $Context.UvImportPath -Raw | ConvertFrom-Json
        $desiredPkgs = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            return
        }

        if ($WhatIfPreference) {
            # Compare with export to show only what's actually missing
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

        foreach ($pkg in $desiredPkgs) {
            if ($PSCmdlet.ShouldProcess($pkg, "Install/upgrade uv tool")) {
                & uv tool install --upgrade $pkg
                if ($LASTEXITCODE -ne 0) {
                    throw "uv tool install failed for '$pkg' with exit code $LASTEXITCODE."
                }
            }
        }
    }
}
