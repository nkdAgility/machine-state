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

function Add-ManualAction {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Description,

        [string]$Command,
        [string]$Reason,
        [string[]]$Steps
    )

    $path = Join-Path $Context.BuildPath "manual-actions.json"
    $actions = @()
    if (Test-Path -LiteralPath $path) {
        $actions = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    }

    $entry = [ordered]@{ category = $Category; description = $Description }
    if ($Command) { $entry.command = $Command }
    if ($Reason)  { $entry.reason  = $Reason  }
    if ($Steps -and $Steps.Count -gt 0) { $entry.steps = $Steps }

    $actions += [pscustomobject]$entry
    $actions | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Write-ManualSummary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $path = Join-Path $Context.BuildPath "manual-actions.json"
    if (-not (Test-Path -LiteralPath $path)) { return }

    $actions = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    if ($actions.Count -eq 0) { return }

    $grouped = $actions | Group-Object category

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║         MANUAL ACTIONS REQUIRED ($($actions.Count))                 ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Yellow

    foreach ($group in $grouped | Sort-Object Name) {
        Write-Host ""
        Write-Host "  [$($group.Name.ToUpper())]" -ForegroundColor Cyan
        foreach ($item in $group.Group) {
            Write-Host "  • $($item.PSObject.Properties['description']?.Value)"
            $cmd   = $item.PSObject.Properties['command']?.Value
            $why   = $item.PSObject.Properties['reason']?.Value
            $steps = $item.PSObject.Properties['steps']?.Value
            if ($cmd)   { Write-Host "      $cmd"            -ForegroundColor DarkGray }
            if ($why)   { Write-Host "      Reason: $why"    -ForegroundColor DarkGray }
            if ($steps) {
                $stepNum = 1
                foreach ($step in @($steps)) {
                    Write-Host "      $stepNum. $step" -ForegroundColor DarkGray
                    $stepNum++
                }
            }
        }
    }
    Write-Host ""
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

    if (where.exe $Command 2>$null) { return }

    Write-Host "$DisplayName not found - installing via winget..."
    & winget install --id $WingetId --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install $DisplayName via winget (exit code $LASTEXITCODE)."
    }

    Invoke-RefreshPath

    if (-not (where.exe $Command 2>$null)) {
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
