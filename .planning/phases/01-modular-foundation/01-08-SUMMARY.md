---
phase: 01-modular-foundation
plan: 08
subsystem: iso-builder-and-docs
tags: [iso, build-cmd, readme, docs, hook-fix]

requires: ["01-06", "01-07"]
provides:
  - "builder/iso/New-BaselineIso.ps1: vendor-neutral ISO builder (git mv from src/New-HPBaselineIso.ps1), SchemaVersion 2 guard, stages only Get-KitPublishFile output"
  - "kit/core/Publish.ps1: Get-KitPublishFile"
  - "Build.cmd: CRLF launcher for the builder"
  - "README.md and docs/hp-elitebook-840-g6-driver-baseline.md rewritten for the kit/builder/staging layout, including the third-party (PSADT) settings and scripts/cloud-init.sh"
  - "Test-Kit.ps1: Pester stage clears hook git variables (fix for config corruption found during this plan)"
requirements-completed: [REPO-01, REPO-04, REPO-06, SEC-01, SEC-02, SEC-03]
---

# Phase 1 Plan 08: ISO builder, Build.cmd and docs

Gate on the final tree: lint 42 files / 0 findings, 407 Pester tests pass, full-history secret scan clean (83 commits).

## Deviation: hook corrupted the shared git config
The first commit that ran tests inside the pre-commit hook leaked `GIT_DIR` and `GIT_INDEX_FILE` into Pester. Tests that init throwaway repos rewrote the real `.git/config` (bare=true, user Hook Proof, gpgsign=false, autocrlf=false). The owner approved the repair; `Test-Kit.ps1` now clears and restores those variables, with a regression test and a fixture. Commits made through the hook after the fix left the config intact.

## Other deviations
- The gate takes about 3 minutes, not 25-40 s, so each hook commit is slow.
- `test(01-08): add failing publish list and ISO tests` has a 51-character subject (not rewritten).

## Open manual checks
- Elevated `Build.cmd -Vendor HP -Model 840-g6 -WhatIf`, then `-Model 840-g5 -WhatIf`.
- `builder\iso\New-BaselineIso.ps1 -IsoPath <Win11 ISO> -PackagePath staging\hp\840-g6\win11-24H2 -WhatIf`, elevated.
- Real UAC relaunch (plan 01-07) and `irm .../kit/Test-DeviceBaseline.ps1 | iex` after merge.
- A real install from the built ISO, confirming `C:\Kit\firstboot.log`.
