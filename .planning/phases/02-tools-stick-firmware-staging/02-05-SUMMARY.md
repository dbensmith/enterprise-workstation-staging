---
phase: 02-tools-stick-firmware-staging
plan: 05
subsystem: firmware-staging
tags: [powershell-5.1, pester-6, master-build, exit-codes, child-process, fat32]

requires:
  - phase: 02-tools-stick-firmware-staging
    provides: Publish-FirmwareStage, New-KitFirmwareSnapshot (02-03); Test-FirmwareTarget, Test-FirmwareStage, Show-FirmwareStageFinding, Get-KitFirmwareLayout (02-01); fixture GetFirmwareStickLayout operation (02-02)
provides:
  - builder/Build-ToolsStick.ps1 (master firmware build: pick vendor and models, check target, build, stage, validate, exit 0 or 1)
  - tests/Builder.Master.Tests.ps1 (in-process and real child-process tests against the fixture vendor, with an Invoke-ScriptChild helper that has a timeout and file-fed standard input)
  - tests/fixtures/profiles/fixture/m2.psd1 (second fixture model)
affects: [02-06]

status: complete
actuals:
  tokens: 14200
  tasks: 3
  commits: 3
plan_head_before: 73b73ea5a951f0eef2814e6f6eec8663a611b3d0
plan_head_after: 61370291ce471f3b6ccae2d1270a2d2f11e9a921

tech-stack:
  added: []
  patterns:
    - "The master script names no vendor and writes no file; every write goes through Publish-FirmwareStage or New-KitFirmwareSnapshot (AST test forbids Copy-Item, Remove-Item, Set-Content, Out-File, Start-Process, Invoke-Expression, Format-Volume, Write-Host)"
    - "Target check (Test-FirmwareTarget) runs before any vendor operation, so a wrong volume costs no download"
    - "Every outcome ends in exit 0 (READY, no Fail) or exit 1 (everything else, including every exception) with a short [FAIL] line through Show-FirmwareStageFinding"
    - "Read-Host lives only in Select-BuildChoice and Read-BuildTarget; a session that cannot ask fails with 'Cannot ask for <name> here. Pass -<name> on the command line.'"
    - "Child-process tests run the real powershell.exe 5.1 with PSModulePath cleared, stdin from a file and a kill timeout"

key-files:
  created:
    - builder/Build-ToolsStick.ps1
    - tests/Builder.Master.Tests.ps1
    - tests/fixtures/profiles/fixture/m2.psd1
  modified:
    - kit/core/FirmwarePublish.ps1
    - tests/Firmware.Publish.Tests.ps1

key-decisions:
  - "Tests and implementation are committed together per task (3 commits): the pre-commit hook runs the full Pester suite, so a failing RED commit cannot land. RED was observed locally for Tasks 1 and 2 before the script existed or grew."
  - "In-process 'throws' behaviours of the plan are asserted as exit code 1 plus a [FAIL] line, because the script turns every exception into a red line and exit 1"
  - "Messages name the layout by file name, not full path, so they fit the 44-column phone screen"
  - "A drive letter given alone ('E' or 'E:') is read as the drive root, not the current folder on that drive"
  - "Under -WhatIf the vendor download is previewed, then 'WhatIf: nothing was staged' and exit 0 before GetFirmwareStickLayout"

requirements-completed: [BUILD-01, FW-01, FW-03, FW-05]

duration: one session
completed: 2026-10-20
---

# Phase 2 Plan 05: Master Tools Stick Build Summary

**builder\Build-ToolsStick.ps1: one command that picks a vendor and models, refuses a wrong target before any download, runs GetFirmware and GetFirmwareStickLayout per model, stages through Publish-FirmwareStage, validates, and exits 0 only for a READY stick.**

## What was built

- `builder/Build-ToolsStick.ps1` with the 16 documented parameters (Vendor, Model, TargetPath, DiagnosticsSource, CaptureName, NewDiagnosticsSnapshot, FlashModel, IncludeKit, RemoveStale, AllowFolder, ValidateOnly, OsVer, OutputRoot, VendorRoot, ProfileRoot, LayoutPath), full comment-based help (every parameter, four examples).
- Flow: import Kit.Core, resolve vendor (prompt when omitted; a single vendor is used and announced), parse and de-duplicate `-Model` (list or comma-joined string), load profiles (unknown id lists the available ids), check `-FlashModel` against the selection, resolve and check the target, run GetFirmware per model (`WhatIf` passed explicitly), ShouldProcess gate, run GetFirmwareStickLayout per model, require one shared layout file, replay or record the diagnostics capture, Publish-FirmwareStage, print one BIOS line per model, the stage findings and a last `READY - n files for m models` or `NOT READY - k problem(s); do not leave with this stick`.
- `-ValidateOnly` runs Test-FirmwareStage on the target and nothing else (no vendor, no download); it asks only for the target when that is missing.
- `tests/Builder.Master.Tests.ps1`: 41 It blocks (44 test cases). In-process runs against the fixture vendor (one model, two models with capture and snapshot, model-list parsing, -FlashModel, -IncludeKit, -RemoveStale, -WhatIf, -ValidateOnly, capture selection) and real child-process runs (two models from one comma-joined value, FAT32 and volume-root refusal with no vendor call, missing capture FW-05, altered capture, the 2026-10-05 wrong-folder incident, no manifest, unknown model, non-interactive prompt failure, prompts answered from standard input, answers running out, stale file with and without -RemoveStale, default `-OutputRoot`), plus script-shape tests.
- `tests/fixtures/profiles/fixture/m2.psd1`: second fixture model (Platform 0001, family F01).

## Behaviour proven by tests

