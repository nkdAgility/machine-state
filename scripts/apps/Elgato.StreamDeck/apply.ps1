#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\Resolver-Common.ps1")

$BackupPath = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck\stream-deck-profiles.streamDeckProfilesBackup"

if (-not (Test-Path $BackupPath)) {
    Write-Host "  [stream-deck] No backup found at '$BackupPath' - run capture first."
    return
}

Write-Warning "  [stream-deck] *** MANUAL ACTION REQUIRED ***"
Write-Warning "  [stream-deck] Stream Deck profiles cannot be restored automatically."
Write-Warning "  [stream-deck] Import the backup through the Stream Deck application:"
Write-Warning "  [stream-deck]   1. Open Stream Deck"
Write-Warning "  [stream-deck]   2. Go to Settings > Profiles"
Write-Warning "  [stream-deck]   3. Click the down arrow > Import from backup..."
Write-Warning "  [stream-deck]   4. Select: $BackupPath"

if ($PSCmdlet.ShouldProcess($BackupPath, "Open backup location in Explorer")) {
    Start-Process explorer.exe -ArgumentList "/select,`"$BackupPath`""
}
