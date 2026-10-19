---
phase: 01-modular-foundation
plan: 03
subsystem: vendor-interface
tags: [powershell-5.1, pester-6, vendor-contract, data-only-descriptor, tdd]

requires:
  - phase: 01-modular-foundation
    provides: "Kit.Core module with a pre-declared FunctionsToExport list, Get-KitRoot (plan 01-02)"
provides:
  - "kit/core/VendorContract.psd1: ordered contract table, six operations plus two helpers, each with plane and pinned parameter names"
  - "kit/core/Vendor.ps1: Get-KitVendor (All, ByName, ByManufacturer, ByPath), Test-KitVendorContract, Invoke-KitVendorCommand"
  - "tests/Contract.Tests.ps1: data-driven contract test over every discovered vendor.psd1 (file param VendorRoot)"
  - "tests/Contract.Negative.Tests.ps1: per-operation negative proofs and the child-process exit-code gate"
  - "tests/Vendor.Tests.ps1: resolution, dispatch and Kit.Core export proofs"
  - "tests/fixtures/vendors/complete and missing-op fixture vendors"
affects: [01-06, 01-07, 01-08]

actuals:
  tokens: 10145
  tasks: 3
  commits: 6
plan_head_before: 7df2fb1a1836f26c78c1cc646c5d6ec9d7408160
plan_head_after: 50da2c0a1554dcac8c2e4eadb1fa74bd9397da6b
commits: 6

tech-stack:
  added: []
  patterns:
    - "Data-only descriptors and contract table read with Import-PowerShellDataFile (never dot-sourced or evaluated)"
    - "Checker returns Kit.ContractViolation objects in contract-table order; tests assert exact violations"
    - "Negative gate proof runs the contract test in a child powershell.exe via New-PesterContainer and asserts the process exit code"

key-files:
  created:
    - kit/core/VendorContract.psd1
    - kit/core/Vendor.ps1
    - tests/Contract.Tests.ps1
    - tests/Contract.Negative.Tests.ps1
    - tests/Vendor.Tests.ps1
    - tests/fixtures/vendors/complete/vendor.psd1
    - tests/fixtures/vendors/complete/Fixture.Target.psm1
    - tests/fixtures/vendors/complete/Fixture.Build.psm1
    - tests/fixtures/vendors/missing-op/vendor.psd1
  modified: []

key-decisions:
  - "Violations for module problems (InvalidDescriptor, ModuleNotFound) carry an empty Operation; the contract test's descriptor It also treats UnknownOperation as descriptor-level, so an unknown Commands key fails the contract test"
  - "Kit.Vendor also carries TargetModuleSetting and BuildModuleSetting (the declared strings) so ModuleNotFound can name the missing file"
  - "Test-KitVendorContract imports the vendor modules to inspect them and removes them again; Invoke-KitVendorCommand imports -Global and reuses a loaded copy"
  - "kit/core/Kit.Core.psd1 untouched, as the plan requires"

patterns-established:
  - "Pester file params that PSScriptAnalyzer cannot see used inside BeforeDiscovery are copied to a $script: variable at file level"
  - "Pester discovery-only variables are not visible at run time; tests that need contract order at run time re-read it in BeforeAll"

requirements-completed: [REPO-02, REPO-03]

duration: 18min
completed: 2026-10-19
status: complete
---

# Phase 1 Plan 03: Vendor interface and contract test

Vendor interface mechanism: one data-only contract table in core, data-only vendor descriptors, core functions that resolve a vendor, check it against the contract and dispatch an operation to it, and a Pester contract test that passes for a complete vendor and fails (as a real process exit code) for one missing an operation. Proven on fixture vendors only; the HP descriptor joins in plan 01-06 and is discovered by the same test with no test change.

## Tasks

| Task | Name | RED | GREEN |
|------|------|-----|-------|
| 1 | Tracer: contract table, checker, complete fixture, green contract test | 481f610 | 83b9e4a |
| 2 | Negative proofs and child-process exit code | 3d3a48e | 6925e57 |
| 3 | Vendor resolution and dispatch | ba1fd7a | 50da2c0 |

