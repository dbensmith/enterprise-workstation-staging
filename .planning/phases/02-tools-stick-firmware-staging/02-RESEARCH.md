# Phase 2: Tools Stick Firmware Staging - Research

**Researched:** 2026-10-20
**Domain:** Windows PowerShell 5.1 build-time staging of HP pre-Windows firmware (BIOS images, UEFI diagnostics, Windows flash fallback) onto a FAT32 USB stick, with a hash-based validator and offline Pester coverage
**Confidence:** MEDIUM overall. HIGH for HPCMSL behaviour, hashes, file contents, installer behaviour and repo mechanics (all run or read this session). LOW for which BIOS menu path reads which folder on a real 840 G5 / G6 (no hardware, no USB stick, not elevated). That gap is the reason FW-06 stays `human_needed`.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

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

### Deferred Ideas (OUT OF SCOPE)

- Dell/Lenovo layouts. Automating the flash itself.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BUILD-01 | Operator runs one master build script and chooses brand and models | `builder/Build.ps1` pattern (Architecture Patterns 1); vendor/model discovery through existing `Get-KitVendor`, `Get-KitProfile`; real ModelIds are `840-g5` / `840-g6` (Open Question 7) |
| BUILD-06 | Builder writes a firmware manifest (model, platform ID, latest BIOS version, hash) onto the Tools stick | Manifest schema sketch; hash sources (CVA SHA-256, catalog SHA-384) verified; PS 5.1 JSON/BOM/depth traps verified |
| FW-01 | BIOS files in the exact folder layout HP's pre-Windows USB flash tool reads, per model, FAT32 | HP Pre-Windows Layout Evidence section; recommended superset layout with per-group Verified; FAT32 constraints |
| FW-02 | G5 and G6 BIOS images coexist without overwriting | Verified distinct names `Q78_013100.bin` / `R70_013600.bin`; collision rule; `DEVFW\firmware.bin` cannot hold two models |
| FW-03 | Builder validates staged layout (paths, hashes) and fails loudly | Validator design, negative incident test, Pester seams, exit-code child-process test |
| FW-04 | Builder stages HP's Windows flash tool as fallback | SoftPaq contents verified for both models; CVA silent command and return codes verified |
| FW-05 | Builder stages latest HP UEFI diagnostics where F2 loads it, alongside the BIOS layout | sp171653 (10.8.5.0) verified newest found; installer behaviour from MSI tables and Installer.exe strings; capture-and-replay procedure |
| FW-06 | Layout proven by flashing a real G5 and G6 from the stick | Bench checklist content; stays open (`human_needed`) by design |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

No `./CLAUDE.md` or `.claude/CLAUDE.md` exists in this repo (checked). The binding rules come from the Phase 1 gate and the user's global rules:

- **Quality gate** `Test-Kit.ps1` on Windows PowerShell 5.1: PSScriptAnalyzer 1.25.0 with zero findings, **no suppression of any kind** (inline, config or severity filter) - user rule "NEVER disable or bypass linting rules" and enforced by `tests/Repo.Tests.ps1` (`carries no SuppressMessage attribute`). Pester 6.2.0 pinned. gitleaks 8.30.1 pre-commit.
- **Pure ASCII** in every `.ps1`/`.psm1`/`.psd1`/`.cmd` (enforced: `'<File> is pure ASCII'`). No em dashes, no smart quotes, in code, comments or help.
- **PowerShell style** (user rules): approved verbs, singular nouns, full cmdlet names, `[switch]` never `[bool]` for flags, `SupportsShouldProcess` on state-changing commands, `Write-Host` only for UI text (inside a `Show-*` function, the pattern the lint gate accepts - see Pitfall 11), no `Read-Host` inside library functions (prompts only in the entry script), comment-based help on public functions.
- **Pester 6 style**: one `BeforeAll`/`BeforeEach`/`AfterAll`/`AfterEach` per block, `Should -Invoke` (no `Assert-MockCalled`), a default mock when a `-ParameterFilter` mock can miss, `-ForEach` data must be non-empty, files independently runnable.
- **Core is vendor-neutral and tested for it:** `tests/Core.Tests.ps1` scans every file under `kit/core` for `\bHP\b|HPCMSL|Hewlett|SoftPaq` (case-sensitive).
- Commit conventions (Conventional Commits, no AI attribution) apply to executors, not to this research. This research was not committed.

## Summary

The phase is mostly mechanics the repo already knows how to do (data-file layouts, hash manifests, vendor contract, PS 5.1 gates). The hard part is the one thing nobody could verify from documents: **which folder on the stick each G5/G6 BIOS menu reads**. This session closed everything that could be closed without hardware by reading HP's own binaries and metadata statically (no installer was run; one SoftPaq self-extraction was attempted and hung, see Pitfall 6). Findings that change the plan:

1. **Hash sources are real and cheap.** HP's catalog (`Get-HPBIOSUpdates -Platform <id> -All`) returns a `Sha384` for each BIOS `.bin`, and SoftPaq metadata (`Get-HPSoftpaqMetadata`) returns `SoftPaqSHA256`. Both were checked against files on disk and match exactly (G6 `.bin` SHA-384 and the SoftPaq `.exe` SHA-256 for four SoftPaqs). So D-06's "vendor download hash" is: SHA-256 for the SoftPaq executable, SHA-384 for the BIOS image, and nothing per-file for the other extracted files (those are Authenticode-signed by HP instead).
2. **The G5 and G6 BIOS files do not collide.** The packages are `Q78_013100.bin` (24,258,144 bytes) and `R70_013600.bin` (31,253,904 bytes), each with a single `.bin`, no `.sig`/`.s12`. Everything is far below FAT32's 4 GiB file limit.
3. **UEFI diagnostics are one generic package, not per platform, and STACK.md's version is stale.** The newest I could confirm is `sp171653` = 10.8.5.0 (HP page effective 2026-03-13, supersedes `sp167305` 10.8.4.0). It does not appear in HPCMSL's per-platform catalog, so "latest" cannot be discovered by platform query; pin the SoftPaq number in the layout/snapshot and re-check at refresh time.
4. **The diagnostics USB install is GUI-only.** The MSI runs `C:\Windows\HP\Installer.exe -usb -uefisupport` for USB (silent form exists only for the hard-drive/ESP target). Static strings in that HP-signed `Installer.exe` show it writes `%s\EFI\HP\SystemDiags\` and `%s\EFI\HP\BIOSUpdate\` (plus `DI.efi`), requires FAT32, and can rename or format the volume to `HP_TOOLS`. So D-09 "capture and replay" is the right call, with a manual capture step; and the tree is under `\EFI\HP\`, not under `\Hewlett-Packard\SystemDiags` as STACK.md assumed.
5. **Current vs New is explained, not solved.** Evidence points to different menus using different folders: HP's own tool strings contain `BIOS\Current\`, `BIOS\New\`, `BIOS\Previous\`, `BiosUpdate\`, `DEVFW\`, `Hewlett-Packard`, `EFI\HP\`; community reports say F10 "Update System BIOS" wants `...\BIOS\New`, HP's support page (via search summary) routes the F2 diagnostics "Firmware Management" through `...\BIOS\Current`; HP's own 2026 SoftPaq doc says Esc/F10 "Using Local Media" wants `HP\DEVFW\firmware.bin` or `EFI\HP\DEVFW\firmware.bin`. Whether 2018/2019 platforms implement the DEVFW flavour is unknown. Recommendation: stage a **superset** with each placement as its own `Group` carrying its own `Verified` state, prune after the bench.
6. **A trap for the bench:** the G6 `1.36.00` SoftPaq carries `MinimumBIOSVersion_R70 = 01.35.02` (CVA `[Dependency]`), and its return-code table has `1602 ... Flash failed due to dependency not satisfied`. A G6 on an older BIOS may refuse 1.36.00 from the stick. Bench the G6 on a unit already at or above 1.35.02, or stage the chain.

**Primary recommendation:** Build the stager/validator as vendor-neutral data-driven code in `kit/core` (new file, new exports, pinned-export test updated), add one new Build-plane contract operation for the layout, resolve BIOS images from the existing `Save-HPKitFirmware` output (no second download), verify them with the catalog SHA-384 and CVA SHA-256, stage the superset layout plus a captured diagnostics tree, write `firmware-manifest.json` without BOM at depth 6, and let the validator re-read the stick against that same manifest. Ship the bench checklist; do not mark FW-06 done.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Pick vendor and models, choose target drive | Builder entry script (`builder/Build.ps1`) | `kit/core` (vendor/profile discovery) | Prompts belong only at the entry layer; library functions take parameters |
| Download and hash-check BIOS / SoftPaqs | HP build module (`builder/vendors/hp`, HPCMSL) | - | HPCMSL is builder-only; core must not name a vendor |
| Declare what goes where on the stick (layout data) | Vendor layout file under `kit/vendors/hp/layouts` | `kit/core` loader/schema check | Layout is data (D-01); `kit/` travels to the laptop so Assess/Verify can read the same file later |
| Resolve layout to concrete source/destination/hash entries | HP build module (`GetFirmwareStickLayout` operation) | `kit/core` (merge, collision check) | Only the vendor knows file names and hash sources; the merge/collision rule is vendor-neutral |
| Copy to the stick, write manifest, write READY | `kit/core` (`Publish-FirmwareStage`) | OS (FAT32 volume) | Vendor-neutral file operations; destructive volume actions (format) are never automatic |
| Validate (paths, hashes, FAT32 rules, unexpected files) | `kit/core` (`Test-FirmwareStage`) | - | Reused by Assess/Verify on the laptop; must run with no module installs |
| Console green/yellow/red output | Entry script + one `Show-*` function | - | Output is UI text; data stays in result objects |
| Capture HP diagnostics tree | Operator on the builder (HP's GUI installer) + a capture script | Layout snapshot data (committed) | HP installer USB mode has no silent switch |
| Prove layout on hardware (FW-06) | Operator at the bench | Layout `Verified` blocks | Cannot be automated or unit-tested |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Windows PowerShell | 5.1.26100.9711 (this builder) | All code | Project constraint [VERIFIED: `$PSVersionTable` this session] |
| HPCMSL | 1.9.0 (PowerShell Gallery, published 2026-08-18) | `Get-HPBIOSUpdates`, `Get-HPSoftpaqList`, `Get-HPSoftpaq`, `Get-HPSoftpaqMetadata`, `Get-HPDeviceDetails` | Already the Phase 1 builder dependency; HP's own library [VERIFIED: `Find-Module HPCMSL` -> Version 1.9.0, Author HP Development Company L.P., PublishedDate 2026-08-18] |
| Pester | 6.2.0 | Tests | Pinned in `Test-Kit.ps1` [VERIFIED: Test-Kit.ps1:100 `$pesterVersion = '6.2.0'`] |
| PSScriptAnalyzer | 1.25.0 | Lint | Pinned [VERIFIED: Test-Kit.ps1:101 `$analyzerVersion = '1.25.0'`] |

### Supporting (built in, no install)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Get-FileHash` | inbox | SHA-256 and SHA-384 | All hashing; SHA-384 length 96 hex chars [VERIFIED: probe this session] |
| `Import-PowerShellDataFile` | inbox | Layout/snapshot `.psd1` loading (rejects code) | Layout files; array of hashtables keeps order, `$true/$false/$null` parse [VERIFIED: probe this session] |
| `[System.IO.DriveInfo]` | .NET 4.x | `DriveFormat` (`FAT32`), `VolumeLabel`, `DriveType` without CIM or admin | The volume-info seam [VERIFIED: returned `NTFS Fixed` for C: in 5.1 this session; FAT32/removable values on a real stick unverified] |
| `Set-Volume`, `Write-VolumeCache` (Storage module) | inbox on Windows 11 | Set label `HP_TOOLS`; flush before eject | Behind a seam, `ShouldProcess`-guarded; admin needed (assumed) |
| `Get-AuthenticodeSignature` | inbox | HP signature check on extracted `.exe` | Optional extra validator check for FW-04 files [VERIFIED: `HpFirmwareUpdRec64.exe` Status Valid, signer HP Inc.] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Reusing `Save-HPKitFirmware` output | `Get-HPBIOSUpdates -Download` for the `.bin` | Direct download is smaller and self-verifies SHA-384, but the SoftPaq is needed anyway for the Windows flash tool (FW-04); a second download duplicates the work Phase 1 removed |
| Capture-and-replay of diagnostics | Rebuild the tree from the MSI payload with `msiexec /a` or 7-Zip | Needs a guess at the file-to-folder mapping; useful only as a hash cross-check against a real capture. Do not make it the primary path |
| `[IO.DriveInfo]` | `Get-Volume` / `Win32_Volume` CIM | Both need more setup and are harder to mock; DriveInfo is one line |

