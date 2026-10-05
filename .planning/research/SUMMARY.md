# Project Research Summary

**Project:** Enterprise Workstation Staging
**Domain:** Vendor-neutral laptop provisioning toolkit (PowerShell 5.1, USB-driven, offline-tolerant)
**Researched:** 2026-10-05
**Confidence:** MEDIUM-HIGH (HP specifics HIGH from vendor docs; Dell/Lenovo LOW; architecture derived from existing code and best practices)

---

## Executive Summary

This project is a modular, phone-operator-driven laptop provisioning toolkit for used-business-laptop refurbishment at vendor shops. The central design insight is that the refurb domain is operationally constrained — one technician, two USB sticks, unreliable shop internet, no module installs on targets — yet must enforce a strict mandatory order (firmware before imaging, BIOS defaults before diagnostics) to avoid bricking or breaking down later steps. The research grounded this in a concrete incident (2026-10-05, five units failed because BIOS files landed in the wrong USB folder layout) and validated that the toolkit stack (PowerShell 5.1, HPCMSL, DISM, Pester, Google Apps Script) is sound but requires very careful implementation of vendor-specific details, secrets hygiene, and result deduplication.

The recommended approach is to build in two concurrent tracks: first, a foundation layer (modular repo skeleton, vendor interface, secrets scanning) with a high-value incident fix (BIOS layout validation at build time); then, the core provisioning engine (Assess mode, Deploy stages, online gating, Atera install, result sync). Pitfalls are numerous but well-understood; the biggest risks are BIOS file-folder mismatches (now preventable via a validator), G5/G6 driver mixing (solved by platform-ID selection), silent Windows setup failures (solved by staging table + state machine), and secrets leaking into git or results (solved by runtime config + secret scan). The roadmap must front-load hardware acceptance tests (P2) and integrate bench validation of unattended setup (P5) before shipping to production.

---

## Key Findings

### Recommended Stack

**Languages & runtime:**
- **PowerShell 5.1** (inbox, stock Windows 11) — all scripts, both builder and target; no PS 7 syntax; all dependencies vetted for 5.1 compatibility
- **Windows batch** (Setup answer files, bootstrap entry points) — minimal, for automated entry

**Build & testing (builder PC only; never installed on targets):**
- **HPCMSL 1.9.0** — `Get-HPDeviceDetails`, `Get-HPSoftpaqList`, `New-HPDriverPack`, `Get-HPBIOSUpdates` for HP driver and firmware operations; install via `Install-Module` on builder only
- **Pester 6.2.0** — unit tests, vendor contract tests, layout validation; supports Windows PowerShell 5.1; replaces inbox 3.4.0; existing tests need migration from Pester 3 syntax
- **PSScriptAnalyzer 1.25.0** — lint PS 5.1 code; fix findings (no suppressions per user policy)
- **gitleaks v8.30.1** — secret scanning (pre-commit + CI); single Go binary, MIT licensed

**Image & ISO building (builder only):**
- **IMAPI2 (inbox COM)** — dual-boot BIOS+UEFI ISO creation; existing code already uses this, no ADK needed; UDF format so `install.wim` >4 GB fits
- **DISM (inbox PowerShell module)** — offline image servicing: mount, inject drivers, dismount, export, split WIM
- **Split-WindowsImage (DISM)** — split `install.wim` into `.swm` for FAT32 Install stick (<4 GB per file)

**Unattended setup & first-logon:**
- **autounattend.xml** (Microsoft-Windows-Shell-Setup, oobeSystem + specialize) — local account, autologon, first-logon launcher; generated dynamically, not hand-authored; **DO NOT use SetupComplete.cmd** (disabled on OEM keys)
- **FirstLogonCommands** (oobeSystem) — launches single orchestrator, runs as admin, after logon, with network available

**Results store:**
- **Google Apps Script web app** (recommended for MVP) — `doPost` to upsert, `doGet` for CSV/JSON export; free, no stored credentials on laptops (write key only), works with Excel Power Query
- **Alternative: Azure Blob with write-only SAS** — better leak profile, design seam accommodates either

**Summary rationale:** PowerShell 5.1 is the constraint; every tool validated for compatibility. Build-side tools are production-grade and current. IMAPI2 already proven. Store choice trades setup simplicity vs. leak resistance; either viable with seam design.

### Expected Features

**Table Stakes:**
- Read-only Assess mode; firmware staging in exact layout (incident fix); stage-order enforcement; green/yellow/red output; per-serial ISO 8601 UTC results; offline-first catch-up sync; real online check (not just "connected"); gated Atera install; modular vendor interface

**Differentiators:**
- Write-only upload credential; idempotent conditional-create sync; G5+G6 shared image; custom latest-driver pack; firmware-currency check; resumable state machine; `irm | iex` bootstrap with hash verification

