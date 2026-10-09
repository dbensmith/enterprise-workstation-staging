# Phase 1: Modular Foundation - Research

**Researched:** 2026-10-09
**Domain:** Windows PowerShell 5.1 repo restructure (common module + HP vendor module), Pester 6 / PSScriptAnalyzer quality gates, gitleaks secret gate, run-time config
**Confidence:** HIGH for tooling (versions, rule behaviour and hook mechanics were run on this machine), MEDIUM for G5 platform data, LOW for BIOS-default setting names

## Summary

This phase is a refactor plus three quality gates. Most of the risk is in mechanics that look trivial but break on Windows PowerShell 5.1, and this session tested those mechanics directly. Pester 6.2.0 and PSScriptAnalyzer 1.25.0 both load and run under Windows PowerShell 5.1.26100. Under Pester 6.2.0 the current suite gives **20 passed, 8 failed**. All 8 failures are the D-06 defect (`ConvertTo-HPBiosVersion` / `Get-FirmwareSkipReason` are not defined). PSScriptAnalyzer 1.25.0 with default rules reports **13 findings**, all `PSAvoidUsingWriteHost` in `src/Test-DeviceBaseline.ps1`. Functions whose name starts with the `Show-` verb do not trigger that rule, so the fix is to move coloured output into a `Show-*` function. No suppression is needed. The existing `-LogPath` test passes even though the installer has no `-LogPath` parameter, because it only matches a string. A new test must bind the answer-file arguments against the installer's real `param()` block.

gitleaks v8.30.1 (the current release) finds **no leaks** in the full history (`--log-opts="--all"`, 19 commits). A versioned hook wired through `git config core.hooksPath .githooks` blocked a commit holding a generated GitHub-style token. That held even with an inline `gitleaks:allow` comment, because the hook passes `--ignore-gitleaks-allow`. Two Windows traps were found and proven:

1. Launching `powershell.exe` from a PowerShell 7 parent (or from git-bash started by one) leaks PS 7's `PSModulePath`, and Windows PowerShell 5.1 then fails to load its own inbox modules. Clearing `PSModulePath` before the launch fixes it (verified for both `Run.cmd` and the sh hook).
2. gitleaks reads `.gitleaks.toml` from the **scan target path**, not from the current directory. Always pass `-c <repo>\.gitleaks.toml` or scan the repo root.

The vendor interface should be a data-only `vendor.psd1` plus a contract table in core (names and parameters). A data-driven Pester contract test checks each descriptor. A parameterized-container prototype run in a fresh `powershell.exe` exited **0** for a complete vendor and **1** for a fixture missing one operation, which is exactly success criterion 1. HPCMSL 1.9.0 already exports `Get-HPDeviceModel`, `Get-HPBIOSVersion` and `New-HPDriverPack`, so HP vendor commands need a `HPKit` noun prefix to avoid colliding with the library the builder imports.

**Primary recommendation:** Build `Test-Kit.ps1` first, with pinned tools in a gitignored `.tools/`, gitleaks before lint and tests, and the PSModulePath reset. Then move the code with `git mv` into `kit/core`, `kit/vendors/hp` and `builder/vendors/hp`, keeping the suite green after every move. Fix D-06 by implementing the two functions in the HP target module and adding `-LogPath` with a transcript in `try/finally`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Repo layout and USB-copyability
- **D-01:** Two top-level code areas split by where code runs. `kit/` is everything that runs on the target laptop and IS the Tools stick content: copied verbatim to USB and runs identically in the repo and on the stick. `builder/` is PC-only code (HPCMSL, ISO servicing, Publish-Sticks) and is never copied to a stick. — **Reversibility:** costly — every path, test and doc depends on this split.
- **D-02:** Structure:
  ```text
  README.md            "Start here": 3 commands only
  Build.cmd            PC: one command builds/publishes the sticks
  kit/
    Run.cmd, Run.ps1   laptop: the ONE command (Assess/Deploy menu; -Mode also works)
    core/              shared vendor-neutral module (only copy; builder imports it too)
    vendors/hp/        laptop-side HP code + vendor.psd1 descriptor
    profiles/hp/       840-g5.psd1, 840-g6.psd1
    config.example.psd1
  builder/
    Build.ps1, Publish-Sticks.ps1, iso/ (ISO servicing)
    vendors/hp/        HPCMSL build-side code
  tests/  docs/
  staging/             gitignored build output
  ```
- **D-03:** Scripts locate modules relative to `$PSScriptRoot`, never absolute paths, so repo and USB behave identically. `Run.cmd` starts Windows PowerShell 5.1 with the right execution policy so the operator types one command.
- **D-04:** DRY: shared code has one copy in `kit/core`. The installer is no longer copied into every package; packages under `staging/` hold data only (Drivers/, Firmware/, manifest.json), no scripts.
- **D-05:** The old flat `src/` scripts are renamed vendor-neutral, with vendor as a parameter (e.g. `Build-DriverBaseline -Vendor HP`). README and docs commands are updated to match. Existing `HPDriverBaseline.psm1` is split: `New-WindowsInstallIso` and `Select-InstallImage` go to core/ISO servicing; `Select-OsRelease`, `Select-BaselineSoftpaq`, `Split-SoftpaqCommand`, `ConvertTo-ReturnCodeMap` go to the HP vendor code.
- **D-06:** Known defects fixed in this phase (needed for green tests): the installer lacks the `-LogPath` parameter the ISO's unattend passes; tests reference `ConvertTo-HPBiosVersion` and `Get-FirmwareSkipReason`, which do not exist, so implement them in the HP laptop-side module. The firmware-timing redesign (firmware flashed in the specialize pass) is NOT done here; it belongs to Phases 2, 4 and 5.

#### Vendor interface
- **D-07:** Each vendor declares its interface with a data-only descriptor `vendor.psd1` mapping operation names to command names. No PowerShell classes, no naming convention.
- **D-08:** Contract = six required operations (ListModels, GetVendorPack, NewCustomPack, GetFirmware, InstallDrivers, InstallFirmware) plus two required helpers (GetDeviceIdentity, GetInstalledFirmwareVersion). Build-plane operations live in `builder/vendors/<v>/`, target-plane ones in `kit/vendors/<v>/`.
- **D-09:** The Pester contract test checks that every mapped command exists AND has the agreed parameter names. A negative test uses a fixture vendor missing one operation and must fail, as success criterion 1 requires.

#### Profiles and output
- **D-10:** One standalone `.psd1` per model under `kit/profiles/hp/` (840-g5, 840-g6), no shared base file. Each carries platform ID, expected BIOS defaults, firmware minimum, pack selection data and excludes.
- **D-11:** G5/G6 values not yet confirmed on hardware (BIOS defaults, firmware minimums) get best-known research values plus a `Verified = $false` flag. A test fails loudly if later code relies on an unverified value. Research platform IDs: G5 = 83B2 (Q78 BIOS family), G6 = 8549 (R70 BIOS family).
- **D-12:** Build output goes to `staging/<vendor>/<model>/<os>-<release>/` (repo-relative, gitignored; replaces `HP_Staging/`). `-OutputRoot` can override it.

#### Quality and secret gates
- **D-13:** Gates run as a local pre-commit hook only (no GitHub Actions CI). Accepted trade-off: hooks can be bypassed with `--no-verify`.
- **D-14:** One script, `Test-Kit.ps1`, runs Pester 5+, PSScriptAnalyzer (zero findings, zero suppressions) and gitleaks under Windows PowerShell 5.1. `-InstallHook` installs the pre-commit hook; a switch scans full history for success criterion 4.
- **D-15:** Real config lives in `kit/config.local.psd1` (gitignored), beside `Run.cmd`, so it travels with the Tools stick and is found the same way in the repo and on USB. Parameters override it. The committed `kit/config.example.psd1` documents the schema (Atera settings only).

### Claude's Discretion
- Exact module/function names, parameter names beyond what the contract test pins, and internal file organisation within `core/` and each vendor folder.
- Pester and PSScriptAnalyzer version pinning (research: Pester 6.2.0 for PS 5.1, PSScriptAnalyzer 1.25.0, gitleaks v8.30.1) and how gitleaks is installed.
- How `Run.cmd` elevates and handles execution policy, within D-03.
- Handling of the existing `HP_Staging/` folder and gitignore updates.

### Deferred Ideas (OUT OF SCOPE)
- GitHub Actions CI as a backstop to the local hook: not wanted now. Revisit if hook bypass becomes a problem.
- Firmware-timing redesign of the unattend specialize pass: Phases 2, 4 and 5.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REPO-01 | Shared, vendor-neutral code in one common module; vendor code in per-vendor modules | Module layout (Architecture Patterns), D-05 split map, relative-import pattern (Pattern 1) |
| REPO-02 | Each vendor module implements one interface (6 ops) | Contract table + `vendor.psd1` (Pattern 2), HPCMSL name-collision finding, stub rules for ops landing in later phases |
| REPO-03 | Pester contract tests check the full interface | Data-driven contract test + parameterized-container negative proof, verified exit 0/1 (Pattern 3) |
| REPO-04 | Build output in separate per-vendor/model folders | `Get-KitPackagePath` pure function, `staging/` gitignore, current path code quoted (Pattern 5) |
| REPO-05 | G5/G6 profiles carry platform ID, BIOS defaults, firmware minimum, pack selection | Profile schema with `Verified` blocks and accessor guard (Pattern 4); G6 BIOS 01.36.00 verified from staged manifest; G5 Q78 01.31.00 cited |
| REPO-06 | Tests under Pester 5+ on PS 5.1; PSScriptAnalyzer clean, no suppressions | Measured baseline (20/8 and 13 findings), Pester 6 migration traps, PSSA rule traps, settings file (Patterns 6-7) |
| SEC-01 | Repo and history hold no credentials or customer settings | Full-history scan clean (verified); custom Atera rule tested with no false positives on history |
| SEC-02 | Gitignored local config + committed `.example` | `*.local.psd1` already ignored (verified with `git check-ignore`); `Import-PowerShellDataFile` rejects code (verified); image-copy exclusion pitfall |
| SEC-03 | gitleaks pre-commit hook | `core.hooksPath` hook blocks planted token (verified), `--ignore-gitleaks-allow`, LF line-ending trap, PSModulePath trap |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