**Installation:** nothing new. HPCMSL is already a builder prerequisite. Note `Initialize-HPCMSL` calls `Install-Module HPCMSL`, which fails on a builder with inbox PowerShellGet 1.0.0.1 (Pitfall 7).

**Version verification:** `Find-Module HPCMSL` returned 1.9.0 (2026-08-18) on 2026-10-20; the 15 HP.* dependency modules were all 1.9.0.

## Package Legitimacy Audit

This phase installs no new external package. HPCMSL (PowerShell Gallery) is already a Phase 1 dependency. The `gsd-tools package-legitimacy` seam supports only `npm|pypi|crates`; running it for `HPCMSL` returned `SLOP` ("exists: false"), which is a wrong-ecosystem artefact, not a finding. Manual evidence instead:

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| HPCMSL 1.9.0 | PowerShell Gallery | published 2026-08-18 (line existed since 2019; 1.9.0 is a release of an established library) | not queried | none listed on the Gallery page (`ProjectUri` empty); docs at developers.hp.com/hp-client-management | seam unsupported for this ecosystem; manual: Author "HP Development Company L.P." | Approved (already in use since Phase 1). Tag `[CITED: developers.hp.com/hp-client-management]`, not `[VERIFIED: npm registry]` |

**Packages removed due to [SLOP] verdict:** none (the one SLOP above is a false positive from the wrong ecosystem).
**Packages flagged as suspicious [SUS]:** none.

Tooling used for research only, not part of the project: 7-Zip 26.04 (static archive listing of HP SoftPaqs). Do not add it as a dependency.

## HP Pre-Windows USB Layout: Evidence and Recommended Superset

This is the section the plan must treat as a hypothesis set. Everything below is labelled by how it was obtained.

### What HP's own binaries say (static string scan, nothing executed)

