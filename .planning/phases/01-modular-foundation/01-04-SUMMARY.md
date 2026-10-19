---
phase: 01-modular-foundation
plan: 04
subsystem: hp-target-plane
tags: [powershell-5.1, pester-6, hp, firmware, drivers, bitlocker, tdd]

requires:
  - phase: 01-modular-foundation
    provides: "Kit.Core module with Invoke-KitTool (plan 01-02)"
provides:
  - "kit/vendors/hp/HP.Target.psm1: ConvertTo-HPBiosVersion, Get-FirmwareSkipReason, Get-HPKitInstalledFirmware, Get-HPKitDeviceIdentity, Install-HPKitDriver, Install-HPKitFirmware"
  - "tests/HP.Target.Tests.ps1: 37 tests in five Describes, every Mock and Should -Invoke carries -ModuleName HP.Target"
affects: [01-06, 01-07]

actuals:
  tokens: 8076
  tasks: 3
  commits: 6
plan_head_before: ae7a3d993aa0a86804cba050ba515da9474ae8cf
plan_head_after: 06c846680c7d05e5ea91b2afd81f810edb3a0737
commits: 6

tech-stack:
  added: []
  patterns:
    - "Default throwing Get-CimInstance mock in every Describe that touches CIM; specific -ParameterFilter mocks registered after it"
    - "Mock bodies read $script: variables each It sets (no closures)"
    - "Stub global BitLocker functions created with Set-Item Function:\\global: only when the BitLocker module is absent, removed in AfterAll"
    - "Private ConvertTo-HPKitResult builds the one result shape both install commands emit"

key-files:
  created:
    - kit/vendors/hp/HP.Target.psm1
    - tests/HP.Target.Tests.ps1
  modified: []

key-decisions:
  - "Install-HPKitDriver calls ShouldProcess (so -Confirm answered No stops it) and still calls Invoke-KitTool under -WhatIf with -WhatIf:$WhatIfPreference, so the real command line is printed and nothing runs"
  - "Install-HPKitFirmware orders items by partition (non-BIOS then BIOS) instead of Sort-Object, so manifest order is kept within each group on 5.1"
  - "Under -WhatIf, items and drivers report Result SKIPPED with Detail 'WhatIf: nothing run'"
  - "Driver results carry Mode (Online or Offline) and a null ExitCode; Invoke-KitTool does not return the code"

patterns-established:
  - "Firmware executable containment: GetFullPath of package folder + item folder + file, must start with '<package>\\Firmware\\' (OrdinalIgnoreCase, trailing backslash so Firmware2 does not match)"

requirements-completed: [REPO-02, REPO-06]

duration: 25min
completed: 2026-10-19
status: complete
---

# Phase 1 Plan 04: HP target-plane module

HP target half of the vendor contract: the four target commands (InstallDrivers, InstallFirmware, GetDeviceIdentity, GetInstalledFirmwareVersion) plus the two functions the old tests demanded and nobody wrote (`ConvertTo-HPBiosVersion`, `Get-FirmwareSkipReason`). The module loads on stock Windows PowerShell 5.1 with no HPCMSL and no admin (CIM, registry, pnputil.exe, dism.exe and package firmware executables only). The eight firmware-gating tests that failed in the Pester 6.2.0 baseline now pass.

## Tasks

| Task | Name | RED | GREEN |
|------|------|-----|-------|
| 1 | Tracer: installed-firmware read through the BIOS parser | d0baf02 | 74c498a |
| 2 | Firmware skip gate and device identity | 245434c | eb4228f |
| 3 | Driver and firmware install commands | 743852a | 06c8466 |

## Verification

Full gate, `env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1`, run after the final code commit: exit 0, lint 28 files / 0 findings, 211 Pester tests passed (37 of them in tests/HP.Target.Tests.ps1), no suppressions. Each RED run was confirmed failing before the commit (5 failed, then 11 failed, then 21 failed).

Plan truths checked: the restored parse and skip/run/device assertions pass with the original data (equal and one-step-newer skip; one-step-older, garbage and S70 do not); 'no matching device in this PC' is exact; identity falls back to the registry BaseBoardProduct (mocked '83B2'); dism.exe and pnputil.exe argument lists and the four accepted OkCodes are asserted; a package with no Drivers folder gives one SKIPPED result and zero Invoke-KitTool calls; BIOS runs after the non-BIOS item although it is listed first in the manifest; 3010 maps to SUCCESS, 290 to CANCEL, 7 to FAILURE, 0 to SUCCESS; missing and out-of-package executables give FAILURE with Start-Process never called; Suspend-BitLocker is called once with `$env:SystemDrive` and RebootCount 1 only when a to-be-run item needs a reboot and protection is On, and never when the BIOS is skipped, protection is Off, or under -WhatIf.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Lint] PSShouldProcess on Install-HPKitDriver**
- **Found during:** Task 3 GREEN gate
- **Issue:** The function declared SupportsShouldProcess but only delegated to Invoke-KitTool; PSScriptAnalyzer does not see delegation across a module boundary and flagged it. The plan's GREEN text did not call ShouldProcess.
- **Fix:** The function now calls `$PSCmdlet.ShouldProcess(...)` and proceeds when that is true OR `$WhatIfPreference` is set, so a -WhatIf run still reaches Invoke-KitTool with `-WhatIf:$WhatIfPreference` (the plan's required behaviour) while a -Confirm answered No now stops. No suppression.
- **Files modified:** kit/vendors/hp/HP.Target.psm1
- **Commit:** 06c8466

**2. [Rule 3 - Lint] PSReviewUnusedParameter on the BitLocker stubs in the test**
- **Found during:** Task 3 GREEN gate
- **Issue:** The stub scriptblocks declared MountPoint and RebootCount without using them.
- **Fix:** the stub body assigns both to `$null`. No suppression.
- **Files modified:** tests/HP.Target.Tests.ps1
- **Commit:** 06c8466

### Other notes

- Tests added beyond the plan: empty string parse, case-insensitive device IDs, driver -WhatIf not passed when not requested, failing tool propagates, launch error maps to FAILURE, BitLocker Off, BitLocker suspend failure only warns.
- The RED commit for Task 3 left the BitLocker stub unused-parameter lint finding, fixed in the GREEN commit (the RED commit is not required to pass lint; the gate was run after GREEN).
- Not tested: the `-Confirm` answered No branch of Install-HPKitDriver (it would need an interactive prompt).
- PSScriptAnalyzer RULE_ERROR did not recur.

## Known Stubs

None. The global `Get-BitLockerVolume` / `Suspend-BitLocker` functions are test-only stand-ins, created only when the BitLocker module is absent and removed in AfterAll.

## Threat Flags

None. T-1-11 (BitLocker suspend scoped to the system drive, one reboot, only when needed, inside ShouldProcess), T-1-12 (unknown or mismatched BIOS never skips) and T-1-13 (executable must stay under `<package>\Firmware\`) are mitigated and each has a test.

## Self-Check: PASSED

kit/vendors/hp/HP.Target.psm1 and tests/HP.Target.Tests.ps1 exist; commits d0baf02, 74c498a, 245434c, eb4228f, 743852a and 06c8466 are ancestors of HEAD.