No `./CLAUDE.md` or `./.claude/CLAUDE.md` exists in the repo (checked this session). `.planning/config.json` points `claude_md_path` at `./.claude/CLAUDE.md`, which is absent. The user's global rules apply and carry the same weight as locked decisions:

- **No lint bypass of any kind:** "NEVER disable or bypass linting rules (e.g. via inline disable comments, ignore annotations, or configuration overrides)". So `PSScriptAnalyzerSettings.psd1` may only *enable* extra rules; it may not use `ExcludeRules`, `Severity` filtering, or `[Diagnostics.CodeAnalysis.SuppressMessage]`. Treat `gitleaks:allow` comments and `.gitleaksignore` entries the same way: do not use them.
- **Pester v6 guidance:** use `*.Tests.ps1`; put all code inside Pester blocks; use `BeforeDiscovery` for test-generation data; keep one hook of each type per block; use `Should -Invoke` (not `Assert-MockCalled`); add a default mock when unmatched calls are valid; avoid an empty `-ForEach`.
- **PowerShell style:** approved Verb-Noun names, singular nouns, `[switch]` never `[bool]`, `SupportsShouldProcess` on state-changing functions, comment-based help on public functions, no aliases, `$PSCmdlet.ThrowTerminatingError` preferred in advanced functions.
- **Commits:** Conventional Commits, subject 50 characters or less, imperative, no AI attribution or emoji. PRs need a detailed body passed with `--body-file`.
- **Docs lookup:** Context7 first for library docs.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Vendor-neutral helpers (ISO servicing, contract check, config load, profile accessor, package path) | `kit/core` module (shared) | builder imports it via relative path | D-04: one copy only; must run offline on stock 5.1 |
| HP target operations (InstallDrivers, InstallFirmware, GetDeviceIdentity, GetInstalledFirmwareVersion, BIOS version parse, firmware skip gate) | `kit/vendors/hp` (target plane) | — | Runs on stock laptop: CIM, pnputil, DISM only, no HPCMSL |
| HP build operations (ListModels, GetVendorPack, NewCustomPack, GetFirmware, softpaq selection) | `builder/vendors/hp` (build plane) | — | Needs HPCMSL and internet; never on a stick |
| Interface definition | `kit/vendors/hp/vendor.psd1` (data) + core contract table | tests | D-07/D-08: data only |
| Per-model data | `kit/profiles/hp/*.psd1` | build and target both read | D-10 |
| Run-time secrets | `kit/config.local.psd1` (gitignored) | parameters override | D-15 |
| Quality and secret gates | `Test-Kit.ps1` + `.githooks/pre-commit` | `.gitleaks.toml`, `PSScriptAnalyzerSettings.psd1` | D-13/D-14 |
| Build output | `staging/<vendor>/<model>/<os>-<release>/` (data only) | — | D-04, D-12 |

## Standard Stack

### Core
| Library / tool | Version | Purpose | Why standard |
|----------------|---------|---------|--------------|
| Windows PowerShell | 5.1 (builder measured 5.1.26100.9549) | All code, both planes | Project constraint [VERIFIED: `$PSVersionTable` this session] |
| Pester | **6.2.0** (PSGallery, published 2026-09-09; newest) | Unit + contract tests | Supports exactly WinPS 5.1 and PS 7.4+ [CITED: pester/docs migrations/v5-to-v6]; ran on 5.1 this session [VERIFIED: local run] |
| PSScriptAnalyzer | **1.25.0** (PSGallery, published 2026-03-20; newest) | Lint, zero findings | Microsoft; ran on 5.1 this session, 75 rules loaded [VERIFIED: local run] |
| gitleaks | **v8.30.1** (GitHub release 2026-03-21; newest) | Pre-commit + full-history secret scan | MIT single binary; `gitleaks git` form [VERIFIED: `gh release list`, local runs] |

### Supporting
| Tool | Version | Purpose | When to use |
|------|---------|---------|-------------|
| git for Windows | 2.55.0.windows.5 (builder) | Hook host (`sh`), `check-ignore` tests | Already installed [VERIFIED: `git --version`] |
| HPCMSL | 1.9.0 | Builder-only HP catalog | Not needed for Phase 1 tests; build module must load **without** it (lazy import) |

### Alternatives Considered
| Instead of | Could use | Tradeoff |
|------------|-----------|----------|
| gitleaks zip pinned by SHA-256 into `.tools/` | `winget install --id Gitleaks.Gitleaks --version 8.30.1 -e` (winget lists 8.30.1) [VERIFIED: `winget show`] | winget is simpler but puts the binary on a shim path a fresh shell may not see, and Test-Kit cannot assert the hash. Recommend the zip; accept winget as a fallback lookup on PATH |
| `pre-commit` Python framework | plain `core.hooksPath` sh hook | The framework needs Python (only the Store stub is present) and adds a second runner; D-14 wants one script |
| `Install-Module -Scope CurrentUser` | `Save-Module` into `.tools/Modules` | The builder's CurrentUser module path is under OneDrive (`C:\Users\ben\OneDrive\Documents\WindowsPowerShell\Modules`) [VERIFIED]. A repo-local `.tools/Modules` avoids sync churn and the inbox Pester 3.4.0 clash |

**Installation (builder, run by `Test-Kit.ps1 -InstallTools`):**
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force   # PowerShellGet 1.0.0.1 needs it
Save-Module -Name Pester -RequiredVersion 6.2.0 -Path .tools\Modules -Repository PSGallery
Save-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Path .tools\Modules -Repository PSGallery
# gitleaks: download gitleaks_8.30.1_windows_x64.zip from the v8.30.1 release, check SHA-256, expand to .tools\gitleaks\
```
Pinned gitleaks archive hash (`gitleaks_8.30.1_windows_x64.zip`): `d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e` [VERIFIED: matched the release's `gitleaks_8.30.1_checksums.txt` and a local `sha256sum` this session].

**Version verification:** `Find-PSResource` this session returned Pester 6.2.0 (2026-09-09), 6.1.0, 6.0.1, 6.0.0 and PSScriptAnalyzer 1.25.0 (2026-03-20), 1.24.0. `gh release list -R gitleaks/gitleaks` returned v8.30.1 as Latest (2026-03-21) [VERIFIED].

The builder today has only inbox **Pester 3.4.0**, no PSScriptAnalyzer and no gitleaks, and PowerShellGet/PackageManagement are 1.0.0.1 [VERIFIED: `Get-Module -ListAvailable`].

## Package Legitimacy Audit

The `package-legitimacy` seam supports only npm/pypi/crates (it returned a usage error for `psgallery`), so the check was done by hand:

| Package | Registry | Age | Downloads | Source repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| Pester 6.2.0 | PSGallery | project since 2011; 6.x since 2026-07 | not measured (ships inbox in Windows as 3.4.0) | github.com/Pester/Pester (Author "Pester Team") | OK (manual) | Approved |
| PSScriptAnalyzer 1.25.0 | PSGallery | 1.x since 2015 | not measured | github.com/PowerShell/PSScriptAnalyzer (Author "Microsoft Corporation") | OK (manual) | Approved |
| gitleaks 8.30.1 | GitHub releases / winget `Gitleaks.Gitleaks` | since 2018 | not measured | github.com/gitleaks/gitleaks (MIT) | OK (manual) | Approved, pinned by SHA-256 |

Project URIs and authors came from `Find-PSResource` metadata; docs came from Context7 `/pester/docs`, `/powershell/psscriptanalyzer` and `/gitleaks/gitleaks` (official org repos) [VERIFIED].
**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```text
 Operator / developer
   |                                   |                                     |
   | Run.cmd (stick or repo)           | builder\*.ps1 (PC)                   | git commit
   v                                   v                                     v
 cmd: clear PSModulePath            Import core (..\kit\core)            .githooks/pre-commit (sh)
   -> powershell.exe 5.1              + builder\vendors\hp (lazy HPCMSL)    -> env -u PSModulePath
      -ExecutionPolicy Bypass          |                                     powershell.exe Test-Kit.ps1 -PreCommit
   v                                   v                                        |
 Run.ps1: self-elevate if needed    Load profile kit\profiles\hp\<m>.psd1        1. gitleaks git --pre-commit --staged
   -> Import kit\core                  (Import-PowerShellDataFile)                  (fail -> exit 1, commit blocked)
   -> Resolve vendor from              |                                         2. PSScriptAnalyzer (kit, builder, tests, root)
      kit\vendors\*\vendor.psd1        v                                            (any finding -> exit 1)
      (Manufacturer regex)           Contract op via descriptor                  3. Pester 6.2.0 (tests\)
   -> Load kit\config.local.psd1      (NewCustomPack / GetFirmware ...)             (any failure -> exit 1)
      (optional; params override)      |                                        Test-Kit.ps1 -ScanHistory
   v                                   v                                          -> gitleaks git --log-opts=--all
 Target op via descriptor           staging\hp\<model>\<os>-<rel>\
 (InstallDrivers / Audit ...)        manifest.json, Drivers\, Firmware\  (data only, no scripts)
                                       |
                                       v
                                    builder\iso\New-BaselineIso.ps1 -> copies kit code (minus config.local) into image
