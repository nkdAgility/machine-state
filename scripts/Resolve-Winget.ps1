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
            & winget export --output $Context.WingetExportPath --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                throw "Winget export failed with exit code $LASTEXITCODE."
            }
        }
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateYaml)) {
            throw "Merged state file not found at '$($Context.MergedStateYaml)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $mergedState = Get-Content -LiteralPath $Context.MergedStateYaml -Raw | ConvertFrom-Yaml

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

        if ($PSCmdlet.ShouldProcess($Context.WingetImportPath, "Import packages with Winget")) {
            & winget import --import-file $Context.WingetImportPath --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                throw "Winget import failed with exit code $LASTEXITCODE."
            }
        }
    }
}
