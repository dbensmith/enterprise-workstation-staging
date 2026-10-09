# Requirements: Enterprise Workstation Staging

**Defined:** 2026-10-05
**Core Value:** An HP EliteBook 840 G5 or G6 goes from firmware update to verified, imaged laptop in the required order with minimal operator input, and a PASS result saved to the Tools stick.

## v1 Requirements

### Repo & Vendor Interface

- [ ] **REPO-01**: Shared, vendor-neutral code lives in one common module; vendor code lives in per-vendor modules
- [ ] **REPO-02**: Each vendor module implements one interface: list models, fetch vendor pack, build custom pack, fetch firmware, install drivers, install firmware
- [ ] **REPO-03**: Pester contract tests check that a vendor module implements the full interface
- [ ] **REPO-04**: Build outputs are written to separate folders per vendor and model
- [ ] **REPO-05**: Per-model profiles (`.psd1`) exist for 840 G5 and 840 G6 and carry platform ID, expected BIOS defaults, firmware minimum and pack selection data
- [ ] **REPO-06**: Existing Pester tests run under Pester 5+ on Windows PowerShell 5.1, and PSScriptAnalyzer runs clean without suppressions

### Secrets

- [ ] **SEC-01**: Repo and its history contain no credentials or customer-specific settings (Atera MSI/link)
- [ ] **SEC-02**: Operator supplies secrets at run time via a gitignored local config, the Tools stick, or parameters; a committed `.example` config documents the schema
- [ ] **SEC-03**: A secret scan (gitleaks) runs as a pre-commit hook or CI check

### Build

- [ ] **BUILD-01**: Operator runs one master build script and chooses brand and models
- [ ] **BUILD-02**: Builder lists ISOs in `src/iso/` with build and edition, asks for confirmation, and asks for a path when none is found
- [ ] **BUILD-03**: Builder can produce a driver set from the vendor's latest published pack
- [ ] **BUILD-04**: Builder can produce a custom driver pack from each model's latest individual drivers (HP: HPCMSL `New-HPDriverPack`)
- [ ] **BUILD-05**: Builder records the pack and firmware versions used in a build manifest
- [ ] **BUILD-06**: Builder writes a firmware manifest (model, platform ID, latest BIOS version, hash) onto the Tools stick

### Firmware Staging

- [ ] **FW-01**: Builder stages BIOS files in the exact folder layout HP's pre-Windows USB flash tool reads, per model, on a FAT32 volume
- [ ] **FW-02**: G5 and G6 BIOS images coexist on the Tools stick without overwriting each other's files
- [ ] **FW-03**: Builder validates the staged layout (required paths present, hashes match) and fails loudly before the operator leaves
- [ ] **FW-04**: Builder stages HP's Windows flash tool as a fallback
- [ ] **FW-05**: Builder stages the latest HP UEFI diagnostics in the folder the F2 menu loads from, alongside the BIOS layout
- [ ] **FW-06**: The staged layout has been proven by flashing a real G5 and a real G6 from the stick via the pre-Windows menu

### Image & Media

- [ ] **IMG-01**: Builder produces a slipstreamed Windows 11 image per model (G5, G6) with that platform's drivers injected
- [ ] **IMG-02**: Image runs unattended setup and pauses only at the network screen, where the operator types the Wi-Fi password
- [ ] **IMG-03**: Image contains no Wi-Fi profile or key
- [ ] **IMG-04**: Image launches the first-logon run automatically after the first sign-in
- [ ] **IMG-05**: Local account `User` ends up with a blank password and is not forced to create a password at second logon
- [ ] **IMG-06**: Builder writes the Install stick (bootable, split WIM for FAT32, per-model packs)
- [ ] **IMG-07**: Install stick boots on a G5 and a G6 after a BIOS defaults reset with Secure Boot on
- [ ] **IMG-08**: Image never carries or flashes firmware; first-boot runs skip firmware, and a Pester test fails if the generated answer file invokes a firmware install
- [ ] **IMG-09**: One combined image works on both G5 and G6, using platform-ID driver selection (v1, not MVP: schedule after the per-model image is proven)

