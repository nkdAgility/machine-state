#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

$installUrl = "https://international.download.nvidia.com/Windows/broadcast/sdk/AR/nvidia_ar_sdk_installer_v0.8.2_ampere.exe"

$catalog = @(
    @{
        Id            = "nvidia-ar-sdk-ampere"
        Name          = "NVIDIA AR SDK (Ampere/30xx)"
        RequiresAdmin = $true
        Check         = {
            $uninstallPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($path in $uninstallPaths) {
                $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like "*NVIDIA AR SDK*" } |
                    Select-Object -First 1
                if ($entry) { return $true }
            }
            return $false
        }
        Apply         = {
            $installer = Join-Path $env:TEMP "nvidia_ar_sdk_ampere.exe"
            Write-Host "  Downloading NVIDIA AR SDK..."
            Invoke-WebRequest -Uri $installUrl -OutFile $installer -UseBasicParsing
            Write-Host "  Running installer..."
            & $installer /S
            if ($LASTEXITCODE -ne 0) {
                throw "NVIDIA AR SDK installer exited with code $LASTEXITCODE"
            }
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }.GetNewClosure()
    }
)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "nvidia-ar-sdk" -Catalog $catalog
