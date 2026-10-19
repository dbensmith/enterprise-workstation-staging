---
phase: 01-modular-foundation
plan: 05
subsystem: profiles-and-config
tags: [powershell-5.1, pester-6, profiles, run-time-config, verified-values, tdd]

requires:
  - phase: 01-modular-foundation
    provides: "Kit.Core module with a pre-declared FunctionsToExport list and Get-KitRoot (plan 01-02)"
provides:
  - "kit/profiles/hp/840-g6.psd1 and 840-g5.psd1: standalone model profiles with SchemaVersion, Vendor, ModelId, Platform(+Verified/Source), BiosFamily, PackSelection, FirmwareMinimum and BiosDefaults blocks"
  - "kit/core/Profile.ps1: Get-KitProfile (ByModel / ByPath, schema checks, ProfilePath key) and Get-KitVerifiedValue (guard with -AllowUnverified)"
  - "kit/core/Config.ps1: Get-KitConfig (example defaults, config.local.psd1, non-empty -Override), Source and LocalPath"
  - "kit/config.example.psd1: committed empty ThirdParty schema (InstallerUrl, IntegratorLogin, CustomerId, InstallToken)"
  - "tests/Profiles.Tests.ps1 (35 tests) and tests/Config.Tests.ps1 (19 tests), including the AST scan that forbids direct reads of FirmwareMinimum / BiosDefaults"
affects: [01-06, 01-07, 01-08]

actuals:
  tokens: 12673
  tasks: 3
  commits: 7
plan_head_before: a6b413c07f7ce58e467910e7a94aa4b0745fe6a8
plan_head_after: d0963c9baa3e5380e3c9ab98006aa021a2c35abe
commits: 7

tech-stack:
  added: []
  patterns:
    - "Profiles and config are read with Import-PowerShellDataFile only; code in a data file is refused and never runs"
    - "Unconfirmed values carry Verified = $false and are read through Get-KitVerifiedValue, which throws unless -AllowUnverified (then warns)"
    - "A static AST scan of kit/ and builder/ (member access and string index) makes any direct read outside Profile.ps1 fail the gate; the scan is proven on a TestDrive sample"
    - "Private helpers (Read-KitProfileFile, Merge-KitConfigData) stay out of the pre-declared manifest, and an export test proves it"

key-files:
  created:
    - kit/core/Profile.ps1
    - kit/core/Config.ps1
    - kit/config.example.psd1
    - kit/profiles/hp/840-g5.psd1
    - tests/Profiles.Tests.ps1
    - tests/Config.Tests.ps1
  modified:
    - kit/profiles/hp/840-g6.psd1
    - src/Build-HPDriverBaseline.ps1

key-decisions:
  - "Core code names no vendor, so the required nested keys of FirmwareMinimum in Profile.ps1 are Version, Verified and Source; the SoftPaq id is vendor-specific, is asserted on the real profiles in tests, and passes through Get-KitVerifiedValue untouched (it returns every key of the block except Verified and Source)"
  - "A config.local.psd1 parse failure throws a fixed message with the detail withheld, because the engine's message can quote part of the file (SEC-02)"
  - "Get-KitVerifiedValue treats any Verified value that is not exactly $true as unverified (fails closed)"

patterns-established:
  - "Profile paths are <ProfileRoot>\\<vendor lowercased>\\<ModelId>.psd1; ModelId must equal the file name and Vendor the folder name"

requirements-completed: [REPO-05, SEC-02]

duration: 17min
completed: 2026-10-19
status: complete
---

# Phase 1 Plan 05: Model profiles and run-time config

One standalone data profile per model (G5 and G6) with every unconfirmed value flagged, a guarded accessor so code cannot lean on an unverified value without saying so, and one run-time config loader that reads the git-ignored `kit/config.local.psd1` over a committed, empty example. No vendor name appears in `kit/core`, and `kit/core/Kit.Core.psd1` was not touched (the pre-declared export list already named all three functions).

## Tasks

| Task | Name | RED | GREEN |
|------|------|-----|-------|
| 1 | Tracer: G6 profile -> Get-KitProfile -> Kit.Core export | 62579c8 | 48334d0 (pure move), fca77de |
| 2 | G5 profile and Get-KitVerifiedValue plus AST scan | 3ed20f9 | a59ca12 |
| 3 | Committed example and Get-KitConfig | c5874db | d0963c9 |

## Verification

Full gate, `env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1`, run after the final code commit: exit 0, lint 34 files / 0 findings, 277 Pester tests passed, no suppressions. `Test-Kit.ps1 -PreCommit` on the staged Task 3 files also passed (gitleaks: staged changes clean). Each RED run was confirmed failing before its commit (12, 16 and 17 failures). PSScriptAnalyzer RULE_ERROR did not recur.

