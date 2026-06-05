# machine-state — Guidance for LLM Contributors

## Core Model

```
YAML says what.
PowerShell says how.
machine-state.ps1 decides when.
working/ shows what happened.
```

LLMs may help maintain this repository. No LLM is required to run it.

---

## State File Routing

This is the most important rule. Use the correct file based on scope:

| Scope | File | Examples |
|-------|------|---------|
| **Cross-platform, every machine** | `state/common.yaml` | git repos, dotnet tools, PS modules, `setup.git` IDs |
| **Windows, every Windows machine** | `state/win/windows-common.yaml` | winget packages, npm globals, uv tools, `setup.windows` IDs |
| **Windows x64 only** | `state/win/windows-x64.yaml` | x64-specific winget packages |
| **Windows ARM64 only** | `state/win/windows-arm64.yaml` | ARM64-specific winget packages |
| **One specific machine** | `state/machines/<Name>.yaml` | machine-unique packages, `git.cloneRoot`, per-machine scripts |

**If it is cross-platform and not machine-specific, it goes in `state/common.yaml`.**

---

## Two Distinct Concerns

### 1. Primary State — what is installed on this machine

Primary state is declared in YAML and lives under `state/`. The engine reads it,
merges it, and drives installation. These are first-class citizens with their own
merge, build, and execute pipeline:

| Concern | Canonical YAML location | Resolver script |
|---------|------------------------|-----------------|
| Winget packages | `state/win/*.yaml`, `state/machines/<Name>.yaml` | `systems/Winget/Resolve.ps1` |
| Node / npm globals | `state/win/windows-common.yaml` | `systems/Node/Resolve.ps1` |
| Python / uv tools | `state/win/windows-common.yaml` | `systems/Uv/Resolve.ps1` |
| .NET global tools | `state/common.yaml` | `systems/DotNet/Resolve.ps1` |
| PowerShell modules | `state/common.yaml` | `systems/PSModule/Resolve.ps1` |
| Git repositories | `state/common.yaml` | `systems/GitRepos/Resolve.ps1` |
| Windows OS setup | `state/win/windows-common.yaml` (`setup.windows`) | `systems/WindowsSetup/Resolve.ps1` |
| Git app config | `state/common.yaml` (`setup.git`) | `Resolve-GitSetup.ps1` |

**Do not put primary state in `scripts/apps/`.** It belongs in `state/` so the
engine can merge, deduplicate, and validate it.

### 2. App Configuration — how an installed app is configured

App configuration is specific to a single application. It is not merged or
deduplicated by the engine — the app resolver owns it entirely.

Structure:

```
scripts/apps/<Publisher.AppName>/apply.ps1     ← called during Execute stage (configure or install)
scripts/apps/<Publisher.AppName>/capture.ps1   ← called during Capture stage (export state back to repo)
scripts/apps/<Publisher.AppName>/build.ps1     ← called during Build stage (optional, prepare artifacts)
state/config/<Publisher.AppName>/              ← config files committed to the repo
```

Only create the scripts you need — none are mandatory. The engine discovers them
automatically by scanning `scripts/apps/` for the relevant filename.

Each script accepts only `-Context` (no `-Stage`) and uses
`[CmdletBinding(SupportsShouldProcess)]`. They call `Invoke-SetupStage` with the
stage hardcoded to the script's role (`Execute` in `apply.ps1`, etc.).

Examples:

| App | Scripts | Config |
|-----|---------|--------|
| Oh My Posh | `apply.ps1` | `state/config/JanDeDobbeleer.OhMyPosh/ohmyposh.nkdagility.json` |
| Stream Deck | `apply.ps1`, `capture.ps1` | `state/config/Elgato.StreamDeck/stream-deck-profiles.streamDeckProfilesBackup` |

### Ad-hoc installers — apps not available in winget

If an app has no winget package, create an `apply.ps1` that:

1. Checks the Windows uninstall registry to see if the app is already installed.
2. Downloads the installer to `$env:TEMP` and runs it silently if not found.
3. Cleans up the downloaded file afterwards.

Use `Invoke-SetupStage -Stage Execute` with a Check / Apply catalog entry, setting
`RequiresAdmin` appropriately. Architecture-specific URLs should be selected from
`$Context.Architecture`.

Examples: `scripts/apps/Nvidia.ArSDK/apply.ps1`, `scripts/apps/GitHub.GitHubCopilot/apply.ps1`

### Winget post-install hooks — `Resolve.ps1`