Source A: `HpFirmwareUpdRec64.exe` from `sp174025` (SHA-256 `9670dbadb4e56787a2d8510cf43e4758a558b53aa9011696ce55544effef1409`, signature Valid, signer HP Inc.). UTF-16 strings, verbatim: `Create Recovery USB flash drive`, `BIOS\Current\`, `BIOS\New\`, `BIOS\Previous\`, `BiosUpdate\`, `DEVFW\`, `EFI\HP\`, `Hewlett-Packard`, `HP_TOOLS`, `format fs=FAT32 label="HP_TOOLS" quick`, `HP_TOOLS partition has wrong file system.` Class/method names in the same file: `HPBiosUpdate::UsbKey::CopyBiosUpdate`, `HPBiosUpdate::Partition::CreateHpBiosFolderHierarchy`. English usage text (undocumented in the shipped `HpFirmwareUpdRec.txt`): `-h:  Create HP_TOOLS partition if not present.`, `-w: Output firmware.bin`, `-o: Number of postpone opportunities allowed. Default is 3. Max value is 5.`, `-t: Postpone time in minutes. Default is 10 minutes. Max value is 60 minutes.` [VERIFIED: static scan of the file this session]

Source B: `Installer.exe` inside `Setup.msi` inside `sp167305` (10.8.4.0). The 10.8.5.0 package (`sp171653`) has the same MSI custom actions and install folder (Source C), but its `Installer.exe` was not string-scanned, so treat the folder names below as true for 10.8.4.0 and expected for 10.8.5.0. Verbatim UTF-16 strings: `%s\EFI\HP\SystemDiags\`, `%s\EFI\HP\SystemDiags\DI.efi`, `%s\EFI\HP\BIOSUpdate\`, `%s\EFI\HP\DI.efi`, `\BIOS\Current`, `\BIOS\New`, `\BIOS\Previous`, `\Hewlett-Packard`, `\SystemDiags`, `HP_TOOLS`, `Renamed the volume name from %s to %s`, `Format FS=FAT32 LABEL="%s" QUICK`, `c:\windows\system32\format.com %s /FS:FAT32 /V:HP_TOOLS/y`; ASCII: `Invalid USB partition, please format USB flash drive as FAT32.`, `SetVolumeLabelW`, `-usb`, `-hdd`, `-uefisupport`, `-esp`, `-bestsize`. [VERIFIED: static scan this session]

Source C: MSI custom actions of `sp167305` and `sp171653` (read read-only through the Windows Installer COM object), verbatim:
```
InstallHDD       | C:\Windows\HP\Installer.exe -hdd -uefisupport -esp -bestsize
InstallUSB       | C:\Windows\HP\Installer.exe -usb -uefisupport
InstallHDDSilent | C:\Windows\HP\Installer.exe -hdd -uefisupport -esp -s -bestsize
LaunchDiags      | C:\Windows\HP\BootUefiMem.exe -uefi -reboot
```
with sequence conditions `InstallUSB: (INSTALL_MODE = 2) AND (UILevel <> 2)` and `InstallHDDSilent: UILevel = 2`. `INSTALLFOLDER` is `Windows\HP`. [VERIFIED: MSI tables read this session; `ProductVersion` 10.8.4.0 and 10.8.5.0]

Source D: payload of that MSI (59 files, long names from the MSI `File` table): `SystemDiags.efi`, `HpSysDiags.efi`, `SysDiags.efi`, their `32`-suffixed variants, `SysDiagsArm.efi`, `BiosMgmt.efi`, `HpBiosMgmt.efi`, `HpBiosUpdate.efi` (+32), `CryptRSA.efi`, `CryptRSA32.efi`, each `.efi` with `.s12`, `.s14`, `.s23` signature companions (256 bytes each), `SystemDiags.dll`, `HpSysDiags`-family DLLs, `HpUefiSupport.dll`, `HpBiosUpdate.dll`, `UEFIDefinitions.json`, `EADB.json`, `BiosConfigUtility64.exe`, `BootUefiMem.exe`, `Installer.exe`. The MSI installs these to `%WINDIR%\HP`; `Installer.exe` then places them on the target volume. `DI.efi` is not in the payload list, so the installer creates it (string: `Failed to create DI.efi`). [VERIFIED: MSI File table this session]

### What HP's documentation and the community say

| Claim | Source | Tag |
|-------|--------|-----|
| Esc "Update System and Supported Device Firmware" and F10 "Update System BIOS" > "...Using Local Media" read `HP\DEVFW` or `EFI\HP\DEVFW`; file "must be named 'firmware.bin'"; HpFirmwareUpdRec "has a feature that will copy the image file to the correct folder on a USB device for you" | `Bios Flash.htm`, HP Firmware Pack `sp174025`, copyright 2026 (read this session) | [VERIFIED: file read] for the text; whether G5/G6 firmware implements this flavour is [ASSUMED] unknown |
| Crisis recovery: copy the `.bin` to `EFI\HP\BIOS\current` on a FAT/FAT32 partition and power on | same document | [VERIFIED: file read] |
| A package with several BIOS families "packs both files together when creating BIOS Update USB key, which will not result in a successful update" - delete the non-matching `.bin` | same document | [VERIFIED: file read]. It speaks of the tool's merged key, not the file-picker menu |
| F10 "Update System BIOS" local media: error "could not find one of the BIOS update binary files"; tool looks in `Hewlett-Packard\BIOS\New` or `EFI\HP\BIOS\New`; fix reported = move files from `Current` to `New` | HP Support Community threads (403 to direct fetch; via search summaries) | [CITED: h30434.www3.hp.com threads, search summary] MEDIUM-LOW |
| F2 diagnostics path "Firmware Management > BIOS Update > Select BIOS Image to Apply > HP_TOOLS-USB Drive > Hewlett-Packard > BIOS > Current" | HP support document ish_4208192 (page times out; via search summary) | [CITED: support.hp.com ish_4208192, search summary] MEDIUM-LOW |
| A tree written by an HP recovery tool on a Windows VM (older HPFlashWinx64): `HP\BIOS\{Current(.bin+.sig),New,Previous}`, `HP\BIOSUpdate\`, `HP\DEVFW\{Current,New,Previous}`, plus a `Hewlett-Packard\` copy of `HP\` | dvdkon.ggu.cz blog, 2024-07-20 | [CITED: dvdkon.ggu.cz/blogpost/hp_ex360_bios_update] LOW-MEDIUM; different model and tool generation |
| A hand-placed diagnostics tree started F2 diagnostics but "Firmware Management" was missing | dvdkon.ggu.cz Linux blog | [CITED] LOW; indicates hand-assembled trees are incomplete |
| F2 searches USB, then hard drive, then built-in | HP user guide via search summary; STACK.md | [CITED] MEDIUM |
| Diagnostics "must be run from a FAT or FAT32 partition with a partition name of HP_TOOLS or EFI"; installer renames the USB partition to HP_TOOLS; "HP recommends users not place additional data on the HP_TOOLS or EFI partition" | HP FTP release notes for `sp167305` and `sp171653` (fetched) | [VERIFIED: ftp.hp.com/pub/softpaq/sp171501-172000/sp171653.html fetched this session] |

### Can everything share one FAT32 volume with both models?

- **Two BIOS images:** yes by file name. `Q78_013100.bin` and `R70_013600.bin` are different names and different families, so neither overwrites the other [VERIFIED: 7-Zip listing of `sp157750.exe` and file listing of `sp174025`]. Whether the BIOS picker lists both and rejects the wrong family safely is unverified (bench). HP's "packs both files together" warning applies to the merged `firmware.bin` mechanism, so `DEVFW\firmware.bin` is inherently one model per stick; keep it out of the default layout.
- **Diagnostics with BIOS files:** the diagnostics package is not model-specific (CVA `Private_ProductType = Desktops`, system list empty, returned by no per-platform catalog query for 83B2) so one copy serves both laptops. HP's statement about "no additional data" is a recommendation about an unprotected partition, not a technical prohibition; the real risk is the HP installer renaming or reformatting the volume (Source B), which is an ordering problem (Pitfall 3). Extra top-level folders (`kit\`, `results\`, `firmware\`) are therefore expected to be harmless but unverified for F2 and for the F10 picker.
- **Verdict:** one volume is plausible and is what D-04 locks. Treat "F2 still loads diagnostics, and the F10/Firmware-Management pickers still list both images, with `kit\` and `results\` present" as bench items.

### Recommended default layout (superset, prune after bench)

All `[ASSUMED]` as to which row works; every row is its own `Group` so the bench result is one line per group.

| Group | Destination (relative to the volume root) | Contents | Why it is there |
|-------|-------------------------------------------|----------|-----------------|
| `F10-New` | `Hewlett-Packard\BIOS\New\` | each selected model's `.bin`, original name | community F10 local-media path |
| `F10-New-ESP` | `EFI\HP\BIOS\New\` | same files | same reports list `EFI\HP\BIOS\New` as equivalent |
| `Diag-Current` | `Hewlett-Packard\BIOS\Current\` | same files | HP support path for Firmware Management; also what HP's recovery tool writes |
| `Diag-Current-ESP` | `EFI\HP\BIOS\Current\` | same files | HP doc crisis-recovery folder |
| `Diag-Tree` | `EFI\HP\SystemDiags\`, `EFI\HP\BIOSUpdate\`, `EFI\HP\DI.efi` | captured snapshot of HP installer output | Source B strings |
| `Esc-DEVFW` | `HP\DEVFW\firmware.bin`, `EFI\HP\DEVFW\firmware.bin` | one model's image produced by `HpFirmwareUpdRec64.exe -w` | **Off by default**: one model only, creation by `-w` unverified, only for the `-FlashModel` escape hatch |
| `Win-Fallback` | `firmware\hp\<platform>\` | whole extracted SoftPaq folder | FW-04 (D-08) |

Closed folders (the validator rejects any file not in the layout): the four `BIOS\New` / `BIOS\Current` folders. The diagnostics tree is validated against its snapshot. The stick root allows `kit`, `results`, `firmware`, `firmware-manifest.json`, the READY marker, `System Volume Information` and `$RECYCLE.BIN` (Windows creates the first on FAT32 sticks).

`.bin` copies per model are 24.2 MB (G5) and 31.3 MB (G6) times four groups, about 220 MB, plus the diagnostics payload (MSI is 53 MB compressed, 116 MB raw), plus two fallback folders (about 40 MB raw each). Comfortable on any stick of 8 GB or more.

### Hash sources (for D-06) - all checked against files on disk this session

| File | Vendor hash | Where it comes from | Result |
|------|-------------|---------------------|--------|
| SoftPaq `.exe` | SHA-256 | `(Get-HPSoftpaqMetadata -Number N).Softpaq.SoftPaqSHA256` | `sp174025.exe` on disk `22e7030c00323d8c64e392ce8575f5dc36dea41b151922bf25a4cacb4b7d2dcb` equals CVA `SoftPaqSHA256 = 22E7030C00323D8C64E392CE8575F5DC36DEA41B151922BF25A4CACB4B7D2DCB`; downloads of `sp157750` (`FA19E12E...8BBAE`), `sp167305` (`008E2F10...E4259`), `sp171653` (`80858E96...73BD96`) also equal their CVA values (compared case-insensitively) |
| BIOS `.bin` | SHA-384 | `Get-HPBIOSUpdates -Platform <id> -All` property `Sha384` | `R70_013600.bin` SHA-384 `944748b1138f06b3f977ffb0bac10346611bcae1845e793bc25fb15e9ed338a284bc1ce71b8cfcb9fcc347a642eb3ba7` equals the catalog's `Sha384` for `Ver 1.36.00` |
| other extracted files (`HpFirmwareUpdRec64.exe`, DLLs) | none per file | - | HP Authenticode signature (`Valid`, HP Inc.) is the integrity signal; record our own SHA-256 |
| diagnostics payload files | none from HP per file | - | our SHA-256 from the captured snapshot; the SoftPaq SHA-256 identifies the version captured |

`Get-HPBIOSUpdates -Download` itself compares the downloaded file to `Sha384` and throws `Downloaded file hash does not match the expected hash.` [VERIFIED: HP.ClientManagement.psm1 source read]. Its `-Latest` output has only `Ver, Date, Bin`; `-All` adds `Sha384`, `RollbackAllowed`, `Importance`, `Dependency` [VERIFIED: property names printed this session]. The catalog version reads `1.31.00` (leading zero trimmed) while the SoftPaq and profile read `01.31.00`; compare as `[version]`.

## Architecture Patterns

### System Architecture Diagram

```
 OPERATOR (builder PC, elevated 5.1)
   |
   |  builder\Build.ps1 -Vendor HP -Model 840-g5,840-g6 -TargetPath E:\   (prompts only here)
   v
 +------------------------------+      +----------------------------------------------+
 | entry: choose vendor/models  |----->| kit\core  Get-KitVendor / Get-KitProfile      |
 | target drive check (UI only) |      | (vendor-neutral, no HP names)                 |
 +--------------+---------------+      +----------------------------------------------+
                | per model
                v
 +-----------------------------------------------+     HPCMSL (builder only)
 | Invoke-KitVendorCommand  GetFirmware          |---> Get-HPSoftpaqList / Get-HPSoftpaq -Extract
 |   (Save-HPKitFirmware, existing)              |     Get-HPSoftpaqMetadata (CVA: SHA-256, SilentInstall, ReturnCode)
 +--------------+--------------------------------+     Get-HPBIOSUpdates -All (Sha384, Dependency)
                | package dir  staging\hp\<model>\win11-<rel>\Firmware\spNNN\
                v
 +-----------------------------------------------+
 | Invoke-KitVendorCommand  GetFirmwareStickLayout|<--- kit\vendors\hp\layouts\hp-usb-flash.layout.psd1  (data)
 |   returns resolved entries:                    |<--- kit\vendors\hp\layouts\captures\*.snapshot.psd1 (diagnostics paths + SHA-256)
 |   RelativePath, SourcePath, Group, Required,   |
 |   Sha256, Size, VendorHash{Algo,Value,Source}  |
 +--------------+--------------------------------+
                v
 +-----------------------------------------------+
 | kit\core  Publish-FirmwareStage                |
 |  1 merge models; same dest + different hash => stop (D-03)
 |  2 refuse non-FAT32 / fixed disk (seam: Get-KitVolumeInfo), -AllowFolder for tests
 |  3 delete old READY, copy entries, set label HP_TOOLS (ShouldProcess)
 |  4 write firmware-manifest.json (no BOM, depth 6, UTC)
 |  5 Test-FirmwareStage  --> findings (Pass/Warn/Fail)
 |  6 all Pass/Warn => write READY last ; any Fail => no READY, exit 1
 +--------------+--------------------------------+
                v
   Show-* lines (green/yellow/red) + exit code  --->  operator leaves for the shop
                |
   later, on the laptop: Assess/Verify call Test-FirmwareStage on the stick it ran from
