---
phase: "1"
slug: "modular-foundation"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: "2026-10-09"
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 6.2.0 on Windows PowerShell 5.1; PSScriptAnalyzer 1.25.0; gitleaks 8.30.1 |
| **Config file** | none — Wave 0 installs `PSScriptAnalyzerSettings.psd1`, `.gitleaks.toml`, `.githooks/pre-commit`; Pester config built in `Test-Kit.ps1` |
| **Quick run command** | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Kit.ps1` |
| **Full suite command** | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Kit.ps1 -ScanHistory` |
| **Estimated runtime** | ~60 seconds |

---

## Sampling Rate

- **After every task commit:** Run the quick run command (once Wave 0 lands, the pre-commit hook runs it)
- **After every plan wave:** Run the full suite command
- **Before `/gsd-verify-work`:** Full suite must be green, zero PSSA findings, history clean, hook proof green
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

Filled in by the planner and `/gsd-validate-phase` once plans exist. Requirement → test map from research:

| Requirement | Behavior | Test Type | Automated Command | File Exists | Status |
|-------------|----------|-----------|-------------------|-------------|--------|
| REPO-01 | Core imports offline; no vendor name in `kit/core` | unit | `Invoke-Pester tests/Core.Tests.ps1` | ❌ W0 | ⬜ pending |
| REPO-01 | Moved HP helpers keep behavior | unit | `Invoke-Pester tests/HP.Build.Tests.ps1` | ❌ W0 | ⬜ pending |
| REPO-02 | HP descriptor maps all 8 ops with pinned params | contract | `Invoke-Pester tests/Contract.Tests.ps1` | ❌ W0 | ⬜ pending |
| REPO-03 | Fixture missing any one op fails (child process exits 1) | contract (negative) | `Invoke-Pester tests/Contract.Tests.ps1` | ❌ W0 | ⬜ pending |
| REPO-04 | Output paths `staging/<vendor>/<model>/<os>-<release>` distinct per model | unit | `Invoke-Pester tests/Core.Tests.ps1` | ❌ W0 | ⬜ pending |
| REPO-05 | G5/G6 profiles load, required keys, `Verified` gate throws | unit + static | `Invoke-Pester tests/Profiles.Tests.ps1` | ❌ W0 | ⬜ pending |
| REPO-06 | Suite green on 5.1; PSSA zero findings, no suppressions; D-06 defects fixed | gate + unit | `Test-Kit.ps1`; `Invoke-Pester tests/Repo.Tests.ps1, tests/HP.Target.Tests.ps1` | ❌ W0 | ⬜ pending |
| SEC-01 | Full history has no secrets | gate | `Test-Kit.ps1 -ScanHistory` | ❌ W0 | ⬜ pending |
| SEC-02 | `kit/config.local.psd1` ignored, example committed with empty values | unit | `Invoke-Pester tests/Repo.Tests.ps1` | ❌ W0 | ⬜ pending |
| SEC-03 | Hook blocks a runtime-generated token in a temp repo | integration | `Invoke-Pester tests/Repo.Tests.ps1 -Tag Hook` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Test-Kit.ps1` with `-InstallTools` (pinned versions, SHA-256 for gitleaks) and `-InstallHook`
- [ ] `.gitignore` additions (`staging/`, `.tools/`) and `.gitattributes` (LF hook, CRLF `.cmd`)
- [ ] `PSScriptAnalyzerSettings.psd1`, `.gitleaks.toml`, `.githooks/pre-commit`
- [ ] `tests/` skeleton: `Core`, `HP.Build`, `HP.Target`, `Contract`, `Profiles`, `Repo` test files and `tests/fixtures/vendors/missing-op/`
- [ ] Tools installed on the builder (`Test-Kit.ps1 -InstallTools` run once)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| `Run.cmd` self-elevates through UAC from a non-admin prompt | D-03 | Needs an interactive UAC prompt | On a laptop or VM, open a normal cmd on the stick, run `Run.cmd`, accept UAC, confirm the menu appears elevated |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
