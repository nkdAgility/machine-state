#Requires -Version 7.0

<#
.SYNOPSIS
    Sync secrets from 1Password to this machine and to the nkdagility GitHub
    organisation as Actions secrets.

.DESCRIPTION
    Two independent, tag-driven operations against the shared 1Password vault:

      Local   — items tagged 'environment-variable' are set as Machine-scope
                environment variables (same source the NkdAgility.Secrets engine
                app uses during 'machine-state apply').

      Publish — items tagged 'github-organisation' are pushed to the GitHub org
                as org-level Actions secrets with 'all repositories' visibility.
                This is the deliberate "not all of them" subset: an item only
                publishes if you add the 'github-organisation' tag in 1Password.

    A field's label becomes the variable / secret name. GitHub secret names are
    normalised to GitHub's allowed pattern ([A-Z0-9_], not starting with a digit
    or 'GITHUB_'); a normalisation that changes the name is reported.

    The repo root is on the user PATH (machine-state-path setup topic), so once a
    machine is set up you can run 'publish-secrets' from anywhere.

.PARAMETER Org
    GitHub organisation to publish to. Defaults to 'nkdagility'.

.PARAMETER LocalOnly
    Only set local environment variables; skip publishing to GitHub.

.PARAMETER PublishOnly
    Only publish to GitHub; skip setting local environment variables.

.EXAMPLE
    publish-secrets
    Sets local env vars from the 'environment-variable' tag and publishes the
    'github-organisation' subset to the nkdagility org.

.EXAMPLE
    publish-secrets -PublishOnly -WhatIf
    Shows which org secrets would be published, without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Org = "nkdagility",
    [switch]$LocalOnly,
    [switch]$PublishOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Same vault the NkdAgility.Secrets engine app reads (scripts/apps/NkdAgility.Secrets/apply.ps1).
$VaultId            = "p4h6jpjo6e24ivjxiahaw7skoy"
$LocalTag           = "environment-variable"
$PublishTag         = "github-organisation"

function Test-Prerequisite {
    param([string]$Command, [string]$Hint)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Host "  '$Command' not found. $Hint" -ForegroundColor Red
        return $false
    }
    return $true
}

# Fetch all non-purpose name/value field pairs from every vault item carrying a tag.
function Get-OpPairsByTag {
    param([Parameter(Mandatory)][string]$Tag)

    $items = op item list --vault $VaultId --tags $Tag --format json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "op item list (tag '$Tag') failed: $items" }
    $items = $items | ConvertFrom-Json

    $pairs = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not $items -or $items.Count -eq 0) { return $pairs }

    foreach ($item in $items) {
        $json = op item get $item.id --vault $VaultId --format json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to read item '$($item.title)': $json"
            continue
        }
        $detail = $json | ConvertFrom-Json
        foreach ($field in $detail.fields) {
            # Strict-mode-safe property reads: not every field carries every key.
            $props   = $field.PSObject.Properties.Name
            $purpose = if ($props -contains 'purpose') { $field.purpose } else { $null }
            $label   = if ($props -contains 'label')   { $field.label }   else { $null }
            $value   = if ($props -contains 'value')   { $field.value }   else { $null }

            if ($purpose) { continue }                       # skip username/password/notes
            if (-not $label -or $null -eq $value) { continue }
            $pairs.Add([pscustomobject]@{ Name = $label; Value = $value })
        }
    }
    return $pairs
}

