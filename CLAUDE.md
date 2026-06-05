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

## Two Distinct Concerns

### 1. Primary State — what is installed on this machine

Primary state is declared in YAML and lives under `state/`. The engine reads it,
merges it, and drives installation. These are first-class citizens with their own
merge, build, and execute pipeline:

| Concern | YAML location | Resolver script |
|---------|---------------|-----------------|
| Winget packages | `state/machines/<Name>.yaml`, `state/win/*.yaml` | `scripts/Resolve-Winget.ps1` |
| Node / npm globals | `state/win/*.yaml`, `state/apps/*.yaml` | `scripts/Resolve-Node.ps1` |
| Python / uv tools | `state/win/*.yaml`, `state/apps/*.yaml` | `scripts/Resolve-Uv.ps1` |
| .NET tools / SDKs | `state/win/*.yaml`, `state/apps/*.yaml` | `scripts/Resolve-DotNet.ps1` |
| PowerShell modules | `state/win/*.yaml`, `state/apps/*.yaml` | `scripts/Resolve-PSModule.ps1` |
| Git repositories | `state/apps/git-common.yaml` | `scripts/Resolve-Git.ps1`, `scripts/Resolve-GitCleanup.ps1` |

**Do not move primary state concerns into `scripts/apps/`.** They belong in `state/` so
the engine can merge, deduplicate, and validate them.

### 2. App Configuration — how an installed app is configured

App configuration is specific to a single application. It is not merged or
deduplicated by the engine — the app resolver owns it entirely.

Structure:

```
scripts/apps/<Publisher.AppName>/Resolve.ps1   ← resolver (Export / Build / Execute)
state/config/<Publisher.AppName>/              ← config files committed to the repo
```

Examples:

| App | Resolver | Config |
|-----|----------|--------|
| Oh My Posh | `scripts/apps/JanDeDobbeleer.OhMyPosh/Resolve.ps1` | `state/config/JanDeDobbeleer.OhMyPosh/ohmyposh.nkdagility.json` |
| Stream Deck | `scripts/apps/Elgato.StreamDeck/Resolve.ps1` | `state/config/Elgato.StreamDeck/stream-deck-profiles.streamDeckProfilesBackup` |
| Git config | `scripts/apps/Git.Git/Resolve.ps1` | *(no config files — sets `git config --global` values)* |

App resolvers use `Setup-Engine.ps1` (`Invoke-SetupStage`) with a catalog of
Check / Apply pairs. They do not add entries to the primary YAML state.

---

## Naming Convention

App folders use the winget `Publisher.AppName` identifier — the same ID used in
`state/win/*.yaml` and `state/machines/*.yaml`. This makes it unambiguous which
winget package an app resolver belongs to.

---

## Repository Layout

```
state/
  machines/       ← one file per named workstation
  win/            ← shared Windows platform state (packages, setup IDs)
  apps/           ← shared app-level primary state (git repos, npm globals, etc.)
  config/         ← app config files, one folder per Publisher.AppName

scripts/
  machine-state.ps1 (root)
  State-Engine.ps1
  Setup-Engine.ps1
  Resolver-Common.ps1
  Resolve-Winget.ps1      ← primary concern resolvers (flat, named by concern)
  Resolve-Node.ps1
  Resolve-Uv.ps1
  Resolve-Git.ps1
  Resolve-GitCleanup.ps1
  apps/
    Git.Git/Resolve.ps1               ← app config resolvers
    JanDeDobbeleer.OhMyPosh/Resolve.ps1
    Elgato.StreamDeck/Resolve.ps1

working/          ← generated outputs, gitignored except .gitkeep
```

---

## Rules for LLM Contributors

1. **Primary state belongs in YAML.** If something is installed via Winget, npm, uv,
   or PowerShell modules, it goes in `state/`, not in an app resolver.

2. **App configuration belongs in `scripts/apps/<Publisher.AppName>/`.** If something
   configures an already-installed app (dotfiles, registry settings, profile entries),
   it goes there.

3. **Do not merge these two concerns.** A resolver in `scripts/apps/` must not modify
   `state/` YAML. The engine-driven pipeline owns `state/`.

4. **App resolver naming.** Always use the winget `Publisher.AppName` format for the
   folder name under `scripts/apps/` and `state/config/`.

5. **Resolver contract.** Every `Resolve.ps1` under `scripts/apps/` must accept
   `-Stage` (`Export` / `Build` / `Execute`) and `-Context`, and must use
   `[CmdletBinding(SupportsShouldProcess)]`.

6. **Export updates state.** Where an app stores config files (e.g. Stream Deck
   profiles), the Export stage should write back to `state/config/<Publisher.AppName>/`
   so the repo stays current and changes can be committed.

7. **No Bash.** PowerShell 7+ only.

8. **No hidden LLM dependency.** Every script must run without an LLM present.
