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

function Assert-NpmAvailable {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm was not found on PATH. Install Node.js/npm before running stage '$Stage'."
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
        Assert-NpmAvailable
        New-DirectoryIfMissing -Path $Context.ExportPath

        $raw = & npm list -g --depth=0 --json
        if ($LASTEXITCODE -ne 0) {
            throw "npm global export failed with exit code $LASTEXITCODE."
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

        if ($PSCmdlet.ShouldProcess($Context.NodeExportPath, "Export npm global packages")) {
            $exportModel | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Context.NodeExportPath -Encoding UTF8
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

        if ($PSCmdlet.ShouldProcess($Context.NodeImportPath, "Write npm import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Context.NodeImportPath -Encoding UTF8
        }
    }

    "Execute" {
        Assert-NpmAvailable

        if (-not (Test-Path -LiteralPath $Context.NodeImportPath)) {
            throw "npm import manifest was not found at '$($Context.NodeImportPath)'. Run build first."
        }

        $manifest = Get-Content -LiteralPath $Context.NodeImportPath -Raw | ConvertFrom-Json
        $desiredPkgs = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            return
        }

        if ($WhatIfPreference) {
            # Compare with export to show only what's actually missing
            $installedPkgs = @()
            if (Test-Path -LiteralPath $Context.NodeExportPath) {
                $exportDoc = Get-Content -LiteralPath $Context.NodeExportPath -Raw | ConvertFrom-Json
                $installedPkgs = @($exportDoc.packages | ForEach-Object { $_.id })
            }

            $missingPkgs = @($desiredPkgs | Where-Object { $installedPkgs -notcontains $_ } | Sort-Object)

            if ($missingPkgs.Count -eq 0) {
                Write-Host "All npm packages are already installed"
            }
            else {
                Write-Host "Would install $($missingPkgs.Count) npm package(s):"
                foreach ($pkg in $missingPkgs) { Write-Host "  - $pkg" }
            }
            return
        }

        if ($PSCmdlet.ShouldProcess("npm global packages", "Install/upgrade npm packages")) {
            & npm install -g @($desiredPkgs)
            if ($LASTEXITCODE -ne 0) {
                throw "npm global install failed with exit code $LASTEXITCODE."
            }
        }
    }
}
