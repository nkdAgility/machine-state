#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Setup-Engine.ps1")

$vaultId = "p4h6jpjo6e24ivjxiahaw7skoy"

$catalog = @(
    @{
        Id            = "nkdagility-secrets"
        Name          = "NkdAgility Secrets (1Password)"
        RequiresAdmin = $false
        Check         = {
            if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
                Write-Warning "1Password CLI (op) not found — skipping secrets. Install AgileBits.1Password.CLI via winget."
                return $true
            }
            return $false
        }
        Apply         = {
            Write-Host "  Fetching environment-variable secrets from 1Password..."

            $items = op item list --vault $vaultId --tags "environment-variable" --format json 2>&1
            if ($LASTEXITCODE -ne 0) { throw "op item list failed: $items" }
            $items = $items | ConvertFrom-Json

            if (-not $items -or $items.Count -eq 0) {
                Write-Warning "  No items tagged 'environment-variable' found in vault $vaultId."
                return
            }

            $pairs = [System.Collections.Generic.List[pscustomobject]]::new()

            foreach ($item in $items) {
                $json = op item get $item.id --vault $vaultId --format json 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "  Failed to read item '$($item.title)': $json"
                    continue
                }
                $detail = $json | ConvertFrom-Json

                foreach ($field in ($detail.fields | Where-Object { -not $_.purpose })) {
                    if (-not $field.label -or $null -eq $field.value) { continue }
                    $pairs.Add([pscustomobject]@{ Name = $field.label; Value = $field.value })
                }
            }

            if ($pairs.Count -eq 0) {
                Write-Warning "  No fields found to set."
                return
            }

            # Build a single elevated script that sets all Machine-scope env vars at once
            $lines = $pairs | ForEach-Object {
                $escaped = $_.Value -replace "'", "''"
                "[System.Environment]::SetEnvironmentVariable('$($_.Name)', '$escaped', 'Machine')"
            }
            $lines += "Write-Host '  $($pairs.Count) environment variable(s) set.'"

            $tmp = Join-Path $env:TEMP "nkdagility-secrets-apply.ps1"
            $lines | Set-Content -LiteralPath $tmp -Encoding UTF8

            Write-Host "  Applying $($pairs.Count) variable(s) via sudo..."
            sudo pwsh -NonInteractive -File $tmp
            if ($LASTEXITCODE -ne 0) {
                throw "Elevated env var apply failed (exit $LASTEXITCODE)"
            }

            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }.GetNewClosure()
    }
)

Invoke-SetupStage -Stage Execute -Context $Context -Topic "nkdagility-secrets" -Catalog $catalog
