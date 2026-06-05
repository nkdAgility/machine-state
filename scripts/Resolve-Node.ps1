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

function Install-NodeIfMissing {
    if (Get-Command npm -ErrorAction SilentlyContinue) { return }

    Write-Host "Node.js/npm not found - installing via winget..."
    & winget install --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Node.js via winget (exit code $LASTEXITCODE)."
    }

    Invoke-RefreshPath

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm still not found on PATH after installing Node.js. Open a new terminal and re-run."
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
        Install-NodeIfMissing
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
                $upgrades | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $upgradesPath -Encoding UTF8
                Write-Host "$($upgrades.Count) npm package(s) have upgrades available"
            }
            elseif (Test-Path -LiteralPath $upgradesPath) {
                Remove-Item -LiteralPath $upgradesPath -Force
            }
        }
        else {
            Write-Host "npm not available - skipping upgrade check"
        }
    }

    "Execute" {
        Install-NodeIfMissing

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

        if ($PSCmdlet.ShouldProcess("npm global packages", "Install/upgrade npm packages")) {
            & npm install -g @($desiredPkgs)
            if ($LASTEXITCODE -ne 0) {
                throw "npm global install failed with exit code $LASTEXITCODE."
            }
        }
    }
}
