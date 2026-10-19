---
phase: 01-modular-foundation
plan: 06
subsystem: hp-vendor-and-build-entry
tags: [powershell-5.1, pester-6, vendor-contract, hp, build-plane, tdd]

requires:
  - phase: 01-modular-foundation
    provides: "Vendor contract and Get-KitVendor / Invoke-KitVendorCommand (01-03), HP target module (01-04), profiles and Get-KitProfile (01-05), Get-KitPackagePath (01-02)"
provides:
  - "kit/vendors/hp/vendor.psd1: HP descriptor mapping all eight contract entries"
  - "builder/vendors/hp/HP.Build.psm1: Get-HPKitModel, Save-HPKitVendorPack (BUILD-03 stub), New-HPKitCustomPack and Save-HPKitFirmware (the old Drivers and Firmware stages), with lazy HPCMSL"
  - "builder/Build-DriverBaseline.ps1: vendor-neutral build entry (-Vendor, -Model or -ProfilePath, -VendorRoot, -OutputRoot, -OsVer, -Stage) writing manifest SchemaVersion 2"
  - "tests/Builder.Tests.ps1 plus fixture build ops and fixture profile: end-to-end build without HPCMSL or admin"
affects: [01-07, 01-08]

actuals:
  tokens: 11880
  tasks: 3
  commits: 7
plan_head_before: 46ebdef1465e7c59853eeb895fd705fb195fcb3b
plan_head_after: 4294faefcc675898d2a00f72d003a8cca7cf79e8
commits: 7

tech-stack:
  added: []
  patterns:
    - "Build operations take the staging ROOT and compute their own package folder with Get-KitPackagePath, because only the vendor can resolve an empty OsVer to the newest catalog release"
    - "Third-party command names in tests (HPCMSL) are faked by a stand-in module generated from a name/parameter table, so the real names stay lint-clean without suppression"
    - "-WhatIf is passed to vendor commands explicitly in the parameter hashtable; preference variables do not cross module boundaries"
    - "A vendor-neutral script is proven neutral by an AST scan (no -HP / HPCMSL command, no 'HP' string) rather than by review"

key-files:
  created:
    - kit/vendors/hp/vendor.psd1
    - builder/Build-DriverBaseline.ps1
    - tests/Builder.Tests.ps1
    - tests/fixtures/profiles/fixture/m1.psd1
  modified:
    - builder/vendors/hp/HP.Build.psm1
    - tests/HP.Build.Tests.ps1
    - tests/Contract.Tests.ps1
    - tests/Vendor.Tests.ps1
    - tests/fixtures/vendors/complete/Fixture.Build.psm1
  moved:
    - "src/Build-HPDriverBaseline.ps1 -> builder/Build-DriverBaseline.ps1 (pure rename commit, then rewrite)"

key-decisions:
  - "A mock sees each piped SoftPaq as its own New-HPBuildDriverPack call, so the test asserts one call per included SoftPaq (two) and none for an excluded one, not 'invoked once'"
  - "The build script merges the previous manifest's ToolVersions with the new results, so a -Stage Firmware rerun keeps the driver stage's tool versions"
  - "The second stage is built against the release the first stage resolved, so a two-stage run cannot straddle two catalog releases"
  - "Save-HPKitVendorPack calls ShouldProcess and then always throws, so -WhatIf gets the same NotImplementedException as a real run"

patterns-established:
  - "Rename-then-rewrite in two commits keeps git log --follow reaching the original import"

requirements-completed: [REPO-01, REPO-02, REPO-03, REPO-04]

duration: 23min
completed: 2026-10-19
status: complete
---

# Phase 1 Plan 06: HP vendor behind the interface and a vendor-neutral build entry

