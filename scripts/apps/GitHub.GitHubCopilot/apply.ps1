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
    "https://github.com/github/app/releases/latest/download/GitHub-Copilot-windows-arm64-setup.exe"
} else {
    "https://github.com/github/app/releases/latest/download/GitHub-Copilot-windows-x64-setup.exe"
}

$catalog = @(
    @{
        Id            = "github-copilot"
        Name          = "GitHub Copilot"
        RequiresAdmin = $false
        Check         = {
            $uninstallPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($path in $uninstallPaths) {
                $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like "*GitHub Copilot*" } |
                    Select-Object -First 1
                if ($entry) { return $true }
            }
            return $false
        }
        Apply         = {
            $installer = Join-Path $env:TEMP "GitHub-Copilot-setup.exe"
            Write-Host "  Downloading GitHub Copilot ($arch)..."
            Invoke-WebRequest -Uri $installUrl -OutFile $installer -UseBasicParsing
            Write-Host "  Running installer..."
            & $installer /S
            if ($LASTEXITCODE -ne 0) {
                throw "GitHub Copilot installer exited with code $LASTEXITCODE"
            }
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }.GetNewClosure()
    }
)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "github-copilot" -Catalog $catalog
