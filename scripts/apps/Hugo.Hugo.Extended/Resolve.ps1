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

if ($Stage -ne "Execute") { return }

# Winget installs Hugo as a bare zip extract and does not always create a shim in
# WinGet\Links. Find the package directory and ensure it is on the user PATH.

$packagesRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
$hugoDir = Get-ChildItem -LiteralPath $packagesRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object Name -like "Hugo.Hugo.Extended_*" |
    Select-Object -First 1

if (-not $hugoDir) {
    Write-Warning "Hugo.Hugo.Extended: package directory not found under $packagesRoot - skipping PATH fix"
    return
}

$hugoExe = Join-Path $hugoDir.FullName "hugo.exe"
if (-not (Test-Path -LiteralPath $hugoExe)) {
    Write-Warning "Hugo.Hugo.Extended: hugo.exe not found in $($hugoDir.FullName) - skipping PATH fix"
    return
}

$userPath = [Environment]::GetEnvironmentVariable("PATH", "User") ?? ""
if ($userPath -split ";" | Where-Object { $_ -eq $hugoDir.FullName }) {
    Write-Host "Hugo.Hugo.Extended: PATH already contains $($hugoDir.FullName)"
    return
}

if ($PSCmdlet.ShouldProcess("User PATH", "Add $($hugoDir.FullName)")) {
    $newPath = ($userPath.TrimEnd(";") + ";" + $hugoDir.FullName).TrimStart(";")
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Invoke-RefreshPath
    Write-Host "Hugo.Hugo.Extended: added $($hugoDir.FullName) to user PATH"
}