The HP vendor now sits behind the same interface as the fixture vendor. `Test-Kit.ps1` runs the data-driven contract test over `kit/vendors/hp/vendor.psd1` and it passes for both planes with no change to the contract test beyond one discovery It. The old HP build script is gone from `src/`: its Drivers and Firmware stages live in `New-HPKitCustomPack` and `Save-HPKitFirmware`, and `builder/Build-DriverBaseline.ps1 -Vendor <v> -Model <m>` runs any vendor through `Invoke-KitVendorCommand` and writes a data-only package to `<OutputRoot>\<vendor>\<model>\<os>-<release>\`.

## Tasks

| Task | Name | RED | GREEN |
|------|------|-----|-------|
| 1 | Tracer: HP descriptor, both HP modules, contract green for HP | 6b00c7e | 32a10a2 |
| 2 | Move the driver and firmware stages into New-HPKitCustomPack and Save-HPKitFirmware | e6ea6b5 | 8710874 |
| 3 | Vendor-neutral builder/Build-DriverBaseline.ps1, proven with the fixture vendor | 4573fcf | 70ae2b5 (pure rename), 4294fae |

## Verification

Full gate, `env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1`, run after the final code commit: exit 0, lint 37 files / 0 findings, 324 Pester tests passed, no suppressions. Before this plan the gate had 277 tests. PSScriptAnalyzer died once or twice per full run with the known `RULE_ERROR` null reference; an immediate rerun was clean each time, as the plan allowed. Each RED run was confirmed failing before its commit (6, 17 and 10 failures).

Plan truths checked by tests:
- `Vendor hp contract` runs the nine data-driven Its for HP and passes; `Vendor discovery` finds `HP` in the default kit vendors folder; the missing-op child-process gate from 01-03 still exits 1.
- `Get-HPKitModel` lists 840-g5 (83B2, unverified) then 840-g6 (8549, verified); `Save-HPKitVendorPack` throws `NotImplementedException` naming BUILD-03, the model, release and output path; importing HP.Build still leaves `Get-Module HPCMSL` empty.
- With an HPCMSL stand-in: `New-HPKitCustomPack` resolves 24H2 from the OS list, writes into `<root>\hp\840-g6\win11-24H2`, keeps sp174163 and sp153128, excludes sp152918 and sp168736 (profile) and sp109038 (DPB=false) with Stage `Drivers`, and returns PackKind `custom` and an HPCMSL ToolVersions key; a pinned 23H2 flows into the catalog query and package path; 25H2 throws the `Available:` message; an empty selection throws; `-WhatIf` builds nothing and creates no Drivers folder; unelevated throws "elevated" except under `-WhatIf`.
- `Save-HPKitFirmware` calls `Get-HPSoftpaq` with Number 174025 and DestinationPath `<package>\Firmware\sp174025`; the BIOS entry is AutoInstall, SilentInstall `HpFirmwareUpdRec.exe` / `-r -b -s`, RebootRequired, ReturnCodes 290 then 3010; the SSD entry is not auto-installed and keeps its PCI id; `-WhatIf` downloads nothing.
- `Build-DriverBaseline.ps1 -Vendor Fixture` writes `fixture\m1\win11-24H2\manifest.json` (Vendor, ModelId, Platform 0000, OsVer 24H2, SchemaVersion 2, fx001, fx100, ToolVersions) and `Drivers\fixture.inf`; no `.ps1`/`.psm1` under the package; a `-Stage Firmware` rerun keeps the Drivers entry; `-WhatIf` writes no manifest; the AST has no `-HP`/HPCMSL command, no `HP`/`HPCMSL` string and no `Copy-Item`; the `-OutputRoot` default expression is `(Join-Path $PSScriptRoot '..\staging')`; the script calls `-Operation NewCustomPack` and `-Operation GetFirmware`.
- `git ls-files src/Build-HPDriverBaseline.ps1` prints nothing; `git log --follow` on the new path reaches fca77de and the original import 1d5e66c.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Lint] ShouldProcess on the signature stubs**
- **Found during:** Task 1 GREEN gate
- **Issue:** PSShouldProcess flagged the three build operations declared with `SupportsShouldProcess` but no `ShouldProcess` call.
- **Fix:** each stub calls `$PSCmdlet.ShouldProcess` first. `Save-HPKitVendorPack` still throws regardless, so `-WhatIf` gets the same answer as a real run; the two other stubs were replaced in Task 2.
- **Commit:** 32a10a2

**2. [Rule 3 - Lint] HPCMSL stand-in cannot be written as functions**
- **Found during:** Task 2 GREEN gate
- **Issue:** the plan's stand-in module defines `Get-HPDeviceDetails` (PSUseSingularNouns) and `New-HPBuildDriverPack` (PSUseShouldProcessForStateChangingFunctions); the names belong to HPCMSL and cannot be renamed, and suppression is forbidden.
- **Fix:** the stand-in is generated from a name-to-parameter-block table by `Import-HPCMSLStandIn` in the test file and imported with `New-Module` / `Import-Module -Global`. No rule is disabled and every command still echoes its bound parameters.
- **Commit:** 8710874

**3. [Rule 1 - Bug in the plan's test wording] "invoked once" for the piped pack build**
- **Found during:** Task 2 GREEN
- **Issue:** Pester mocks a piped command once per pipeline item, so `New-HPBuildDriverPack` receiving two SoftPaqs counted as two calls.
- **Fix:** the test asserts two calls with Path = package folder and Name `Drivers`, and zero calls for any excluded SoftPaq id. Production code is unchanged (it pipes, as the old script did).
- **Commit:** 8710874

**4. [Rule 1 - Bug] Empty Excluded list broke the summary output**
- **Found during:** Task 3 GREEN
- **Issue:** `$manifest.Excluded | Format-Table | Out-String | Write-Information` binds nothing when the list is empty (the fixture has no exclusions), failing on the mandatory `MessageData`.
- **Fix:** both summary tables are written as `Write-Information "$(... | Out-String)"`.
- **Commit:** 4294fae

**5. [Rule 3 - Blocking] Test-side adjustments**
- `tests/Vendor.Tests.ps1`: the existing GetFirmware dispatch It passed `ModelProfile = 'm'` and `OutputPath = 'o'`, which the extended fixture cannot use (it computes a real package path). It now loads the fixture profile, passes `$TestDrive` and `-WhatIf`, and asserts PackagePath. Commit 4573fcf.
- `tests/Builder.Tests.ps1`: the helper's own `-WhatIf` switch tripped PSUseSupportsShouldProcess, so it is named `-Preview`; the AST check for `-Operation` reads the next command element because `CommandParameterAst.Argument` is empty for a space-separated value; the shape Describe asserts the script exists first so a missing script cannot pass the scans vacuously (it did in the first RED run). Commits 4573fcf, 4294fae.

### Other notes

- The move was split into a pure-rename commit (70ae2b5) before the rewrite (4294fae) so `git log --follow` works; the rename commit alone leaves a script that imports a module that no longer exists, so only the end of the series is meant to be green. This replaces the 01-05 stop-gap `-ProfilePath` default.
- `Initialize-HPCMSL` still installs HPCMSL from the PowerShell Gallery when it is missing, including under `-WhatIf` (unchanged behaviour of the old script; T-1-20 accepted).
- The real catalog path (`builder\Build-DriverBaseline.ps1 -Vendor HP -Model 840-g6 -WhatIf` with internet and HPCMSL) was not run here; it is the end-of-phase manual check in Plan 01-08.
- `README.md` and `docs/hp-elitebook-840-g6-driver-baseline.md` still mention `src\Build-HPDriverBaseline.ps1` and `HP_Staging`; the docs rewrite is Plan 01-08. `src/Install-HPDriverBaseline.ps1` is no longer copied into packages (D-04) and is retired by a later plan.

## Known Stubs

`Save-HPKitVendorPack` throws `NotImplementedException` by design: HP's published driver pack download is BUILD-03, delivered in Phase 4. It exists so the contract sees the real signature, and its test asserts the message.

## Threat Flags

None. T-1-18 (package folder only from Get-KitPackagePath; Reset-HPKitDirectory only on `<package>\Drivers` and `<package>\Firmware`), T-1-19 (no Copy-Item in the build script; no `.ps1`/`.psm1` under the package, both tested) are mitigated. T-1-20 is accepted as planned. No package was installed.

## Self-Check: PASSED

kit/vendors/hp/vendor.psd1, builder/vendors/hp/HP.Build.psm1, builder/Build-DriverBaseline.ps1, tests/Builder.Tests.ps1, tests/fixtures/profiles/fixture/m1.psd1 and tests/fixtures/vendors/complete/Fixture.Build.psm1 exist; commits 6b00c7e, 32a10a2, e6ea6b5, 8710874, 4573fcf, 70ae2b5 and 4294fae are ancestors of HEAD; `src/Build-HPDriverBaseline.ps1` is no longer tracked.