# GitHub Actions secret names: [A-Z0-9_], may not start with a digit or 'GITHUB_'.
function ConvertTo-SecretName {
    param([Parameter(Mandatory)][string]$Name)
    $clean = ($Name.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
    if ($clean -match '^[0-9]') { $clean = "_$clean" }
    return $clean
}

if ($PublishOnly -and $LocalOnly) {
    throw "-LocalOnly and -PublishOnly are mutually exclusive."
}

if (-not (Test-Prerequisite -Command "op" -Hint "Install AgileBits.1Password.CLI via winget.")) {
    exit 1
}

# ---------------------------------------------------------------------------
# Local: set Machine-scope environment variables.
# ---------------------------------------------------------------------------
if (-not $PublishOnly) {
    Write-Host "Local environment variables (tag '$LocalTag')..." -ForegroundColor Cyan
    $localPairs = @(Get-OpPairsByTag -Tag $LocalTag)

    if ($localPairs.Count -eq 0) {
        Write-Warning "  No items tagged '$LocalTag' found in vault $VaultId."
    }
    elseif ($PSCmdlet.ShouldProcess("$($localPairs.Count) Machine-scope environment variable(s)", "Set")) {
        # One elevated script sets every Machine-scope var at once (matches the engine app).
        $lines = $localPairs | ForEach-Object {
            $escaped = $_.Value -replace "'", "''"
            "[System.Environment]::SetEnvironmentVariable('$($_.Name)', '$escaped', 'Machine')"
        }
        $lines += "Write-Host '  $($localPairs.Count) environment variable(s) set.'"

        $tmp = Join-Path $env:TEMP "publish-secrets-local.ps1"
        $lines | Set-Content -LiteralPath $tmp -Encoding UTF8
        try {
            Write-Host "  Applying $($localPairs.Count) variable(s) via sudo..."
            sudo pwsh -NonInteractive -File $tmp
            if ($LASTEXITCODE -ne 0) { throw "Elevated env var apply failed (exit $LASTEXITCODE)" }
        }
        finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        foreach ($p in $localPairs) { Write-Host "  would set $($p.Name)" }
    }
}

# ---------------------------------------------------------------------------
# Publish: push the tagged subset to the GitHub org as Actions secrets.
# ---------------------------------------------------------------------------
if (-not $LocalOnly) {
    Write-Host ""
    Write-Host "Publish to GitHub org '$Org' (tag '$PublishTag', visibility: all)..." -ForegroundColor Cyan

    if (-not (Test-Prerequisite -Command "gh" -Hint "Install GitHub.cli via winget.")) {
        exit 1
    }

    $publishPairs = @(Get-OpPairsByTag -Tag $PublishTag)
    if ($publishPairs.Count -eq 0) {
        Write-Warning "  No items tagged '$PublishTag' found — nothing to publish."
        Write-Host "Done." -ForegroundColor Green
        return
    }

    $failed = 0
    foreach ($pair in $publishPairs) {
        $secretName = ConvertTo-SecretName -Name $pair.Name
        if ($secretName -like 'GITHUB_*') {
            Write-Warning "  Skipping '$($pair.Name)': GitHub forbids secret names starting with 'GITHUB_'."
            continue
        }
        if ($secretName -ne $pair.Name) {
            Write-Host "  '$($pair.Name)' -> '$secretName' (normalised)" -ForegroundColor DarkGray
        }

        if (-not $PSCmdlet.ShouldProcess("$secretName in org $Org", "Set Actions secret")) {
            Write-Host "  would publish $secretName"
            continue
        }

        # Value piped via stdin so it never appears in the process command line.
        $result = $pair.Value | gh secret set $secretName --org $Org --visibility all --app actions 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failed++
            Write-Warning "  Failed to set '$secretName': $result"
        }
        else {
            Write-Host "  set $secretName" -ForegroundColor Green
        }
    }

    if ($failed -gt 0) {
        Write-Host ""
        Write-Host "$failed secret(s) failed. If you saw a 403 / scope error, the active gh token" -ForegroundColor Yellow
        Write-Host "lacks 'admin:org'. Refresh it with:" -ForegroundColor Yellow
        Write-Host "  gh auth refresh -h github.com -s admin:org" -ForegroundColor Yellow
        Write-Host "(If GITHUB_TOKEN is set in your environment, gh uses that token regardless of" -ForegroundColor Yellow
        Write-Host " keyring auth — unset it or ensure it has admin:org.)" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