### Provisioning Engine

- [ ] **PROV-01**: Operator chooses Assess or Deploy from a minimal menu or via `-Mode`; the menu defaults to Assess
- [ ] **PROV-02**: Script auto-detects vendor, model and platform ID
- [ ] **PROV-03**: Script runs from the Tools stick with no module installs on the target
- [ ] **PROV-04**: Deploy enforces the required order and warns or stops when firmware is out of date
- [ ] **PROV-05**: Deploy offers a firmware-from-Windows fallback that suspends BitLocker on the Windows drive only
- [ ] **PROV-06**: A re-run resumes from the last completed stage instead of restarting
- [ ] **PROV-07**: Output is green/yellow/red, fits a phone screen, and maps harmless exit codes to warnings
- [ ] **PROV-08**: Deploy supports `-WhatIf` for bench testing

### Assess

- [ ] **ASSESS-01**: Assess changes nothing on the laptop
- [ ] **ASSESS-02**: Assess reports serial, model, CPU, RAM, disk size and health, battery wear, BIOS version vs the firmware manifest, TPM, Secure Boot and activation
- [ ] **ASSESS-03**: Assess flags lock and ownership red flags: BIOS setup password, BitLocker on, domain/Azure AD join, MDM enrollment, Absolute persistence (detect only, never bypass)
- [ ] **ASSESS-04**: Assess writes a per-serial result file to the Tools stick

### First Logon

- [ ] **LOGON-01**: Offline steps (drivers, `User` account setup) run without internet
- [ ] **LOGON-02**: Driver install tolerates drivers that don't match the hardware and picks the pack by platform ID
- [ ] **LOGON-03**: First-logon run survives a reboot mid-sequence and continues
- [ ] **LOGON-04**: Online gate confirms internet with a real HTTPS request to Atera's endpoints (TLS 1.2), with bounded retry, then defers with a warning
- [ ] **LOGON-05**: Atera installer never starts until the online gate passes, has a hard timeout, and is confirmed by the `AteraAgent` service running
- [ ] **LOGON-06**: First-logon run cleans up autologon after it finishes
- [ ] **LOGON-07**: Operator records the UEFI diagnostics pass/fail at a quick prompt so it lands in the result

### Verify

- [ ] **VERIFY-01**: Verify always runs last, after Atera
- [ ] **VERIFY-02**: Verify checks firmware is current, BIOS settings match profile defaults, driver errors, activation, account state, Atera and Splashtop
- [ ] **VERIFY-03**: Verify records the disk sanitization method used (re-image)

### Results

- [ ] **RES-01**: Every result carries an ISO 8601 UTC timestamp (e.g. `2026-10-05T10:02:00Z`), schema version and tool version
- [ ] **RES-02**: Results are saved per serial to the Tools stick's `results` folder, one file per run

### Web Bootstrap

- [ ] **BOOT-01**: A short `irm <url> | iex` served from GitHub runs the provisioning script from a tagged release, not `main`
- [ ] **BOOT-02**: Bootstrap falls back to the on-stick copy when offline
- [ ] **BOOT-03**: The web route pulls only scripts, modules and profiles (no secrets, ISOs or BIOS files)

## v2 Requirements

### Vendors

- **VEND-01**: Dell driver and firmware module
- **VEND-02**: Lenovo driver and firmware module

### Hardening & Convenience

- **HARD-01**: Bootstrap verifies the payload's SHA-256 against a pinned manifest
- **HARD-03**: Condition grade (A/B/C) derived from battery wear, disk health, specs and lock flags
- **HARD-04**: SSD secure-erase or crypto-erase with recorded evidence

## Out of Scope

