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
| Winget packages | `state/win/*.yaml`, `state/machines/<Name>.yaml` |
| Node / npm globals | `state/win/windows-common.yaml` |
| Python / uv tools | `state/win/windows-common.yaml` |
| .NET global tools | `state/common.yaml` |
| PowerShell modules | `state/common.yaml` |
| Git repositories | `state/common.yaml` |
| Windows OS setup | `state/win/windows-common.yaml` (`setup.windows`) |
| Git global config | `state/common.yaml` (`setup.git`) |

The engine merges these, deduplicates by `id`, sorts deterministically, and writes
a combined manifest to `working/<MachineName>/` before executing.

### App Configuration

App configuration is everything needed to *configure* an already-installed application —
dotfiles, registry settings, profile entries, backup/restore of app data.

Each app has scripts under `scripts/apps/<Publisher.AppName>/`:

| Script | Stage | Purpose |
|--------|-------|---------|
| `apply.ps1` | Execute | Configure or install the app |
| `capture.ps1` | Capture | Export app state back to `state/config/` |
| `build.ps1` | Build | Prepare artifacts (rarely needed) |

Only create the scripts you need — none are required. For apps not available in
winget, `apply.ps1` checks the Windows registry and downloads/installs the app
directly if missing.

| App | Scripts | Config |
|-----|---------|--------|
| Git | `apply.ps1` | *(global git config — no files)* |
| Oh My Posh | `apply.ps1`, `capture.ps1` | `state/config/JanDeDobbeleer.OhMyPosh/` |
| Stream Deck | `apply.ps1`, `capture.ps1` | `state/config/Elgato.StreamDeck/` |
| VS Code | `apply.ps1` | *(settings synced via VS Code)* |
| OBS Studio | `apply.ps1`, `capture.ps1` | `state/config/OBSProject.OBSStudio/` |
| NVIDIA AR SDK | `apply.ps1` | *(ad-hoc installer — not in winget)* |
| GitHub Copilot | `apply.ps1` | *(ad-hoc installer — not in winget)* |

## Stages

| Stage | What it does |
|-------|-------------|
| `export` | Read current machine state into `working/<MachineName>/export/` |
| `merge` | Combine all referenced YAML into `working/<MachineName>/machine-state.yaml` |
| `build` | Generate tool-specific manifests in `working/<MachineName>/build/` |
| `execute` | Apply desired state — install packages, configure apps |
| `sync` | Run all four stages in order |
| `capture` | Export then update stored YAML with any new packages found |
| `status` | Show resolved machine, config paths, and scripts |
| `validate` | Check YAML shape and references without installing |

## Repository Layout

```
state/
  common.yaml         ← cross-platform, every machine (dotnet tools, PS modules, git repos, setup.git)
  machines/           ← one file per named workstation
  win/                ← Windows platform state (winget packages, npm, uv, setup.windows)
  config/             ← app config files committed to the repo, one folder per Publisher.AppName

scripts/
  State-Engine.ps1
  Setup-Engine.ps1
  Resolver-Common.ps1
  systems/
    WindowsSetup/Resolve.ps1    ← Windows OS configuration
    Winget/Resolve.ps1          ← winget + msstore packages
    DotNet/Resolve.ps1          ← dotnet global tools
    PSModule/Resolve.ps1        ← PowerShell modules
    Node/Resolve.ps1            ← npm global packages
    Uv/Resolve.ps1              ← uv tools
    GitRepos/Resolve.ps1        ← git repo clone/pull
    GitReposCleanup/Resolve.ps1 ← git branch cleanup
  apps/
    Git.Git/apply.ps1
    JanDeDobbeleer.OhMyPosh/apply.ps1
    JanDeDobbeleer.OhMyPosh/capture.ps1
    Elgato.StreamDeck/apply.ps1
    Elgato.StreamDeck/capture.ps1
    Microsoft.VisualStudioCode/apply.ps1
    OBSProject.OBSStudio/apply.ps1
    OBSProject.OBSStudio/capture.ps1
    Nvidia.ArSDK/apply.ps1
    GitHub.GitHubCopilot/apply.ps1

working/              ← generated outputs (gitignored)
```

## Working Folder

All generated files go under `working/<MachineName>/`:

```
export/                     ← observed current state
  winget.export.json
  node.npm.export.json
  uv.tools.export.json
  git.export.json
  windows.setup.json

machine-state.yaml          ← merged desired state (YAML)
machine-state.json          ← merged desired state (JSON)

build/                      ← tool-specific install manifests
  winget.import.json
  winget.upgrades.json
  node.npm.import.json
  uv.tools.import.json
  git.ops.json

logs/                       ← execution logs
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
