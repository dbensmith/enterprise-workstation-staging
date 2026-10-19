---
phase: 01-modular-foundation
plan: 07
subsystem: laptop-entry-points
tags: [powershell-5.1, pester-6, launcher, installer, transcript, uac, audit, tdd]

requires:
  - phase: 01-modular-foundation
    provides: "Kit.Core with Get-KitVendor, Invoke-KitVendorCommand, Get-KitConfig, ConvertTo-KitCommandLine (01-02, 01-03, 01-05); HP target module (01-04); HP descriptor (01-06)"
provides:
  - "kit/Run.cmd: operator's one command, CRLF, clears PSModulePath, starts 5.1 with process-scope Bypass"
  - "kit/Run.ps1: -Mode Audit|Install dispatcher; third-party config presence line; UAC relaunch for real Install runs only"
  - "kit/Install-DriverBaseline.ps1: vendor-neutral installer (-PackagePath, -OfflineImagePath, -SkipFirmware, -Force, -LogPath, -Vendor) running every vendor step through Invoke-KitVendorCommand"
  - "kit/Test-DeviceBaseline.ps1: the audit, moved with no content change; nothing left at src/Test-DeviceBaseline.ps1"
  - "tests/Kit.Tests.ps1 and package fixtures minimal and broken-fw"
affects: [01-08]

actuals:
  tokens: 6300
  tasks: 3
  commits: 7
plan_head_before: b09255afa82a8b1b148736af4c245053cb64c6a3
plan_head_after: c2578258a4060e64727a77ad35570bc0e766340c
commits: 7

tech-stack:
  added: []
  patterns:
    - "Installer progress goes through a Show-InstallMessage helper that writes to the host, because Windows PowerShell 5.1 keeps the information stream out of a transcript"
    - "The elevated relaunch line is built from PSBoundParameters and quoted by ConvertTo-KitCommandLine; -WhatIf never elevates"
    - "The web-style audit run is a script block built from the file text, so irm | iex is exercised without Invoke-Expression"
    - "Moves are a pure-rename commit (R100) before the rewrite so git log --follow keeps the history"

key-files:
  created:
    - kit/Run.cmd
    - kit/Run.ps1
    - tests/Kit.Tests.ps1
    - tests/fixtures/packages/minimal/manifest.json
    - tests/fixtures/packages/broken-fw/manifest.json
  modified:
    - kit/Install-DriverBaseline.ps1
  moved:
    - "src/Install-HPDriverBaseline.ps1 -> kit/Install-DriverBaseline.ps1 (R100 commit, then rewrite)"
    - "src/Test-DeviceBaseline.ps1 -> kit/Test-DeviceBaseline.ps1 (R100, content unchanged)"

key-decisions:
  - "Elevation lives in Run.ps1, not Run.cmd (RESEARCH Pattern 9); Audit never elevates"
  - "The installer's #Requires -RunAsAdministrator became an explicit check that lets -WhatIf rehearse unelevated"
  - "No forwarder at the old audit path (user decision 2026-10-18); README is left to Plan 01-08"

patterns-established:
  - "Child-process end-to-end tests run native commands through one helper with a local ErrorActionPreference of Continue and merged output"

requirements-completed: [REPO-01, REPO-06, SEC-02]

duration: 35min
completed: 2026-10-19
status: complete
---

# Phase 1 Plan 07: Laptop entry points

The operator's one command now reaches the HP module through the common module. `kit\Run.cmd -Mode Install -PackagePath <pkg> -Vendor HP -Force -WhatIf` runs from cmd.exe under Windows PowerShell 5.1, changes nothing, prints the baseline line and `Done with 0 failure(s)`, and exits 0. The installer is vendor-neutral, the `-LogPath` first-boot form binds and logs even on failure, and the audit lives at `kit/Test-DeviceBaseline.ps1` with nothing left under `src/`.

## Tasks

| Task | Name | RED | GREEN |
|------|------|-----|-------|
| 1 | Tracer: Run.cmd -> Run.ps1 -> Install-DriverBaseline.ps1 -> Kit.Core -> HP target (-WhatIf) | ca774d0 | d971066 (pure rename), c3d4cdd |
| 2 | -LogPath transcript, failure exit codes, offline rehearsal, config presence, Install-only elevation | 31c9074 | afe93b8 |
| 3 | Move the audit into kit/, nothing left at src/ | n/a (move first, per plan) | 4993077 (R100 move), c257825 (tests) |

## Verification

Full gate, `env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1`, run after the last code commit: exit 0, lint 39 files / 0 findings, 348 Pester tests passed, no suppressions. Before this plan the gate had 324 tests. PSScriptAnalyzer did not hit the RULE_ERROR null reference in these runs. Both RED runs were confirmed failing before their commits (5 and 7 failures).

