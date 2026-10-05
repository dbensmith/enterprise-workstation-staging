# Project Research Summary

**Project:** Enterprise Workstation Staging
**Domain:** Used business-laptop provisioning toolkit
**Researched:** 2026-10-05
**Overall Confidence:** MEDIUM-HIGH

## Executive Summary

This toolkit solves intake testing and imaging of refurbished laptops with zero network infrastructure. Rebuild with three architectural layers, split firmware staging into distinct phases (direct cause of 2026-10-05 incident), enforce strict stage-ordered pipeline with idempotent, resumable steps. Invest first in incident prevention (firmware layout validation, marker-based stick discovery).

**Key risks:** BIOS staging in wrong folder; image flashing firmware violates order; mixed G5/G6 drivers brick units; blank-password mechanics incomplete; Atera launched offline hangs. All preventable with testable designs.

## Key Findings

### Recommended Stack

- Windows PowerShell 5.1 (project constraint)
- HPCMSL 1.9.0 (min PS 5.1, builder only)
- Pester 6.2.0 (only version supporting 5.1)
- PSScriptAnalyzer 1.25.0 (no suppressions per policy)
- gitleaks v8.30.1 (MIT, pre-commit + CI)
- HP Platform IDs: G5 = 83B2 (Q78 BIOS), G6 = 8549 (R70 BIOS)
- Central store: Google Apps Script + Sheet (free, idempotent upsert)

**Confidence:** HIGH for versioning. MEDIUM for 26H2 OS support with HP catalogs.

### Expected Features (Must Ship)

- Per-serial result records (ISO 8601 UTC)
- Read-only Assess mode (inventory, lock checks, no mutations)
- Enforced stage order with state resumption
- Firmware staging in exact vendor layout (HP F10/DEVFW paths)
- Online gate before Atera (real HTTPS to Atera endpoints)
- Idempotent results sync (server-side upsert by serial+timestamp)

### Critical Pitfalls & Prevention

1. **BIOS files in wrong folder (2026-10-05 incident)** — Generate from HpFirmwareUpdRec sandbox, snapshot with SHA-256. Validator post-build; refuse publish if paths missing. Hardware test on G5+G6.

2. **Image flashes BIOS in specialize pass** — Unattend passes -SkipFirmware; image carries no Firmware folder. Pester test scans for absence.

3. **G5/G6 BIOS families collide on stick** — Platform-ID selection at build/runtime. Never put two ROM families in same folder. Filter firmware-class INFs from bulk pnputil.

4. **Blank-password account setup incomplete** — Layered: specialize net accounts /maxpwage:unlimited, unattend blank password, first-logon PasswordNeverExpires + /logonpasswordchg:no. Test on 26300 VM twice.

5. **Atera launched offline, hangs** — Real HTTPS to Atera endpoints; accept any HTTP status. Clock-skew check; MSI only if gate passed; hard timeout ~10 min. Cache gate result.

## Implications for Roadmap

### Suggested Phase Structure (9 phases; 8 deferred to v2; 9 is v1 but not MVP)

1. **Phase 1: Foundation** — Repo skeleton, vendor interface, secret scan, runtime config, stick discovery, git hygiene. Research: None.

2. **Phase 2: Firmware Staging** — Layout manifest, Tools-stick structure, Publish-Sticks, validator, menu SOP. Delivers incident fix. Research: Bench test HP BIOS paths on real G5/G6.

3. **Phase 3: Driver Packs** — Custom pack builder, platform ID detection, Assess mode, check library, profiles. Research: HP catalog gaps, G5 latest BIOS.

4. **Phase 4: Image Build** — ISO pipeline, unattend generator, Install-stick (FAT32, split-WIM), build manifest. Research: VM bench on 26300; hardware boot test.

5. **Phase 5: First-Logon** — Stage engine, online gate, LocalAccount, FirmwareGate, Atera stage, console output. Research: FirstLogonCommands on 26300; BitLocker suspension depth.

6. **Phase 6: Verification & Store** — Result schema, check expansion, sync algorithm, store adapter. Research: Apps Script PS 5.1 compatibility.

7. **Phase 7: Bootstrap** — Bootstrap stub, release packaging, short URL. Research: None.

8. **Phase 8 (v2+): Dell/Lenovo** — Deferred. Needs catalog research, hardware bench per vendor.

9. **Phase 9 (v1, not MVP): G5+G6 Union** — After per-model images are proven. Research overlap; deploy only once bench-proven.

### Research Flags

- **Phase 2:** BENCH VERIFY — HP BIOS USB paths on real G5/G6.
- **Phase 3:** MEDIUM-PRIORITY — HP catalog gaps, G5 latest BIOS.
- **Phase 4:** VM BENCH + HARDWARE TEST — blank-password on 26300, FAT32 boot with Secure Boot ON.
- **Phase 5:** HARDWARE BENCH (optional) — Atera MSI timeout realism.
- **Phase 6:** APPS SCRIPT RESEARCH — PS 5.1 compatibility; if negative, pivot to Azure Blob.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified via PowerShell Gallery / Context7 docs 2026-10-05 |
| Features | MEDIUM | Industry patterns + vendor constraints verified |
| Architecture | MEDIUM-HIGH | Grounded in reading existing code |
| Pitfalls | MEDIUM-HIGH | Vendor docs HIGH; gaps at MEDIUM level |
| USB layouts | MEDIUM | HP SoftPaq HIGH; folder variants MEDIUM (conflicting); bench verification flagged |
| First-logon | MEDIUM | Microsoft docs HIGH; mechanisms need VM bench |
| Online gate | MEDIUM | Atera docs MEDIUM-HIGH; timeout inference MEDIUM |
| Store options | MEDIUM | Apps Script basics HIGH; PS 5.1 redirect not bench-verified |

**Overall: MEDIUM-HIGH.** Foundations solid; architecture testable; hardware/Apps Script unknowns are phase-level research tasks, not roadmap blockers.

### Gaps to Address (Phase-Level Research)

1. HP USB layouts (Phase 2) — Bench test on real G5/G6
2. Apps Script PS 5.1 (Phase 6) — Test doPost 302, LockService, Excel Power Query
3. Blank-password autologon on 26300 (Phase 5) — VM bench two reboots
4. G5 latest BIOS and 2023 certs (Phase 3) — Confirm sp157750, certificate inclusion
5. DISM union tolerance (Phase 4) — Confirm /Add-Driver /Recurse exit codes
6. FAT32 split-WIM boot (Phase 4) — Hardware test on G5/G6 with Secure Boot ON
7. Atera MSI properties (Phase 5) — Hardware bench on stock Windows

All phase-level, not blockers.

---

## Ready for Roadmap

**Status: SYNTHESIS COMPLETE**

All four research files synthesized. Incident fix isolated and safe. Architecture sound. Confidence MEDIUM-HIGH. Hardware/Apps Script gaps are phase-level research tasks with clear success criteria; not roadmap blockers.

**Recommendation:** APPROVED for roadmap planning.

*Research synthesized: 2026-10-05*
*Confidence: MEDIUM-HIGH | Status: Ready for requirements & roadmap*