## Verification

Full gate, `env -u PSModulePath powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1`, run after the final code commit: exit 0, lint 26 files / 0 findings, 170 Pester tests passed, no suppressions. Before this plan the gate had 101 tests.

Plan truths checked: 8 MissingOperation and 8 CommandNotFound Its each assert exactly one violation; MissingParameter names `OutputPath`; the code-carrying descriptor yields InvalidDescriptor and `ran.txt` is absent; the child gate exits 1 for `missing-op`, 0 for `complete`, and non-zero when no descriptor is found; `Kit.Core.psd1` has no `(01-03)` commit; `Vendor.ps1` has no `Invoke-Expression`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Empty `Commands` table rejected by the descriptor reader**
- **Found during:** Task 2 GREEN (empty-Commands test)
- **Issue:** The first reader treated any key whose string form is empty as missing; an empty hashtable stringifies to empty, so `Commands = @{}` threw instead of producing eight MissingOperation violations.
- **Fix:** `Commands` is checked separately (present and a hashtable); the other three keys keep the non-empty check.
- **Commit:** 6925e57

**2. [Rule 1 - Bug] Invoke-KitVendorCommand saw the whole contract array as one entry**
- **Found during:** Task 3 GREEN
- **Issue:** `Get-KitVendorContractTable` returns the array wrapped with a unary comma; piping it straight into `Where-Object` passed the array as one item, so every plane resolved wrongly.
- **Fix:** assign the table to a variable first, then filter.
- **Commit:** 50da2c0

**3. [Rule 1 - Bug] Test read a discovery-only variable at run time**
- **Found during:** Task 2 GREEN
- **Issue:** the contract-order assertion used `$script:operationNames`, set only in BeforeDiscovery, so it was `$null` at run time.
- **Fix:** the test re-reads the contract table in BeforeAll as `$script:contractOrder`.
- **Commit:** 6925e57

**4. [Rule 3 - Lint] Lint findings fixed in code, no suppressions**
- **Found during:** Task 1 GREEN gate
- **Issue:** 12 findings: PSUseOutputTypeCorrectly (private table loader), PSUseDeclaredVarsMoreThanAssignments and PSReviewUnusedParameter in the contract test, PSProvideCommentHelp on the fixture modules.
- **Fix:** `[OutputType([System.Array])]`; `$script:` discovery variables and a file-level `$script:vendorRoots = $VendorRoot`; comment-based help on every fixture function. The fixture files committed in the RED commit were therefore edited in the GREEN commit.
- **Commit:** 83b9e4a

**5. [Rule 2 - Missing coverage] Descriptor It also fails on UnknownOperation**
- UnknownOperation violations name an operation, so the plan's "empty Operation" filter would have let a vendor with a stray Commands key pass the contract test. The descriptor It now includes UnknownOperation. Commit 6925e57.

### Other notes

- The "exits 1 for missing-op" gate It passed at the Task 2 RED stage because Task 1's happy path already reports MissingOperation; the plan anticipated that some cases could pass early. The other four new cases (UnknownOperation, InvalidDescriptor, ModuleNotFound/-Plane, empty Commands) failed RED as intended.
- Added one test beyond the plan: the gate exits non-zero when a vendor root holds no descriptor (T-1-10, vacuous pass).
- Ledger note: the first full-gate run after the Task 1 fixes died with a PSScriptAnalyzer `RULE_ERROR` (null reference) on the pre-existing `builder/vendors/hp/HP.Build.psm1`; an immediate identical rerun passed. Not caused by this plan's files; if it recurs it is a flaky analyzer cache, not a finding.

## Known Stubs

None.

## Threat Flags

None. T-1-08 is mitigated and tested (descriptor code never runs); T-1-10 is mitigated (always-present complete fixture, empty -ForEach throws, child exit-code gate).

## Self-Check: PASSED

All nine created files exist; commits 481f610, 83b9e4a, 3d3a48e, 6925e57, ba1fd7a and 50da2c0 are ancestors of HEAD.
