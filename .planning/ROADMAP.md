# Roadmap: Enterprise Workstation Staging

## Overview

The work starts from the existing HP 840 G6 baseline tooling. The repo is first restructured into a common module plus an HP vendor module, with secrets kept out of git. Next, the 2026-10-05 wrong-folder incident is fixed: BIOS images and UEFI diagnostics go onto the Tools stick in HP's exact layout, and that layout is proven on real hardware. With the Tools stick trusted, the read-only Assess mode gives the operator a pre-purchase check. The builder then produces per-model G5 and G6 images on the Install stick. Deploy and the first-logon run take a freshly imaged laptop through drivers, the online gate and Atera. Verify closes every run and saves its result to the Tools stick. Phases 1-6 deliver the MVP (the core value). Phase 7 adds two v1 items that are not MVP: the GitHub web bootstrap and one combined G5+G6 image. Phase 7 is scheduled only after the per-model images and platform-ID driver selection are proven.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Modular Foundation** - Common module plus HP vendor module behind one interface, G5/G6 profiles, clean tests and lint, no secrets in the repo
- [ ] **Phase 2: Tools Stick Firmware Staging** - Master build script stages BIOS, UEFI diagnostics and the Windows flash fallback in HP's exact USB layout, validated and proven on real G5/G6
- [ ] **Phase 3: Read-Only Assess** - Provisioning script runs from the Tools stick and gives a pre-purchase verdict saved per serial, changing nothing
- [ ] **Phase 4: Per-Model Image and Install Stick** - ISO selection, vendor or custom driver packs, unattended per-model G5 and G6 images on a bootable Install stick, no firmware in the image
- [ ] **Phase 5: Deploy and First Logon** - Deploy enforces the stage order; first logon runs drivers, the online gate and Atera, resumable across reboots
- [ ] **Phase 6: Verify** - Verify runs last on every laptop and saves its result to the Tools stick
- [ ] **Phase 7: Web Bootstrap and Combined Image** - Short GitHub bootstrap that runs the current `main`, with offline fallback, plus one image for both G5 and G6 (v1, not MVP)

## Phase Details

### Phase 1: Modular Foundation
**Goal**: The existing HP tooling lives in a vendor-neutral repo (common module plus an HP vendor module behind one interface) that carries G5 and G6 profiles, passes tests and lint on Windows PowerShell 5.1, and holds no secrets
**Depends on**: Nothing (first phase)
**Requirements**: REPO-01, REPO-02, REPO-03, REPO-04, REPO-05, REPO-06, SEC-01, SEC-02, SEC-03
**Success Criteria** (what must be TRUE):
  1. The existing HP baseline build, install and audit scripts run through a common module plus an HP vendor module, and a Pester contract test passes for the HP module but fails for a module missing any of the six interface functions
  2. Pester 5+ passes on Windows PowerShell 5.1, and PSScriptAnalyzer reports zero findings with no suppressions
  3. Profiles for the 840 G5 and 840 G6 load with platform ID, expected BIOS defaults, firmware minimum and pack selection data, and build output for each model lands in its own vendor/model folder
  4. A gitleaks scan of the full history is clean, and a commit containing a planted fake token is blocked by the pre-commit hook or CI check
  5. The operator supplies Atera settings by copying the committed `.example` config, and git treats the filled-in copy as ignored
**Plans**: TBD

### Phase 2: Tools Stick Firmware Staging
**Goal**: The operator builds a Tools stick whose BIOS and UEFI diagnostics files sit exactly where HP's pre-Windows tools look for them, so the 2026-10-05 wrong-folder incident cannot happen again
**Depends on**: Phase 1
**Requirements**: BUILD-01, BUILD-06, FW-01, FW-02, FW-03, FW-04, FW-05, FW-06
**Success Criteria** (what must be TRUE):
  1. The operator runs one master build script, picks HP and the 840 G5 and G6, and gets a FAT32 Tools stick holding both models' BIOS files in HP's pre-Windows flash tool layout, with neither model overwriting the other
  2. When a required path is missing or a hash doesn't match, the build stops with a red message naming the problem file before the operator leaves for the shop
  3. A real G5 and a real G6 each flash their BIOS from the Tools stick via the pre-Windows menu
  4. The F2 menu on a G5 or G6 loads the latest UEFI diagnostics from the stick rather than the older built-in version
  5. The Tools stick carries a firmware manifest (model, platform ID, latest BIOS version, hash) and HP's Windows flash tool as a fallback
**Plans**: TBD

### Phase 3: Read-Only Assess
**Goal**: Before buying, the operator runs Assess from the Tools stick and gets a phone-readable verdict on a candidate laptop (specs, health, firmware currency, lock red flags), saved per serial, with nothing on the laptop changed
**Depends on**: Phase 2
**Requirements**: PROV-01, PROV-02, PROV-03, PROV-07, ASSESS-01, ASSESS-02, ASSESS-03, ASSESS-04, RES-01, RES-02
**Success Criteria** (what must be TRUE):
  1. On a stock Windows laptop, the provisioning script starts from the Tools stick with no module installs, opens a minimal menu that defaults to Assess (or skips the menu via `-Mode`), and detects vendor, model and platform ID by itself
  2. Assess reports serial, model, CPU, RAM, disk size and health, battery wear, BIOS version against the firmware manifest, TPM, Secure Boot and activation as green/yellow/red lines that fit a phone screen, with known-harmless exit codes shown as yellow warnings
  3. Assess flags a BIOS setup password, BitLocker on, domain or Azure AD join, MDM enrollment and Absolute persistence as red flags, and never tries to bypass them
  4. A before/after comparison shows Assess changed nothing on the laptop, and each run adds a new per-serial file to the stick's `results` folder carrying an ISO 8601 UTC timestamp, schema version and tool version