Plan truths checked by tests: G6 loads Platform 8549, BiosFamily R70, minimum 01.36.00 / sp174025 and the original DriverExclude list; G5 loads 83B2, Q78, 01.31.00 / sp157750; a profile missing PackSelection and BiosFamily throws naming both; ModelId/file-name, Vendor/folder-name, SchemaVersion and non-boolean Verified mismatches throw; unknown model lists the available ModelIds; FirmwareMinimum, BiosDefaults and the G5 Platform throw "<Name> for <ModelId> is unverified"; the G6 Platform returns 8549 with no warning; `-AllowUnverified` returns the value with exactly one warning; the AST scan finds nothing on the real tree and flags a TestDrive sample (member access and string index); both minimums match `^\d{2}\.\d{2}\.\d{2}$`, survive the `[version]` cast, and compare below / not-below / above at one minor step; the example is tracked, not ignored, holds only `''` values and exactly the four ThirdParty keys; `kit/config.local.psd1` is ignored by `.gitignore:28:*.local.psd1`; defaults, local, override-wins and empty-override-does-not-clear behave as specified; unknown keys and sections (local and override) throw; a code-carrying local file throws and its marker file is never created; stream capture shows no warning, information or error record and no value in verbose output; both export tests pass.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] SoftPaq key removed from the core schema check**
- **Found during:** Task 1 GREEN gate
- **Issue:** The core neutrality scan in tests/Core.Tests.ps1 (`\bHP\b|HPCMSL|Hewlett|SoftPaq`) failed on `'SoftPaq'` in Profile.ps1's required nested keys. The plan lists SoftPaq as part of the FirmwareMinimum shape but also forbids vendor names in core.
- **Fix:** Profile.ps1 requires Version, Verified and Source for FirmwareMinimum. `Get-KitVerifiedValue -Name FirmwareMinimum` returns every key of the block except Verified and Source, so Version and SoftPaq still come back. The SoftPaq id is asserted on both real profiles in tests/Profiles.Tests.ps1 instead.
- **Files modified:** kit/core/Profile.ps1, tests/Profiles.Tests.ps1
- **Commit:** fca77de, 3ed20f9

**2. [Rule 3 - Blocking] Old build script default profile path**
- **Found during:** Task 1 GREEN
- **Issue:** `git mv src/profiles/hp-elitebook-840-g6.psd1 kit/profiles/hp/840-g6.psd1` left `src/Build-HPDriverBaseline.ps1` defaulting `-ProfilePath` to the deleted file. The plan does not list that script in files_modified (Plan 01-06 moves and rewrites it).
- **Fix:** one-line default change to `..\kit\profiles\hp\840-g6.psd1`. The profile still carries the top-level keys the script reads (Name, Platform, Os, OsVer, DriverExclude, FirmwareExclude). Plan 01-06 replaces the file, so the edit is a stop-gap.
- **Files modified:** src/Build-HPDriverBaseline.ps1
- **Commit:** fca77de

**3. [Rule 2 - Missing critical functionality] Parse-failure detail withheld in Get-KitConfig**
- **Found during:** Task 3 GREEN
- **Issue:** The plan wraps a load failure as "config.local.psd1 is not a plain data file: <message>". The engine's message can quote part of the file, which holds secrets; SEC-02 forbids writing a config value to any stream.
- **Fix:** the message is fixed text ("... Detail withheld so no value is echoed."). Errors elsewhere name keys only.
- **Files modified:** kit/core/Config.ps1
- **Commit:** d0963c9

**4. [Rule 3 - Lint] Test helper names and key order**
- **Found during:** Task 3 gate
- **Issue:** PSUseShouldProcessForStateChangingFunctions flagged the test helper `New-TestKitFolder`; the example-keys test compared against a hand-ordered list that does not match culture-aware `Sort-Object` order.
- **Fix:** helper renamed `Write-TestKitFolder`; expected list sorted with the same `Sort-Object`. No suppression.
- **Files modified:** tests/Config.Tests.ps1
- **Commit:** d0963c9

### Other notes

- The G6 move was split into a pure-rename commit (48334d0) before the extension commit (fca77de). Done in one commit the content change was too large for git to follow the rename; now `git log --follow` on kit/profiles/hp/840-g6.psd1 reaches the original import commit 1d5e66c. The intermediate commit has the moved profile without its loader; only the end of the series is meant to be green.
- The plan's Task 3 acceptance text still mentions `AccountId`; the example uses `InstallToken` as the interfaces block and the task instruction (ThirdParty keys InstallerUrl, IntegratorLogin, CustomerId, InstallToken) say.
- Tests added beyond the plan: unsupported SchemaVersion, vendor with no profile folder, path-traversal ModelId, code in a profile file, override with an unknown key, non-text config value, missing example, empty-override on defaults.
- `README.md` (tree listing) and `docs/hp-elitebook-840-g6-driver-baseline.md` still mention the old `profiles/hp-elitebook-840-g6.psd1`; the docs rewrite is a later plan in this phase.

## Known Stubs

None. The unverified values are flagged data, not stubs: BIOS default setting names and values, the firmware minimums and the G5 platform id (`83B2`) are all `Verified = $false` / `PlatformVerified = $false` until confirmed on hardware (RESEARCH A1, A2).

## Threat Flags

None. T-1-14 (data-only loading, code-carrying file refused and never run, unknown keys rejected), T-1-15 (no Write-Host/Write-Information in Config.ps1, stream-capture test), T-1-16 (Verified flags, guard, AST scan) and T-1-17 (example holds only empty strings, `*.local.psd1` ignore rule tested, secret scan clean) are mitigated and each has a test.

## Self-Check: PASSED

kit/core/Profile.ps1, kit/core/Config.ps1, kit/config.example.psd1, kit/profiles/hp/840-g5.psd1, kit/profiles/hp/840-g6.psd1, tests/Profiles.Tests.ps1 and tests/Config.Tests.ps1 exist; commits 62579c8, 48334d0, fca77de, 3ed20f9, a59ca12, c5874db and d0963c9 are ancestors of HEAD; `git ls-files src/profiles` prints nothing; no commit with scope `(01-05)` touches kit/core/Kit.Core.psd1.
