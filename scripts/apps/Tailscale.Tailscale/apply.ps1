#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Write-Warning "  [tailscale] tailscale not found on PATH - skipping configuration"
    return
}

$catalog = @(

    @{
        Id            = "tailscale-up"
        Name          = "Tailscale connected"
        RequiresAdmin = $false
        Check         = {
            $status = & tailscale status --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            $status -and $status.BackendState -eq "Running"
        }
        Apply         = {
            & tailscale up --unattended=true
        }
    }

)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "tailscale" -Catalog $catalog
