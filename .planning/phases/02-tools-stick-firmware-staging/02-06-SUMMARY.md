---
phase: 02-tools-stick-firmware-staging
plan: 06
subsystem: docs
tags: [firmware, docs, readme, pester, hp, fw-06]
requires:
  - phase: 02-tools-stick-firmware-staging
    provides: "layout (02-04) and master build script (02-05)"
provides:
  - "docs/firmware-bench-checklist.md, an optional FW-06 bench procedure and Verified-block recording format"
  - "README section '## Tools stick firmware' with first-run and later-run commands"
  - "tests/Docs.Firmware.Tests.ps1, tying docs to layout groups and Build-ToolsStick.ps1 parameters"
affects: [FW-06]
tech-stack:
  added: []
  patterns: ["docs pinned to data files by tests generated from the layout and the script AST"]
key-files:
  created:
    - docs/firmware-bench-checklist.md
    - tests/Docs.Firmware.Tests.ps1
  modified:
    - README.md
key-decisions:
  - "FW-06 is DEFERRED (no G5/G6 hardware, none expected). The checklist and README call the bench optional and imply no bench is planned."
  - "FW-06 stays unchecked; REQUIREMENTS.md, STATE.md and ROADMAP.md were not touched (the orchestrator annotates FW-06)."
status: complete
commits: 2
plan_head_before: fce9a0f66ff6f31e04b3ad6c9e7cf92b5773461d
plan_head_after: 0f89e967b7772b832ca3d00ec970a90b6193176f
actuals:
  tokens: 7000
  tasks: 2
  commits: 2
completed: 2026-10-20
---

# Phase 2 Plan 06: Bench Checklist and README Summary

Optional FW-06 bench checklist (nine headings, one Appendix A row per layout group) plus a README "Tools stick firmware" section, with docs pinned to the layout file and the script's parameter block by tests. FW-06 is deferred, not scheduled.

## Tasks

| Task | Name | Commit | Files |
| --- | --- | --- | --- |
| 1 | Bench checklist pinned to layout groups and script switches | 351e44b | docs/firmware-bench-checklist.md, tests/Docs.Firmware.Tests.ps1 |
| 2 | README section, tree lines, pinned sections untouched | 0f89e96 | README.md, tests/Docs.Firmware.Tests.ps1 |
| 3 | FW-06 bench on real 840 G6 and 840 G5 (checkpoint:human-verify) | none | none |

## Deferred: no hardware available

Task 3 (checkpoint:human-verify, FW-06 bench): **Deferred: no hardware available.** Benjamin has no HP EliteBook 840 G5 or 840 G6 and will not get any. This overrides the plan's "pending human verification" wording. It was not waited on, not approved and not auto-approved, and the plan finished. The three human-check blocks of Task 1 (flash and F2 on real G5/G6; F2 shows diagnostics 10.8.5.0; real FAT32 stick -ValidateOnly) stay unexecuted for the same reason.

The checklist stays in the repo as an optional procedure for anyone who later has the hardware. Its wording (and the README's) says FW-06 is deferred and the bench is optional; it names no date and does not imply a bench is planned. It still says "FW-06 stays open until the Verified blocks below are filled for a real G5 and a real G6", so it does not claim the requirement is done.

Invariants held: FW-06 is still `- [ ]` and `| FW-06 | Phase 2 | Pending |` in .planning/REQUIREMENTS.md (checked with the plan's grep). No layout `Verified.Status` was changed (the layout file is not in the diff). No file under .planning/ was edited except this SUMMARY.

## Deviations from Plan

**1. [Operator override] FW-06 deferred, not pending a bench**
- **Found during:** Task 1, Task 3
- **Change:** README tree line for the checklist, README closing paragraph and the checklist intro say "deferred" and "optional" instead of describing a coming bench. Tests assert the words `deferred` and `optional` are present and `scheduled` is absent in the checklist, and `deferred` present and `scheduled` absent in the README section.
- **Files:** docs/firmware-bench-checklist.md, README.md, tests/Docs.Firmware.Tests.ps1

**2. [Rule 3 - Blocking] Combined RED and GREEN commits**
- **Issue:** The pre-commit hook runs the full gate, so a commit holding only failing tests is rejected. The RED step was proven by letting the hook run on the test-only commit (45 failures, commit refused), then again after fixing the tests' own bugs (13 README failures with the checklist in place). Each task is therefore one commit holding tests and implementation.
- **Commits:** 351e44b, 0f89e96

**3. [Rule 1 - Bug] Test defects found by the gate, fixed before the commits**
- Discovery-phase variables are not visible at run time in Pester, bare-string `-ForEach` items have no named variable, and PSScriptAnalyzer (PSUseOutputTypeCorrectly) flagged two helper functions. Fixed in the tests (values read in BeforeAll, hashtable ForEach items, helpers without CmdletBinding like Repo.Tests.ps1). No lint rule was disabled.

**4. [Environment] Focused test runs not available**
- The sandbox refuses `powershell.exe` in a Bash command, so `Test-Kit.ps1 -TestPath` could not be run directly. `git hook run pre-commit` (the full gate, about 2.5 minutes) was used for every test run.

## Verification

- Full gate via the pre-commit hook on both commits: lint 59 files 0 findings, gitleaks clean, Pester 849 passed, 0 failed.
- tests/Repo.Tests.ps1 "Operator docs" and tests/Builder.Tests.ps1 Build.cmd tests pass unchanged. README "Start here" still holds exactly three fenced commands; Build.cmd still points at builder\Build-DriverBaseline.ps1.
- README section has exactly two fenced commands, only the first with -NewDiagnosticsSnapshot; every switch printed after Build-ToolsStick.ps1 is a real parameter (AST check).

## Known Stubs

None.

## Threat Flags

None. Documentation and tests only.

## Self-Check: PASSED

- docs/firmware-bench-checklist.md, tests/Docs.Firmware.Tests.ps1, README.md present.
- Commits 351e44b and 0f89e96 are ancestors of HEAD.