**Defer to v2+:**
- Auto-update without pinning; background sync; Dell/Lenovo modules; condition scoring

### Architecture Approach

**Design: Three planes, one shared core.** Builder (admin, internet, vendor tools ok) vs. target (stock Windows 11, PS 5.1, no module installs). One vendor interface (descriptor + command map). Shared core handles all vendor-neutral logic: output, clock, config/secrets, stick discovery, result schema, store sync, online probe, layout validator, unattend generator, ISO servicing.

**One engine, three entry points:** Stick-based, `irm | iex` web bootstrap, image first-logon. Same stage table, result writer, state/resume.

**Major components:**
1. **core module** — vendor-neutral functions (Output, Clock UTC, Native wrapper, Config+Secrets, Stick discovery by marker, Result validator, Store adapter seam, Sync, Online probe, Layout validator, Unattend generator, ISO servicing)
2. **Vendor modules** — descriptor + HP.Build.psm1 + HP.Target.psm1; six operations per vendor
3. **Stage engine** — declarative table: Identify → Assess → Firmware gate → Account → Drivers → Online gate → Atera → Verify → Persist → Sync; Assess read-only enforced; Verify guaranteed last
4. **Build-Kit.ps1** — master orchestration, ISO selection, pack building, manifest v2, `Publish-Sticks` with validation
5. **Provision.ps1** — operator entry, auto-detects vendor/model
6. **Check library** — one function per verification check
7. **Bootstrap stub** (~40 lines) — TLS 1.2, elevate, find stick, fetch+verify SHA-256, run Provision.ps1; fallback to stick offline

**Two USB sticks:** Tools (FAT32, BIOS layout, diagnostics, kit, results) and Install (bootable, split-WIM, packs).

### Critical Pitfalls & Prevention

**Top 5 operationally damaging:**

1. **BIOS files in wrong folder** (incident) — F10, Esc menu, crisis recovery each look in different folders. **Prevention:** Generate layout with HP's own tool, snapshot into manifest, validator at build-time + every run, hardware acceptance test (real G5 and G6).

2. **Two ROM families (G5 Q78, G6 R70) collide** — `firmware.bin` can only be one; stale packs say both files "will not result in a successful update." **Prevention:** Per-model folders with build-time activation or bench-proven coexistence under crisis-recovery path.

3. **Blank-password side effects** — Default policy blocks network logon (RDP, SMB, scheduled tasks); password expiry breaks autologon; Splashtop fails. **Prevention:** Document trade-off, test mechanism on build 26300, keep policy as-is, use security code for Splashtop.

4. **FirstLogonCommands not resumable; SetupComplete disabled on OEM keys** — Reboot mid-sequence stops further commands. **Prevention:** Single orchestrator with `state.json`; idempotent stages; RunOnce/SYSTEM task on reboot.

5. **Atera MSI started offline hangs on token dialog** — Silent mode hangs invisibly. **Prevention:** Real online check (HTTPS reachability + clock skew) before launch, hard timeout ~10 min, kill on timeout, retry logic.

---

## Implications for Roadmap

### Phase 1: Foundation & Incident Fix (P1)
Secrets scanning, `.gitignore`, repo skeleton, drift fixes, vendor descriptor contract. BIOS layout validation prep (direct incident countermeasure).

### Phase 2: Build Plane & Firmware Layout (P2)
Build-Kit.ps1, manifest v2, HP.Build.psm1, firmware layout generator, Publish-Sticks with full validation, UEFI diagnostics tree capture. Hardware acceptance: real G5 and G6 BIOS flash via F10 menu.

### Phase 3: Driver Selection & G5+G6 Overlap (P3)
HP.Target.psm1 (identity, firmware version), platform-ID-based pack selection, G5/G6 softpaq diff analysis, per-INF driver install tolerance, firmware-class INF filter.

### Phase 4: Image Build & Media (P4)
Master ISO build (DISM per-platform injection, generated unattend), split-WIM for FAT32, Install stick layout, boot test on defaults-reset G5/G6 with Secure Boot ON.

### Phase 5: Unattended Setup & First-Logon Engine (P5)
Stage engine (declarative, Assess read-only enforced, Verify guaranteed last), state machine with resume, blank-password account setup (specialize + first-logon), online gate (real HTTPS check + clock skew), Atera gating, clean-up (autologon removal, WLAN deletion). Bench on Hyper-V Gen 2 VM.

### Phase 6: Results, Sync & Central Store (P6)
Result schema v1 (immutable, ISO 8601 Z, `resultId` key), store adapter seam, sync algorithm (idempotent put, oldest-first, watermark optimization), Google Apps Script or Azure Blob implementation.

### Phase 7: `irm | iex` Bootstrap & Web Route (P7)
Bootstrap stub (TLS 1.2, find stick, fetch+verify release SHA-256), kit.json manifest, short GitHub-controlled URL, scope (scripts/modules/profiles ok; no secrets/ISO/BIOS).

