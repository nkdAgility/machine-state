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

function Assert-WingetAvailable {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Winget was not found on PATH. Install Winget before running stage '$Stage'."
    }
}

function Get-WingetVersion {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $version = (& winget --version 2>$null | Select-Object -First 1)
        if ($version) {
            return $version.TrimStart("v")
        }
    }
    catch {
        return $null
    }

    return $null
}

function New-DirectoryIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-SourcePackages {
    param(
        [Parameter(Mandatory)]
        [object]$StateObject,

        [Parameter(Mandatory)]
        [string]$SourceName
    )

    $wingetNode = Get-ObjectValue -Object $StateObject -Name "winget"
    $packagesNode = Get-ObjectValue -Object $wingetNode -Name "packages"
    $sourceNode = Get-ObjectValue -Object $packagesNode -Name $SourceName
    if (-not $sourceNode) {
        return @()
    }

    return @($sourceNode)
}

function New-WingetSourceBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [array]$Packages
    )

    $sourceDetails = if ($Name -eq "winget") {
        [ordered]@{
            Argument   = "https://cdn.winget.microsoft.com/cache"
            Identifier = "Microsoft.Winget.Source_8wekyb3d8bbwe"
            Name       = "winget"
            Type       = "Microsoft.PreIndexed.Package"
        }
    }
    else {
        [ordered]@{
            Argument   = "https://storeedgefd.dsx.mp.microsoft.com/v9.0"
            Identifier = "StoreEdgeFD"
            Name       = "msstore"
            Type       = "Microsoft.Rest"
        }
    }

    $packageItems = @()
    foreach ($pkg in @($Packages)) {
        $packageId = Get-ObjectValue -Object $pkg -Name "id"
        if ($null -eq $pkg -or -not $packageId) {
            continue
        }

        $packageItems += [ordered]@{
            PackageIdentifier = [string]$packageId
        }
    }

    return [ordered]@{
        Packages      = $packageItems
        SourceDetails = $sourceDetails
    }
}

switch ($Stage) {
    "Export" {
        Assert-WingetAvailable
        New-DirectoryIfMissing -Path $Context.ExportPath

        if ($PSCmdlet.ShouldProcess($Context.WingetExportPath, "Export Winget state")) {
            $unavailablePath = Join-Path $Context.ExportPath "winget.unavailable.json"
            $licensePath = Join-Path $Context.ExportPath "winget.license-required.json"

            # Run winget export and capture stderr for unavailable/license warnings
            $stderrFile = [System.IO.Path]::GetTempFileName()
            try {
                & winget export --output $Context.WingetExportPath --accept-source-agreements 2>$stderrFile
                $exitCode = $LASTEXITCODE

                # Parse stderr for warnings
                $unavailable = @()
                $licenseRequired = @()

                if (Test-Path -LiteralPath $stderrFile) {
                    $stderrLines = Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue
                    foreach ($line in $stderrLines) {
                        if ($line -match "Installed package is not available from any source:\s*(.+)") {
                            $unavailable += [ordered]@{
                                name   = $Matches[1].Trim()
                                reason = "not available from any source"
                            }
                        }
                        elseif ($line -match "Exported package requires license agreement to install:\s*(.+)") {
                            $licenseRequired += [ordered]@{
                                name   = $Matches[1].Trim()
                                reason = "requires license agreement"
                            }
                        }
                        else {
                            # Echo other warnings to console
                            Write-Warning $line
                        }
                    }
                }

                # Save unavailable packages
                if ($unavailable.Count -gt 0) {
                    $unavailable | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $unavailablePath -Encoding UTF8
                    Write-Host "$($unavailable.Count) sideloaded/unavailable packages logged to winget.unavailable.json"
                }
                elseif (Test-Path -LiteralPath $unavailablePath) {
                    Remove-Item -LiteralPath $unavailablePath -Force
                }

                # Save license-required packages
                if ($licenseRequired.Count -gt 0) {
                    $licenseRequired | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $licensePath -Encoding UTF8
                    Write-Host "$($licenseRequired.Count) license-required packages logged to winget.license-required.json"
                }
                elseif (Test-Path -LiteralPath $licensePath) {
                    Remove-Item -LiteralPath $licensePath -Force
                }

                if ($exitCode -ne 0) {
                    throw "Winget export failed with exit code $exitCode."
                }
            }
            finally {
                if (Test-Path -LiteralPath $stderrFile) {
                    Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state file not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $mergedState = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json

        $wingetPackages = @(Get-SourcePackages -StateObject $mergedState -SourceName "winget")
        $msstorePackages = @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore")

        $wingetVersion = Get-WingetVersion

        $importModel = [ordered]@{
            '$schema' = "https://aka.ms/winget-packages.schema.2.0.json"
            Sources   = @(
                (New-WingetSourceBlock -Name "winget" -Packages $wingetPackages),
                (New-WingetSourceBlock -Name "msstore" -Packages $msstorePackages)
            )
        }

        if ($wingetVersion) {
            $importModel.WinGetVersion = $wingetVersion
        }

        if ($PSCmdlet.ShouldProcess($Context.WingetImportPath, "Write Winget import JSON")) {
            $importModel | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Context.WingetImportPath -Encoding UTF8
        }
    }

    "Execute" {
        Assert-WingetAvailable

        if (-not (Test-Path -LiteralPath $Context.WingetImportPath)) {
            throw "Winget import file was not found at '$($Context.WingetImportPath)'. Run build first."
        }

        $importDoc = Get-Content -LiteralPath $Context.WingetImportPath -Raw | ConvertFrom-Json
        $desiredWinget = @($importDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget' } | ForEach-Object { $_.Packages.PackageIdentifier })
        $desiredMsstore = @($importDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'msstore' } | ForEach-Object { $_.Packages.PackageIdentifier })

        if ($WhatIfPreference) {
            # Compare with export to show only what's actually missing
            $installedWinget = @()
            $installedMsstore = @()
            if (Test-Path -LiteralPath $Context.WingetExportPath) {
                $exportDoc = Get-Content -LiteralPath $Context.WingetExportPath -Raw | ConvertFrom-Json
                $installedWinget = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget' } | ForEach-Object { $_.Packages.PackageIdentifier })
                $installedMsstore = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'msstore' } | ForEach-Object { $_.Packages.PackageIdentifier })
            }
            else {
                Write-Warning "No export found at $($Context.WingetExportPath) - run 'capture' first for accurate diff. Showing all desired packages."
            }

            $missingWinget = @($desiredWinget | Where-Object { $installedWinget -notcontains $_ } | Sort-Object)
            $missingMsstore = @($desiredMsstore | Where-Object { $installedMsstore -notcontains $_ } | Sort-Object)

            if ($missingWinget.Count -eq 0 -and $missingMsstore.Count -eq 0) {
                Write-Host "All winget packages are already installed"
            }
            else {
                if ($missingWinget.Count -gt 0) {
                    Write-Host "Would install $($missingWinget.Count) winget package(s):"
                    foreach ($pkg in $missingWinget) { Write-Host "  - $pkg" }
                }
                if ($missingMsstore.Count -gt 0) {
                    Write-Host "Would install $($missingMsstore.Count) msstore package(s):"
                    foreach ($pkg in $missingMsstore) { Write-Host "  - $pkg" }
                }
            }
            return
        }

        if ($PSCmdlet.ShouldProcess($Context.WingetImportPath, "Import packages with Winget")) {
            & winget import --import-file $Context.WingetImportPath --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                throw "Winget import failed with exit code $LASTEXITCODE."
            }
        }
    }
}