```

### Recommended Project Structure

```
builder/
  Build.ps1                          # NEW master entry (BUILD-01); Build-DriverBaseline.ps1 stays
  vendors/hp/HP.Build.psm1           # + Get-HPKitFirmwareStickLayout (and BIOS-image/hash helpers); export list edited
kit/
  core/
    Firmware.ps1                     # NEW: layout loader, merge, Publish-/Test-FirmwareStage, FAT32 rules, Get-KitVolumeInfo seam
    Kit.Core.psd1                    # FunctionsToExport extended (see Pitfall 1)
    VendorContract.psd1              # + GetFirmwareStickLayout (Build plane)
    Vendor.ps1                       # ValidateSet in Invoke-KitVendorCommand extended
  vendors/hp/
    vendor.psd1                      # + GetFirmwareStickLayout = '...'
    layouts/hp-usb-flash.layout.psd1 # NEW (D-01)
    layouts/captures/diagnostics-sp171653.snapshot.psd1   # NEW after the bench capture (paths + SHA-256 + size only)
tests/
  Firmware.Tests.ps1                 # core stager/validator/FAT32/READY/manifest
  HP.Firmware.Tests.ps1              # HP layout resolution with the HPCMSL stand-in
  fixtures/vendors/complete/...      # + new op in Fixture.Build.psm1 and both vendor.psd1 fixtures
