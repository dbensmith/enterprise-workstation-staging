---
phase: 01-modular-foundation
plan: 02
subsystem: core-module
tags: [powershell-5.1, kit-core, hp-build, pester, vendor-neutral]

requires: ["01-01"]
provides:
  - "kit/core/Kit.Core.psd1 and .psm1: vendor-neutral core module, 13-name FunctionsToExport pinned by a test"
  - "kit/core/IsoServicing.ps1: Select-InstallImage, New-WindowsInstallIso (moved with git mv; helper type KitCore.ComStreamWriter)"
  - "kit/core/Paths.ps1: Get-KitRoot, Get-KitPackagePath (<root>/<vendor>/<model>/<release>, creates nothing, rejects empty, separator and dot-leading segments)"
  - "kit/core/Native.ps1: ConvertTo-KitCommandLine, Invoke-KitTool (-OkCode, warns on accepted non-zero, throws otherwise, no process under -WhatIf)"
  - "builder/vendors/hp/HP.Build.psm1: Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap"
  - "tests/Core.Tests.ps1, tests/HP.Build.Tests.ps1; vendor-neutrality scan over kit/core"
affects: [01-03, 01-04, 01-05, 01-06, 01-07, 01-08]

requirements-completed: [REPO-01, REPO-04, REPO-06]

key-files:
  created: [kit/core/Kit.Core.psd1, kit/core/Kit.Core.psm1, kit/core/Paths.ps1, kit/core/Native.ps1, tests/Core.Tests.ps1, tests/HP.Build.Tests.ps1]
  moved: [src/HPDriverBaseline.psm1 -> kit/core/IsoServicing.ps1 + builder/vendors/hp/HP.Build.psm1, src/HPDriverBaseline.Tests.ps1 -> tests/]
---

# Phase 1 Plan 02: Core module and HP build split

Split `src/HPDriverBaseline.psm1` along the vendor line: ISO servicing into `kit/core`, HP helpers into `builder/vendors/hp`. Added per-model output paths and the native-command wrapper.

## Verification
Full gate (`Test-Kit.ps1`, Windows PowerShell 5.1) on the merged tree: lint 17 files / 0 findings, 101 Pester tests pass, exit 0.

## Commits
- 86b6394 refactor(01-02): move HP files to builder and tests
- 187ad2e / 62918ea test+feat: Kit.Core and HP.Build split
- 9788886 / 07e8a69 test+feat: per-model package paths
- 9aca7bf / aae414d test+feat: native command wrapper

## Deviations
1. Pure-rename commit before RED so `git log --follow` survives the large edits.
2. `Get-KitRoot` normalises with `[IO.Path]::GetFullPath` (tests import via a `..` path).
3. Invoke-KitTool tests build mock bodies with `[scriptblock]::Create` so module-bound mocks need no test-scope variables.

## Notes
- The executor could not run the gate under its worktree guard; the gate was run by the orchestrator after merging.
- `src/Build-HPDriverBaseline.ps1` (line 56) and `src/New-HPBaselineIso.ps1` (line 85) still import the removed `src/HPDriverBaseline.psm1`; Plans 01-06 and 01-08 rewire them. README and `docs/hp-elitebook-840-g6-driver-baseline.md` still name the old file.
