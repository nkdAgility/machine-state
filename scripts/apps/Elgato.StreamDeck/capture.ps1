#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateConfigDir = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck"

Write-Warning "  [stream-deck] *** MANUAL ACTION REQUIRED ***"
Write-Warning "  [stream-deck] Stream Deck profiles cannot be exported automatically."
Write-Warning "  [stream-deck] Export the backup through the Stream Deck application:"
Write-Warning "  [stream-deck]   1. Open Stream Deck"
Write-Warning "  [stream-deck]   2. Go to Settings > Profiles"
Write-Warning "  [stream-deck]   3. Click the down arrow > Export backup..."
Write-Warning "  [stream-deck]   4. Save to: $StateConfigDir\stream-deck-profiles.streamDeckProfilesBackup"

if ($PSCmdlet.ShouldProcess($StateConfigDir, "Open backup destination in Explorer")) {
    Start-Process explorer.exe -ArgumentList "`"$StateConfigDir`""
}
