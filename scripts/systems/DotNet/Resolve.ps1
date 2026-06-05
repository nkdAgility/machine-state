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

switch ($Stage) {

    "Export" {
        Install-ToolIfMissing -Command dotnet -WingetId Microsoft.DotNet.SDK.10 -DisplayName ".NET SDK"
        New-DirectoryIfMissing -Path $Context.ExportPath

        $exportPath = Join-Path $Context.ExportPath "dotnet.tools.export.json"

        $raw = & dotnet tool list --global 2>$null
        $tools = @()

        if ($LASTEXITCODE -eq 0 -and $raw) {
            # Output is a table: skip the header lines (first two rows)
            $lines = @($raw -split "`r?`n" | Select-Object -Skip 2 | Where-Object { $_.Trim() })
            foreach ($line in $lines) {
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 2) {
                    $tools += [ordered]@{
                        id      = $parts[0].Trim().ToLowerInvariant()
                        version = $parts[1].Trim()
                    }
                }
            }
        }

        $exportModel = [ordered]@{ packages = @($tools | Sort-Object id) }

        if ($PSCmdlet.ShouldProcess($exportPath, "Export dotnet global tools")) {
            $exportModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $exportPath -Encoding UTF8
        }

        Write-Host "$($tools.Count) dotnet global tool(s) installed"
    }

    "Build" {
        if (-not (Test-Path -LiteralPath $Context.MergedStateJson)) {
            throw "Merged state not found at '$($Context.MergedStateJson)'. Run merge first."
        }

        New-DirectoryIfMissing -Path $Context.BuildPath

        $importPath   = Join-Path $Context.BuildPath "dotnet.tools.import.json"
        $mergedState  = Get-Content -LiteralPath $Context.MergedStateJson -Raw | ConvertFrom-Json
        $dotnetProp   = $mergedState.PSObject.Properties['dotnet']
        $dotnetVal    = if ($dotnetProp) { $dotnetProp.Value } else { $null }
        $pkgProp      = if ($dotnetVal) { $dotnetVal.PSObject.Properties['packages'] } else { $null }
        $pkgVal       = if ($pkgProp) { $pkgProp.Value } else { $null }
        $toolsProp    = if ($pkgVal) { $pkgVal.PSObject.Properties['tools'] } else { $null }
        $desired      = if ($toolsProp) { @($toolsProp.Value) } else { @() }

        $names = @($desired | ForEach-Object {
            $id = if ($_ -is [string]) { $_ } else { $_.PSObject.Properties['id']?.Value ?? $_['id'] }
            if ($id) { [string]$id }
        } | Where-Object { $_ } | Sort-Object -Unique)

        $importModel = [ordered]@{
            packageManager = "dotnet"
            installScope   = "global"
            packages       = $names
        }

        if ($PSCmdlet.ShouldProcess($importPath, "Write dotnet tools import manifest")) {
            $importModel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $importPath -Encoding UTF8
        }

        Write-Host "dotnet: $($names.Count) tool(s) in desired state"
    }

    "Execute" {
        Install-ToolIfMissing -Command dotnet -WingetId Microsoft.DotNet.SDK.10 -DisplayName ".NET SDK"

        $importPath = Join-Path $Context.BuildPath "dotnet.tools.import.json"
        if (-not (Test-Path -LiteralPath $importPath)) {
            throw "dotnet tools import manifest not found at '$importPath'. Run build first."
        }

        $manifest     = Get-Content -LiteralPath $importPath -Raw | ConvertFrom-Json
        $desiredPkgs  = @($manifest.packages)

        if ($desiredPkgs.Count -eq 0) {
            Write-Host "No dotnet global tools configured"
            return
        }

        # Get currently installed tools
        $exportPath = Join-Path $Context.ExportPath "dotnet.tools.export.json"
        $installedIds = @()
        if (Test-Path -LiteralPath $exportPath) {
            $exportDoc = Get-Content -LiteralPath $exportPath -Raw | ConvertFrom-Json
            $installedIds = @($exportDoc.packages | ForEach-Object { $_.id })
        }

        $toInstall = @($desiredPkgs | Where-Object { $installedIds -notcontains $_.ToLowerInvariant() })
        $toUpdate  = @($desiredPkgs | Where-Object { $installedIds -contains $_.ToLowerInvariant() })

        if ($WhatIfPreference) {
            if ($toInstall.Count -eq 0 -and $toUpdate.Count -eq 0) {
                Write-Host "All dotnet tools are installed"
            }
            else {
                if ($toInstall.Count -gt 0) {
                    Write-Host "Would install $($toInstall.Count) dotnet tool(s):"
                    foreach ($t in $toInstall) { Write-Host "  - $t" }
                }
                if ($toUpdate.Count -gt 0) {
                    Write-Host "Would update $($toUpdate.Count) dotnet tool(s):"
                    foreach ($t in $toUpdate) { Write-Host "  - $t" }
                }
            }
            return
        }

        $workList = @(
            @($toInstall | ForEach-Object { [ordered]@{ action = "install"; id = $_ } }) +
            @($toUpdate  | ForEach-Object { [ordered]@{ action = "update";  id = $_ } })
        )

        $total   = $workList.Count
        $current = 0
        $failed  = @()

        if ($total -eq 0) {
            Write-Host "All dotnet tools are installed"
            return
        }

        Write-Host ""
        Write-Host "==> $total dotnet tool operation(s) to perform"
        Write-Host ""

        foreach ($item in $workList) {
            $current++
            $tag   = "[$current/$total]"
            $pct   = [int](($current - 1) / $total * 100)
            $label = "$tag $($item.action.Substring(0,1).ToUpper() + $item.action.Substring(1))ing $($item.id)"
            Write-Progress -Activity "dotnet tools" -Status $label -PercentComplete $pct
            Write-Host $label

            if ($PSCmdlet.ShouldProcess($item.id, "dotnet tool $($item.action)")) {
                if ($item.action -eq "install") {
                    & dotnet tool install --global $item.id
                }
                else {
                    & dotnet tool update --global $item.id
                }

                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "$tag Failed to $($item.action) $($item.id) (exit code $LASTEXITCODE)"
                    $failed += $item.id
                }
                else {
                    Write-Host "$tag Done"
                }
            }
            Write-Host ""
        }

        Write-Progress -Activity "dotnet tools" -Completed
        $succeeded = $total - $failed.Count
        Write-Host "==> dotnet tools: $succeeded/$total succeeded$(if ($failed.Count -gt 0) { ", $($failed.Count) failed: $($failed -join ', ')" })"
    }
}
