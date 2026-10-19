# Phase 2: Tools Stick Firmware Staging - Context

**Gathered:** 2026-10-19 (autonomous run, defaults chosen by Claude; Benjamin reviews in the PR)
**Status:** Ready for planning

<domain>
## Phase Boundary

The master build script stages BIOS images, HP UEFI diagnostics, the Windows flash tool fallback and a firmware manifest onto the Tools stick, in HP's exact pre-Windows layout, and validates the result so a wrong-folder stick fails loudly on the builder PC (the 2026-10-05 incident).

Requirements: BUILD-01, BUILD-06, FW-01..FW-06. Out of scope: Assess (Phase 3), ISO and Install stick (Phase 4), Deploy/first logon (Phase 5).

FW-06 (flash a real G5 and G6 from the stick) needs hardware. The code ships with a bench checklist and layout `Verified = $false`; the requirement stays open until Benjamin records the bench result. Verification therefore ends `human_needed`, by design.
</domain>

<decisions>
## Implementation Decisions

- **D-01:** Layout is data, not code. Each vendor ships a layout file (`kit/vendors/hp/layouts/hp-usb-flash.layout.psd1`) listing RelativePath, source kind and a `Verified` block (Model, Bios, Date, By). Unverified layouts stage fine but print a yellow warning and the manifest records `verified: false`. Resolves the `Current` vs `New` disagreement in research by making both a one-line change plus bench result.
- **D-02:** Builder entry is `builder/Build.ps1` (vendor-neutral, exists via Build-DriverBaseline pattern): parameters `-Vendor HP -Model 840G5,840G6 -TargetPath <drive|folder>`; interactive pick when omitted. Stage logic lives in `builder/vendors/hp/HP.Build.psm1` (`Get-FirmwareStickLayout`) and a vendor-neutral `Publish-FirmwareStage` / `Test-FirmwareStage` in `kit/core` (validator is reused by Assess/Verify later).
- **D-03:** G5 and G6 coexist: platform-ID-specific file names are kept as HP ships them, never renamed, so no overwrite. The validator fails if two models map to the same destination path with different hashes. If the bench shows the F10 flash tool cannot choose between models in one tree, `-FlashModel` stages one model only (escape hatch, built now).
- **D-04:** Tools stick is FAT32. Builder refuses a non-FAT32 target (or folder target with a `-AllowFolder` switch for tests) and names the volume problem in red. Volume label `HP_TOOLS` is requested for diagnostics; the stage tree holds only vendor trees plus `firmware-manifest.json`, `kit/` and `results/` side by side.
- **D-05:** Firmware manifest `firmware-manifest.json` (schema version, tool version, ISO 8601 UTC build time, per model: platform ID, latest BIOS version, file list with SHA-256, verified flag). Written by the stager from the same layout list the validator reads; no second source of truth.
- **D-06:** Validation (FW-03): required paths present, every file SHA-256 matches manifest and the vendor download hash, no unexpected files in vendor flash folders, FAT32 name limits OK. Failure = red line naming the exact file, non-zero exit, stick marked incomplete (no `READY` marker). Runs automatically at the end of staging and standalone (`Test-FirmwareStage`).
- **D-07:** Downloads go through the HP build module (HPCMSL on the builder only) and are cached under `staging/hp/<model>/firmware/`. Tests mock the download layer; no network in Pester.
- **D-08:** Windows flash fallback (FW-04) staged under `firmware\hp\<platform>\` (HPFirmwareUpdRec64 plus CVA data), as the existing Firmware stage produces.
- **D-09:** UEFI diagnostics (FW-05) are fetched from HP at build time, captured as a tree snapshot with hashes into the layout manifest ("capture and replay"), and staged to the volume root location HP's installer writes. Exact tree is unverified until bench; same Verified mechanism.
- **D-10:** Bench checklist `docs/firmware-bench-checklist.md` records steps and the Verified block fields for FW-06; Benjamin runs it on real hardware.

### Claude's Discretion
Function and file names beyond the above, Pester structure, how the HP download is wrapped, console formatting (green/yellow/red, phone width).
</decisions>

<canonical_refs>
- `.planning/ROADMAP.md` Phase 2 goal and 5 success criteria
- `.planning/REQUIREMENTS.md` BUILD-01, BUILD-06, FW-01..FW-06
- `.planning/research/ARCHITECTURE.md` sections 3, 7 (Tools stick layout, multi-model collisions)
- `.planning/research/PITFALLS.md` Pitfall 1 and P2 items
- `.planning/research/FEATURES.md` firmware staging rows
- `.planning/phases/01-modular-foundation/01-CONTEXT.md` D-01..D-15 (layout, vendor interface, gates)
- `Test-Kit.ps1` quality gate (Windows PowerShell 5.1, Pester, PSScriptAnalyzer zero findings, no suppressions)
</canonical_refs>

<code_context>
Existing: `kit/core/*` (Paths, Publish, Vendor, Config), `kit/vendors/hp/vendor.psd1`, `builder/Build-DriverBaseline.ps1`, `builder/vendors/hp/HP.Build.psm1`, `kit/core/Publish.ps1` (Get-KitPublishFile), tests under `tests/`.
Vendor contract already has `GetFirmware`; add `GetFirmwareStickLayout` to the contract table and descriptor.
</code_context>

<specifics>
Operator works from a phone: validator output must be short green/yellow/red lines.
</specifics>

<deferred>
- Dell/Lenovo layouts. Automating the flash itself.
</deferred>