### Phase 8: Dell & Lenovo Modules (Later)
After HP stable; driver catalog parsing, per-vendor firmware layout, contract tests.

**Phase Ordering Rationale:** Foundations and incident fix first (secrets/layout cannot be added later). Build plane before target code (manifests must be ready). Assess before Deploy (simpler entry point). Engine before first-logon hardening (state machine required). Store research gates Phase 6 but design seam is ready. Bootstrap is last convenience layer.

**Research Flags:**
- P2: G5 BIOS version/platform ID; exact HP BIOS menu paths (F10/Esc folders); UEFI diagnostics tree + F2 visibility
- P4: Secure Boot boot-manager matching firmware DB (2023 certs) on defaults-reset G5/G6; DISM union behavior
- P5: Blank-password survival on build 26300; FirstLogonCommands timing/elevation; UEFICA2023Status after reset
- P6: Store research (Apps Script 302, Excel Power Query Web refresh, consumer account "Anyone" limits; or Azure Blob SAS conditional-create)
- P7: GitHub releases/latest redirect from PS 5.1; Expand-Archive on large zips

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| **Stack** | MEDIUM-HIGH | PowerShell 5.1 compatibility verified; versions current 2026-10-05. IMAPI2/DISM from existing code (HIGH). Apps Script recommendation based on cross-reference; 302 behavior, Power Query refresh coverage flagged for verification. |
| **Features** | MEDIUM | Table-stakes grounded in refurb norms and existing code. Differentiators derived from architecture patterns. Anti-features confirmed out-of-scope. |
| **Architecture** | MEDIUM-HIGH | Two-plane split, vendor interface, stage engine all derived from existing `src/`. USB layout/manifest designed around incident facts; specifics flagged for bench validation. |
| **Pitfalls** | MEDIUM-HIGH | Critical pitfalls grounded in HP docs (HIGH), Microsoft Learn (HIGH), local code (HIGH). Moderate pitfalls corroborated or MS-documented. Research flags identify HP-specific unverified behaviors and Windows mechanics. |
| **Roadmap** | MEDIUM | Phase dependencies logical; foundations → incident fix → engine → hardening. P2 and P5 require hardware/VM bench validation (gates provided). |

**Overall confidence: MEDIUM-HIGH.** Stack sound, architecture proven, pitfalls well-understood. Main uncertainty: HP firmware-menu specifics and Windows unattended-setup behavior on build 26300 (bench-testable, non-blocking). Store choice (Apps Script vs. Blob) not finalized but both viable with seam design.

### Gaps to Address

1. **G5 BIOS version and platform ID** — confirm sp157750 is latest, validate 83B2 ID, Phase 3 pre-work
2. **HP BIOS USB menu paths** — which folder each menu actually reads on G5 and G6, Phase 2 bench gate
3. **UEFI diagnostics tree and F2 visibility** — exact filenames and volume coexistence, Phase 2 bench test
4. **Secure Boot certificates and boot-manager signing** — do 2023 certs survive defaults reset, Phase 4 bench boot
5. **FirstLogonCommands timing/elevation on 26300** — run concurrently? Survive reboot? Phase 5 bench (Hyper-V VM)
6. **Blank-password autologon and expiry** — survive manual sign-ins, Phase 5 bench
7. **Central-store capabilities** — Apps Script 302 from PS 5.1, Excel refresh, consumer account limits, or Azure Blob SAS, store research phase
8. **G5/G6 softpaq overlap** — compute actual diff via `New-HPDriverPack -WhatIf`, Phase 3 pre-work
9. **DISM /Recurse with union and non-matching INF** — does bad INF abort or fail-soft, Phase 4 bench
10. **GitHub releases/latest redirect and Expand-Archive** — verify from PS 5.1, Phase 7 bench

---

## Sources

**Primary (HIGH):**
- HP CMSL 1.9.0 docs via Context7; local `HP_Staging/` SoftPaq files (sp174025, sp167305)
- Microsoft Learn: SetupComplete/OEM keys, FirstLogonCommands, Suspend-BitLocker, blank-password policy, PnPUtil codes, Secure Boot expiry, Power Query
- Pester 6.2.0 docs via Context7 (5.1 support, class caching breaks Mock)
- Local `src/` inspection (existing scripts, tests, `.gitignore`)

**Secondary (MEDIUM):**
- HP support pages (HP_TOOLS, BIOS folders, rollback); HP BitLocker April 2026 incident; Dell/Lenovo docs; Microsoft Q&A (blank password, FirstLogon); Atera support (ports/hosts); Google Apps Script quotas

**Tertiary (LOW, needs verification):**
- HP community threads (BIOS folder trees via search summaries, 403 direct fetch); BIOS Sledgehammer README; Splashtop support thread; TLS 1.2 community sources; git-history scrubbing guides
