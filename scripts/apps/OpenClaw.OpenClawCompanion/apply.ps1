#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

$arch       = [string]$Context.Architecture
$installUrl = if ($arch -eq "arm64") {
    "https://github.com/openclaw/openclaw/releases/latest/download/OpenClawCompanion-Setup-arm64.exe"
} else {
    "https://github.com/openclaw/openclaw/releases/latest/download/OpenClawCompanion-Setup-x64.exe"
}

$catalog = @(
    @{
        Id            = "openclaw-companion"
        Name          = "OpenClaw Companion"
        RequiresAdmin = $false
        Check         = {
            $uninstallPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($path in $uninstallPaths) {
                $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like "*OpenClaw*" } |
                    Select-Object -First 1
                if ($entry) { return $true }
            }
            return $false
        }
        Apply         = {
            $installer = Join-Path $env:TEMP "OpenClawCompanion-Setup.exe"
            Write-Host "  Downloading OpenClaw Companion ($arch)..."
            Invoke-WebRequest -Uri $installUrl -OutFile $installer -UseBasicParsing
            Write-Host "  Running installer..."
            & $installer /S
            if ($LASTEXITCODE -ne 0) {
                throw "OpenClaw Companion installer exited with code $LASTEXITCODE"
            }
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }.GetNewClosure()
    }
)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "openclaw-companion" -Catalog $catalog