```

### Recommended Project Structure

```text
.gitattributes              *.cmd eol=crlf, .githooks/* eol=lf (see Pitfall 6)
.gitignore                  + staging/, .tools/ (keep HP_Staging/, *.local.psd1, results/)
.gitleaks.toml              [extend] useDefault + Atera rule
.githooks/pre-commit        sh, calls Test-Kit.ps1 -PreCommit
PSScriptAnalyzerSettings.psd1   enables extra rules only
Test-Kit.ps1                gates (D-14)
Build.cmd                   PC entry (Phase 2 fills in the master build; Phase 1 may stub or omit)
README.md
kit/
  Run.cmd  Run.ps1
  Install-DriverBaseline.ps1     was src/Install-HPDriverBaseline.ps1 (+ -LogPath, -Vendor)
  Test-DeviceBaseline.ps1        audit; stays self-contained for irm | iex (see Open Question 1)
  config.example.psd1
  core/
    Kit.Core.psd1  Kit.Core.psm1   (manifest with explicit FunctionsToExport)
    IsoServicing.ps1               New-WindowsInstallIso, Select-InstallImage
    VendorContract.psd1            operation -> plane + required parameter names (data)
    Vendor.ps1                     Get-KitVendor, Test-KitVendorContract, Invoke-KitVendorCommand
    Profile.ps1                    Get-KitProfile, Get-KitVerifiedValue
    Config.ps1                     Get-KitConfig
    Paths.ps1                      Get-KitPackagePath, Get-KitRoot
  vendors/hp/
    vendor.psd1
    HP.Target.psm1                 ConvertTo-HPBiosVersion, Get-FirmwareSkipReason, Install-HPKit*, Get-HPKit*
  profiles/hp/
    840-g5.psd1  840-g6.psd1
builder/
  Build-DriverBaseline.ps1       was src/Build-HPDriverBaseline.ps1 (-Vendor HP -Model 840-g6)
  iso/New-BaselineIso.ps1        was src/New-HPBaselineIso.ps1
  vendors/hp/HP.Build.psm1       Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap + build ops
tests/
  Core.Tests.ps1  HP.Build.Tests.ps1  HP.Target.Tests.ps1  Contract.Tests.ps1
  Profiles.Tests.ps1  Repo.Tests.ps1 (gitignore, hook proof, no stray scripts)
  fixtures/vendors/missing-op/vendor.psd1 + Missing.Target.psm1
staging/                         gitignored
```
File names inside `core/` and the vendor folders are Claude's discretion. The `.ps1`-per-concern files can be dot-sourced by `Kit.Core.psm1`.

### Pattern 1: Relative imports that work in repo and on USB (D-03)
**What:** Every entry script resolves modules from `$PSScriptRoot`. The builder reaches into `..\kit\core`.
```powershell
# kit/Run.ps1 and kit/Install-DriverBaseline.ps1
Import-Module (Join-Path $PSScriptRoot 'core\Kit.Core.psd1') -Force
# builder/Build-DriverBaseline.ps1
Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'vendors\hp\HP.Build.psm1') -Force
```
`$PSScriptRoot` works for paths with spaces when launched via `Run.cmd` [VERIFIED: prototype in a `cmd test` folder printed the correct root]. Under `irm | iex` there is no `$PSScriptRoot` (Phase 7 concern; see Open Question 1).

### Pattern 2: Data-only descriptor + contract table in core (D-07/D-08)
```powershell
# kit/vendors/hp/vendor.psd1   (data only; command names are Claude's discretion)
@{
    Name         = 'HP'
    Manufacturer = '^(HP|Hewlett-Packard)\b'
    TargetModule = 'HP.Target.psm1'                 # relative to this folder (kit/vendors/hp)
    BuildModule  = 'HP.Build.psm1'                  # relative to builder/vendors/hp (absent on a stick)
    Commands     = @{
        ListModels                  = 'Get-HPKitModel'
        GetVendorPack               = 'Save-HPKitVendorPack'
        NewCustomPack               = 'New-HPKitCustomPack'
        GetFirmware                 = 'Save-HPKitFirmware'
        InstallDrivers              = 'Install-HPKitDriver'
        InstallFirmware             = 'Install-HPKitFirmware'
        GetDeviceIdentity           = 'Get-HPKitDeviceIdentity'
        GetInstalledFirmwareVersion = 'Get-HPKitInstalledFirmware'
    }
}
```
```powershell
# kit/core/VendorContract.psd1   (pinned names the contract test enforces; recommended values)
@{
    ListModels                  = @{ Plane = 'Build';  Parameters = @() }
    GetVendorPack               = @{ Plane = 'Build';  Parameters = @('ModelProfile', 'OsVer', 'OutputPath') }
    NewCustomPack               = @{ Plane = 'Build';  Parameters = @('ModelProfile', 'OsVer', 'OutputPath') }
    GetFirmware                 = @{ Plane = 'Build';  Parameters = @('ModelProfile', 'OutputPath') }
    InstallDrivers              = @{ Plane = 'Target'; Parameters = @('PackagePath', 'OfflineImagePath') }
    InstallFirmware             = @{ Plane = 'Target'; Parameters = @('PackagePath') }
    GetDeviceIdentity           = @{ Plane = 'Target'; Parameters = @() }
    GetInstalledFirmwareVersion = @{ Plane = 'Target'; Parameters = @() }
}
```
- The command names above were checked against the commands HPCMSL 1.9.0 exports (250 commands across 14 of its 15 sub-modules). None collide. In contrast, `Get-HPDeviceModel`, `Get-HPBIOSVersion` and `New-HPDriverPack` **do** exist in HPCMSL [VERIFIED: `Find-PSResource ... .Includes.Command`].
- Do **not** name a parameter `Profile`: PSSA raises `PSAvoidAssignmentToAutomaticVariable` for `$Profile` [VERIFIED: probe]. Use `ModelProfile`.
- `GetVendorPack` is BUILD-03 (Phase 4). The Phase 1 command must exist with the pinned parameters and **use** them, or PSSA raises `PSReviewUnusedParameter` [VERIFIED: probe]. Example: `throw [System.NotImplementedException]::new("GetVendorPack for $($ModelProfile.ModelId) $OsVer -> $OutputPath arrives in Phase 4.")` (verified clean).
- `HP.Build.psm1` must import HPCMSL **inside** functions (the existing `Initialize-HPCMSL` pattern), never through `#Requires -Modules HPCMSL` or a top-level `Import-Module`. Otherwise the contract test cannot import it offline.

### Pattern 3: Contract test, data-driven, with a negative proof (D-09, criterion 1)
- Put the logic in core, `Test-KitVendorContract -DescriptorPath <path> [-Plane Build,Target]`. It returns violation objects (`MissingOperation`, `CommandNotFound`, `MissingParameter`), so tests can assert exact violations.
- `tests/Contract.Tests.ps1` takes `param([string]$VendorRoot)`. It uses `BeforeDiscovery` to enumerate `vendor.psd1` files under the root (default `kit/vendors`) and runs `Describe 'Vendor <Name>' -ForEach $vendors`, with one `It` per operation.
- Negative "any of the six" proof: in `TestDrive`, clone the HP descriptor six times, each without one operation, and assert that `Test-KitVendorContract` reports exactly that operation (`It -ForEach` over the six names).
- Criterion 1 proof ("a Pester contract test ... fails"): run the contract test file against `tests/fixtures/vendors/missing-op` in a **child** `powershell.exe` and assert exit code 1. The prototype gave exit 0 for a complete vendor and exit 1 for a vendor missing `InstallDrivers` [VERIFIED: local run]. Running two `Invoke-Pester` calls in one session with `Run.Container` picked up stray `*.Tests.ps1` files from the current directory in the prototype, so isolate the nested run in its own process.
```powershell
# Verified prototype shape (Pester 6.2.0, PS 5.1)
$c = New-PesterConfiguration
$c.Run.Container = New-PesterContainer -Path $contractTests -Data @{ VendorRoot = $fixtureRoot }
$c.Run.Exit = $true            # process exit code = failure state
$c.Output.Verbosity = 'None'
Invoke-Pester -Configuration $c
```
Parameter check: `(Get-Command -Name $cmd -Module $mod.Name).Parameters.Keys | Should -Contain $p` [VERIFIED: prototype].

### Pattern 4: Profile schema with Verified blocks + guarded accessor (D-10/D-11)
Extend the existing keys; do not replace them. The existing build script reads `Platform`, `Os`, `OsVer`, `DriverExclude` and `FirmwareExclude` at the top level [VERIFIED: src/Build-HPDriverBaseline.ps1:99-105, 122, 137]. Existing profile, verbatim [VERIFIED: src/profiles/hp-elitebook-840-g6.psd1:7-18]:
```text
    Name            = 'HP EliteBook 840 G6'
    Platform        = '8549'
    Os              = 'win11'
    OsVer           = ''
    DriverExclude   = @(
        'AMD Video'
        'DisplayLink'
        'Hotkey Support'
    )
    FirmwareExclude = @()
```
(inline comments omitted from the quote). Recommended G6 profile:
```powershell
# kit/profiles/hp/840-g6.psd1
@{
    SchemaVersion   = 1
    Vendor          = 'HP'
    ModelId         = '840-g6'
    Name            = 'HP EliteBook 840 G6'
    Platform        = '8549'
    BiosFamily      = 'R70'
    Os              = 'win11'
    OsVer           = ''
    DriverExclude   = @('AMD Video', 'DisplayLink', 'Hotkey Support')
    FirmwareExclude = @()
    PackSelection   = @{ Preferred = 'Custom'; Allowed = @('Custom', 'Vendor') }
    FirmwareMinimum = @{
        Version  = '01.36.00'; SoftPaq = 'sp174025'
        Verified = $false
        Source   = 'HP_Staging/8549-win11-24H2/manifest.json built 2026-09-28 (HPCMSL 1.9.0); not bench-checked'
    }
    BiosDefaults    = @{
        Settings = @{ 'Secure Boot' = 'Enable'; 'TPM Device' = 'Available'; 'TPM State' = 'Enable' }
        Verified = $false
        Source   = 'Best-known values; setting names and values unconfirmed on hardware'
    }
}
```
- G6 BIOS: the staged package manifest lists `sp174025 HP BIOS and System Firmware (R70) 1.36.00 BIOS - System Firmware` [VERIFIED: read `HP_Staging/8549-win11-24H2/manifest.json` this session].
- G5: `Platform = '83B2'`, `BiosFamily = 'Q78'`, `FirmwareMinimum.Version = '01.31.00'`, `SoftPaq = 'sp157750'` [CITED: ftp.hp.com sp157750.html: "HP Firmware Pack (Q78)", "01.31.00 REV: A PASS: 1", April 30, 2025, lists "HP EliteBook 840 G5 Notebook PC"]. The page does **not** state the platform ID. 83B2 rests on a third-party driver table and a forum BIOS dump, so mark it `PlatformVerified = $false` as well.
- BIOS default setting names and values are [ASSUMED] for both models (see the Assumptions Log). Pick names that match `Get-HPBIOSSettingsList` output once someone runs it on a real unit (Phase 6, VERIFY-02).
- Guard (D-11): `Get-KitVerifiedValue -ModelProfile $p -Name FirmwareMinimum` throws `"<Name> for <ModelId> is unverified (Verified = `$false); confirm on hardware first"` unless `-AllowUnverified`. Two tests: (1) the accessor throws for `Verified = $false`. (2) A static AST scan of `kit/` and `builder/` fails if any code reads `.FirmwareMinimum` or `.BiosDefaults` outside `Profile.ps1`. Rule (2) is what makes "later code relies on an unverified value" fail loudly.
- Load profiles with `Import-PowerShellDataFile`. It refuses commands inside a `.psd1` and keeps `$false` as `[bool]` [VERIFIED: probe rejected `(Get-Date)`; `$false` returned `Boolean`].

### Pattern 5: Per-vendor/model output path (D-12, REPO-04)
Current code, verbatim [VERIFIED: src/Build-HPDriverBaseline.ps1:46 and :103]:
```text
    [string]$OutputRoot = 'C:\HP_Staging',
$packageDir = Join-Path $OutputRoot ('{0}-{1}-{2}' -f $baseline.Platform, $baseline.Os, $osRelease)
```
Replace both with a pure core function that is unit-tested offline:
```powershell
function Get-KitPackagePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Vendor,
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][string]$Os,
        [Parameter(Mandatory)][string]$OsVer
    )
    Join-Path $OutputRoot (Join-Path $Vendor.ToLowerInvariant() (Join-Path $ModelId ('{0}-{1}' -f $Os, $OsVer)))
}
# default: $OutputRoot = Join-Path $PSScriptRoot '..\staging'   ->  staging\hp\840-g6\win11-24H2
```
The New-BaselineIso default (`'C:\HP_Staging\8549-win11-24H2'`, `'C:\HP_Staging\IsoBuild'`) [VERIFIED: src/New-HPBaselineIso.ps1:68, :74] moves to the same scheme. Test: G5 and G6 paths differ, and both sit under `<root>\hp\`.

### Pattern 6: Lint that passes with zero findings and zero suppressions (REPO-06)
```powershell
# PSScriptAnalyzerSettings.psd1   (enables only; no ExcludeRules, no Severity filter)
@{
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
    }
}
```
- Run under **Windows PowerShell 5.1**, not pwsh. On 5.1, PS 7-only syntax such as `??` already appears as a `ParseError` finding [VERIFIED: probe].
- Do **not** enable `PSUseCompatibleCommands` on `tests/`. With the 5.1 profile it flagged 40 findings in `HPDriverBaseline.Tests.ps1` ("The parameter 'Be' is not available for command 'Should'"), because the profile captures inbox Pester 3.4 [VERIFIED: probe]. Enabling it on `kit/` alone would be an extra check. Not enabling an optional rule is not a suppression, but keep one settings file to stay simple.
- Lint scope: pass `kit`, `builder`, `tests` and the root `*.ps1` explicitly, never `-Path .`. A repo-root recursive walk would lint `.tools/Modules` (Pester's own source) and `HP_Staging/` (holds copies of `Install-HPDriverBaseline.ps1` and `Test-DeviceBaseline.ps1`) [VERIFIED: `find HP_Staging -iname *.ps1`]. Add a `Repo.Tests.ps1` check that every tracked `*.ps1`/`*.psm1`/`*.psd1` lies under a linted path. Today the only tracked scripts under `.claude/` are `.sh` files [VERIFIED: `git ls-files`].
- Rule traps verified this session:

| Rule | Trigger | Fix |
|------|---------|-----|
| `PSAvoidUsingWriteHost` | `Write-Host` anywhere except inside a `Show-*` function | Put coloured output in e.g. `Show-AuditLine` (verified: no finding inside `Show-KitLine`, finding inside `Write-KitLine`) |
| `PSReviewUnusedParameter` | Stub parameters never read | Reference them (e.g. in the NotImplemented message) |
| `PSAvoidAssignmentToAutomaticVariable` | A parameter named `$Profile` | `ModelProfile` |
| `PSUseSingularNouns` | `Get-HPModels` | `Get-HPKitModel` |
| `PSUseShouldProcessForStateChangingFunctions` | `New-*` (also `Set/Remove/Start/Stop/Restart/Reset/Update`) without `SupportsShouldProcess` | `[CmdletBinding(SupportsShouldProcess)]` + `$PSCmdlet.ShouldProcess` |
| `PSUseOutputTypeCorrectly` (Information) | Advanced function returns a known type not in `[OutputType()]` | Declare `[OutputType([string])]` etc. |
| `PSUseDeclaredVarsMoreThanAssignments` | Plain `$x = ...` in Pester `BeforeAll`, used in `It` | Keep the existing `$script:` prefix convention (verified: `$script:scoped` clean, `$plain` flagged) |

### Pattern 7: Pester 6 migration of the existing suite
Baseline under Pester 6.2.0 / PS 5.1: **20 passed, 8 failed**. All failures are `CommandNotFoundException` for `ConvertTo-HPBiosVersion` and `Get-FirmwareSkipReason` [VERIFIED: local run]. When moving tests to `tests/`:
- Import modules by relative path (`Join-Path $PSScriptRoot '..\kit\vendors\hp\HP.Target.psm1'`) instead of AST extraction, because the functions now live in a module.
- Every `Mock Get-CimInstance` must add `-ModuleName HP.Target` (and so must `Should -Invoke`). Otherwise the call from inside the module is not intercepted [CITED: pester/docs usage/modules.mdx "Mock and Should-Invoke must use the same -ModuleName"].
- Pester 6 no longer falls through on unmatched `-ParameterFilter`. The existing `-ParameterFilter { $ClassName -eq 'Win32_BIOS' }` mock means `Get-FirmwareSkipReason` must call **only** `Get-CimInstance -ClassName Win32_BIOS` for BIOS items and **only** `Win32_PnPEntity` for device items. Any other CIM call throws "no default mock to fall back to" [CITED: pester/docs migrations/v5-to-v6]. Add a default `Mock Get-CimInstance { throw "unexpected CIM call $ClassName" }` so drift fails with a clear message.
- Keep the AST technique for standalone scripts (the `New-BaselineIso` answer-file test, the installer `param()` check).
- Pin the version explicitly: `Import-Module <.tools path>\Pester\6.2.0\Pester.psd1` (or `-RequiredVersion 6.2.0`) **before** `Invoke-Pester`. With only autoload, 5.1 picks inbox 3.4.0 on this builder [VERIFIED: 3.4.0 is the only installed Pester].

### Pattern 8: D-06 defect fixes
**Installer `param()` today, verbatim** [VERIFIED: src/Install-HPDriverBaseline.ps1:22-32]:
```text
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('Path', 'ImagePath')]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$OfflineImagePath,

    [switch]$SkipFirmware,

    # Apply even if the board's platform ID does not match the manifest.
    [switch]$Force
)
```
**Answer-file command today, verbatim** [VERIFIED: src/New-HPBaselineIso.ps1:137]:
```text
          <Path>cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File %SystemDrive%\HP\Baseline\Install-HPDriverBaseline.ps1 -LogPath %SystemDrive%\HP\Baseline\firstboot.log</Path>
```
The existing test only asserts `BeLike '*Install-HPDriverBaseline.ps1 -LogPath*'` [VERIFIED: src/HPDriverBaseline.Tests.ps1:180], which is why it passes while the run would fail binding.

Fix pattern (transcript closes even on `exit`):
```powershell
param(
    # ...existing parameters...
    [string]$LogPath
)
if ($LogPath) { $null = Start-Transcript -Path $LogPath -Append }
try {
    # existing body, including its `exit [int]($script:failures -gt 0)` lines
}
finally {
    if ($LogPath) { $null = Stop-Transcript }
}
```
[VERIFIED: probe on 5.1. `exit 1` inside `try` ran `finally`, the transcript held the output and an "End time" footer, and the process exit code stayed 1.] New test: parse the answer-file `<Path>`, take each `-Name` token after the `.ps1`, and assert it is in the installer's `ParamBlock.Parameters` names (AST). That catches the defect class rather than a string.

**Missing functions** (go in `kit/vendors/hp/HP.Target.psm1`). Contract from the tests, verbatim [VERIFIED: src/HPDriverBaseline.Tests.ps1:132-133, 140-145, 152, 164]:
```text
$script:bios = [pscustomobject]@{ Id = 'sp174025'; Name = 'HP BIOS and System Firmware (R70)'; Version = '1.36.00'; Category = 'BIOS - System Firmware'; Devices = @() }
$script:ssd = [pscustomobject]@{ Id = 'sp149654'; Name = 'Samsung SSD Firmware update'; Version = 'HPS8NFXV'; Category = 'Firmware'; Devices = @('PCI\VEN_144D&DEV_A809&SUBSYS_A809144D') }
$installed = ConvertTo-HPBiosVersion 'R70 Ver. 01.36.00'
$package = ConvertTo-HPBiosVersion 'HP BIOS and System Firmware (R70) 1.36.00'
$installed.Family | Should -Be 'R70'
$installed.Version | Should -Be ([version]'1.36.0')
$package.Version | Should -Be $installed.Version
ConvertTo-HPBiosVersion 'unknown' | Should -BeNullOrEmpty
Get-FirmwareSkipReason $bios | Should -BeLike '*already current*'
Get-FirmwareSkipReason $ssd | Should -Be 'no matching device in this PC'
```
Behaviour the tests require:
- `ConvertTo-HPBiosVersion` takes one positional string and returns `{ Family; Version }`, or `$null` when it cannot parse.
- `Get-FirmwareSkipReason` takes one positional firmware entry.
  - BIOS entry (`Category -like 'BIOS*'`): same family and installed version greater than or equal to the package version gives a string containing "already current". An older version, unparseable text or another family (`S70`) gives `$null`.
  - Device-specific entry: none of `Devices` present in any `Win32_PnPEntity.HardwareID` gives exactly `'no matching device in this PC'`. A match gives `$null`.

Illustrative parser, unverified until the tests run [ASSUMED]:
```powershell
function ConvertTo-HPBiosVersion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)
    if ($Text -match '\b(?<family>[A-Z]\d{2})\b.*?(?<ver>\d{1,2}\.\d{2}\.\d{2})') {
        [pscustomobject]@{ Family = $Matches.family; Version = [version]$Matches.ver }
    }
}
```
`[version]'01.36.00'` equals `[version]'1.36.0'` (Major 1, Minor 36, Build 0) [ASSUMED; the test will prove it].

Wire it up: `GetInstalledFirmwareVersion` (`Get-HPKitInstalledFirmware`) = `ConvertTo-HPBiosVersion (Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion`, and the installer's firmware loop calls `Get-FirmwareSkipReason` before each item.

### Pattern 9: Run.cmd launching Windows PowerShell 5.1 (D-03)
Verified prototype (CRLF file, path with a space, launched from a pwsh parent):
```bat
@echo off
setlocal
rem A parent PowerShell 7 session leaks its module paths; Windows PowerShell 5.1 rebuilds the default when this is empty.
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run.ps1" %*
exit /b %ERRORLEVEL%
```
Result: `PS=5.1.26100.9549 Edition=Desktop Mode=Deploy`, `$PSScriptRoot` correct, `Get-ExecutionPolicy` = Bypass at Process scope, and the script's `exit 3` came back as the cmd exit code. Without the `set "PSModulePath="` line the same launch failed with "The 'Get-ExecutionPolicy' command was found in the module 'Microsoft.PowerShell.Security', but the module could not be loaded" [VERIFIED: both runs this session].
- Stock Windows clients default to **Restricted**. `-ExecutionPolicy` sets the Process scope, which beats CurrentUser/LocalMachine but **not** a Group Policy `MachinePolicy`/`UserPolicy`. Bypass also skips the downloaded-file (Mark of the Web) zone check [CITED: learn.microsoft.com about_Execution_Policies, 5.1].
- Elevation: do it in `Run.ps1`, not cmd. Check `WindowsPrincipal.IsInRole(Administrator)` and, if not admin, `Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList` with `-NoProfile -ExecutionPolicy Bypass -File "<this script>"` plus the original bound parameters, then `exit`. Quoting arguments through cmd for `RunAs` is fragile. The relaunch logic is [ASSUMED] (UAC cannot be exercised non-interactively here) and needs one manual check.
- Phase 1 `Run.ps1` scope: the Assess/Deploy menu is PROV-01 (Phase 3). For Phase 1 a thin `-Mode` dispatcher is enough: `Audit` runs `Test-DeviceBaseline.ps1`, and `Install` runs `Install-DriverBaseline.ps1` against a package path. Keep the menu out.

### Pattern 10: gitleaks gate (SEC-01/SEC-03, criterion 4)
```sh
#!/bin/sh
# .githooks/pre-commit  (LF line endings; enabled by: git config core.hooksPath .githooks)
root=$(git rev-parse --show-toplevel) || exit 1
exec env -u PSModulePath powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$root/Test-Kit.ps1" -PreCommit
```
`Test-Kit.ps1 -PreCommit` runs, in this order:
1. `gitleaks git --pre-commit --staged --redact --no-banner --ignore-gitleaks-allow -c <root>\.gitleaks.toml <root>`. On a non-zero exit, print red and `exit 1` **before** loading Pester. That also prevents recursion when the hook-proof test commits in a temp repo.
2. PSScriptAnalyzer.
3. Pester.

`Test-Kit.ps1 -ScanHistory` runs `gitleaks git --redact --no-banner --log-opts="--all" -c <root>\.gitleaks.toml <root>`.

Verified this session:
- A temp repo with this hook style (gitleaks called directly) let a clean commit through and blocked a commit holding a runtime-generated GitHub-style token (`commit exit=1`, no new commit in `git log`). It also blocked the same token carrying an inline `gitleaks:allow` comment, thanks to `--ignore-gitleaks-allow`.
- `env -u PSModulePath` lets 5.1 start cleanly even when the parent exported PS 7's module path [VERIFIED].
- Full history of this repo with `--log-opts="--all"` gave 19 commits scanned and no leaks. Merge commits carry no patch, so 21 revs gave 19 scanned [VERIFIED].
- Config lookup is `--config`, then `GITLEAKS_CONFIG`, then `GITLEAKS_CONFIG_TOML`, then `(target path)/.gitleaks.toml`. Scanning a subfolder silently used default rules until `-c` was passed [VERIFIED: help text + probe].

```toml
# .gitleaks.toml
title = "enterprise-workstation-staging"

[extend]
useDefault = true

[[rules]]
id = "atera-agent-link"
description = "Atera agent installer link or MSI properties carrying a real value"
regex = '''(?i)(?:accountId|IntegratorLogin|customerId)\s*[=:]\s*['"]?([A-Za-z0-9%@._-]{6,})'''
secretGroup = 1
keywords = ["accountid", "integratorlogin", "customerid"]
```
This rule caught a realistic fake Atera link (account id and percent-encoded login, also decoded). It reported nothing on this repo's full history, including `.planning/` docs that mention these property names [VERIFIED: probe + history scan]. Keep `config.example.psd1` values **empty** (`''`) so the rule needs no allowlist. Do not add `[[allowlists]]`, `.gitleaksignore` or `gitleaks:allow`. Property names are [ASSUMED] (see A4).

**Hook-proof Pester test (criterion 4):**
1. In `TestDrive`, `git init` and set `user.name`/`user.email`.
2. Copy `Test-Kit.ps1`, `.gitleaks.toml` and `.githooks/`, then `git config core.hooksPath .githooks`.
3. Write a file whose token is **built at run time** (`'gh' + 'p_' + random 36 alphanumerics`). A literal token in the test file would trip the repo's own scan.
4. `git add` and `git commit`, then assert `$LASTEXITCODE -ne 0` and that `git rev-parse --verify HEAD` fails (no commit created).

Let Test-Kit find gitleaks through `$env:KIT_GITLEAKS`, then `<root>\.tools\gitleaks\gitleaks.exe`, then PATH, so the temp-repo copy finds the binary.

### Pattern 11: Run-time config (D-15, SEC-02, criterion 5)
```powershell
# kit/config.example.psd1   (committed; copy to config.local.psd1 and fill in)
@{
    Atera = @{
        # Agent download link from Atera (Devices > Download installer). Leave empty to skip Atera.
        InstallerUrl    = ''
        # MSI properties, if you install from a saved MSI instead of the link.
        IntegratorLogin = ''
        CustomerId      = ''
        AccountId       = ''
    }
}
```
- `kit/config.local.psd1` is **already** ignored: `.gitignore:24:*.local.psd1` [VERIFIED: `git check-ignore -v --no-index kit/config.local.psd1` exit 0], and `kit/config.example.psd1` is not ignored (exit 1). Criterion-5 test: run both `check-ignore` calls from Pester.
- `Get-KitConfig -Root $kitRoot [-Override <hashtable>]`: if `config.local.psd1` exists, load it with `Import-PowerShellDataFile`, then let non-null parameters win. A missing file gives an empty config, and later stages treat that as "Atera skipped" (yellow).
- Schema test: the keys in `config.example.psd1` equal the keys `Get-KitConfig` documents, and every value in the example is `''`.

### Anti-Patterns to Avoid
- **Copying `kit/` wholesale into the ISO/image:** `kit/config.local.psd1` (Atera secrets) would land in the image. The ISO builder must copy an explicit allow-list (`core/`, `vendors/<v>/`, `profiles/<v>/`, the installer) or exclude `*.local.psd1`, with a test.
- **Copying the installer into each staging package:** D-04 forbids it and it caused the drift behind D-06. Today `Build-HPDriverBaseline.ps1:171` does `Copy-Item -Path (Join-Path $PSScriptRoot 'Install-HPDriverBaseline.ps1') -Destination $packageDir -Force` [VERIFIED]. Remove it, and point `New-BaselineIso` at the kit copy. Today it reads `$installer = Join-Path $PackagePath 'Install-HPDriverBaseline.ps1'` [VERIFIED: src/New-HPBaselineIso.ps1:88].
- **Lint/test from pwsh:** results differ (parser, inbox modules). Test-Kit must refuse to run, or relaunch itself, when `$PSVersionTable.PSEdition -ne 'Desktop'`.
- **`-Path .` recursion for PSSA or `gitleaks dir` on the repo:** walks the ignored 10 GB `HP_Staging/` and `.tools/`. Use explicit lint paths and `gitleaks git` (history/staged), not `dir`.
- **Classes for the interface:** rejected by D-07, and they break `Mock` on 5.1 (prior research, ARCHITECTURE section 3.2).

## Don't Hand-Roll

| Problem | Don't build | Use instead | Why |
|---------|-------------|-------------|-----|
| Secret detection | Regex grep in Test-Kit | gitleaks default rules + one custom Atera rule | Hundreds of maintained provider rules, entropy, decoding (it decoded a percent-encoded login in the probe) |
| Parsing `.psd1` data | `Invoke-Expression`, dot-sourcing, `ConvertFrom-StringData` | `Import-PowerShellDataFile` | Restricted language; rejects code (verified) |
| Process-level policy | Editing registry or `Set-ExecutionPolicy` machine-wide | `powershell.exe -ExecutionPolicy Bypass` in Run.cmd/hook | Process scope only; nothing persists on the target |
| Hook installation | Copying files into `.git/hooks` | `git config core.hooksPath .githooks` (versioned hook) | Hook content is reviewed in git; install is one command (verified relative path works) |
| Contract introspection | Regex over `.psm1` source | `Get-Command -Module` + `.Parameters.Keys` after `Import-Module` | Sees the real bound parameter set, including aliases |
| Tool integrity | Trusting a download | `Get-FileHash -Algorithm SHA256` against a pinned constant | One line; protects the hook binary |

**Key insight:** Every gate in this phase must be provable by a failing case: a broken vendor fixture, a planted token, an unverified profile value, an unknown unattend parameter. Write the negative test first (TDD mode is on in config).

## Runtime State Inventory

| Category | Items found | Action required |
|----------|-------------|-----------------|
| Stored data | `HP_Staging/8549-win11-24H2/` holds a built package with its own **copies** of `Install-HPDriverBaseline.ps1` (identical to `src/`, so it lacks `-LogPath`) and `Test-DeviceBaseline.ps1`. `HP_Staging/` also holds a 10 GB built ISO `...HP8549.iso` whose answer file runs the broken `-LogPath` command. `src/iso/` holds an 8 GB source ISO [VERIFIED: `ls`, `diff`]. All are gitignored. | No data migration. Do **not** delete or `git mv` them (they are untracked). Document that the old ISO's first-boot run fails binding and must not be used to make sticks; rebuild in Phase 4. Moving `src/` with `git mv` leaves untracked `src/iso/` in place (see Open Question 2) |
| Live service config | README's interim one-liner downloads `.../main/src/Test-DeviceBaseline.ps1` from raw.githubusercontent.com [VERIFIED: README.md]. Moving the file breaks any copy of that URL operators have saved or typed | Decide in planning (Open Question 1): update README, and optionally leave a forwarder at the old path until Phase 7 |
| OS-registered state | None: no scheduled tasks or services. `.git/hooks/` has only `*.sample`; `core.hooksPath` is unset [VERIFIED] | `-InstallHook` sets `core.hooksPath` (per-clone, not versioned; document it in README) |
| Secrets/env vars | `$env:PK_OUTFILE` is read by `Test-DeviceBaseline.ps1:3-4` [VERIFIED]. No secrets exist yet; no `config.local.psd1` exists | Keep the `PK_OUTFILE` name unchanged |
| Build artifacts | Old defaults point at absolute `C:\HP_Staging` (build, ISO). Other builders may have packages there. The README used `..\HP_Staging` relative to `src/` [VERIFIED] | Code edit only (new `staging/` default). Mention in README that old `HP_Staging/` packages are obsolete because they contain a copied installer |

## Common Pitfalls

### Pitfall 1: PowerShell 7 module path leaks into Windows PowerShell 5.1
**What goes wrong:** `powershell.exe` started from pwsh (or from git-bash or a hook whose parent is pwsh) cannot load `Microsoft.PowerShell.Security` and other inbox modules. `Get-ExecutionPolicy`, `Get-FileHash` and similar then fail.
**Why:** The child inherits the `PSModulePath` environment variable holding PS 7 paths.
**How to avoid:** `set "PSModulePath="` in `.cmd`, `env -u PSModulePath` in sh, and `Start-Process` with a cleaned environment in Test-Kit's self-relaunch [VERIFIED].
**Warning signs:** "command was found in the module ... but the module could not be loaded".

### Pitfall 2: The answer-file test passes while the first-boot run cannot bind
**What goes wrong:** String-matching tests miss parameter drift between generator and script.
**How to avoid:** An AST test binds every `-Name` in the generated command against the target script's `param()` (Pattern 8).

### Pitfall 3: Moving functions into modules silently disables mocks
**What goes wrong:** `Mock Get-CimInstance` without `-ModuleName` does not intercept calls made inside `HP.Target`. Tests then hit real CIM on the builder (it returns the builder's own BIOS) or throw under Pester 6.
**How to avoid:** `-ModuleName HP.Target` on every `Mock` and `Should -Invoke`. Add a default throwing mock [CITED: pester docs].

### Pitfall 4: Inbox Pester 3.4.0 wins autoload
**What goes wrong:** `Invoke-Pester` without an explicit import runs 3.4.0 on this builder, and v5+ syntax (`BeforeAll`, `-ForEach`) fails.
**How to avoid:** Import the pinned 6.2.0 manifest by path first, and assert `(Get-Module Pester).Version -eq '6.2.0'` in Test-Kit [VERIFIED: only 3.4.0 installed].

### Pitfall 5: gitleaks scans with default rules when pointed at a subfolder
**How to avoid:** Always pass `-c "$root\.gitleaks.toml"` [VERIFIED: probe found nothing without `-c` on a subfolder, 3 findings with it].

### Pitfall 6: Line endings break the hook and the batch file
**What goes wrong:** `core.autocrlf=true` on this builder [VERIFIED], and no `.gitattributes` exists. A hook checked out with CRLF fails under sh (`\r` in the shebang/commands). LF-only `.cmd` files are known to misparse labels in cmd.exe [ASSUMED].
**How to avoid:** `.gitattributes` with `.githooks/* text eol=lf`, `*.sh text eol=lf`, `*.cmd text eol=crlf`. Keep `.ps1/.psm1/.psd1` ASCII-only (all current files are ASCII [VERIFIED: `file`, `grep -P '[^\x00-\x7F]'`]), because 5.1 reads BOM-less non-ASCII as ANSI.

### Pitfall 7: Secrets copied with the kit
**What goes wrong:** `config.local.psd1` sits inside `kit/` by design (D-15). Any "copy kit" step (ISO image, web route later, zip for support) carries it.
**How to avoid:** One core function lists the publishable kit files and excludes `*.local.psd1` and `results/`. Add a test asserting that the ISO staging list never contains `config.local.psd1`.

### Pitfall 8: Recursive gates
**What goes wrong:** The hook-proof Pester test commits in a temp repo. The hook runs Test-Kit, which runs Pester, which runs the hook-proof test again.
**How to avoid:** Test-Kit runs gitleaks first and exits before Pester when it finds something (the proof test only commits a leaking file). Belt and braces: Test-Kit sets `$env:KIT_GATE_ACTIVE = '1'` and skips the Pester stage when it is already set.

### Pitfall 9: HPCMSL command-name collisions
**What goes wrong:** A vendor command named like an HPCMSL export (`Get-HPDeviceModel`, `Get-HPBIOSVersion`, `New-HPDriverPack`) shadows or is shadowed by the library on the builder [VERIFIED: present in HPCMSL 1.9.0].
**How to avoid:** Use the `HPKit` noun prefix. Add a contract assertion that no mapped command name appears in a committed list of HPCMSL exports (optional).

### Pitfall 10: Hook run time
**What it costs:** On this builder, PSSA over `src/` plus module load took about 14 s and the Pester suite about 7 s. gitleaks staged takes under 1 s [VERIFIED: `time`]. Expect about 25-40 s per commit as the repo grows.
**Mitigation:** gitleaks first (fast fail). This is acceptable under D-13. Do not add a skip switch; that would be a bypass.

## Code Examples

### Test-Kit.ps1 skeleton (shape; names are discretion)
```powershell
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$PreCommit,      # staged secret scan, then lint, then tests
    [switch]$ScanHistory,    # full-history secret scan (criterion 4)
    [switch]$InstallHook,    # git config core.hooksPath .githooks
    [switch]$InstallTools    # Save-Module pinned versions + gitleaks zip with SHA-256 check into .tools\
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run Test-Kit.ps1 under Windows PowerShell 5.1 (powershell.exe).' }
# 1 secrets -> 2 PSScriptAnalyzer (explicit paths, -Settings "$root\PSScriptAnalyzerSettings.psd1") -> 3 Pester 6.2.0 (Run.Exit / non-zero on failure)
# Exit 0 only if all three are clean; print green/red one line per gate.
```

### Pester 6 contract test (verified shape)
```powershell
param([string]$VendorRoot = (Join-Path $PSScriptRoot '..\kit\vendors'))
BeforeDiscovery {
    $script:vendors = foreach ($d in Get-ChildItem -Path $VendorRoot -Filter vendor.psd1 -Recurse) {
        @{ Name = $d.Directory.Name; Descriptor = $d.FullName }
    }
}
Describe 'Vendor <Name> contract' -ForEach $vendors {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
        $script:violations = @(Test-KitVendorContract -DescriptorPath $Descriptor)
    }
    It 'has no contract violations' {
        $violations | Should -BeNullOrEmpty
    }
}
```

## State of the Art

| Old approach | Current approach | When changed | Impact |
|--------------|------------------|--------------|--------|
| `gitleaks protect --staged` / `gitleaks detect` | `gitleaks git --pre-commit --staged` / `gitleaks git` | v8.19+ (old forms deprecated) | Use the new forms only [CITED: gitleaks cmd/detect.go comments] |
| Pester 5 fall-through mocks | Pester 6 throws on unmatched filtered mocks | Pester 6.0.0 (2026-07-07) | Add default mocks |
| `Assert-MockCalled` | `Should -Invoke` | Removed in Pester 6 | None used in this repo today [VERIFIED: test file read] |
| `[rules.allowlist]` | `[[rules.allowlists]]` | gitleaks v8.21.0 | Not needed: no allowlists planned |

## Assumptions Log

| # | Claim | Section | Risk if wrong |
|---|-------|---------|---------------|
| A1 | BIOS default setting names/values (`Secure Boot`=`Enable`, `TPM Device`=`Available`, `TPM State`=`Enable`) for 840 G5/G6 | Pattern 4 | Wrong names make Phase 6 verify always fail; mitigated by `Verified = $false` + accessor guard |
| A2 | G5 platform ID 83B2 (third-party table + forum BIOS dump, no HP page) | Pattern 4 | Wrong platform makes the installer's board check refuse G5 units; mitigated by `PlatformVerified = $false`, confirm with `Get-HPDeviceDetails -Platform 83B2` on the builder |
| A3 | Self-elevation relaunch via `Start-Process -Verb RunAs` passes parameters correctly | Pattern 9 | Operator sees a second window without the chosen mode; needs one manual UAC test |
| A4 | Atera property names `IntegratorLogin`, `CustomerId`, `AccountId` and "installer link" as the config schema | Pattern 11, `.gitleaks.toml` | Schema renamed in Phase 5; gitleaks rule may miss a real value; confirm against a real Atera download link (never commit it) |
| A5 | `ConvertTo-HPBiosVersion` regex shape and `[version]` equality | Pattern 8 | Tests will fail fast and show it; low risk |
| A6 | LF-only `.cmd` misparsing in cmd.exe | Pitfall 6 | Low; `.gitattributes` costs nothing |
| A7 | `Save-Module` with inbox PowerShellGet 1.0.0.1 works after `Install-PackageProvider NuGet -Scope CurrentUser` (the existing build script uses the same provider bootstrap for `Install-Module`) | Standard Stack | `-InstallTools` fails on a fresh builder; fallback is `Install-Module -Scope AllUsers` from an elevated shell, or `Save-PSResource` from pwsh (verified working here) |

## Open Questions

1. **Audit script location vs the published `irm` URL**
   - What we know: README publishes `.../main/src/Test-DeviceBaseline.ps1` for `irm | iex`. The script is already vendor-neutral and self-contained, and `irm | iex` gives no `$PSScriptRoot`, so it cannot import `kit/core`.
   - What's unclear: whether moving it (D-05) may break that URL before Phase 7, and how literally criterion 1 ("audit scripts run through a common module") should apply to it.
   - Recommendation: move it to `kit/Test-DeviceBaseline.ps1`, keep it self-contained (fix lint with a local `Show-*` function), and launch it from `Run.ps1 -Mode Audit` after core resolves the vendor. Update the README URL. Ask the user whether to keep a 3-line forwarder at `src/Test-DeviceBaseline.ps1` until Phase 7.
2. **Where source ISOs live after `src/` goes away**
   - What we know: BUILD-02 (Phase 4) says "Builder lists ISOs in `src/iso/`". An 8 GB ISO sits there now (ignored). D-02 puts ISO *servicing code* in `builder/iso/`.
   - Recommendation: in Phase 1 leave the untracked `src/iso/` alone. Record the question for Phase 4, where the options are to keep `src/iso/` as a drop folder or amend BUILD-02 to e.g. `iso/`. Do not move ISO files in this phase.
3. **What `Build.cmd` does in Phase 1**
   - What we know: the master build is BUILD-01 (Phase 2).
   - Recommendation: Phase 1 ships `builder/Build-DriverBaseline.ps1` and `builder/iso/New-BaselineIso.ps1` as the moved scripts. Either omit `Build.cmd` or make it a launcher with the same PSModulePath/Bypass pattern as `Run.cmd` that forwards to `builder/Build-DriverBaseline.ps1`. Planner's call; keep README to 3 commands.
4. **Unverified-value guard granularity**
   - Recommendation: block-level `Verified` (per `FirmwareMinimum`, `BiosDefaults`, plus `PlatformVerified` on G5). Per-setting flags are overbuild until bench data exists.

## Environment Availability

| Dependency | Required by | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Windows PowerShell | everything | yes | 5.1.26100.9549 | — |
| PowerShell 7 (pwsh) | not required (only the source of the PSModulePath trap) | yes | 7.6.6 | — |
| Pester 6.2.0 | REPO-03/06 | **no** (only inbox 3.4.0) | — | `Test-Kit -InstallTools` (Save-Module to `.tools/`) |
| PSScriptAnalyzer 1.25.0 | REPO-06 | **no** | — | `Test-Kit -InstallTools` |
| gitleaks 8.30.1 | SEC-01/03 | **no** (not on PATH) | — | `-InstallTools` zip + SHA-256; or `winget install --id Gitleaks.Gitleaks --version 8.30.1 -e` (verified available) |
| git (sh for hooks) | SEC-03 | yes | 2.55.0.windows.5 | — |
| PowerShellGet / PackageManagement | tool install | yes, old | 1.0.0.1 / 1.0.0.1 | NuGet provider bootstrap (A7) |
| HPCMSL | not needed for Phase 1 tests | not checked as installed | — | Build module must import lazily |
| Internet (PSGallery, GitHub) | `-InstallTools` once | yes this session | — | Pre-seeded `.tools/` copy |

Repo drive `Z:` reports DriveType **Fixed** (not a network share) [VERIFIED: `[IO.DriveInfo]`], so `staging/` under the repo is safe for later DISM work.

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** Pester 6.2.0, PSScriptAnalyzer 1.25.0 and gitleaks 8.30.1. The first plan must include the `-InstallTools` step (or a manual install task) before any gate can be green.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Pester 6.2.0 on Windows PowerShell 5.1; PSScriptAnalyzer 1.25.0; gitleaks 8.30.1 |
| Config file | none yet. Wave 0 adds `PSScriptAnalyzerSettings.psd1`, `.gitleaks.toml`; Pester config is built in `Test-Kit.ps1` via `New-PesterConfiguration` |
| Quick run command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Kit.ps1 -PreCommit` (note: needs staged changes for the secret step; otherwise just lint + tests) |
| Full suite command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Kit.ps1 -ScanHistory` plus the default run (lint + Pester) |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test type | Automated command | File exists? |
|--------|----------|-----------|-------------------|-------------|
| REPO-01 | Core module imports offline; no vendor name appears in `kit/core` (AST/text scan for `HP`, `HPCMSL`) | unit | `Invoke-Pester tests/Core.Tests.ps1` | no (Wave 0) |
| REPO-01 | Moved HP helpers keep behavior (existing Select-OsRelease / Softpaq / ReturnCodeMap / ISO tests) | unit | `Invoke-Pester tests/HP.Build.Tests.ps1, tests/Core.Tests.ps1` | partially (src/HPDriverBaseline.Tests.ps1, to be split) |
| REPO-02 | HP descriptor maps all 8 ops to existing commands with pinned params | contract | `Invoke-Pester tests/Contract.Tests.ps1` | no |
| REPO-03 | Missing-any-of-six detection (6 generated fixtures) + child-process run on `fixtures/vendors/missing-op` exits 1 | contract (negative) | same file, `It -ForEach` over op names | no |
| REPO-04 | `Get-KitPackagePath` gives `<root>\hp\840-g5\...` and `<root>\hp\840-g6\...`, distinct; build/ISO defaults resolve under `staging/` | unit | `Invoke-Pester tests/Core.Tests.ps1` | no |
| REPO-05 | Both profiles load with `Import-PowerShellDataFile`, carry required keys, G5 `83B2`/G6 `8549`; accessor throws on `Verified = $false`; AST scan finds no direct `.FirmwareMinimum`/`.BiosDefaults` reads outside Profile.ps1 | unit + static | `Invoke-Pester tests/Profiles.Tests.ps1` | no |
| REPO-06 | Whole suite green on 5.1 with Pester 6.2.0; PSSA zero findings; settings file has no `ExcludeRules`/`Severity`; no `SuppressMessage` attribute anywhere | gate + static | `Test-Kit.ps1` (gate) and `Invoke-Pester tests/Repo.Tests.ps1` | no |
| REPO-06 | D-06: `ConvertTo-HPBiosVersion`/`Get-FirmwareSkipReason` tests (moved, `-ModuleName`); unattend args bind to installer `param()` | unit | `Invoke-Pester tests/HP.Target.Tests.ps1, tests/HP.Build.Tests.ps1` | partially |
| SEC-01 | Full history clean | gate | `Test-Kit.ps1 -ScanHistory` | no |
| SEC-02 | `git check-ignore kit/config.local.psd1` exit 0, `kit/config.example.psd1` exit 1; example values all `''`; `Get-KitConfig` merge + override; ISO copy list excludes `*.local.psd1` | unit | `Invoke-Pester tests/Repo.Tests.ps1, tests/Core.Tests.ps1` | no |
| SEC-03 | Temp repo with hook blocks runtime-generated token (commit exit != 0, no HEAD); `.githooks/pre-commit` has LF endings and calls `--ignore-gitleaks-allow` path | integration | `Invoke-Pester tests/Repo.Tests.ps1 -Tag Hook` | no |
| D-03 | `Run.cmd` contains `set "PSModulePath="`, `-ExecutionPolicy Bypass`, `%~dp0Run.ps1`; file is CRLF | static | `Invoke-Pester tests/Repo.Tests.ps1` | no |
| — | UAC self-elevation from a non-admin cmd on a real laptop/VM | manual-only | n/a (needs interactive UAC) | — |

### Sampling Rate
- **Per task commit:** the pre-commit hook (gitleaks staged, then PSSA, then Pester) once Wave 0 installs it. Before the hook exists, run `Test-Kit.ps1` by hand.
- **Per wave merge:** `Test-Kit.ps1` + `Test-Kit.ps1 -ScanHistory`.
- **Phase gate:** full suite green, zero PSSA findings, history clean, hook proof green, before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `Test-Kit.ps1` with `-InstallTools` (pinned versions, SHA-256) and `-InstallHook`
- [ ] `.gitignore` additions: `staging/`, `.tools/`; `.gitattributes`
- [ ] `PSScriptAnalyzerSettings.psd1`, `.gitleaks.toml`, `.githooks/pre-commit`
- [ ] `tests/` skeleton: `Core.Tests.ps1`, `HP.Build.Tests.ps1`, `HP.Target.Tests.ps1`, `Contract.Tests.ps1`, `Profiles.Tests.ps1`, `Repo.Tests.ps1`, `fixtures/vendors/missing-op/`
- [ ] Tools installed on the builder (`-InstallTools` run once)

## Security Domain

`security_enforcement: true`, ASVS level 1 (from `.planning/config.json`).

### Applicable ASVS Categories
| ASVS category | Applies | Standard control |
|---------------|---------|-----------------|
| V2 Authentication | no | No auth surface in this phase |
| V3 Session Management | no | — |
| V4 Access Control | partial | Admin elevation is explicit (UAC), never silent; no privilege stored |
| V5 Input Validation | yes | `Import-PowerShellDataFile` for profiles/config/descriptors (restricted language, verified); `ValidateSet`/`ValidateScript` on parameters |
| V6 Cryptography | yes (integrity only) | `Get-FileHash -Algorithm SHA256` for the pinned gitleaks archive; no custom crypto |
| V8 Data Protection / V14 Config | yes | Secrets only in gitignored `kit/config.local.psd1` or parameters; gitleaks gate; no secrets in logs (Atera values never written via transcript: the installer transcript must not run Atera steps, which are a later phase) |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard mitigation |
|---------|--------|---------------------|
| Credential committed to a possibly public repo | Information disclosure | gitleaks staged hook + full-history scan; custom Atera rule; empty example values |
| Inline `gitleaks:allow` / `.gitleaksignore` used to slip a secret through | Tampering | `--ignore-gitleaks-allow` in every invocation (verified); a Repo test fails if `.gitleaksignore` exists |
| Hook bypass with `--no-verify` | Repudiation | Accepted (D-13); `-ScanHistory` before any push/share catches it afterwards |
| `config.local.psd1` baked into an ISO/image | Information disclosure | Allow-list copy + test (Pitfall 7) |
| Code execution through a tampered `.psd1` | Elevation of privilege | `Import-PowerShellDataFile`, never dot-source or `Invoke-Expression` data files |
| Tampered gitleaks/Pester download | Tampering | Pinned versions; SHA-256 for gitleaks; PSGallery over TLS 1.2 |
| Execution policy bypass reaching beyond the run | — | Process-scope `-ExecutionPolicy Bypass` only; nothing persisted (cited) |

## Sources

### Primary (HIGH confidence)
- Local runs this session (Windows PowerShell 5.1.26100.9549): Pester 6.2.0 on the existing suite, PSScriptAnalyzer 1.25.0 on `src/` plus rule probes, gitleaks 8.30.1 history scan and hook proof, Run.cmd and PSModulePath probes, `Import-PowerShellDataFile` probe, transcript/`exit` probe, contract-test prototype.
- Context7 `/pester/docs`: migrations/v5-to-v6 (5.1/7.4+ only, no fall-through mocks, empty `-ForEach`), usage/modules (`-ModuleName`), installation (side-by-side `-Force -SkipPublisherCheck`).
- Context7 `/gitleaks/gitleaks`: README config example (`[extend] useDefault`, rules, allowlists), cmd/detect.go (deprecated `protect`/`detect` mapping), cmd/root.go (exit code, ignore paths).
- Context7 `/powershell/psscriptanalyzer`: UseCompatibleSyntax configuration, settings files.
- PSGallery via `Find-PSResource` (versions, dates, authors, HPCMSL 1.9.0 command lists); `gh release list/view -R gitleaks/gitleaks`; `winget show Gitleaks.Gitleaks`.
- Repo files read this session: `src/*.ps1`, `src/HPDriverBaseline.psm1`, `src/profiles/hp-elitebook-840-g6.psd1`, `.gitignore`, `README.md`, `HP_Staging/8549-win11-24H2/manifest.json`, `.planning/research/{SUMMARY,STACK,ARCHITECTURE,PITFALLS}.md`.

### Secondary (MEDIUM confidence)
- learn.microsoft.com, about_Execution_Policies (5.1), updated 2026-08-31: client default Restricted, Process scope precedence, Group Policy override, Bypass skips zone check.
- ftp.hp.com/pub/softpaq/sp157501-158000/sp157750.html: Q78 01.31.00, 2025-04-30, 840 G5 supported.

### Tertiary (LOW confidence)
- Web search for platform 83B2: [ManageEngine supported drivers](https://www.manageengine.com/patch-management/supported-drivers.html) and a [BadCaps forum profile](https://www.badcaps.net/member/157878-gpatadia), both third-party.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH. Versions from the registries this session; all three tools executed on 5.1.
- Architecture: HIGH for mechanics (contract prototype, relative import, Run.cmd verified); MEDIUM for naming and layout choices, which are recommendations within Claude's discretion.
- Pitfalls: HIGH. Most were reproduced this session.
- Profile data: G6 BIOS HIGH (staged manifest); G5 BIOS MEDIUM (HP page); G5 platform MEDIUM-LOW; BIOS defaults LOW.

**Research date:** 2026-10-09
**Valid until:** 2026-11-08 (tool versions move monthly; re-check Pester/gitleaks releases at planning time)
