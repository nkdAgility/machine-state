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

        $allWingetPackages  = @(Get-SourcePackages -StateObject $mergedState -SourceName "winget")
        $allMsstorePackages = @(Get-SourcePackages -StateObject $mergedState -SourceName "msstore")

        # Split into automated and manual packages
        $wingetPackages  = @($allWingetPackages  | Where-Object { -not (Get-ObjectValue -Object $_ -Name "manual") })
        $msstorePackages = @($allMsstorePackages | Where-Object { -not (Get-ObjectValue -Object $_ -Name "manual") })
        $manualPackages  = @(
            ($allWingetPackages  | Where-Object { Get-ObjectValue -Object $_ -Name "manual" } | ForEach-Object { [ordered]@{ id = [string](Get-ObjectValue -Object $_ -Name "id"); source = "winget"  } }),
            ($allMsstorePackages | Where-Object { Get-ObjectValue -Object $_ -Name "manual" } | ForEach-Object { [ordered]@{ id = [string](Get-ObjectValue -Object $_ -Name "id"); source = "msstore" } })
        )

        # Write manual package list
        $manualPath = Join-Path $Context.BuildPath "winget.manual.json"
        if ($manualPackages.Count -gt 0) {
            $manualPackages | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manualPath -Encoding UTF8
            Write-Host "$($manualPackages.Count) package(s) marked for manual installation"
        }
        elseif (Test-Path -LiteralPath $manualPath) {
            Remove-Item -LiteralPath $manualPath -Force
        }

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

        # Detect packages with available upgrades (filtered to automated desired packages only)
        $upgradesPath = Join-Path $Context.BuildPath "winget.upgrades.json"
        $desiredIds = @($wingetPackages | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" }) +
                      @($msstorePackages | ForEach-Object { Get-ObjectValue -Object $_ -Name "id" })

        Write-Host "Checking for available upgrades..."
        $upgradeOutput = & winget upgrade --include-unknown 2>$null
        $upgrades = @()

        # Parse winget upgrade output (table format)
        $inTable = $false
        foreach ($line in $upgradeOutput) {
            if ($line -match "^-+$" -or $line -match "^[-\s]+$") {
                $inTable = $true
                continue
            }
            if ($line -match "^\d+ upgrades available" -or [string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($inTable -and $line.Length -gt 20) {
                if ($line -match "^(.+?)\s{2,}(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$") {
                    $pkgId = $Matches[2].Trim()
                    # Only include if in desired state
                    if ($desiredIds -contains $pkgId) {
                        $upgrades += [ordered]@{
                            name      = $Matches[1].Trim()
                            id        = $pkgId
                            installed = $Matches[3].Trim()
                            available = $Matches[4].Trim()
                            source    = $Matches[5].Trim()
                        }
                    }
                }
            }
        }

        if ($upgrades.Count -gt 0) {
            $upgrades | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $upgradesPath -Encoding UTF8
            Write-Host "$($upgrades.Count) package(s) have upgrades available"
        }
        elseif (Test-Path -LiteralPath $upgradesPath) {
            Remove-Item -LiteralPath $upgradesPath -Force
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

            # Check for upgrades (from build stage)
            $upgradesPath = Join-Path $Context.BuildPath "winget.upgrades.json"
            $upgradeableWinget = @()
            if (Test-Path -LiteralPath $upgradesPath) {
                $upgradeableWinget = @(Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json)
            }

            $hasWork = $missingWinget.Count -gt 0 -or $missingMsstore.Count -gt 0 -or $upgradeableWinget.Count -gt 0

            if (-not $hasWork) {
                Write-Host "All winget packages are installed and up to date"
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
                if ($upgradeableWinget.Count -gt 0) {
                    Write-Host "Would upgrade $($upgradeableWinget.Count) package(s):"
                    foreach ($pkg in $upgradeableWinget | Sort-Object { $_.id }) {
                        Write-Host "  - $($pkg.id): $($pkg.installed) -> $($pkg.available)"
                    }
                }
            }
            return
        }

        # Build a priority map from the merged state (lower number = install first, default 999)
        $priorityMap = @{}
        if (Test-Path -LiteralPath $Context.MergedStateJson) {
            $mergedForPriority = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
            foreach ($src in @("winget", "msstore")) {
                foreach ($pkg in @(Get-SourcePackages -StateObject $mergedForPriority -SourceName $src)) {
                    $pkgId  = Get-ObjectValue -Object $pkg -Name "id"
                    $pkgPri = Get-ObjectValue -Object $pkg -Name "priority"
                    if ($pkgId) {
                        $priorityMap[[string]$pkgId] = if ($null -ne $pkgPri) { [int]$pkgPri } else { 999 }
                    }
                }
            }
        }

        # Diff desired vs installed so we only attempt packages that are actually missing
        $installedWinget = @()
        $installedMsstore = @()
        if (Test-Path -LiteralPath $Context.WingetExportPath) {
            $exportDoc = Get-Content -LiteralPath $Context.WingetExportPath -Raw | ConvertFrom-Json
            $installedWinget  = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget'  } | ForEach-Object { $_.Packages.PackageIdentifier })
            $installedMsstore = @($exportDoc.Sources | Where-Object { $_.SourceDetails.Name -eq 'msstore' } | ForEach-Object { $_.Packages.PackageIdentifier })
        }

        $missingWinget  = @($desiredWinget  | Where-Object { $installedWinget  -notcontains $_ } | Sort-Object { if ($priorityMap.ContainsKey($_)) { $priorityMap[$_] } else { 999 } }, { $_ })
        $missingMsstore = @($desiredMsstore | Where-Object { $installedMsstore -notcontains $_ } | Sort-Object { if ($priorityMap.ContainsKey($_)) { $priorityMap[$_] } else { 999 } }, { $_ })

        $upgradesPath = Join-Path $Context.BuildPath "winget.upgrades.json"
        $upgradeableWinget = @()
        if (Test-Path -LiteralPath $upgradesPath) {
            $upgradeableWinget = @(Get-Content -LiteralPath $upgradesPath -Raw | ConvertFrom-Json)
        }

        $failed = @()

        foreach ($pkg in $missingWinget) {
            if ($PSCmdlet.ShouldProcess($pkg, "winget install (winget source)")) {
                Write-Host "Installing $pkg..."
                & winget install --id $pkg --source winget --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to install $pkg (exit code $LASTEXITCODE)"
                    $failed += $pkg
                }
            }
        }

        foreach ($pkg in $missingMsstore) {
            if ($PSCmdlet.ShouldProcess($pkg, "winget install (msstore source)")) {
                Write-Host "Installing $pkg..."
                & winget install --id $pkg --source msstore --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to install $pkg (exit code $LASTEXITCODE)"
                    $failed += $pkg
                }
            }
        }

        foreach ($pkg in $upgradeableWinget) {
            if ($PSCmdlet.ShouldProcess($pkg.id, "winget upgrade")) {
                Write-Host "Upgrading $($pkg.id) ($($pkg.installed) -> $($pkg.available))..."
                & winget upgrade --id $pkg.id --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to upgrade $($pkg.id) (exit code $LASTEXITCODE)"
                    $failed += $pkg.id
                }
            }
        }

        if ($missingWinget.Count -eq 0 -and $missingMsstore.Count -eq 0 -and $upgradeableWinget.Count -eq 0) {
            Write-Host "All winget packages are installed and up to date"
        }
        elseif ($failed.Count -gt 0) {
            Write-Warning "$($failed.Count) package(s) failed: $($failed -join ', ')"
        }

        # Print manual installation reminders
        $manualPath = Join-Path $Context.BuildPath "winget.manual.json"
        if (Test-Path -LiteralPath $manualPath) {
            $manualPkgs = @(Get-Content -LiteralPath $manualPath -Raw | ConvertFrom-Json)
            if ($manualPkgs.Count -gt 0) {
                Write-Host ""
                Write-Host "*** MANUAL INSTALLS REQUIRED ***"
                Write-Host "The following packages must be installed manually (e.g. run without elevation):"
                foreach ($pkg in $manualPkgs) {
                    Write-Host "  winget install --id $($pkg.id) --source $($pkg.source) --accept-package-agreements"
                }
                Write-Host ""
            }
        }
    }
}
