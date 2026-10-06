# Phase 1: Modular Foundation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-10-06
**Phase:** 1-Modular Foundation
**Areas discussed:** Repo layout & migration, Vendor interface contract, Profiles & output folders, Lint/test/secret-scan gates

---

## Repo layout & migration

| Option | Description | Selected |
|--------|-------------|----------|
| src/Common + src/Vendors/HP | Sibling module folders under src/ | |
| Top-level modules/ | Modules at repo root, src/ only entry scripts | |
| You decide | Claude picks | |
| (free text) | "Think about this and propose a solution and explain why" | ✓ |

**User's choice:** Asked Claude to propose. First proposal (src/core, src/vendors/hp, src/scripts, tests/, config/) was sent back for adjustment with the requirement: "both DRY and also easily copyable to USB for target systems ... one command ... locate and use it easily both within the repo and on USB without needing a degree".
**Notes:** Revised proposal approved: `kit/` (laptop-side, copied verbatim to the Tools stick, `Run.cmd` entry) and `builder/` (PC-only, `Build.cmd` entry). Alternative offered and not chosen: a single top-level `vendors/hp` with an allow-list publish.

| Option | Description | Selected |
|--------|-------------|----------|
| Refactor in place, keep names | Thin callers keep old names | |
| Rename to vendor-neutral names | e.g. Build-DriverBaseline -Vendor HP | ✓ |
| Keep old scripts as shims | Deprecated wrappers | |

**User's choice:** Rename to vendor-neutral names.

| Option | Description | Selected |
|--------|-------------|----------|
| Fix in Phase 1 | Implement missing functions, fix -LogPath | ✓ |
| Delete/skip failing tests | Hides gaps | |
| You decide | | |

**User's choice:** Fix in Phase 1.

---

## Vendor interface contract

| Option | Description | Selected |
|--------|-------------|----------|
| Descriptor file | vendor.psd1 maps operations to commands | ✓ |
| Naming convention | Glob by name | |
| PowerShell classes | Abstract base class | |

**User's choice:** Descriptor file.

| Option | Description | Selected |
|--------|-------------|----------|
| Helpers required | 6 ops + GetDeviceIdentity + GetInstalledFirmwareVersion | ✓ |
| Optional capability flags | Only six required | |

**User's choice:** Helpers required.

| Option | Description | Selected |
|--------|-------------|----------|
| Names + parameters | Plus negative fixture test | ✓ |
| Names only | | |

**User's choice:** Names + parameters.

---

## Profiles & output folders

| Option | Description | Selected |
|--------|-------------|----------|
| One file per model | Standalone G5 and G6 .psd1 | ✓ |
| Shared base + overrides | | |

| Option | Description | Selected |
|--------|-------------|----------|
| Schema + best-known values, marked unverified | Verified = $false flag | ✓ |
| Schema with empty placeholders | | |

| Option | Description | Selected |
|--------|-------------|----------|
| staging/<vendor>/<model>/<os>-<release>/ | Repo-relative, gitignored | ✓ |
| Outside the repo by default | | |

---

## Lint, test & secret-scan gates

| Option | Description | Selected |
|--------|-------------|----------|
| Local pre-commit + GitHub Actions CI | Hook plus backstop | |
| Local pre-commit only | No CI | ✓ |
| CI only | | |

**Notes:** Recommended option was pre-commit + CI; user chose local pre-commit only (hook is bypassable; accepted).

| Option | Description | Selected |
|--------|-------------|----------|
| One script: Test-Kit.ps1 | Pester + PSScriptAnalyzer + gitleaks, -InstallHook | ✓ |
| Separate documented commands | | |

| Option | Description | Selected |
|--------|-------------|----------|
| kit/config.local.psd1 | Beside Run.cmd, travels with stick | ✓ |
| Separate config/ folder | | |

## Claude's Discretion

Module/function names beyond contract-pinned parameters, tool version pinning and gitleaks install method, Run.cmd elevation details, handling of existing HP_Staging/.

## Deferred Ideas

- GitHub Actions CI backstop.
- Firmware-timing redesign of the unattend specialize pass (Phases 2, 4, 5).
