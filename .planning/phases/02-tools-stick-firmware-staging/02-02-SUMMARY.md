---
phase: 02-tools-stick-firmware-staging
plan: 02
subsystem: vendor-contract
tags: [powershell, hp, hpcmsl, firmware, vendor-contract, pester]
requires:
  - phase: 02-tools-stick-firmware-staging (plan 01)
    provides: Get-KitFirmwareLayout loader and tests/fixtures/firmware/fixture.layout.psd1
provides:
  - "Contract operation GetFirmwareStickLayout (Build plane), nine entries"
  - "Result contract Kit.FirmwareStickLayout"
  - "Get-HPKitFirmwareStickLayout (HP.Build) and Get-FixtureKitFirmwareStickLayout"
  - "kit/vendors/hp/layouts/hp-usb-flash.layout.psd1 (seven groups, one Verified block each)"
affects: [02-03, 02-04, 02-05]
tech-stack:
  added: []
  patterns:
    - "Vendor build operation reads the package GetFirmware already filled; no second download"
    - "Catalog hash must equal the file hash or the call throws naming the file"
key-files:
  created:
    - kit/vendors/hp/layouts/hp-usb-flash.layout.psd1
    - tests/Firmware.Vendor.Tests.ps1
    - tests/HP.Firmware.Tests.ps1
  modified:
    - kit/core/VendorContract.psd1
    - kit/core/Vendor.ps1
    - kit/vendors/hp/vendor.psd1
    - builder/vendors/hp/HP.Build.psm1
    - tests/fixtures/vendors/complete/vendor.psd1
    - tests/fixtures/vendors/complete/Fixture.Build.psm1
    - tests/fixtures/vendors/missing-op/vendor.psd1
    - tests/Contract.Negative.Tests.ps1
    - tests/HP.Build.Tests.ps1
key-decisions:
  - "Original BIOS image names are kept as destination names (FW-02)"
  - "Vendor download hash is SHA-384 from the HP catalog, checked against the file before anything is returned (BUILD-06)"
  - "Catalog versions compared as [version]; LatestBios.Version formatted two digits per part"
requirements-completed: [FW-01, FW-02, BUILD-06]
status: complete
commits: 4
plan_head_before: 81439b5f8507001a5a54f913605371a1a05840ee
plan_head_after: 8d22499b27227e617b64152da35f90285542bc28
actuals:
  tokens: 30000
  tasks: 3
  commits: 4
duration: ~35min
completed: 2026-10-19
---

# Phase 2 Plan 02: Vendor stick-layout operation Summary

New Build-plane contract operation `GetFirmwareStickLayout` that turns a downloaded firmware package into resolved Tools-stick entries with original file names and a catalog-verified SHA-384, implemented for HP (`Get-HPKitFirmwareStickLayout`) and for the fixture vendor, with the HP layout shipped as data (seven candidate groups, each its own unverified `Verified` block).

## What was built

- **Contract (nine entries):** `GetFirmwareStickLayout(ModelProfile, PackagePath, LayoutPath)` sits directly after `GetFirmware` in `kit/core/VendorContract.psd1`; `Invoke-KitVendorCommand` accepts the name. HP, the complete fixture and the missing-op fixture map it. `Test-KitVendorContract` reports nothing for HP and the complete fixture and exactly one `MissingOperation InstallDrivers` for the missing-op fixture.
- **HP resolver:** asks `Get-HPBIOSUpdates -Platform <id> -All`, picks the highest `[version]`, finds the image by the catalog `Bin` name inside the folder `Save-HPKitFirmware` filled, checks SHA-384 against the catalog (case-insensitive), records SHA-256 and the SHA-384 `VendorHash`, and emits entries per layout group (BiosImage -> `<Folder>\<Bin>`, FlashImage -> `<Folder>\firmware.bin`, Captured -> nothing, other kinds throw). Read-only.
- **Safety rails (T-2-05/06/07):** each of these throws a message naming the file: empty catalog (names platform and model), catalog entry without Sha384, catalog file name that is empty or holds a path separator, wildcard or drive character, image missing (says to run the firmware stage first), image in two SoftPaq folders (lists both), wrong family (name must start with the profile BiosFamily), SHA-384 mismatch (`does not match the HP catalog hash for 1.36.00`). A test proves the package tree is byte-identical before and after.
- **HP layout data:** `hp-usb-flash.layout.psd1`, label `HP_TOOLS`, FAT32, groups F10-New, F10-New-ESP, Diag-Current, Diag-Current-ESP, Diag-Tree (Captured:diagnostics-sp171653), Esc-DEVFW, Esc-DEVFW-ESP; the two DEVFW groups default off; all seven `Verified.Status = $false`.
- **Fixture vendor:** `Save-FixtureKitFirmware` writes a run-time fake image (`<BiosFamily>_000100.bin`, never committed); `Get-FixtureKitFirmwareStickLayout` returns the same result contract for BiosImage, FlashImage and WindowsFlashTool groups and nothing for Captured groups, plus a `WindowsFlash` block.

