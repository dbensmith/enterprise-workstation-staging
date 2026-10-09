# Enterprise Workstation Staging

## What This Is

A modular, vendor-neutral laptop provisioning toolkit built on this repo's existing HP tooling (driver baseline, ISO build, install, audit). One operator, working mostly from a phone, prepares used business laptops on site at vendor shops: assess before purchase, update firmware, run diagnostics, image, and verify, with results landing in a central store an Excel tracker can pull from.

## Core Value

An HP EliteBook 840 G5 or G6 goes from firmware update to verified, imaged laptop in the required order with minimal operator input, and a PASS result reaches the central store even when the shop's internet is unreliable.

## Requirements

### Validated

<!-- Inferred from existing code (README); no codebase map yet. -->

- ✓ HP driver and firmware baseline build via HPCMSL (`src/Build-HPDriverBaseline.ps1`) — existing
- ✓ Windows ISO servicing: offline driver injection, unattended first-boot installer, bootable dual BIOS/UEFI ISO via IMAPI2 (`src/New-HPBaselineIso.ps1`) — existing
- ✓ Standalone baseline installer, online (pnputil, BitLocker suspend, BIOS flash) or offline (DISM) (`src/Install-HPDriverBaseline.ps1`) — existing
- ✓ Post-imaging device audit: serial, CPU, RAM, boot disk, BIOS, OS edition, activation, Atera/Splashtop (`src/Test-DeviceBaseline.ps1`) — existing
- ✓ Profile for HP Platform 8549 (EliteBook 840 G6) and Pester tests — existing

### Active

Required order per laptop: (1) Assess, read-only, before purchase; (2) BIOS/firmware update; (3) reset BIOS to defaults straight after; (4) boot USB UEFI diagnostics (latest version from the stick, not the older built-in) and run them; (5) image, with Wi-Fi password typed at Windows' setup network screen and never stored in the image; (6) first logon: offline steps (drivers, local account setup) → wait until confirmed online → Atera → verify last → upload results.

**Modular repo**
- [ ] Shared code in a common area; vendor code in per-vendor modules behind one interface (list models, fetch vendor pack, build custom pack, fetch firmware, install drivers, install firmware)
- [ ] Build outputs kept separate per vendor and model
- [ ] Adding Dell or Lenovo later means writing a new module, not restructuring the repo

