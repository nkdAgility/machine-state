# machine-state

PowerShell-first machine rebuild and synchronization for named workstations.

```
YAML says what.
PowerShell says how.
machine-state.ps1 decides when.
working/ shows what happened.
```

## Purpose

Rebuild, update, export, and synchronize workstation state in a deterministic way.
Given the same input YAML, the output is always the same.

## Supported Machines

| Name | Platform | Notes |
|------|----------|-------|
| NKDA-BEHEMOTH | Windows x64 | Intel i9, NVIDIA GPU |
| NKDA-ROCINANTE | Windows ARM64 | Snapdragon Surface, 64 GB RAM |

## How to Run

On a fresh machine or from `cmd.exe`, use the bootstrap wrapper:

```cmd
machine-state.cmd sync
```

This installs PowerShell 7+ and the YAML module if missing, then hands off to the script.

If PowerShell 7+ is already available:

```powershell
./machine-state.ps1 sync           # Capture current state, then apply desired state
./machine-state.ps1 capture        # Record current machine state only
./machine-state.ps1 apply          # Install everything from stored config
./machine-state.ps1 status         # Show resolved machine, files, scripts, and paths
./machine-state.ps1 validate       # Check state files are valid without installing
```

`-MachineName` is optional. If omitted the machine is resolved from `$env:COMPUTERNAME`.

## Two Distinct Concerns

### Primary State

Primary state is everything the machine needs *installed*. It lives in YAML under
`state/` and is managed by the engine pipeline (merge → build → execute).

| Concern | Where it lives |
|---------|----------------|
| Winget packages | `state/machines/<Name>.yaml`, `state/win/*.yaml` |
| Node / npm globals | `state/win/*.yaml`, `state/apps/*.yaml` |
| Python / uv tools | `state/win/*.yaml`, `state/apps/*.yaml` |
| .NET tools / SDKs | `state/win/*.yaml`, `state/apps/*.yaml` |
| PowerShell modules | `state/win/*.yaml`, `state/apps/*.yaml` |
| Git repositories | `state/apps/git-common.yaml` |

The engine merges these, deduplicates by id, sorts deterministically, and writes
a combined manifest to `working/<MachineName>/merge/` before executing.

### App Configuration

App configuration is everything needed to *configure* an already-installed application —
dotfiles, registry settings, profile entries, backup/restore of app data.

Each app has its own resolver under `scripts/apps/<Publisher.AppName>/Resolve.ps1`.
Config files committed to the repo live under `state/config/<Publisher.AppName>/`.

| App | Resolver | Config |
|-----|----------|--------|
| Oh My Posh | `scripts/apps/JanDeDobbeleer.OhMyPosh/Resolve.ps1` | `state/config/JanDeDobbeleer.OhMyPosh/` |
| Stream Deck | `scripts/apps/Elgato.StreamDeck/Resolve.ps1` | `state/config/Elgato.StreamDeck/` |
| Git config | `scripts/apps/Git.Git/Resolve.ps1` | *(global git config values, no files)* |

App resolvers run as part of the normal stage pipeline but are self-contained —
they do not feed back into primary YAML state.

## Stages

| Stage | What it does |
|-------|-------------|
| `export` | Read current machine state into `working/<MachineName>/export/` |
| `merge` | Combine all referenced YAML into `working/<MachineName>/merge/` |
| `build` | Generate tool-specific manifests in `working/<MachineName>/build/` |
| `execute` | Apply desired state — install packages, configure apps |
| `sync` | Run all four stages in order |
| `capture` | Export then update stored YAML with any new packages found |
| `status` | Show resolved machine, config paths, and scripts |
| `validate` | Check YAML shape and references without installing |

## Repository Layout

```
state/
  machines/       ← one file per named workstation
  win/            ← shared Windows platform state
  apps/           ← shared app-level primary state (git repos, npm globals, etc.)
  config/         ← app config files committed to the repo

scripts/
  Resolve-Winget.ps1      ← primary concern resolvers
  Resolve-Node.ps1
  Resolve-Uv.ps1
  Resolve-DotNet.ps1
  Resolve-PSModule.ps1
  Resolve-Git.ps1
  Resolve-GitCleanup.ps1
  apps/
    Git.Git/                        ← app configuration resolvers
    JanDeDobbeleer.OhMyPosh/
    Elgato.StreamDeck/

working/          ← generated outputs (gitignored)
```

## Working Folder

All generated files go under `working/<MachineName>/`:

```
export/   ← observed current state
merge/    ← combined desired state
build/    ← tool-specific install manifests
logs/     ← execution logs
```

These are outputs. `state/` is the source of truth.

## Determinism

- Package entries are deduplicated by `id`
- Package lists are sorted by `id`
- Output files are written to predictable paths
- The same input YAML always produces the same generated output

## LLM Boundary

LLMs may help maintain this repository. No LLM is required to run it.
Execution depends only on PowerShell 7+, Winget, and `powershell-yaml`.
See `CLAUDE.md` for contributor guidance.