- Both models' BIOS images land in `Vendor\BIOS\New` and `Vendor\BIOS\Current` with different content and neither overwrites the other; `firmware\fx\0000` and `firmware\fx\0001` hold the fallback files; the captured tree lands under `EFI\FX`; `FX\DEVFW` stays out of a normal build; the manifest lists both models and three shared records.
- A non-FAT32 or non-root target exits 1 with a red line naming the volume root; `<out>\fixture` is never created and no manifest exists anywhere.
- The incident (image moved to the wrong folder) exits 1 with `[FAIL]` and the image file name; moving it back exits 0.
- A missing capture exits 1 with a message that begins FW-05; an altered capture file exits 1, names the file and says it differs from the recorded snapshot, and READY is gone.
- `-Model m1,m2` as one command-line value (what `powershell.exe -File` delivers) selects both models.
- Prompts answered on standard input (`1`, `1,2`, stick path) build both models; running out of answers exits 1 instead of hanging; `-NonInteractive` names `-Model`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] $PSScriptRoot is empty in a param default under Windows PowerShell 5.1**
- **Found during:** Task 3 (the two child-process tests that do not pass `-OutputRoot`)
- **Issue:** With `[CmdletBinding()]` and `powershell.exe -File`, `$PSScriptRoot` is empty while parameter defaults are evaluated, so `[string]$OutputRoot = (Join-Path $PSScriptRoot '..\staging')` fails with "Cannot bind argument to parameter 'Path' because it is an empty string" for every run that omits `-OutputRoot`. The plan's interface block and its AST test pin that exact default text.
- **Fix:** `$OutputRoot` has no default in the param block; the body sets `if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot '..\staging' }`. The AST test now pins that assignment, and a child-process test proves the default works. The effective default is the one the plan intended.
- **Files modified:** builder/Build-ToolsStick.ps1, tests/Builder.Master.Tests.ps1
- **Commit:** 6137029

**2. [Rule 1 - Bug] A failed rerun left the READY of the earlier run on the stick**
- **Found during:** Task 3 (altered-capture test expects READY gone)
- **Issue:** Publish-FirmwareStage deleted READY only after Get-KitStagePlan succeeded, so a rerun refused at plan time (FW-05 altered or missing capture, bad entry, hash mismatch) left the old READY in place, the stale-marker pitfall (RESEARCH Pitfall 14). Core change was outside the plan's `files_modified`, but the plan's own behaviour ("READY is gone from the stick") and the FW-03 prohibition require it.
- **Fix:** The plan call is wrapped in try/catch; on failure the catch removes `<target>\READY` and rethrows, only when not under -WhatIf and only when the file's first line is a 64-character lower-case hex hash (a marker this function wrote). Three tests added to tests/Firmware.Publish.Tests.ps1 (removed on refusal, a foreign READY file is kept, -WhatIf leaves it).
- **Files modified:** kit/core/FirmwarePublish.ps1, tests/Firmware.Publish.Tests.ps1
- **Commit:** 6137029

**3. [Rule 3 - Blocking] RED and GREEN committed together**
- **Issue:** The pre-commit hook runs the whole Pester suite, so a commit with failing tests is rejected; the plan's separate RED commits cannot be made without bypassing the hook (same finding as Plan 02-03).
- **Fix:** One commit per task with tests and implementation together. RED was confirmed by running the focused tests before the script (Task 1: 6 failed) and before the new options (Task 2: 15 failed, 10 passed).

**4. [Rule 3 - Blocking] Test output matching across wrapped lines**
- **Issue:** Show-FirmwareStageFinding wraps at 44 columns, so a phrase or long path can split across lines.
- **Fix:** Messages name the layout by file name; the test helpers expose a `Flat` property (whitespace folded) for phrase matches. No product change.

### Plan wording interpreted

- In-process "throws a message" cases (unknown FlashModel, no capture in the layout, two captures without -CaptureName) are asserted as exit code 1 plus a `[FAIL]` line with the same message, because the script converts every exception into a red line and exit 1 (Task 3 rule).

## Auth gates

None.

## Deferred Issues

- **Build-DriverBaseline.ps1 has the same `$PSScriptRoot` param-default bug** (`[string]$OutputRoot = (Join-Path $PSScriptRoot '..\staging')` with `[CmdletBinding()]`). `Build.cmd -Vendor HP -Model 840-g6` without `-OutputRoot` fails at parameter binding under Windows PowerShell 5.1; existing tests always pass `-OutputRoot`. Out of scope here (plan says Build-DriverBaseline.ps1 stays unchanged); recorded in `deferred-items.md` in this phase directory.

## Known Stubs

None. The script has no placeholder data.

## Threat Flags

None. No new network endpoint or trust boundary beyond the plan's threat model (T-2-19 to T-2-22 mitigated and tested: target check before any vendor call, ValidatePattern on Vendor and FlashModel with model ids through Get-KitProfile, exit 0 only for READY without Fail, named-parameter message plus child timeout for prompts).

## Gate result

Pre-commit gate on the final commit: gitleaks staged scan clean, `Lint: 57 files, 0 findings`, `Tests: 721 passed` (Failed 0). No lint suppression of any kind. Build.cmd, builder/Build-DriverBaseline.ps1 and README.md are unchanged (`git log --name-only` over the plan lists only the five files below).

## Files changed

builder/Build-ToolsStick.ps1, tests/Builder.Master.Tests.ps1, tests/fixtures/profiles/fixture/m2.psd1, kit/core/FirmwarePublish.ps1, tests/Firmware.Publish.Tests.ps1

## Commits

- 07f0519 feat(02-05): add master Tools stick build
- 48ff5c4 feat(02-05): add prompts, capture and stage options
- 6137029 feat(02-05): fail loudly from the master build

## Self-Check: PASSED