`Resolve.ps1` under `scripts/apps/<PackageId>/` is a **winget post-install hook**.
It is called by `systems/Winget/Resolve.ps1` immediately after that specific winget
package is installed, and accepts `-Stage` and `-Context`. Use it only when a winget
package needs extra configuration applied right after installation (e.g. `Git.Git`).
Do not use `Resolve.ps1` as a general app lifecycle script — use `apply.ps1` instead.

---

## Naming Convention

App folders use the winget `Publisher.AppName` identifier — the same ID used in
`state/win/*.yaml` and `state/machines/*.yaml`. This makes it unambiguous which
winget package an app resolver belongs to.

---

## Repository Layout

```
state/
  common.yaml           ← cross-platform, every machine (dotnet tools, PS modules, git repos, setup.git)
  machines/             ← one file per named workstation
  win/                  ← Windows platform state (winget packages, npm, uv, setup.windows)
  config/               ← app config files, one folder per Publisher.AppName

scripts/
  State-Engine.ps1
  Setup-Engine.ps1
  Resolver-Common.ps1
  systems/
    WindowsSetup/Resolve.ps1    ← Windows OS configuration
    Winget/Resolve.ps1          ← winget packages
    DotNet/Resolve.ps1          ← dotnet global tools
    PSModule/Resolve.ps1        ← PowerShell modules
    Node/Resolve.ps1            ← npm global packages
    Uv/Resolve.ps1              ← uv tools
    GitRepos/Resolve.ps1        ← git repo clone/pull
    GitReposCleanup/Resolve.ps1 ← git branch cleanup
  apps/
    Git.Git/apply.ps1                          ← git global config (setup.git catalog)
    JanDeDobbeleer.OhMyPosh/apply.ps1          ← apply.ps1 = Execute stage
    JanDeDobbeleer.OhMyPosh/capture.ps1        ← capture.ps1 = Capture stage
    Elgato.StreamDeck/apply.ps1
    Elgato.StreamDeck/capture.ps1
    Microsoft.VisualStudioCode/apply.ps1
    OBSProject.OBSStudio/apply.ps1
    OBSProject.OBSStudio/capture.ps1
    Nvidia.ArSDK/apply.ps1                     ← ad-hoc installer (not in winget)
    GitHub.GitHubCopilot/apply.ps1             ← ad-hoc installer (not in winget)

working/          ← generated outputs, gitignored except .gitkeep
```

---

## Rules for LLM Contributors

1. **Cross-platform config belongs in `state/common.yaml`.** dotnet tools, PS modules,
   git repos, `setup.git` IDs — anything that runs on every machine regardless of OS
   or architecture goes here.

2. **Windows-specific config belongs in `state/win/windows-common.yaml`.** winget
   packages, npm globals, uv tools, `setup.windows` IDs.

3. **Primary state belongs in YAML.** If something is installed via Winget, npm, uv,
   dotnet, or PowerShell modules, it goes in `state/`, not in an app resolver.

4. **App configuration belongs in `scripts/apps/<Publisher.AppName>/`.** If something
   configures an already-installed app (dotfiles, registry settings, profile entries),
   it goes there.

5. **Do not merge these two concerns.** A resolver in `scripts/apps/` must not modify
   `state/` YAML. The engine-driven pipeline owns `state/`.

6. **App resolver naming.** Always use the winget `Publisher.AppName` format for the
   folder name under `scripts/apps/` and `state/config/`.

7. **App script contract.** Scripts under `scripts/apps/<Publisher.AppName>/` accept
   only `-Context` and use `[CmdletBinding(SupportsShouldProcess)]`. The stage is
   implicit in the filename (`apply.ps1` = Execute, `capture.ps1` = Capture,
   `build.ps1` = Build). The exception is `Resolve.ps1`, which is a winget
   post-install hook and must accept both `-Stage` and `-Context`.

8. **Capture updates state.** Where an app stores config files (e.g. Stream Deck
   profiles, OBS scenes), the `capture.ps1` script should write them back to
   `state/config/<Publisher.AppName>/` so the repo stays current and changes can
   be committed.

9. **No Bash.** PowerShell 7+ only.

10. **No hidden LLM dependency.** Every script must run without an LLM present.

11. **Windows `sudo` is available.** The machine runs Windows 11 with `sudo` enabled in
    `forceNewWindow` mode (`sudo config --enable forceNewWindow`). Scripts that need
    elevation can prefix commands with `sudo` rather than requiring a separate admin
    session. The `sudo` setup entry in `state/win/windows-common.yaml` ensures this is
    configured on every Windows machine. Catalog items with `RequiresAdmin = $true` in
    app resolvers are applied via the engine's admin-elevation path; they should not
    inline `sudo` themselves.
