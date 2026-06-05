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

$StreamDeckAppData = Join-Path $env:APPDATA "Elgato\StreamDeck\ProfilesV2"
$BackupSourcePath  = Join-Path $Context.RepositoryRoot "state\config\Elgato.StreamDeck\stream-deck-profiles.streamDeckProfilesBackup"

switch ($Stage) {

    "Export" {
        Write-Host "  [stream-deck] Export: capturing current Stream Deck profiles..."

        if (-not (Test-Path $StreamDeckAppData)) {
            Write-Warning "  [stream-deck] Stream Deck ProfilesV2 folder not found at '$StreamDeckAppData' - skipping export."
            return
        }

        # Pack ProfilesV2 contents directly into the state config file so it
        # stays current and can be committed back to the repository.
        $stateDir = Split-Path -Parent $BackupSourcePath
        New-DirectoryIfMissing -Path $stateDir

        if ($PSCmdlet.ShouldProcess($BackupSourcePath, "Update Stream Deck backup")) {
            if (Test-Path $BackupSourcePath) { Remove-Item $BackupSourcePath -Force }
            Compress-Archive -Path "$StreamDeckAppData\*" -DestinationPath $BackupSourcePath
            Write-Host "  [stream-deck] Backup updated: '$BackupSourcePath'"
        }
    }

    "Build" {
        # Nothing to build - the backup file is the deployable artifact.
        Write-Host "  [stream-deck] Build: no build step required (backup is ready to deploy)."
    }

    "Execute" {
        Write-Host "  [stream-deck] Execute: restoring Stream Deck profiles..."

        if (-not (Test-Path $BackupSourcePath)) {
            throw "Stream Deck backup not found at '$BackupSourcePath'. Run export first to generate it."
        }

        # The .streamDeckProfilesBackup file is a ZIP archive.
        # Extract into ProfilesV2, merging with any existing profiles.
        New-DirectoryIfMissing -Path $StreamDeckAppData

        $tempExtract = Join-Path $env:TEMP "stream-deck-restore-$(Get-Random)"
        try {
            Expand-Archive -Path $BackupSourcePath -DestinationPath $tempExtract -Force

            $profiles = Get-ChildItem -Path $tempExtract -Filter "*.sdProfile" -ErrorAction SilentlyContinue
            if (-not $profiles) {
                # Backup may contain the profiles directly or in a sub-folder
                $profiles = Get-ChildItem -Path $tempExtract -Recurse -Filter "*.sdProfile" -ErrorAction SilentlyContinue
            }

            if ($profiles) {
                foreach ($profile in $profiles) {
                    $dest = Join-Path $StreamDeckAppData $profile.Name
                    if ($PSCmdlet.ShouldProcess($dest, "Restore Stream Deck profile")) {
                        Copy-Item -Path $profile.FullName -Destination $dest -Recurse -Force
                        Write-Host "  [stream-deck] Restored profile: $($profile.Name)"
                    }
                }
            }
            else {
                # No .sdProfile entries found - copy everything from the archive root
                $items = Get-ChildItem -Path $tempExtract
                foreach ($item in $items) {
                    $dest = Join-Path $StreamDeckAppData $item.Name
                    if ($PSCmdlet.ShouldProcess($dest, "Restore Stream Deck item")) {
                        Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
                        Write-Host "  [stream-deck] Restored: $($item.Name)"
                    }
                }
            }

            Write-Host "  [stream-deck] Profile restore complete. Restart the Stream Deck application to apply."
        }
        finally {
            if (Test-Path $tempExtract) {
                Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