| Feature | Reason |
|---------|--------|
| Excel tracker workbook | Operator builds and owns it |
| Central online results store, upload or sync of results | Out of scope (decided 2026-10-09); results stay on the Tools stick |
| Automated pre-Windows firmware flash and BIOS defaults reset | Wish list; risks bricking; verify-only instead |
| Storing the Wi-Fi password in the image or repo | Secrets constraint; typed at the setup network screen |
| Module installs on target laptops | Targets are stock Windows |
| PXE/MDT/SCCM imaging server | Needs a server and LAN at every shop; contradicts the two-stick model |
| Autopilot hash registration | Needs tenant credentials on the laptop; not part of this flow |
| Bypassing BIOS passwords, MDM locks or Absolute | Legal and security exposure; detect and recommend "do not buy" |
| GUI front end | Phone-first operator; colour text menu is enough |
| Auto-update from `main` without pinning | Supply-chain risk |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| REPO-01 | Phase 1 | Pending |
| REPO-02 | Phase 1 | Pending |
| REPO-03 | Phase 1 | Pending |
| REPO-04 | Phase 1 | Pending |
| REPO-05 | Phase 1 | Pending |
| REPO-06 | Phase 1 | Pending |
| SEC-01 | Phase 1 | Pending |
| SEC-02 | Phase 1 | Pending |
| SEC-03 | Phase 1 | Pending |
| BUILD-01 | Phase 2 | Pending |
| BUILD-02 | Phase 4 | Pending |
| BUILD-03 | Phase 4 | Pending |
| BUILD-04 | Phase 4 | Pending |
| BUILD-05 | Phase 4 | Pending |
| BUILD-06 | Phase 2 | Pending |
| FW-01 | Phase 2 | Pending |
| FW-02 | Phase 2 | Pending |
| FW-03 | Phase 2 | Pending |
| FW-04 | Phase 2 | Pending |
| FW-05 | Phase 2 | Pending |
| FW-06 | Phase 2 | Pending |
| IMG-01 | Phase 4 | Pending |
| IMG-02 | Phase 4 | Pending |
| IMG-03 | Phase 4 | Pending |
| IMG-04 | Phase 4 | Pending |
| IMG-05 | Phase 5 | Pending |
| IMG-06 | Phase 4 | Pending |
| IMG-07 | Phase 4 | Pending |
| IMG-08 | Phase 4 | Pending |
| IMG-09 | Phase 7 | Pending |
| PROV-01 | Phase 3 | Pending |
| PROV-02 | Phase 3 | Pending |
| PROV-03 | Phase 3 | Pending |
| PROV-04 | Phase 5 | Pending |
| PROV-05 | Phase 5 | Pending |
| PROV-06 | Phase 5 | Pending |
| PROV-07 | Phase 3 | Pending |
| PROV-08 | Phase 5 | Pending |
| ASSESS-01 | Phase 3 | Pending |
| ASSESS-02 | Phase 3 | Pending |
| ASSESS-03 | Phase 3 | Pending |
| ASSESS-04 | Phase 3 | Pending |
| LOGON-01 | Phase 5 | Pending |
| LOGON-02 | Phase 5 | Pending |
| LOGON-03 | Phase 5 | Pending |
| LOGON-04 | Phase 5 | Pending |
| LOGON-05 | Phase 5 | Pending |
| LOGON-06 | Phase 5 | Pending |
| LOGON-07 | Phase 5 | Pending |
| VERIFY-01 | Phase 6 | Pending |
| VERIFY-02 | Phase 6 | Pending |
| VERIFY-03 | Phase 6 | Pending |
| RES-01 | Phase 3 | Pending |
| RES-02 | Phase 3 | Pending |
| BOOT-01 | Phase 7 | Pending |
| BOOT-02 | Phase 7 | Pending |
| BOOT-03 | Phase 7 | Pending |

**Coverage:**
- v1 requirements: 57 total
- Mapped to phases: 57
- Unmapped: 0 ✓

---
*Requirements defined: 2026-10-05*
*Last updated: 2026-10-06 after roadmap creation (traceability mapped to 7 phases)*