Plan truths checked by tests in tests/Kit.Tests.ps1:
- Run.cmd bytes are CRLF only, hold `set "PSModulePath="`, `-ExecutionPolicy Bypass`, `"%~dp0Run.ps1" %*`, `exit /b %ERRORLEVEL%`, and `git check-attr eol` says crlf.
- The cmd.exe -WhatIf install rehearsal exits 0 with `Baseline: Fixture package` and `Done with 0 failure(s)`; `-Mode Install` without a package path exits non-zero with `-PackagePath is required`.
- Installer AST: all six parameters, `Invoke-KitVendorCommand` present, no `-HP`/HPCMSL command, no `Get-KitConfig`.
- `-LogPath` run on the minimal package exits 0 with `Done with 0 failure(s)` and `End time` in the log; the broken-fw package exits 1 with `executable not found` in the output and the log, which still has `End time`; the offline `-WhatIf` run exits 0 and shows `dism.exe`.
- Run.ps1 AST: exactly one `Start-Process ... -Verb RunAs`, inside the else (Install) clause of the `$Mode -eq 'Audit'` branch; no `Set-ExecutionPolicy`. A copy of kit/ with a sentinel `InstallToken` prints `Third-party settings: found in config.local.psd1`, and neither the output nor the transcript contains the sentinel.
- Audit: `Run.cmd -Mode Audit -OutFile` writes the file with ` SERIAL     : `; the audit text run as a script block with `PK_OUTFILE` set, no script folder, saves the file and prints `Saved: `; the old src path is untracked and absent; the audit holds `PK_OUTFILE`, `[string]$OutFile`, `Read-Host`, `DriveType -eq 'Removable'`, and no `Import-Module` or dot-source.

Acceptance checks: `git show -M --name-status` of the two moves prints `R100` (installer and audit); `git ls-files src/Install-HPDriverBaseline.ps1 src/Test-DeviceBaseline.ps1` prints nothing.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Plan bug] Stop-Transcript has no -WhatIf**
- **Found during:** Task 2 GREEN
- **Issue:** The plan (and acceptance criterion) asks for `Stop-Transcript -WhatIf:$false`. Windows PowerShell 5.1 rejects it with `NamedParameterNotFound`; only `Start-Transcript` honours WhatIf. The first -LogPath run printed the error after the work finished and exited 1.
- **Fix:** `Start-Transcript -Path $LogPath -Append -WhatIf:$false` as specified; plain `Stop-Transcript` in the finally block. The test asserts the exact start text, that the finally block stops the transcript, and that every `exit` sits inside that try.
- **Commit:** afe93b8

**2. [Rule 1 - Bug] Write-Information is not transcribed on 5.1**
- **Found during:** Task 2 GREEN
- **Issue:** With `Write-Information`, the transcript held the What-if lines but not `Done with 0 failure(s)`, so a first-boot log would not show what the install did.
- **Fix:** progress lines go through a small `Show-InstallMessage` helper (Write-Host inside a Show- function, the same pattern the audit and Test-Kit.ps1 already use; no lint suppression). Firmware rows that are not failures are now also printed by the installer, because the module's own `Write-Information` lines do not reach the console or the log.
- **Commit:** afe93b8

**3. [Rule 3 - Blocking] Interim LogPath use in Task 1**
- **Found during:** Task 1 gate
- **Issue:** PSReviewUnusedParameter flagged `-LogPath` (declared in Task 1, implemented in Task 2).
- **Fix:** a one-line `Write-Verbose` in Task 1's commit, replaced by the real transcript in Task 2.
- **Commit:** c3d4cdd, afe93b8

**4. [Rule 1 - Plan wording] Offline test needs a package with a Drivers folder**
- **Found during:** Task 2 RED
- **Issue:** The HP driver command skips a package with no Drivers folder before it reaches dism, so the minimal fixture never prints `dism.exe`.
- **Fix:** the offline It builds a throwaway package under TestDrive (copied manifest plus an empty Drivers folder).
- **Commit:** 31c9074

**5. [Rule 3 - Test adjustment] Third-party line prefix**
- The "not configured" form is a warning, so merged output reads `WARNING: Third-party settings: ...`; the test accepts that prefix. The "found" form is a plain line.

### Other notes

- The pure installer rename (d971066) is a separate commit before the rewrite so `git log --follow` reaches the original import. That commit alone leaves a script that is not yet vendor-neutral; only the end of the series is meant to be green.
- Under `-WhatIf` in a fresh session, Windows PowerShell prints about a dozen `What if: Performing the operation "Set Alias"` lines while CimCmdlets autoloads. They come from the module load under the ambient WhatIf preference, not from the kit; left as is (cosmetic).
- The elevated window opened by UAC closes when the install ends and its output is not visible in the first window. Operators who need the output should pass `-LogPath`. Covered by the manual UAC check below.

## Manual checks still open

- UAC relaunch (RESEARCH Assumption A3): on a laptop or VM, from a normal cmd on the stick, `Run.cmd -Mode Install -PackagePath <built package> -WhatIf` shows no prompt; the same without `-WhatIf` shows one UAC prompt, the elevated window runs with the same parameters, and the first window ends with the installer's exit code.
- `irm .../main/kit/Test-DeviceBaseline.ps1 | iex` on a networked laptop after the branch is merged (needs README from Plan 01-08).

## Known Stubs

None.

## Threat Flags

None. T-1-21 (UAC only in the Install branch and never under -WhatIf, process-scope Bypass, quoted arguments) and T-1-22 (installer never calls Get-KitConfig; Run.ps1 prints fixed text, sentinel test) are mitigated and tested; T-1-24 (removable-only default untouched, test asserts it) holds; T-1-23 is accepted as planned.

## Self-Check: PASSED

kit/Run.cmd, kit/Run.ps1, kit/Install-DriverBaseline.ps1, kit/Test-DeviceBaseline.ps1, tests/Kit.Tests.ps1 and both package fixtures exist; src/Install-HPDriverBaseline.ps1 and src/Test-DeviceBaseline.ps1 are neither tracked nor on disk; commits ca774d0, d971066, c3d4cdd, 31c9074, afe93b8, 4993077 and c257825 are ancestors of HEAD.
