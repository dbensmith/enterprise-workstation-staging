# Phase 1: Modular Foundation - Context

**Gathered:** 2026-10-06
**Status:** Ready for planning

<domain>
## Phase Boundary

The existing HP tooling moves into a vendor-neutral repo: a common module plus an HP vendor module behind one interface, with 840 G5 and 840 G6 profiles. Tests and lint pass on Windows PowerShell 5.1 with no suppressions. No secrets in the repo or its history, and a local gate blocks new ones.

Requirements: REPO-01..06, SEC-01..03. Out of scope here: firmware staging (Phase 2), Assess (Phase 3), image build (Phase 4), first logon (Phase 5), results sync (Phase 6), web bootstrap (Phase 7).

</domain>

<decisions>
## Implementation Decisions

### Repo layout and USB-copyability
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

### Vendor interface
- **D-07:** Each vendor declares its interface with a data-only descriptor `vendor.psd1` mapping operation names to command names. No PowerShell classes, no naming convention.
- **D-08:** Contract = six required operations (ListModels, GetVendorPack, NewCustomPack, GetFirmware, InstallDrivers, InstallFirmware) plus two required helpers (GetDeviceIdentity, GetInstalledFirmwareVersion). Build-plane operations live in `builder/vendors/<v>/`, target-plane ones in `kit/vendors/<v>/`.
- **D-09:** The Pester contract test checks that every mapped command exists AND has the agreed parameter names. A negative test uses a fixture vendor missing one operation and must fail, as success criterion 1 requires.

### Profiles and output
- **D-10:** One standalone `.psd1` per model under `kit/profiles/hp/` (840-g5, 840-g6), no shared base file. Each carries platform ID, expected BIOS defaults, firmware minimum, pack selection data and excludes.
- **D-11:** G5/G6 values not yet confirmed on hardware (BIOS defaults, firmware minimums) get best-known research values plus a `Verified = $false` flag. A test fails loudly if later code relies on an unverified value. Research platform IDs: G5 = 83B2 (Q78 BIOS family), G6 = 8549 (R70 BIOS family).
- **D-12:** Build output goes to `staging/<vendor>/<model>/<os>-<release>/` (repo-relative, gitignored; replaces `HP_Staging/`). `-OutputRoot` can override it.

### Quality and secret gates
- **D-13:** Gates run as a local pre-commit hook only (no GitHub Actions CI). Accepted trade-off: hooks can be bypassed with `--no-verify`.
- **D-14:** One script, `Test-Kit.ps1`, runs Pester 5+, PSScriptAnalyzer (zero findings, zero suppressions) and gitleaks under Windows PowerShell 5.1. `-InstallHook` installs the pre-commit hook; a switch scans full history for success criterion 4.
- **D-15:** Real config lives in `kit/config.local.psd1` (gitignored), beside `Run.cmd`, so it travels with the Tools stick and is found the same way in the repo and on USB. Parameters override it. The committed `kit/config.example.psd1` documents the schema (Atera and store settings only).

### Claude's Discretion
- Exact module/function names, parameter names beyond what the contract test pins, and internal file organisation within `core/` and each vendor folder.
- Pester and PSScriptAnalyzer version pinning (research: Pester 6.2.0 for PS 5.1, PSScriptAnalyzer 1.25.0, gitleaks v8.30.1) and how gitleaks is installed.
- How `Run.cmd` elevates and handles execution policy, within D-03.
- Handling of the existing `HP_Staging/` folder and gitignore updates.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project and requirements
- `.planning/PROJECT.md` — core value, required stage order, constraints
- `.planning/REQUIREMENTS.md` — REPO-01..06, SEC-01..03 (Repo & Vendor Interface, Secrets sections)
- `.planning/ROADMAP.md` — Phase 1 goal and 5 success criteria

### Research
- `.planning/research/ARCHITECTURE.md` — section 1 (existing code and defects), section 2 (three planes, component boundaries), section 3 (vendor interface contract and descriptor mechanism)
- `.planning/research/STACK.md` — Pester, PSScriptAnalyzer, gitleaks versions and PS 5.1 constraints
- `.planning/research/PITFALLS.md` — pitfalls the layout must not reintroduce
- `.planning/research/SUMMARY.md` — platform IDs and phase research flags

### Existing code to migrate
- `src/HPDriverBaseline.psm1` — split per D-05
- `src/Build-HPDriverBaseline.ps1`, `src/New-HPBaselineIso.ps1`, `src/Install-HPDriverBaseline.ps1`, `src/Test-DeviceBaseline.ps1` — rename and relocate per D-01..D-05
- `src/HPDriverBaseline.Tests.ps1` — Pester suite with defects (D-06)
- `src/profiles/hp-elitebook-840-g6.psd1` — profile pattern to extend
- `README.md`, `docs/hp-elitebook-840-g6-driver-baseline.md`, `.gitignore` — update paths and commands

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `New-WindowsInstallIso`, `Select-InstallImage`: vendor-neutral already; move to core/ISO servicing.
- AST-extraction technique in the existing Pester tests: reuse for testing standalone scripts offline.
- Profile `.psd1` pattern (Name, Platform, Os, OsVer, DriverExclude, FirmwareExclude): extend, do not replace.

### Established Patterns
- Module is testable offline without HPCMSL or admin: keep that property on both planes.
- Standalone installer must run on a stock laptop with no module installs.

### Integration Points
- ISO unattend answer file calls the installer (currently with the broken `-LogPath`).
- Entry scripts import the module via `$PSScriptRoot`, which D-03 extends to the new layout.

</code_context>

<specifics>
## Specific Ideas

- The operator works mostly from a phone and has exactly two sticks: the layout must be obvious without deep PowerShell knowledge. "Copy `kit/` to the stick and run `Run.cmd`" is the mental model.
- README must include a short "where is everything" map (builder/ vs kit/ per vendor).

</specifics>

<deferred>
## Deferred Ideas

- GitHub Actions CI as a backstop to the local hook: not wanted now. Revisit if hook bypass becomes a problem.
- Firmware-timing redesign of the unattend specialize pass: Phases 2, 4 and 5.

</deferred>

---

*Phase: 1-Modular Foundation*
*Context gathered: 2026-10-06*
