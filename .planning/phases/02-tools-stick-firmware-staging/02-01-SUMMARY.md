---
phase: 02-tools-stick-firmware-staging
plan: 01
subsystem: firmware-staging
tags: [powershell-5.1, pester-6, fat32, sha256, manifest-validator, layout-loader]

requires:
  - phase: 01-modular-foundation
    provides: Kit.Core module, pinned export list test, vendor-name scan, lint gate
provides:
  - Get-KitFirmwareLayout (data-only layout loader, schema checks, Kit.FirmwareLayout object)
  - Test-FirmwareTarget (FAT32 volume refusal, volume-root check, -AllowFolder)
  - Test-FirmwareStage (manifest-driven stick validator returning Kit.FirmwareFinding objects)
  - Show-FirmwareStageFinding (green/yellow/red phone-width console output)
  - Private seam Get-KitVolumeInfo and helpers Get-KitStagePathProblem, Get-KitClosedFolder
  - tests/fixtures/firmware/fixture.layout.psd1 (neutral layout reused by plans 02-02, 02-03, 02-05)
affects: [02-02, 02-03, 02-04, 02-05, 02-06]

actuals:
  tokens: 25000
  tasks: 3
  commits: 3
plan_head_before: c717c2d087c9f867c7fd815a215cac43a329fd9d
plan_head_after: 9cf11d838a6f8bb3bb56c7ff81996cc1e0757ff5

tech-stack:
  added: []
  patterns:
    - "Manifest on the stick is the only source of expected files (D-05); no path list in code"
    - "Findings are Kit.FirmwareFinding objects; colour only inside the Show- function"
    - "Per-check cap of 10 detail findings, then one 'and N more' line"
    - "Layouts are data read with Import-PowerShellDataFile only; first problem thrown as 'Layout <path>: <problem>'"

key-files:
  created:
    - kit/core/FirmwareCheck.ps1
    - kit/core/FirmwareLayout.ps1
    - tests/Firmware.Check.Tests.ps1
    - tests/Firmware.Layout.Tests.ps1
    - tests/fixtures/firmware/fixture.layout.psd1
  modified:
    - kit/core/Kit.Core.psd1
    - tests/Core.Tests.ps1

key-decisions:
  - "Every check emits one Pass line when clean, so the phone screen shows what was checked, not only what failed"
  - "When the 10-per-check cap collapses only Warn findings, the 'and N more' line is a Warn; any collapsed Fail makes it a Fail"
  - "A record that fails the FAT32 name rules is not file-checked, so one bad file gives one line"
  - "Two records with the same path and same SHA-256 are fine; paths that differ only in case are a Names Fail; same path with different SHA-256 is a Duplicate Fail naming both model ids"
  - "Test-FirmwareTarget runs first; a missing or bad manifest adds one Manifest Fail after the target findings, never a throw"

patterns-established:
  - "Test stick built at run time inside TestDrive (New-TestStick helper), never a committed .bin"
  - "Layout rejection tests mutate the committed fixture text and fail loudly if the mutation does not change it"

requirements-completed: [FW-02, FW-03]

coverage:
  - id: D1
    description: "Test-FirmwareStage turns a missing, resized, re-hashed or vendor-hash-mismatched file into one Fail naming the manifest path"
    requirement: FW-03
    verification:
      - kind: unit
        ref: "tests/Firmware.Check.Tests.ps1#Test-FirmwareStage tracer"
        status: pass
    human_judgment: false
  - id: D2
    description: "The 2026-10-05 wrong-folder incident is a regression test (missing at the manifest path, unexpected file in a closed folder)"
    requirement: FW-03
    verification:
      - kind: unit
        ref: "tests/Firmware.Check.Tests.ps1#Test-FirmwareStage folders and root (the 2026-10-05 incident)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Two models writing different content to one destination are refused by path and both model ids; identical content is accepted"
    requirement: FW-02
    verification:
      - kind: unit
        ref: "tests/Firmware.Check.Tests.ps1#Test-FirmwareStage name rules and duplicates"
        status: pass
    human_judgment: false
  - id: D4
    description: "Get-KitFirmwareLayout loads the fixture, rejects every schema violation by file and problem, and never runs code in a layout"
    verification:
      - kind: unit
        ref: "tests/Firmware.Layout.Tests.ps1"
        status: pass
    human_judgment: false

duration: 24min
completed: 2026-10-19
status: complete
---

# Phase 2 Plan 01: Core layout loader and stick validator Summary

**Vendor-neutral Kit.Core now loads firmware layouts as validated data and proves a Tools stick against its own firmware-manifest.json (sizes, SHA-256, vendor hashes, FAT32 names, closed folders, READY, password files) with one red line per problem and phone-width output.**

## Performance

- **Duration:** 24 min
- **Started:** 2026-10-19T17:07:57Z
- **Completed:** 2026-10-19T17:31:33Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments

- `Test-FirmwareStage` reads only the stick's manifest and returns `Kit.FirmwareFinding` objects. It checks the target volume and label, required manifest keys, FAT32 name rules, file presence, size, SHA-256 and vendor hash, duplicate destinations, closed group folders (including `{Platform}` expansion), the stick root, password files and the READY marker. It also warns about unverified layouts, unverified platforms and minimum-BIOS dependencies. Output is capped at 10 detail findings per check.
- `Test-FirmwareTarget` refuses any volume that is not FAT32 by naming the volume root and the file system found, requires a volume root, warns on FAT32 reported as a fixed disk, and `-AllowFolder` skips the volume checks with one Warn.
- `Show-FirmwareStageFinding` prints `[PASS]` green, `[WARN]` yellow, `[FAIL]` red, wraps at `-Width` (default 44), puts the path on its own indented line and shortens it from the left so the file name survives.
- `Get-KitFirmwareLayout` loads a layout `.psd1` with `Import-PowerShellDataFile` only (a command expression throws "not a plain data file" and never runs), keeps group order, and throws `Layout <path>: <problem>` for every schema violation. Committed neutral `fixture.layout.psd1` is ready for plans 02-02, 02-03 and 02-05.
- Kit.Core exports `Get-KitFirmwareLayout`, `Test-FirmwareTarget`, `Test-FirmwareStage`, `Show-FirmwareStageFinding`, in that order after `Get-KitPublishFile`; manifest and pin changed together at each commit; no vendor word appears under `kit/core`.

## Task Commits

1. **Task 1: End-to-end validator tracer** - `17c62c3` (feat)
2. **Task 2: Complete the validator** - `e533000` (feat)
3. **Task 3: Layout loader and neutral fixture** - `9cf11d8` (feat)

**Plan metadata:** committed separately with this SUMMARY (docs).

_TDD note: each task is one commit holding its tests and implementation, because the pre-commit hook runs the full gate and rejects a commit with failing tests (see Deviations)._

## Files Created/Modified

- `kit/core/FirmwareCheck.ps1` - validator, target check, name rules, volume seam, closed-folder helper, console formatter
- `kit/core/FirmwareLayout.ps1` - `Get-KitFirmwareLayout` and the schema checks
- `kit/core/Kit.Core.psd1` - four new exports
- `tests/Core.Tests.ps1` - export pin updated with the manifest
- `tests/Firmware.Check.Tests.ps1` - hand-built-stick helpers, tracer, name rules, incident, volume, READY, warnings, cap, line formatting
- `tests/Firmware.Layout.Tests.ps1` - fixture load, 21 rejection cases, code-never-runs, accepted variants, export checks
- `tests/fixtures/firmware/fixture.layout.psd1` - neutral layout (FX_TOOLS, five groups, one capture)

## Decisions Made

See `key-decisions` above. None changes a requirement; each fills a gap the plan left to the implementer.

## Deviations from Plan

### TDD commit shape

**1. [Rule 3 - Blocking] RED and GREEN share one commit per task**
- **Found during:** Task 1
- **Issue:** The plan says "commit" after RED, but `.githooks/pre-commit` runs the full gate (lint plus all Pester tests) and rejects any commit with a failing test. A RED-only commit cannot land without bypassing the hook, which the project does not allow.
- **Fix:** Wrote tests first and confirmed RED, then implemented and committed tests plus code together. Task 1 RED was confirmed by the hook itself (13 tests failed, commit refused). Tasks 2 and 3 RED was established by inspection only (the functions did not exist when the tests were written); no separate failing run was made, to save two gate runs.
- **Files modified:** none (process only)
- **Commit:** n/a

### Test runner

**2. [Rule 3 - Blocking] Focused Test-Kit.ps1 runs were not possible from the executor shell**
- **Issue:** The worktree-isolated Bash tool refused to run `powershell.exe` directly. The full gate (secrets, lint, all tests under Windows PowerShell 5.1) was therefore run through the pre-commit hook on each commit, which executes the same `Test-Kit.ps1 -PreCommit`.
- **Result:** All three commits passed the full gate; no gate was skipped or bypassed.

### Plan wording resolved

**3. [Interpretation] "Message `missing` ... the Fail message names the file"**
- The plan asks for `Message` exactly `missing` and also for the message to name `R70_013600.bin`. The file is named by the finding's `Path` (the manifest path, which ends with the file name) and `Show-FirmwareStageFinding` prints that path on its own line. `Message` stays `missing`.

**4. [Interpretation] Cap collapse status**
- The plan says the overflow collapses into one Fail. If every collapsed finding was a Warn, the line is a Warn so a pile of root-entry warnings cannot turn a good stick red. Any collapsed Fail makes it a Fail.

## Issues Encountered

None beyond the deviations above. Lint reported 0 findings over 47 files on the last commit; the full suite ran 529 tests, 0 failed.

## Known Stubs

None.

## Threat Flags

None. All new surface (layout loader, validator) is covered by the plan's threat register: T-2-01 (path rules and tests for each), T-2-02 (data-file-only load plus the code-never-runs test), T-2-03 (READY recomputed from the manifest hash), T-2-04 (cap of 10 and width-bounded lines).

## User Setup Required

None.

## Next Phase Readiness

Plans 02-02 to 02-05 can build on `Get-KitFirmwareLayout`, `Get-KitClosedFolder` (private; reuse for `-RemoveStale`), `Test-FirmwareStage` and `Show-FirmwareStageFinding`. The private seam `Get-KitVolumeInfo` is mockable with `Mock Get-KitVolumeInfo -ModuleName Kit.Core`.

## Self-Check: PASSED