docs/firmware-bench-checklist.md     # NEW (D-10)
staging/hp/captures/                 # gitignored: captured diagnostics tree (binaries)
```

### Pattern 1: Layout is data, resolution is the vendor's job, merging is core's job

**What:** The layout `.psd1` is an ordered array of groups/entries (arrays, not hashtable-of-hashtables, because a hashtable loaded from `.psd1` has no order - the repo already learned this in `VendorContract.psd1`). The HP operation resolves it for one model to concrete `SourcePath`/`RelativePath`/hash entries. Core merges several models, dedupes identical (same destination, same SHA-256), and throws on same destination with different hashes naming both models and the path.
**When to use:** always; no vendor path string in code.
**Example (data file shape; every value follows from the verbatim quotes above):**
```powershell
# kit/vendors/hp/layouts/hp-usb-flash.layout.psd1  (data only, pure ASCII)
@{
    SchemaVersion = 1
    VolumeLabel   = 'HP_TOOLS'
    FileSystem    = 'FAT32'
    Groups        = @(
        @{ Id = 'F10-New';      Folder = 'Hewlett-Packard\BIOS\New';  Source = 'BiosImage'; Closed = $true;  Default = $true
           Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Diag-Current'; Folder = 'Hewlett-Packard\BIOS\Current'; Source = 'BiosImage'; Closed = $true; Default = $true
           Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Diag-Tree';    Folder = 'EFI\HP';                    Source = 'Captured:diagnostics-sp171653'; Closed = $false; Default = $true
           Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Win-Fallback'; Folder = 'firmware\hp\{Platform}';    Source = 'WindowsFlashTool'; Closed = $true; Default = $true
           Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
    )
}
```
(`F10-New-ESP`, `Diag-Current-ESP` and `Esc-DEVFW` follow the same shape. One `Verified` block per group still satisfies D-01's `Verified` block with Model, Bios, Date, By; it just records per path what the bench proved.)

### Pattern 2: One manifest, written from the resolved list, re-read by the validator

**What:** `Publish-FirmwareStage` builds the manifest from the same resolved entry list it copies; `Test-FirmwareStage` reads `firmware-manifest.json` back from the target and walks it. No second list (D-05).
**Manifest sketch (planner may rename keys; keep these facts):**
```json
{
  "schemaVersion": 1,
  "toolVersion": "0.1.0",
  "builtUtc": "2026-10-20T09:00:00Z",
  "vendor": "HP",
  "volumeLabel": "HP_TOOLS",
  "verified": false,
  "groups": [ { "id": "F10-New", "verified": false } ],
  "models": [
    {
      "modelId": "840-g6", "name": "HP EliteBook 840 G6", "platformId": "8549", "platformVerified": true,
      "biosFamily": "R70",
      "latestBios": { "version": "01.36.00", "date": "2026-06-13", "softpaq": "sp174025", "file": "R70_013600.bin", "dependencyMinimum": "01.35.02" },
      "files": [ { "path": "Hewlett-Packard\\BIOS\\New\\R70_013600.bin", "group": "F10-New", "size": 31253904,
                   "sha256": "<64 hex>", "vendorHash": { "algorithm": "SHA384", "value": "944748b1...", "source": "Get-HPBIOSUpdates -All" } } ],
      "windowsFlash": { "path": "firmware\\hp\\8549", "silentInstall": "\"HpFirmwareUpdRec.exe\" -r -b -s",
                        "returnCodes": { "3010": "SUCCESS:REBOOT", "282": "CANCEL", "1602": "CANCEL" } }
    }
  ],
  "diagnostics": { "softpaq": "sp171653", "version": "10.8.5.0", "softpaqSha256": "80858E96...", "snapshot": "diagnostics-sp171653" }
}
```
`toolVersion`: the only version constant in the repo is the Kit.Core module version, `ModuleVersion         = '0.1.0'` [VERIFIED: kit/core/Kit.Core.psd1:2]; read it from the module rather than inventing one.

### Pattern 3: Console output is a thin `Show-*` over result objects

**What:** `Test-FirmwareStage` returns objects (`Status` Pass/Warn/Fail, `Path`, `Group`, `Message`). One `Show-*` function prints `[PASS]`/`[WARN]`/`[FAIL]` lines, short enough for a phone (about 44 columns: truncate long paths from the left, keep the file name). The entry script sets `exit 1` when any Fail.
**Example (mirrors the lint-clean pattern in the repo):**
```powershell
# Test-Kit.ps1:129 (read this session) - the only Write-Host in that script, inside a Show-* function:
#   Write-Host ('[{0}] {1}: {2}' -f $Status, $Gate, $Detail) -ForegroundColor $color
```

### Pattern 4: Seams for everything with side effects

Wrap in a small private function so Pester mocks it with `-ModuleName`: `Get-KitVolumeInfo` (DriveInfo), `Set-KitVolumeLabel`, `Clear-KitVolumeCache` (Write-VolumeCache, warning on failure), and in the HP module the HPCMSL calls (already stand-in friendly). Pester 6 cannot mock a command that does not exist, which is why `tests/HP.Build.Tests.ps1` builds an `HPCMSL` stand-in module from a table (names with plural nouns would trip the style rules if written as functions).

### Pattern 5: Add the contract operation the way Phase 1 added the others

Touch list (each verified by grep this session): `kit/core/VendorContract.psd1` (new entry, Plane Build), `kit/core/Vendor.ps1:309` (`ValidateSet`), `kit/vendors/hp/vendor.psd1`, `builder/vendors/hp/HP.Build.psm1` (`Export-ModuleMember`, line 400), `tests/fixtures/vendors/complete/vendor.psd1` and `.../missing-op/vendor.psd1` and `Fixture.Build.psm1` (+ its `Export-ModuleMember`). `tests/Contract.Tests.ps1` and `tests/Contract.Negative.Tests.ps1` read the operation list from the table, so they extend themselves. Use the repo's naming convention `<Verb>-HPKit<Noun>` (for example `Get-HPKitFirmwareStickLayout`) rather than the bare `Get-FirmwareStickLayout` in CONTEXT; Phase 1 chose the `HPKit` noun prefix to stay clear of HPCMSL exports.

### Anti-Patterns to Avoid

- **Hand-typing folder paths in code.** Paths live in the layout file only. A path string in `.ps1` is the 2026-10-05 failure mode.
- **Re-downloading in the stager.** The stager copies from staged package folders; downloads are the GetFirmware operation's job (and are mockable there).
- **Reformatting or relabelling a stick implicitly.** Format is destructive and never automatic; relabel is `ShouldProcess`-guarded; everything else refuses with a red line.
- **A READY marker that survives a failed re-run.** Delete it before copying; write it only after a clean validation.
- **Counting `System Volume Information` as an unexpected file.** Scope the unexpected-file check to closed folders only.
- **A second source of truth.** The validator must not carry its own path list.
- **Naming the vendor in `kit/core`.** Words `HP`, `HPCMSL`, `Hewlett`, `SoftPaq` there fail `Core.Tests`. Say "vendor", "vendor package", "flash tool".

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Finding the latest BIOS and its hash | Scraping HP pages | `Get-HPBIOSUpdates -Platform <id> -Latest` and `-All` (`Sha384`, `Dependency`) | HP's catalog, verified to match the real file |
| SoftPaq integrity | A custom checksum source | `(Get-HPSoftpaqMetadata -Number N).Softpaq.SoftPaqSHA256` and HPCMSL's built-in Authenticode check on download | HP publishes it; matched for four SoftPaqs |
| Hashing | A hash loop | `Get-FileHash -Algorithm SHA256|SHA384` | Inbox on 5.1 |
| Reading layout data | Parsing text/JSON by hand | `Import-PowerShellDataFile` | Rejects code, handles `$true`/`$null` and nested arrays; the repo already depends on it |
| Volume type/label/file system | CIM queries | `[System.IO.DriveInfo]` | One line, mockable |
| The diagnostics USB tree | Assembling folders by guessing from the MSI | HP's own `Installer.exe -usb` once, captured, then replayed from the snapshot | The installer generates files (`DI.efi`) and chooses folders; guesses lose "Firmware Management" |
| The BIOS recovery tree | Hand-copying | HP's `HpFirmwareUpdRec64.exe` "Create Recovery USB flash drive" once as a reference capture, diffed against the layout | It is the only authoritative writer of `Hewlett-Packard\BIOS\...` |
| ISO 8601 UTC string | `.ToString('o')` | `.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)` | Matches the RES-01 example `2026-10-05T10:02:00Z`; `'o'` gives 7 fractional digits (the Phase 1 build manifest uses `'o'`) |
| JSON without BOM | `Set-Content -Encoding UTF8` | `[IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))` | 5.1 writes a BOM: verified `EF BB BF` |

**Key insight:** every "fiddly" part of this phase (hash source, tree writer, catalog) already exists in HP's tooling or in PowerShell; the repo-specific work is the glue, the data file and the safety rails.

## Common Pitfalls

### Pitfall 1: Pinned exports and vendor-name scan break the build
**What goes wrong:** Adding `Publish-FirmwareStage` / `Test-FirmwareStage` to `Kit.Core.psd1` without updating `tests/Core.Tests.ps1`, or writing "SoftPaq" in a core comment.
**Why:** `Core.Tests.ps1` has `It 'pins the manifest export list for the whole phase, in order'` with `(Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport | Should -Be $expected`, and `if ($line -cmatch '\bHP\b|HPCMSL|Hewlett|SoftPaq')` over every file under `kit/core`. [VERIFIED: tests/Core.Tests.ps1:19-30 and :36]
**How to avoid:** edit manifest and test list together, same order; keep new core file vendor-neutral. New core file can be `Firmware.ps1` (the module dot-sources every `*.ps1` in the folder alphabetically).
**Warning signs:** first red test after adding an export.

### Pitfall 2: README and `Build.cmd` are pinned by tests
**What goes wrong:** Pointing `Build.cmd` at the new `builder\Build.ps1` or adding a README "Start here" command.
**Why:** `Builder.Tests.ps1` requires `'"%~dp0builder\Build-DriverBaseline.ps1" %*'` in `Build.cmd`; `Repo.Tests.ps1` requires the README `## Start here` section to hold exactly three fenced commands (`Build.cmd *`, `*New-BaselineIso.ps1*`, `Run.cmd*`). [VERIFIED: tests/Builder.Tests.ps1:142 and tests/Repo.Tests.ps1:286-293]
**How to avoid:** either leave `Build.cmd` alone and launch `builder\Build.ps1` with its own documented command outside "Start here", or change the pins deliberately in the same plan. Decide explicitly (Open Question Q2).

### Pitfall 3: HP's diagnostics installer can wipe or relabel the stick
**What goes wrong:** Staging BIOS files and then running the HP USB installer erases them.
**Why:** Installer.exe contains both `Renamed the volume name from %s to %s` (relabel) and `format.com ... /FS:FAT32 /V:HP_TOOLS/y` / `Format FS=FAT32 LABEL="%s" QUICK`; which branch runs for a USB that already has a FAT32 volume is not determinable statically. [VERIFIED: strings] Which one HP's USB path uses is [ASSUMED] unknown.
**How to avoid:** order is: format FAT32 once (operator), run HP installer (capture), then stage. The replay design means the HP installer runs only at capture time, never on a stick that holds results. Validator must catch a wiped stick (missing closed-folder files = Fail).

### Pitfall 4: `Current`, `New`, `DEVFW` - one wrong guess recreates the incident
**What goes wrong:** Shipping one folder and hoping.
**How to avoid:** the superset in this document, per-group `Verified`, bench checklist that records which group each menu actually used, then delete the dead groups in a follow-up one-line edit. Do not delete groups before the bench.

### Pitfall 5: G6 `1.36.00` has a minimum-BIOS dependency
**What goes wrong:** Bench unit on an old BIOS refuses the flash and the failure is blamed on the layout.
**Why:** CVA for `sp174025`: `[Dependency] MinimumBIOSVersion_R70 = 01.35.02`, return code `1602:CANCEL:NOREBOOT = Flash failed due to dependency not satisfied.` The catalog's `Dependency` property printed empty for that version, so the CVA is the better source. [VERIFIED: Get-HPSoftpaqMetadata and Get-HPBIOSUpdates output this session]
**How to avoid:** record `dependencyMinimum` in the manifest, warn when the profile minimum is below it, and make the bench checklist demand a G6 already at 01.35.02 or later. Whether the pre-OS menu enforces the same rule is unverified.

### Pitfall 6: SoftPaq self-extraction of the diagnostics package hung
**What goes wrong:** `Get-HPSoftpaq -Number 167305 -Extract` (which runs `<sp>.exe -e -f "<dir>" -s`) produced no files and did not return within 100 seconds in a non-elevated session; the process had to be killed. [VERIFIED: observed this session; the cause is [ASSUMED] to be a hidden UAC prompt because the wrapper is a GUI executable, `Subsystem = Windows GUI`, `Name = hpsoftpaqwrapper.exe`]
**How to avoid:** the builder is elevated by design (`Assert-HPKitElevation`); still, never extract this SoftPaq without a timeout. For capture, the operator uses HP's installer UI anyway. Static 7-Zip listing of the SFX is how the contents were read; do not make 7-Zip a dependency.

### Pitfall 7: HPCMSL cannot be installed with inbox PowerShellGet on 5.1
**What goes wrong:** `Initialize-HPCMSL` (`Install-Module @install`) fails on a builder with PowerShellGet 1.0.0.1.
**Why:** `Save-Module HPCMSL -RequiredVersion 1.9.0` on this machine failed with `The specified module 'HPCMSL' with PowerShellGetFormatVersion '2.0' is not supported by the current version of PowerShellGet`, and `Save-PSResource` from pwsh 7 failed on `HP.ClientManagement` with a null-reference error. What worked: downloading each `.nupkg` from `https://www.powershellgallery.com/api/v2/package/<name>/<version>` and expanding the zips into `<dir>\<name>\<version>`. [VERIFIED: attempted this session]
**How to avoid:** add a pre-flight in the master script that reports "HPCMSL missing / PowerShellGet too old" as a red line with the fix (`Install-Module PowerShellGet -Force` first) before any download. Record in Environment Availability.

### Pitfall 8: `Get-HPSoftpaq -DestinationPath` rejects forward slashes and UNC
**Why:** error text: `Cannot validate argument on parameter 'DestinationPath'. The argument "C:/Users/..." does not match the "^[a-zA-Z]:\\" pattern.` [VERIFIED: observed this session]
**How to avoid:** always pass backslash drive-letter paths (`[IO.Path]::GetFullPath` on a `Join-Path` result); tests that use `$TestDrive` are fine because it is a drive-letter path. A staging folder on a mapped drive works; a UNC `-OutputRoot` does not.

### Pitfall 9: G5 resolves to `win11-22H2`, and its firmware set has more than a BIOS
**What goes wrong:** Hard-coding `24H2` or selecting `Firmware` generically.
**Why:** `Get-HPDeviceDetails -Platform 83B2 -OSList` stops at Windows 11 22H2 (build 22621); the existing code picks the newest indexed release, so the G5 package folder is `staging\hp\840-g5\win11-22H2`. `Get-HPSoftpaqList ... -Category BIOS, Firmware` for 83B2 returns `sp142280` (SSD firmware), `sp154750` (Intel ME firmware, `SSM = True`) and `sp157750` (BIOS). The BIOS `Category` is `BIOS` for the G5 and `BIOS - System Firmware` for the G6. [VERIFIED: queries this session]
**How to avoid:** select the BIOS item with `Category -like 'BIOS*'` (the existing `Get-FirmwareSkipReason` already treats "Category starting with 'BIOS'"), take the newest, and compare its version with the profile minimum.

### Pitfall 10: PS 5.1 JSON traps are real
**Verified this session:** default `ConvertTo-Json` depth collapses a nested `[ordered]` to the string `System.Collections.Specialized.OrderedDictionary`; `-Depth 6` fixes it; `Set-Content -Encoding UTF8` writes `EF BB BF`; `ConvertFrom-Json` tolerates a BOM; a one-element array inside an ordered property stays an array, but a piped one-element root array becomes a bare string. Use an `[ordered]` root, `-Depth 6`, no BOM, and convert `[version]` to string before serializing.

### Pitfall 11: Console colour and the lint gate
`Write-Host` passes the gate only inside a function whose name starts with the `Show-` verb (`Test-Kit.ps1` `Show-GateResult` carries the colour line and the repo lints with 0 findings; Phase 1 research recorded the same rule). Put all colour output in one `Show-*` function.

### Pitfall 12: Test fixtures cannot be committed as `.bin`
`.gitignore` ignores `*.bin`, `*.sig`, `*.msi`, `staging/`, `results/`, and `HPQPswd*.bin`. Create fake BIOS images at run time inside `$TestDrive`; never commit one. The committed layout and snapshot files are `.psd1` and contain paths and hashes only.

### Pitfall 13: Windows adds files to a FAT32 stick
`System Volume Information` (and `$RECYCLE.BIN`-style entries) can appear at the root. A "no unexpected files" rule applied to the whole volume fails on a clean stick. Scope it to closed folders, whitelist the named root entries.

### Pitfall 14: Stale READY marker
If a re-run fails after the old run passed, the old marker would still say "ready". Delete it first, write it last.

### Pitfall 15: Do not stage password tooling by accident
The extracted SoftPaq folder contains `HpqPswd.exe` / `HpqPswd64.exe` (the BIOS-password file utility). The tool itself is harmless, but a generated password file (`HPQPswd*.bin`, `password.bin`) must never reach the stick; the repo already ignores those names. Validator can flag any `*Pswd*.bin` under the stick.

## Code Examples

### Resolve the BIOS version and vendor hash without a second download
```powershell
# Source: HPCMSL 1.9.0, behaviour confirmed by running it this session.
$all    = @(Get-HPBIOSUpdates -Platform $platform -All)               # Ver, Date, Bin, RollbackAllowed, Importance, Dependency, Sha384
$latest = $all | Sort-Object -Property { [version]$_.Ver } -Descending | Select-Object -First 1
$hash   = (Get-FileHash -LiteralPath $binPath -Algorithm SHA384).Hash
if ($hash -ne $latest.Sha384) { throw "BIOS image $binPath does not match the HP catalog hash for $($latest.Ver)." }
```
Verified values for this snippet: `83B2` -> `Ver 1.31.00`, `Date 2025-03-10`, `Bin Q78_013100.bin`, `Sha384 5b657642...ae225`; `8549` -> `Ver 1.36.00`, `Date 2026-06-13`, `Bin R70_013600.bin`, `Sha384 944748b1...3ba7`.

### Vendor hash for the SoftPaq executable
```powershell
$meta = Get-HPSoftpaqMetadata -Number '174025'
$meta.Softpaq.SoftPaqSHA256          # 22E7030C00323D8C64E392CE8575F5DC36DEA41B151922BF25A4CACB4B7D2DCB
$meta.Dependency.MinimumBIOSVersion_R70   # 01.35.02  (section exists only on SoftPaqs that declare one)
$meta.'Install Execution'.SilentInstall   # "HpFirmwareUpdRec.exe" -r -b -s
```

### Fake stick for tests (no hardware, no network)
```powershell
BeforeAll {
    $script:stick = Join-Path $TestDrive 'stick'
    $null = New-Item -ItemType Directory -Path $script:stick
    # Run-time fake image: never committed (.gitignore ignores *.bin)
    $script:g6Image = Join-Path $TestDrive 'R70_013600.bin'
    [IO.File]::WriteAllBytes($script:g6Image, [byte[]](1..64))
    Mock Get-KitVolumeInfo -ModuleName Kit.Core { [pscustomobject]@{ FileSystem = 'FAT32'; Label = 'HP_TOOLS'; IsRemovable = $true } }
}
```
(Mock a private core function with `-ModuleName Kit.Core`; Phase 1 tests do the same for `HP.Build` internals, for example `Mock Initialize-HPCMSL -ModuleName HP.Build {}`.)

### The incident as a regression test
```powershell
It 'fails and names the file when a BIOS image sits in the wrong folder' {
    # stage correctly, then move the image from New to Current only
    Move-Item -LiteralPath (Join-Path $stick 'Hewlett-Packard\BIOS\New\R70_013600.bin') -Destination (Join-Path $stick 'Hewlett-Packard\BIOS\Other\R70_013600.bin')
    $findings = @(Test-FirmwareStage -Path $stick -AllowFolder)
    ($findings | Where-Object Status -EQ 'Fail').Message | Should -BeLike '*R70_013600.bin*'
}
```

### Exit code through a real child process (pattern already in the repo)
`tests/Builder.Tests.ps1` runs `cmd.exe /d /c Build.cmd -Vendor Fixture -VendorRoot ... -ProfilePath ...` and asserts `ExitCode`. Reuse its `Invoke-BuilderChild` approach for `builder\Build.ps1` against the fixture vendor with a deliberately bad stick, asserting a non-zero exit and a `[FAIL]` line.

## State of the Art

| Old Approach (STACK/ARCH/PITFALLS) | Current Finding | When | Impact |
|-----------------------------------|-----------------|------|--------|
| HP diagnostics latest = 10.8.4.0 `sp167305` | 10.8.5.0 `sp171653`, effective 2026-03-13, supersedes `sp167305`; same MSI structure | checked 2026-10-20 | Pin number in the layout/snapshot; re-check at each refresh. A newer one than `sp171653` may exist: not found, not excluded |
| Diagnostics tree = `\Hewlett-Packard\SystemDiags\...` | Installer writes `\EFI\HP\SystemDiags\` and `\EFI\HP\BIOSUpdate\` (+`DI.efi`) | static analysis 2026-10-20 | Snapshot paths come from a real capture, not from STACK.md |
| "Create Recovery USB has no CLI; options only `-f -p -s -b -?`" | The binary also parses `-h`, `-w`, `-o`, `-t`; still no CLI to create the recovery USB | static strings | `-w` can produce `firmware.bin` for the DEVFW path (unverified) |
| "G5 platform 83B2 unverified (profile `PlatformVerified = $false`)" | `Get-HPDeviceDetails -Platform 83B2` lists "HP EliteBook 840 G5 Notebook PC" and the Q78 SoftPaq's system list has `SysId01 = 0x83B2`; the G5 Healthcare Edition is a different platform `845D` | 2026-10-20 | The profile can cite this; a real-unit check is still pending (Q5) |
| G5 BIOS 01.31.00 dated 2025-04-30 | SoftPaq release date 2025-04-30; the `.bin`/catalog date is 2025-03-10 | - | Cosmetic; do not compare the two dates |

**Deprecated/outdated:** nothing is deprecated, but treat STACK.md/ARCHITECTURE.md/PITFALLS.md layout and version claims for HP firmware as superseded by this document where they differ.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Esc/F10 "Update System BIOS > local media" on 2018/2019 EliteBook 840 G5/G6 reads `Hewlett-Packard\BIOS\New` (F10) and the diagnostics Firmware Management reads `...\Current` | Layout Evidence | Wrong group staged only; mitigated by the superset and per-group Verified |
| A2 | The F10/Firmware-Management picker lists both models' images and the BIOS rejects the wrong family safely | Layout Evidence | A bench unit could be offered the wrong file; mitigate by flashing each model only with its own file, and using `-FlashModel` |
| A3 | `.bin` files without `.sig`/`.s12` are accepted by the menus (G5/G6 packages ship none) | Layout Evidence | "Invalid BIOS image" at the bench; the capture via HP's own tool shows what it writes |
| A4 | HP's USB installer relabels rather than reformats an existing FAT32 stick | Pitfall 3 | Staging before capture loses files; order rule covers it |
| A5 | Extra folders (`kit\`, `results\`, `firmware\`) on the HP_TOOLS volume do not break F2 or the pickers | Layout Evidence | D-04 layout fails at the bench; fallback is a second partition or stick |
| A6 | The hidden cause of the `Get-HPSoftpaq -Extract` hang for `sp167305` is a UAC prompt | Pitfall 6 | Might need a different extraction path; only matters if the capture step is automated |
| A7 | FAT32 limits: file size 4 GiB minus 1 byte, 255-character long names, 65,534 entries per folder, 32 GB GUI-format cap (command-line `format` reportedly higher on recent Windows 11) | FAT32 section | Only affects stick choice; none is approached by this payload |
| A8 | `Set-Volume` and `Write-VolumeCache` need admin; `Write-VolumeCache` flushes enough for safe removal | Standard Stack | Use warn-not-fail wrappers |
| A9 | `Copy-Item` of a file carrying a `Zone.Identifier` stream onto FAT32 succeeds (dropping the stream) | FAT32 section | A copy error to handle; test in the bench pass with a downloaded file |
| A10 | `.s12/.s14/.s23` companions are signature variants for different firmware generations and must all be staged | Layout Evidence | Missing sig variant makes F2 refuse an image; the capture snapshot would include whichever HP writes |
| A11 | A hash obtained from the same HP origin protects against corruption and substitution on the wire, not against compromise of HP's origin | Security Domain | Residual supply-chain risk accepted; mitigated by Authenticode (HPCMSL deletes SoftPaqs that fail it unless `-KeepInvalidSigned`) |
| A12 | Newest diagnostics SoftPaq is `sp171653`; a later one could exist | State of the Art | Stale version staged; refresh procedure documented |
| A13 | The 10.8.5.0 installer writes the same `\EFI\HP\SystemDiags\` / `\EFI\HP\BIOSUpdate\` folders as 10.8.4.0 (only 10.8.4.0's `Installer.exe` was string-scanned) | Layout Evidence | Snapshot paths come from the real capture of the version actually staged, so the capture step corrects it |

## Open Questions (RESOLVED)

1. **Which staging groups does the bench prove?**
   - Known: candidate paths and their sources (above). Unknown: the actual per-menu behaviour on G5 and G6.
   - Recommendation: stage the superset, run the bench checklist, then prune groups in one commit. FW-06 stays open until Benjamin records results.
2. **Where does the master script launch from, and what happens to `Build.cmd` and README "Start here"?**
   - D-02 names `builder/Build.ps1`; `Build.cmd` and README are pinned by tests (Pitfall 2).
   - Recommendation: add `builder/Build.ps1`, leave `Build.cmd` and README "Start here" unchanged, document the new command in a separate README section (not "Start here"), or update the two pinned tests in the same plan if the user prefers one entry.
3. **Does the stager also copy `kit\` to the stick?**
   - D-04 says the stage tree holds `kit/` side by side; today README step 3 has the operator copy `kit\` by hand.
   - Recommendation: Phase 2 validates tolerance for `kit\` and `results\` but copies `kit\` only behind an explicit `-IncludeKit` using `Get-KitPublishFile` (which already leaves out `*.local.psd1` and any `results` folder). Planner to confirm.
4. **Should the stick carry dependency-chain BIOS versions?** (G6 1.36.00 needs 01.35.02 or later.) Recommendation: Phase 2 stages latest only, records `dependencyMinimum` and warns; chain staging is a follow-up if the bench shows a unit stuck below the minimum.
5. **Flip `PlatformVerified` for 83B2?** HPCMSL now confirms 83B2 = 840 G5, but the profile says "Confirm ... on a real unit" and `tests/HP.Build.Tests.ps1:62` pins `PlatformVerified | Should -Be @($false, $true)`. Recommendation: leave `$false` until the bench reads `Win32_BaseBoard.Product` on a real G5; update `PlatformSource` text with the HPCMSL evidence either way.
6. **Where do cached downloads live?** D-07 says `staging/hp/<model>/firmware/`; Phase 1 already writes `staging\hp\<model>\win11-<rel>\Firmware\spNNN\` (and `Save-HPKitFirmware` empties that folder and re-downloads every run: `Reset-HPKitDirectory -Path $firmwareDir`, `Get-HPSoftpaq ... -Overwrite yes`). Recommendation: keep the Phase 1 path (it is what `Get-KitPackagePath` and the tests know) and add reuse when the on-disk SoftPaq SHA-256 equals the CVA value; read D-07's path as shorthand unless the user objects.
7. **Interactive model pick format.** D-02 shows `-Model 840G5,840G6`; real ModelIds are `840-g5`, `840-g6` (`Get-KitProfile` validates `^[A-Za-z0-9][A-Za-z0-9._-]*$` and matches the file name). Recommendation: accept `840-g5,840-g6`; optionally also accept `840G5` as an alias only if the user wants it.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Windows PowerShell 5.1 | everything | yes | 5.1.26100.9711 | - |
| Pester 6.2.0 / PSScriptAnalyzer 1.25.0 / gitleaks 8.30.1 | gate | yes (main checkout `.tools`; worktrees resolve it) | pinned | - |
| Full gate baseline | planning | yes | 407 Pester tests passed (121.5 s), lint 42 files 0 findings, run this session | - |
| HPCMSL 1.9.0 | GetFirmware, catalog queries | not installed on this PC | 1.9.0 on the Gallery | direct `.nupkg` download works; inbox PowerShellGet 1.0.0.1 cannot install it (Pitfall 7) |
| Internet to `ftp.hp.com`, `powershellgallery.com` | downloads | yes | - | none; tests never use the network |
| Elevation | `Save-HPKitFirmware`, SoftPaq extraction | no (this session) | - | builder runs elevated by design; this research could not exercise extraction |
| FAT32 USB stick | bench, real stage | none attached (C: NTFS, Z: ReFS Dev Drive only) | - | tests use `-AllowFolder` and a mocked volume seam |
| HP EliteBook 840 G5 and G6 | FW-06 | no | - | none; verification ends `human_needed` |
| pwsh 7.6.7, 7-Zip 26.04 | research only | yes | - | not needed by the project |

**Missing dependencies with no fallback:** real G5/G6 hardware and a stick (FW-06 only).
**Missing dependencies with fallback:** HPCMSL on a fresh builder (install PowerShellGet 2.x first).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Pester 6.2.0 on Windows PowerShell 5.1 (Phase 1 pin) |
| Config file | none; `Test-Kit.ps1` builds the Pester configuration |
| Quick run command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -TestPath tests/Firmware.Tests.ps1,tests/HP.Firmware.Tests.ps1` |
| Full suite command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1` (lint + all tests, about 2.5 minutes today) |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BUILD-01 | Script resolves vendor and models, rejects unknown model, `-TargetPath` required or prompted only at entry | unit + child process | `Test-Kit.ps1 -TestPath tests/Builder.Master.Tests.ps1` | Wave 0 |
| BUILD-06 | Manifest has schema, tool version, UTC `Z` time, per-model platform/latest BIOS/SHA-256, no BOM, depth 6 | unit | `Test-Kit.ps1 -TestPath tests/Firmware.Tests.ps1` | Wave 0 |
| FW-01 | Each selected model's image lands in every default group folder under original name | unit | same | Wave 0 |
| FW-02 | Two models: distinct names coexist; same destination with different content throws naming both models | unit | same | Wave 0 |
| FW-03 | Wrong folder / missing file / flipped byte / extra file in closed folder / non-FAT32 / wrong label / over-long or illegal name each give a Fail naming the file; stale READY removed; READY written only on clean run | unit | same | Wave 0 |
| FW-04 | Fallback folder holds the extracted SoftPaq files for the platform; manifest records silent command and return codes | unit with HPCMSL stand-in | `Test-Kit.ps1 -TestPath tests/HP.Firmware.Tests.ps1` | Wave 0 |
| FW-05 | Captured snapshot is replayed to the recorded paths; hashes verified; refuses when the snapshot is missing and says how to capture | unit | `tests/Firmware.Tests.ps1` | Wave 0 |
| FW-06 | Real G5 and G6 flash from the stick | manual bench | `docs/firmware-bench-checklist.md` | Wave 0 (doc) |
| (contract) | New operation is in the table, descriptor, fixtures; `missing-op` fixture still fails exactly once | contract | `Test-Kit.ps1 -TestPath tests/Contract.Tests.ps1,tests/Contract.Negative.Tests.ps1` | existing, edited |

### Sampling Rate
- **Per task commit:** the focused `-TestPath` run for the files touched (seconds).
- **Per wave merge:** full `Test-Kit.ps1` (lint is part of it; zero findings).
- **Phase gate:** full gate green, then verification reports FW-06 as `human_needed`.

### Wave 0 Gaps
- [ ] `tests/Firmware.Tests.ps1` - core stager, validator, FAT32 rules, manifest golden checks, READY semantics.
- [ ] `tests/HP.Firmware.Tests.ps1` - HP layout resolution; extend the `HPCMSL` stand-in table with `Get-HPBIOSUpdates` (`param($Platform, [switch]$Latest, [switch]$All)`) and mock it per test; compute expected SHA-384 inside the test from the fake image so no network and no real BIOS are used.
- [ ] Fixture vendor updates (`Fixture.Build.psm1`, both `vendor.psd1`) and an extra fixture layout under `tests/fixtures`.
- [ ] `tests/Builder.Master.Tests.ps1` (or extend `Builder.Tests.ps1`) for the entry script via child process, following `Invoke-BuilderChild`.
- [ ] Pinned-test edits: `Core.Tests.ps1` export list; anything pinning the operation count.
- [ ] `docs/firmware-bench-checklist.md` with the Verified fields.

### Offline test recipes (all runnable on this builder with no network and no USB)
- **Pure FAT32 name/size rules** as a function over strings and an integer `Size` (illegal characters `\ / : * ? " < > |`, trailing space or dot, reserved device names CON/PRN/AUX/NUL/COM1-9/LPT1-9, segment over 255, full path over 259, case-insensitive duplicates, size over 4294967295). Never create a 4 GB file; pass the number.
- **Volume checks** behind `Get-KitVolumeInfo`; unit-test the three outcomes (FAT32 removable ok, NTFS refuse naming the volume, fixed disk refuse) by mocking the seam.
- **Hash mismatch**: stage into `TestDrive`, then append a byte to the staged copy.
- **Idempotence**: run `Publish-FirmwareStage` twice; second run changes nothing and still validates.
- **`-WhatIf`**: no files, no manifest, no READY, no label change (pattern: `Test-Path ... | Should -BeFalse` as in `HP.Build.Tests.ps1`).
- **Real FAT32** cannot be exercised without admin (VHD plus `diskpart`/`format`). Not added to the gate (`Test-Kit.ps1` runs everything under `tests/` with no tag filter); put it in the bench checklist instead.

## Security Domain

Config: `security_enforcement: true`, `security_asvs_level: 1`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | - |
| V3 Session Management | no | - |
| V4 Access Control | partly | Builder requires elevation for SoftPaq extraction (existing `Assert-HPKitElevation`); stager refuses fixed disks as `-TargetPath` unless `-AllowFolder` |
| V5 Input Validation | yes | `ValidatePattern` on `-Vendor`/`-Model` (existing pattern `^[A-Za-z0-9][A-Za-z0-9._-]*$`); layout `Folder`/`RelativePath` must be relative, no `..`, no `:`, no leading separator, resolved with `[IO.Path]::GetFullPath` and checked to stay under the target root |
| V6 Cryptography | yes | `Get-FileHash` SHA-256/SHA-384 only; case-insensitive compare of hex; never truncate or hand-roll |
| V10 Malicious Code / V12 Files | yes | Never execute staged files; only HP SoftPaq self-extraction runs, after HPCMSL's Authenticode check; compare the SoftPaq SHA-256 to CVA before extraction |
| V14 Configuration | yes | No secrets in layout, snapshot or manifest; BIOS password tooling outputs are never staged (Pitfall 15) |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal through layout data or CVA-derived names | Tampering | Normalize and prefix-check every destination against the target root; reject rooted or `..` entries |
| Writing to the wrong drive (system disk) | Tampering / DoS | Refuse non-removable and non-FAT32 targets by default; name the volume in the red line |
| Tampered or corrupted download | Tampering | CVA SHA-256 for the SoftPaq, catalog SHA-384 for the image, HPCMSL's Authenticode verification; fail with the file name |
| Stale or forged READY marker | Spoofing | Delete first, write last, marker holds the manifest hash; validator recomputes |
| Secret leakage into manifest | Information disclosure | Allow-list the manifest fields; no environment, config or password data |
| Supply chain (HPCMSL from the Gallery) | Tampering | Pinned `-RequiredVersion 1.9.0`; module is signed by HP; recorded in the build manifest |

## Sources

### Primary (HIGH confidence)
- Context7 `/websites/developers_hp_hp-client-management_doc`: `Get-HPBIOSUpdates` parameters and output, `Get-HPSoftpaq` `-Extract`/`-DestinationPath`, `Get-HPSoftpaqList -Category`.
- HPCMSL 1.9.0 itself, run on this machine: `Get-HPDeviceDetails -Platform 83B2|8549`, `Get-HPBIOSUpdates -Platform ... -Latest|-All`, `Get-HPSoftpaqList ... -Category BIOS, Firmware|Diagnostic`, `Get-HPSoftpaqMetadata -Number 157750|167305|171653|174025|167302`, source of `Get-HPBIOSUpdates` and `Invoke-HPPostDownloadSoftpaqAction` (HP.ClientManagement.psm1, HP.Private.psm1).
- HP FTP release notes (fetched): https://ftp.hp.com/pub/softpaq/sp171501-172000/sp171653.html and https://ftp.hp.com/pub/softpaq/sp167001-167500/sp167305.html.
- HP SoftPaq contents, read locally: `HP_Staging\8549-win11-24H2\Firmware\sp174025\` (`Bios Flash.htm`, `contents.txt`, `HpFirmwareUpdRec.txt`, `R70_013600.inf`, `History.txt`), and 7-Zip listings of downloaded `sp157750.exe`, `sp167305.exe`, `sp171653.exe`; MSI tables and strings of the diagnostics installer (static, nothing executed).
- Repo files read this session: `kit/core/*.ps1`, `Kit.Core.psd1`, `VendorContract.psd1`, `kit/vendors/hp/vendor.psd1`, `builder/vendors/hp/HP.Build.psm1`, `builder/Build-DriverBaseline.ps1`, profiles, `Test-Kit.ps1`, `tests/Core.Tests.ps1`, `Repo.Tests.ps1`, `Builder.Tests.ps1`, `HP.Build.Tests.ps1`, `Contract*.Tests.ps1`, fixtures, `.gitignore`.

### Secondary (MEDIUM confidence)
- HP Support Community threads (403 to direct fetch, used through search summaries): `Hewlett-Packard\BIOS\New` / `EFI\HP\BIOS\New` and the "could not find one of the BIOS update binary files" error; Current-to-New fix.
- HP support document ish_4208192 (times out; search summary): Firmware Management path via `HP_TOOLS-USB Drive > Hewlett-Packard > BIOS > Current`.
- https://dvdkon.ggu.cz/blogpost/hp_ex360_bios_update/ and https://dvdkon.ggu.cz/blogpost/hp_uefi_diagnostics_linux/ ; https://gist.github.com/eNV25/c8001491dc0440656ff7b0ae18993ba1 (fetched).
- Windows 11 FAT32 command-line format limit reports (search summaries; build and date details disagree).

### Tertiary (LOW confidence)
- FAT32 limit figures (65,534 entries, 255-character names) from search summaries; Microsoft's TechNet "File Systems" article was found but not read.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - versions queried, HPCMSL run, gate baseline run.
- Architecture: MEDIUM-HIGH - follows Phase 1 patterns that exist and pass; the new contract operation touch list was grepped.
- HP layout: LOW-MEDIUM - strings, installer behaviour and hashes are solid; menu-to-folder mapping is unverified by design.
- Pitfalls: HIGH for repo and PS 5.1 mechanics (verified), MEDIUM for FAT32/Windows stick behaviour (not testable here).

**Research date:** 2026-10-20
**Valid until:** 2026-11-03 for HP catalog facts (BIOS versions, diagnostics SoftPaq number: HP publishes regularly); repo mechanics valid until the files change.
