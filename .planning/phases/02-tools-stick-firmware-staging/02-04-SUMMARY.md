---
phase: 02-tools-stick-firmware-staging
plan: 04
subsystem: firmware
tags: [hp, hpcmsl, cva, windows-flash-fallback, pester, powershell]
status: complete

requires:
  - phase: 02-tools-stick-firmware-staging
    provides: "Get-HPKitFirmwareStickLayout and the seven-group HP layout (02-02); Publish-FirmwareStage, Test-FirmwareStage and the capture replay (02-01, 02-03)"
provides:
  - "Eighth HP layout group Win-Fallback (firmware\\hp\\{Platform}, WindowsFlashTool, Closed, Default)"
  - "Windows flash fallback entries, WindowsFlash block, LatestBios.DependencyMinimum and Notes in the Kit.FirmwareStickLayout result"
  - "SoftPaq executable hash check against the CVA, download reuse in Save-HPKitFirmware, HPCMSL pre-flight and pinned install"
  - "tests/Firmware.Integration.Tests.ps1: shipped layout + both models + fake capture through the real writer and validator"
affects: [02-05, 02-06]

tech-stack:
  added: []
  patterns:
    - "Private seams mocked with -ModuleName HP.Build (Test-HPKitSoftpaqCache, Test-HPKitHPCMSLInstalled, Get-HPKitPowerShellGetVersion)"
    - "Stand-in modules generated from a spec table for commands the test run may not have (HPCMSL commands, Install-Module, Install-PackageProvider)"

key-files:
  created:
    - tests/Firmware.Integration.Tests.ps1
  modified:
    - builder/vendors/hp/HP.Build.psm1
    - kit/vendors/hp/layouts/hp-usb-flash.layout.psd1
    - tests/HP.Firmware.Tests.ps1

key-decisions:
  - "Win-Fallback entries come from the folder that holds the BIOS image; the SoftPaq self-extractor and any *Pswd*.bin / password.bin are left out and the password file is named in Notes"
  - "Executable hash check: present and different throws; absent or no CVA hash adds a Note only (absent wins when both)"
  - "HPCMSL pin lives in one script-level constant ($script:HPCMSLRequiredVersion = '1.9.0'); an installed HPCMSL of any version is used as is"

requirements-completed: [FW-04, BUILD-06, FW-01, FW-03, FW-05]

duration: ~45min
completed: 2026-10-20
commits: 3
plan_head_before: 73b73ea5a951f0eef2814e6f6eec8663a611b3d0
plan_head_after: 7b23ff33a2c3ed819f3017e05b8dd423a1b6c968
actuals:
  tokens: 52000
  tasks: 3
  commits: 3
---

# Phase 2 Plan 04: HP Windows flash fallback, CVA metadata and download reuse Summary

**HP's whole extracted flash-tool folder is staged under firmware\hp\<platform>\ as a closed Win-Fallback group, the result records how to run it and which BIOS the image needs first, downloads are hash-reused, and the shipped layout plus both HP models plus a fake capture now validate clean through the real writer and validator.**

## Accomplishments

- Task 1 (tracer): `Win-Fallback` group appended to the HP layout (8 groups, 8 `Status = $false`). `Get-HPKitFirmwareStickLayout` lists every file of the SoftPaq folder (sub-folders kept, sorted ordinal-ignore-case) except `<id>.exe` at the root and password files, each skipped password file named in `Notes`. New private helper `Get-HPKitWindowsFlashFile`.
- Task 2: one `Get-HPSoftpaqMetadata -Number <id without sp>` call fills `WindowsFlash` (Path, SilentInstall, ReturnCodes as `RESULT` / `RESULT:REBOOT` ordered by code), `LatestBios.DependencyMinimum` (new helper `Get-HPKitDependencyMinimum`, two digits per part, non-version kept as text with a Note) and checks the SoftPaq executable SHA-256 against the CVA (throws naming the file on a mismatch). `tests/Firmware.Integration.Tests.ps1` proves clean run, closed groups inside open `EFI\HP`, the `{Platform}` token, the root allow-list and `-FlashModel`.
- Task 3: `Test-HPKitSoftpaqCache`, reuse / re-download / superseded-folder removal in `Save-HPKitFirmware` (all `-WhatIf` safe), `Initialize-HPCMSL` pre-flight (PowerShellGet < 2.0.0 or absent stops with the fix) and `RequiredVersion 1.9.0` install pin. New seams `Test-HPKitHPCMSLInstalled` and `Get-HPKitPowerShellGetVersion`.

## Task Commits

1. Task 1: `6e2167c` feat(02-04): stage HP Windows flash fallback folder
2. Task 2: `dfa0a75` feat(02-04): record HP CVA data and prove shipped layout
3. Task 3: `7b23ff3` feat(02-04): reuse verified SoftPaq downloads

## Verification

Full gate (`git hook run pre-commit`, the same script the commit hook runs) at the final commit: secrets scan PASS, lint 55 files 0 findings, Pester 732 passed, 0 failed. Every commit passed the hook (plain `git commit`, no `--no-verify`).

## Deviations from Plan

### Process

**1. [Process] RED and GREEN committed together per task.** The pre-commit hook runs the full gate, so a RED commit with failing tests cannot be made without bypassing the hook. Tests and implementation were written together per task and committed once, after the gate passed. Failing-first was observed once for real: the first Task 3 run failed 4 Initialize-HPCMSL tests (see 2).

**2. [Rule 3 - Blocking] Install-Module / Install-PackageProvider are not mockable in the gate run.** Pester raised `Could not find Command Install-Module` under `env -u PSModulePath powershell.exe`. Added a `PSGetStandIn` module (generated from a spec table, same pattern as the HPCMSL stand-in) in the `Initialize-HPCMSL` Describe, removed in `AfterAll`. Files: `tests/HP.Firmware.Tests.ps1`.

**3. [Env] The plan's verify command (`env -u PSModulePath powershell.exe ... Test-Kit.ps1 -TestPath ...`) was refused by the worktree-isolation guard of the harness**, so focused runs were not possible. Equivalent coverage came from `git hook run pre-commit` (the hook's own full gate) before each commit.

### Auto-fixed Issues

None in code owned by Plans 02-01 to 02-03: the integration test passed against the existing writer and validator first time, so no core file was touched.

### Existing test edits (expected by the new layout)

`tests/HP.Firmware.Tests.ps1` earlier assertions updated for the eighth group: group list / flags (7 to 8), entry counts 6 to 12, image-entry filters exclude `Win-Fallback`, contract test asserts `WindowsFlash.Path`. The `Write-FakeBiosPackage` helper now also writes the tool files, the SoftPaq executable and (with `-PasswordFile`) `HPQPswd1.bin`.

## Known Stubs

None.

## Threat Flags

None. T-2-15 to T-2-18 are mitigated and test-covered (executable hash throw, cache reuse only on hash match, password files left out and named, HPCMSL pinned and PowerShellGet pre-flight).

## Next Phase Readiness

Plan 02-05 (disjoint files) and 02-06 can consume the final eight-group layout and the final resolver content. The manifest now carries `windowsFlash` and `dependencyMinimum` for the bench checklist and the G6 dependency Warn.

## Self-Check: PASSED

- tests/Firmware.Integration.Tests.ps1 present; HP.Build.psm1, layout and HP.Firmware.Tests.ps1 modified
- Commits 6e2167c, dfa0a75 and 7b23ff3 are on branch worktree-agent-a321db8663b6130a1
