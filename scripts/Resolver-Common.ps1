#Requires -Version 7.0
# Shared utility functions dot-sourced by all Resolve-*.ps1 scripts.

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

function New-DirectoryIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-RefreshPath {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Install-ToolIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$WingetId,

        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) { return }

    Write-Host "$DisplayName not found - installing via winget..."
    & winget install --id $WingetId --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install $DisplayName via winget (exit code $LASTEXITCODE)."
    }

    Invoke-RefreshPath

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "$DisplayName still not found on PATH after installing. Open a new terminal and re-run."
    }
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