## Task Commits

1. Fixture command and run-time image: `8e11e1c` feat(02-02): add fixture stick layout op
2. HP layout data and resolver (happy path): `69bfc7b` feat(02-02): add HP stick layout resolver
3. Resolver safety rails: `04785e9` feat(02-02): add HP resolver safety rails
4. Contract entry, dispatch, descriptor mappings, pins: `8d22499` feat(02-02): add GetFirmwareStickLayout operation

Full gate on the final commit: lint 50 files 0 findings, secrets clean, 587 tests passed, 0 failed.

## Deviations from Plan

### Auto-fixed / structural

**1. [Rule 3 - Blocking] Commit order changed so every commit passes the pre-commit gate**
- **Found during:** Task 1 planning
- **Issue:** The plan commits Task 1 (contract table change) while the HP descriptor, the missing-op fixture and `Contract.Negative.Tests.ps1` pins are still unchanged, which leaves the full gate red. The pre-commit hook runs the whole gate and refuses a red commit; RED test-only commits are likewise impossible.
- **Fix:** Four green commits in dependency order: fixture command (tested by calling the fixture module directly) -> HP layout and resolver -> resolver guards -> contract table, `ValidateSet`, all three descriptor mappings, `Contract.Negative` pins and the contract/dispatch tests together. RED was confirmed by attempting the commit with tests only (gate failed: 9 failed for the fixture command, 12 failed for the HP resolver); the safety-rail tests were written before the guards but their separate RED run was not done.
- **Files modified:** same set as the plan.

**2. [Rule 1 - Bug in plan text] FW-02 "no shared RelativePath" cannot hold for the FlashImage groups**
- **Issue:** Both `Esc-DEVFW` groups write the fixed name `HP\DEVFW\firmware.bin` and `EFI\HP\DEVFW\firmware.bin` for every model, so the G5 and G6 results share those two paths by design (the layout comment says that folder holds one model only; they are `Default = $false`).
- **Fix:** The G5/G6 coexistence test asserts no shared path and the shipped name for all four BIOS image groups (the default-on ones), and excludes the two `firmware.bin` flash entries with a comment. Plan 02-03 must keep those two groups off unless a single model is staged.

**3. [Rule 3 - Blocking] Test ordering inside HP.Firmware.Tests.ps1**
- `Test-KitVendorContract` re-imports with `-Force` and then removes the vendor build module, detaching the Pester mocks bound to `HP.Build`. The descriptor test is therefore the last Describe in the file (comment explains), so other tests in the file keep their module.

### Other notes

- Catalog `Bin` validation rejects any character a file name cannot hold (separator, wildcard, colon), a superset of the plan's "path separator", because `-Filter` would otherwise treat `*` as a wildcard.
- The hash-mismatch message prints the catalog `Ver` text (`1.36.00`), as the plan's wording requires, not the zero-padded `01.36.00`.
- One full-gate run during the third commit reported 1 failed of 576; an immediate rerun of the identical tree passed (576). The failing test was not identified (output was truncated); no cause was found in the new code. Flag if it recurs.

## Known Stubs

None. The Diag-Tree capture names `captures\diagnostics-sp171653.snapshot.psd1`, which does not exist yet; it is produced by a later plan (the loader does not require the file).

## Threat Flags

None beyond the plan's threat model (T-2-05, T-2-06, T-2-07 all mitigated and tested).

## Self-Check: PASSED

- Files present: `kit/vendors/hp/layouts/hp-usb-flash.layout.psd1`, `tests/Firmware.Vendor.Tests.ps1`, `tests/HP.Firmware.Tests.ps1`, `builder/vendors/hp/HP.Build.psm1` (contains `function Get-HPKitFirmwareStickLayout`), `tests/fixtures/vendors/complete/Fixture.Build.psm1` (contains `function Get-FixtureKitFirmwareStickLayout`).
- Commits `8e11e1c`, `69bfc7b`, `04785e9`, `8d22499` are ancestors of HEAD.
- No `.bin` file is tracked.