**Plans**: TBD
**UI hint**: yes

### Phase 4: Per-Model Image and Install Stick
**Goal**: The operator builds an Install stick from a confirmed source ISO and the chosen driver packs. It images a G5 or G6 unattended through to the first sign-in and carries no firmware and no Wi-Fi secrets
**Depends on**: Phase 2
**Requirements**: BUILD-02, BUILD-03, BUILD-04, BUILD-05, IMG-01, IMG-02, IMG-03, IMG-04, IMG-06, IMG-07, IMG-08
**Success Criteria** (what must be TRUE):
  1. The builder lists the ISOs in `src/iso/` with build and edition and waits for confirmation (or asks for a path when there are none). It lets the operator use either HP's latest published pack or a custom pack built from each model's latest individual drivers, and writes a build manifest recording the pack and firmware versions used
  2. The Install stick boots a G5 and a G6 after a BIOS defaults reset with Secure Boot on, and Windows setup runs unattended, stopping only at the network screen for the Wi-Fi password
  3. Setup finishes with that model's drivers already injected, and the first-logon run starts automatically after the first sign-in
  4. The image holds no Wi-Fi profile or key and no firmware payload, and a Pester test fails the build if the generated answer file invokes a firmware install
**Plans**: TBD

### Phase 5: Deploy and First Logon
**Goal**: A freshly imaged laptop gets from first sign-in to a running Atera agent in the required order with minimal operator input. It behaves safely offline: online steps defer instead of hanging, and an interrupted run resumes where it stopped
**Depends on**: Phase 3, Phase 4
**Requirements**: PROV-04, PROV-05, PROV-06, PROV-08, LOGON-01, LOGON-02, LOGON-03, LOGON-04, LOGON-05, LOGON-06, LOGON-07, IMG-05
**Success Criteria** (what must be TRUE):
  1. Deploy enforces the required stage order. It warns or stops when the BIOS is below the profile's firmware minimum and offers the Windows flash-tool fallback with BitLocker suspended on the Windows drive only, and `-WhatIf` lists every stage it would run without changing anything
  2. With no network, first logon installs drivers from the pack matching the platform ID (drivers that don't match the hardware show as warnings, not failures) and sets up the `User` account. A reboot mid-sequence or a manual re-run resumes from the last completed stage
  3. The Atera installer starts only after a real HTTPS request (TLS 1.2) to Atera's endpoints succeeds. Offline, the gate retries a bounded number of times, then defers with a yellow warning. Online, the install completes within a hard timeout and is confirmed by the `AteraAgent` service running
  4. The operator answers a quick pass/fail prompt for the UEFI diagnostics, and the answer is recorded in the laptop's result
  5. When first logon finishes, autologon is removed, and at the second sign-in `User` has a blank password and is not asked to create one
**Plans**: TBD

### Phase 6: Verify
**Goal**: Every laptop's run ends with Verify, and its result is saved to the Tools stick
**Depends on**: Phase 5
**Requirements**: VERIFY-01, VERIFY-02, VERIFY-03
**Success Criteria** (what must be TRUE):
  1. Verify always runs last, after Atera. It reports firmware currency, BIOS settings against profile defaults, driver errors, activation, account state, Atera and Splashtop in green/yellow/red, and records re-imaging as the disk sanitization method
**Plans**: TBD

### Phase 7: Web Bootstrap and Combined Image
**Goal**: v1 additions beyond the MVP. The operator can start provisioning from a short GitHub command instead of the stick copy, and one image serves both the G5 and the G6. This phase comes after the per-model images (Phase 4) and platform-ID driver selection (Phase 5) are proven
**Depends on**: Phase 6
**Requirements**: BOOT-01, BOOT-02, BOOT-03, BOOT-04, IMG-09
**Success Criteria** (what must be TRUE):
  1. Typing a short `irm <url> | iex` on a laptop with internet runs the current provisioning script from `main` (no release tags, no version or hash pinning)
  1a. The typed URL is as short as it can be made, because the operator types it by hand. Finding the shortest workable form (research priority, see BOOT-04) comes before the bootstrap is wired up
  2. With no internet, the bootstrap falls back to the copy on the Tools stick
  3. The web route downloads only scripts, modules and profiles, never secrets, ISOs or BIOS files
  4. One combined image installs on a real G5 and a real G6, first logon picks each model's driver pack by platform ID, and Verify passes on both
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Modular Foundation | 0/TBD | Not started | - |
| 2. Tools Stick Firmware Staging | 0/TBD | Not started | - |
| 3. Read-Only Assess | 0/TBD | Not started | - |
| 4. Per-Model Image and Install Stick | 0/TBD | Not started | - |
| 5. Deploy and First Logon | 0/TBD | Not started | - |
| 6. Verify | 0/TBD | Not started | - |
| 7. Web Bootstrap and Combined Image | 0/TBD | Not started | - |