**Master build script**
- [ ] Model selection: choose brand and models; images SHOULD bundle drivers for neighbouring generations (840 G5 + G6) where safe so one image works on either
- [ ] Driver install MUST tolerate drivers that don't match the hardware and SHOULD pick the right pack by platform ID (platform IDs and G5/G6 pack overlap are for research)
- [ ] Drivers MUST support (a) the vendor's latest published pack and (b) a custom pack built from each model's latest individual drivers where vendor tools exist (HP candidate: HPCMSL `New-HPDriverPack`; Dell and Lenovo for research)
- [ ] Firmware: MUST stage BIOS files in the exact folder layout each vendor's pre-Windows flash tool expects on USB (on 2026-10-05 five units couldn't use that route because files were in the wrong folders); MUST also stage the vendor's Windows flash tool as fallback
- [ ] Source ISO chosen by flag at build time: builder looks in `src/iso/`, lists what's there and asks for confirmation; if none, asks for a path. Current base: Win11 Pro 26H2, build 26300.9457 (`26300.9457.260913-0631.26H2_GE_RELEASE_SVC_IM_CLIENTPRO_OEMRET_X64FRE_EN-US.ISO`)
- [ ] ISO output: slipstreamed ISO with unattended setup and a first-logon run for step 6
- [ ] Local account `User` ends up with a blank password, with no forced password creation at second logon (accepted security trade-off; mechanism for research — candidates: `net user User ""`, `net user User /logonpasswordchg:no`, `Set-LocalUser -PasswordNeverExpires`; note `net user User *` prompts interactively and cannot run unattended)
- [ ] USB outputs (to be confirmed by research): "Tools" stick (latest HP UEFI diagnostics in the folder F2 loads from, BIOS images per model in the flash tool's layout, scripts, `results` folder) and "Install" stick (ISO and per-model packs); operator has exactly two sticks

**Provisioning script (manual and recovery path)**
- [ ] Minimal selector: Assess (read-only) or Deploy, also available as `-Mode`
- [ ] Auto-detects vendor, model and platform
- [ ] Deploy MUST enforce the order above: warn or stop on out-of-date firmware, offer firmware-from-Windows fallback with BitLocker suspended on the Windows drive only
- [ ] Verify always runs last
- [ ] MUST run from USB; SHOULD run from a short `irm <url> | iex` served from GitHub (replacing pastebin), with automatic updates from the repo; which pieces the web route can pull is for research

**Atera**
- [ ] MUST NOT start the installer until the laptop is confirmed online (the MSI asks for an install token when offline, which the operator doesn't have)
- [ ] Online check SHOULD be a real request to Atera's endpoints, not just "network connected"

**Results**
- [ ] Verify timestamps every result in ISO 8601 UTC (e.g. `2026-10-05T10:02:00Z`)
- [ ] Results saved per serial to the Tools stick's `results` folder
- [ ] Sync: every script run with internet MUST upload every result on the stick, for any laptop, newer than what the central store has (catches up laptops checked offline); SHOULD run in background if simple, don't overbuild
- [ ] Central store must be pullable by the Excel tracker — needs proper research. Options: Microsoft Forms/Lists, OneDrive/SharePoint Excel via Microsoft Graph, Power Automate, files committed to a private repo, Airtable, cloud storage bucket, others. Compare on: no stored credentials on target laptops, works from PowerShell 5.1, cost, Excel (incl. mobile) pull/refresh, newest result per serial without duplicates, data exposed if a URL leaks

**Secrets**
- [ ] No credentials or customer-specific settings in the repo, including history (Atera MSI and download link, central-store IDs or tokens, etc.); supplied at run time via gitignored local config, the Tools stick, or parameters
- [ ] Repo SHOULD include a secret-scan check (pre-commit or CI)

### Out of Scope

- The Excel tracker workbook itself — operator builds and owns it; this project only provides the central store it pulls from
- Dell and Lenovo driver/firmware modules in the first milestone — repo structure first, modules after research (low priority)
- Automating the firmware flash and defaults reset before Windows — wish list, no milestone
- Storing the Wi-Fi password in the image — typed by the operator at Windows' setup network screen
- Module installs on target laptops — constraint (see below)

## Context

- Existing PowerShell tooling in `src/` (Build-HPDriverBaseline, New-HPBaselineIso, Install-HPDriverBaseline, Test-DeviceBaseline, HPDriverBaseline.psm1, Pester tests, `profiles/hp-elitebook-840-g6.psd1`) and an SOP at `docs/hp-elitebook-840-g6-driver-baseline.md`
- `HP_Staging/` holds local build output (gitignored): staged 8549 baseline and a built ISO
- Operator prepares used business laptops on site at vendor shops, mostly from a phone, with two USB sticks
- Targets now: HP EliteBook 840 G5 and 840 G6
- Known incident: 2026-10-05, five units couldn't use the pre-Windows USB BIOS flash route because files were in the wrong folders
- Vendor shop internet is unreliable; offline laptops must be caught up on later runs

## Constraints

- **Runtime**: Windows PowerShell 5.1, admin rights, no module installs on the target laptop — target laptops are stock Windows
- **Secrets**: nothing credential-like or customer-specific in the repo or its history — repo may be public or shared; secrets come in at run time
- **Network**: unreliable internet — every online step needs graceful offline behavior and later catch-up
- **Output**: green/yellow/red, easy to read; harmless exit codes are warnings, not failures — operator reads results on a phone
- **Ordering**: assess → firmware → BIOS defaults → UEFI diagnostics → image → first logon (drivers → online → Atera → verify → upload) is mandatory
- **Timestamps**: ISO 8601 UTC for all results — avoids timezone conflicts across sites
- **Hardware**: exactly two USB sticks (Tools and Install)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Modular vendor modules behind one interface | Adding Dell/Lenovo should not restructure the repo | — Pending |
| Bundle neighbouring-generation drivers (G5 + G6) in one image where safe | One image works on either model | — Pending |
| Support both vendor-published and custom latest-driver packs | Published packs are often years out of date | — Pending |
| Stage BIOS in exact vendor flash-tool layout, plus Windows flash tool fallback | Five units failed on 2026-10-05 from wrong folder layout | — Pending |
| Blank password for local account `User` | Avoids forced password creation at second logon; operator accepted the trade-off | — Pending |
| Block Atera install until real online check passes | MSI prompts for a token when offline | — Pending |
| Central results store chosen by research | Many viable options; compare on credentials, PS 5.1, cost, Excel pull, dedupe, leak exposure | — Pending |
| Secrets supplied at run time, never committed | No credentials in repo or history | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-10-05 after initialization*
