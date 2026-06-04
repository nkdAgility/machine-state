# machine-state

PowerShell-first machine rebuild and synchronization for named workstations.

This repository treats YAML as the source of truth for desired machine state and uses PowerShell scripts to execute deterministic stages.

YAML says what.
PowerShell says how.
machine-state.ps1 decides when.
working/ shows what happened.

## Purpose

The goal is to rebuild, update, export, and synchronize workstation state in a deterministic way.

## Supported Machines

- NKDA-BEHEMOTH (Windows x64)
- NKDA-ROCINANTE (Windows ARM64)

## What This Does

1. **Record what is installed on this machine** → `capture`
2. **Make this machine match stored config** → `apply`
3. **Do both** → `sync`

## How to Run

On a fresh machine or from cmd.exe, use the bootstrap wrapper:

```cmd
machine-state.cmd sync
```

This installs PowerShell 7+ and the YAML module if missing, then runs the script.

If PowerShell 7+ is already installed, run directly:

```powershell
./machine-state.ps1 capture   # Record current machine state
./machine-state.ps1 apply     # Install everything from stored config
./machine-state.ps1 sync      # Do both
```

`-MachineName` is optional. If omitted, machine name is resolved from the current host.

### Options

```powershell
./machine-state.ps1 capture -ExportOnly  # Record to working/ without updating state/
./machine-state.ps1 apply -BuildOnly     # Prepare manifests but don't install
./machine-state.ps1 apply -WhatIf        # Show what would be installed without doing it
./machine-state.ps1 status               # Show resolved machine and config
./machine-state.ps1 validate             # Check state files are valid
```

## Commands

| Command | What it does |
|---------|--------------|
| `capture` | Record current machine state and add new packages to stored config |
| `capture -ExportOnly` | Record current state to working/ only, don't update stored config |
| `apply` | Install everything from stored config |
| `apply -BuildOnly` | Prepare install manifests without installing |
| `apply -WhatIf` | Show what would be installed without doing it |
| `sync` | Capture then apply |
| `status` | Show resolved machine, files, scripts, and paths |
| `validate` | Check state files are valid |

## State Files

Machine files in state/machines define:

- machine identity and platform metadata
- referenced shared state files
- resolver scripts to run
- machine-specific package additions

Shared files in state/win define reusable package sets.

## Winget Flow

1. export runs Winget export to working/<MachineName>/export/winget.export.json.
2. merge resolves referenced desired state with machine inline desired state.
3. build creates working/<MachineName>/build/winget.import.json.
4. execute runs winget import using that generated import file.

The generated Winget import JSON includes separate sources for winget and msstore and emits only PackageIdentifier entries.

## Working Folder

Generated artifacts are written to:

- working/<MachineName>/export
- working/<MachineName>/merge
- working/<MachineName>/build
- working/<MachineName>/logs

Generated files are outputs, not source of truth.

## Determinism

Given the same input YAML and script versions, merge and build output is deterministic:

- package entries are deduplicated by id
- package lists are sorted by id
- output files are written to predictable paths

## LLM Boundary

LLMs may help maintain this repository, but no LLM is required to run it.
Execution depends only on PowerShell 7+, Winget, and YAML parsing support.
