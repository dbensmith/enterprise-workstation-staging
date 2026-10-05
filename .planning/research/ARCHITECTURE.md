# Architecture Patterns

**Domain:** Modular, vendor-neutral Windows laptop provisioning toolkit (PowerShell 5.1, one operator on site, two USB sticks, unreliable internet)
**Researched:** 2026-10-05
**Overall confidence:** MEDIUM (existing-code findings HIGH because read directly; HP cmdlet facts HIGH from HP CMSL docs via Context7; HP USB layout/label facts MEDIUM from HP support pages and forum threads; Windows unattend/first-logon mechanics MEDIUM; Dell/Lenovo specifics LOW and out of milestone 1)

Confidence tiers were assigned by hand: the `research-plan` / `classify-confidence` seams were not run because the workstation safety rules limit writes to `.planning/research/` and the seam needs a temp input file. Provider tiers used: Context7 HP CMSL and Pester docs = HIGH; HP support pages and HP community threads = MEDIUM; search-result summaries and single GitHub issues = LOW-MEDIUM; engineering judgement is labeled as such.

---

## 1. What the existing `src/` tells us (grounding)

| File | What it really is | Architectural consequence |
|------|-------------------|---------------------------|
| `HPDriverBaseline.psm1` | Mixed bag. Vendor-neutral: `New-WindowsInstallIso`, `Select-InstallImage`. HP-specific: `Select-OsRelease`, `Select-BaselineSoftpaq`, `Split-SoftpaqCommand`, `ConvertTo-ReturnCodeMap` | Split on that line. Neutral half goes to `core`, HP half to `vendors/hp`. Module is already Pester-testable offline (no HPCMSL, no admin) - keep that property. |
| `Build-HPDriverBaseline.ps1` | HP **build-plane** script. Installs HPCMSL from the Gallery on the builder, one profile in, one package out (`<root>\<platform>-<os>-<release>`), writes `manifest.json`, copies `Install-HPDriverBaseline.ps1` into the package | This is the HP implementation of "build custom pack" + "fetch firmware". Package dir naming is vendor-less and model-less: collides the moment a second vendor or model appears. |
| `Install-HPDriverBaseline.ps1` | **Target-plane**, deliberately standalone (copied into every package/image), pnputil online or DISM offline, runs firmware silent installs from manifest (`SilentInstall`, `ReturnCodes`, `Devices`), suspends BitLocker | The manifest is already ~vendor-neutral data (command line, return-code map, device IDs). A vendor-neutral install *engine* driven by the manifest is feasible; only BIOS-version parsing and BitLocker policy are HP-ish. |
| `New-HPBaselineIso.ps1` | Neutral ISO servicing (mount, copy, DISM inject, export, IMAPI2 ISO) with an HP-shaped first-boot hook (`unattend.xml` specialize pass `RunSynchronous`, installs to `C:\HP\Baseline`) | Keep the servicing code. Replace the hook with a generated, testable answer file (specialize + oobeSystem) that launches the neutral first-logon pipeline. |
| `Test-DeviceBaseline.ps1` | Flat `irm \| iex` script: gathers data, applies hard-coded G5/G6/Dell/Lenovo rules, prints, uploads one Google-Form row, writes `<serial>.txt` to "first USB volume" | Becomes the **Verify/Assess check library**. Needs: checks as objects, JSON result, UTC timestamps, vendor knowledge moved to profiles/modules, stick discovery by marker not "first USB volume" (the operator has two sticks). |
| `profiles/hp-elitebook-840-g6.psd1` | Data-only profile (`Name, Platform, Os, OsVer, DriverExclude, FirmwareExclude`) | Right pattern. Extend, do not replace. Move under `profiles/<vendor>/`. |
| `HPDriverBaseline.Tests.ps1` | Pester, AST-extraction trick to test functions inside standalone scripts | Good technique, reuse it. But see defects below. |

### Defects found in the current tree (fix in the foundation phase; they invalidate "validated" status for the first-boot path)

1. **`-LogPath` mismatch.** `New-HPBaselineIso.ps1` writes an answer file that runs `Install-HPDriverBaseline.ps1 -LogPath ...`, and a Pester test asserts that string, but `Install-HPDriverBaseline.ps1` has no `-LogPath` parameter (its params are `OfflineImagePath`, `SkipFirmware`, `Force`). PowerShell fails binding on an unknown named parameter, so the first-boot baseline run cannot start. (HIGH, read from source.)
2. **Tests reference functions that do not exist.** The "Install-HPDriverBaseline firmware gating" tests AST-extract `ConvertTo-HPBiosVersion` and `Get-FirmwareSkipReason` from the installer; neither is defined there (grep over `src/*.ps1` finds them only in the test file). Those tests cannot pass against the current installer. The working tree and tests have drifted; likely cause is the copy-into-every-package model (see anti-pattern 3). (HIGH.)
3. **Firmware runs at the wrong time.** The image hook runs the full installer (pnputil + BIOS flash with BitLocker suspend) during the specialize pass. The mandated order puts firmware *before* imaging (manual, pre-Windows), with Windows-side flash only as an opt-in fallback. Do not carry the firmware step into the first-logon path.
4. **Output folder layout is not vendor/model-safe** (`C:\HP_Staging\<platform>-<os>-<rel>`; ISO default is hard-coded to `C:\HP_Staging\8549-win11-24H2`).
5. **`Test-DeviceBaseline.ps1`** stamps local time (`Get-Date -Format 'yyyy-MM-dd HH:mm'`), overwrites `<serial>.txt` per run (no history), and stores results via "first USB volume" which is ambiguous with two sticks.
6. **Specialize pass is offline by design.** The Wi-Fi password is typed at OOBE's network screen, which comes *after* specialize, so nothing online can ever run there. Online work belongs to first logon (oobeSystem) or later.

---

## 2. Recommended Architecture

### 2.1 Three planes, one shared core

The six vendor operations split cleanly by *where they can run*. This is the most important structural decision: **one vendor interface, two capability planes**.

```
 BUILDER PC (admin, internet, HPCMSL/Dell/Lenovo tools allowed)           TARGET LAPTOP (stock Windows 11, PS 5.1, admin, NO module installs)
+-------------------------------------------------------------+       +---------------------------------------------------------------+
| Build-Kit.ps1  (master build)                               |       | Provision.ps1 (-Mode Assess | Deploy)   <- same engine both ways |
|   select ISO -> select vendor/models -> per model:          |       |   entry points: stick | irm|iex | image first-logon           |
|   ListModels / GetVendorPack / NewCustomPack / GetFirmware  |       |                                                               |
|   -> ISO build (servicing, inject union of drivers,         |       |   Stage engine (ordered table, state.json, Verify-last)        |
|      generated unattend + first-logon hook)                 |       |    Identify > Assess checks > Firmware gate > Account >       |
|   -> Publish-Sticks (writes + VALIDATES stick layouts)      |       |    Drivers > Online gate > Atera > [Verify] > Persist > Sync   |
+---------------+---------------------------------------------+       +-----------+----------------------------------+--------------------+
                |  uses                                                           | uses                             | reads/writes
                v                                                                 v                                  v
+-------------------------------------------------------------------------------------------------------------------------------+
| CORE module (vendor-neutral, no vendor tools, Pester-testable offline)                                                         |
|  Output(green/yellow/red) | Clock(UTC, skew) | Native wrapper | Config+Secrets | Stick discovery | Result record+validator       |
|  Store adapter seam + Sync | Online probe | Layout validator | Hash/manifest | Unattend generator | ISO servicing (IMAPI2)       |
+-------------------------------------------------------------------------------------------------------------------------------+
        |                                    |
        v                                    v
+----------------------------+     +----------------------------+     +----------------------------+
| vendors/hp  (milestone 1)  |     | vendors/dell (later)       |     | vendors/lenovo (later)     |
|  vendor.psd1 (descriptor)  |     |  same descriptor + 6 ops   |     |  same descriptor + 6 ops   |
|  Build.psm1  (HPCMSL)      |     +----------------------------+     +----------------------------+
|  Target.psm1 (CIM/pnputil) |
+----------------------------+
        |
        v
+--------------------------------------------+        +--------------------------------------------+
| profiles/<vendor>/<model>.psd1  (data)     |        | Central store (adapter-selected, TBD by    |
| local config (gitignored) / stick config   |        | store research) <- write from laptops,     |
| (secrets, Atera link, store URL/token)     |        |   read by Excel tracker (not our code)     |
+--------------------------------------------+        +--------------------------------------------+
```

### 2.2 Component boundaries

| Component | Responsibility | Talks to | Must NOT |
|-----------|----------------|----------|----------|
| `core` module | All vendor-neutral logic: output, clock, native-command wrapper, config/secrets, stick discovery, result schema + validator, store seam + sync, online probe, layout declare/validate, unattend generator, ISO servicing | Windows APIs (CIM, file system, HTTPS), vendor modules via descriptor | Import any vendor tool (HPCMSL) or mention a vendor by name |
| Vendor module `Build.psm1` | Catalog queries, downloads, pack/firmware build, firmware USB layout declaration | Vendor web/tools (HPCMSL) on builder only | Be loaded on a target laptop |
| Vendor module `Target.psm1` | Identify device, installed firmware version, install drivers/firmware from a pack on stock Windows | CIM/WMI, `pnputil`, vendor flash exe | Require a module install, internet, or HPCMSL |
| `vendor.psd1` | Descriptor: name, manufacturer match regex, op-to-command map, capabilities, supported OS | core registry | Contain logic |
| Profiles (`.psd1`) | Per-model data: platform IDs, neighbour group, excludes, firmware minimums, expected BIOS settings, check thresholds | build + checks | Contain secrets |
| `Build-Kit.ps1` | Master build orchestration, interactive selection, ISO flow, publish | core, vendor Build modules | Run on target |
| `Provision.ps1` + stage engine | Single pipeline for Assess/Deploy/FirstLogon; enforces order | core, vendor Target modules, store adapter | Contain stage logic inline (stages are functions registered in a table) |
| Check library (`checks/`) | One function per verification check returning a check object | core, vendor Target | Print, upload, or decide verdict |
| Bootstrap stub | ~40 lines: TLS, elevate, find stick, fetch+verify release, launch | GitHub, stick | Hold logic, secrets, or ids |
| Store adapter | `Test-Store`, `Send-StoreResult`, optional `Get-StoreLatest` | core sync only | Be called from stages (sync only) |
| Publisher (`Publish-Sticks.ps1`) | Copy build output into the two stick layouts then re-read and validate | core layout validator, vendor layout declarations | Hand-write vendor paths (paths come from vendor `Get-FirmwareStickLayout`) |

### 2.3 Data flow

```
 vendor web --(Build.psm1)--> staging\<vendor>\<model>\<pkg>\ { manifest.json, Drivers\, Firmware\, Stage\ }
 src\iso\*.iso --(ISO servicing + union of driver INFs + generated unattend)--> images\*.iso (+ image.manifest.json)
 staging + images --(Publish-Sticks + validate)--> TOOLS stick, INSTALL stick

 [pre-Windows, manual]  Tools stick: BIOS flash (F10) -> BIOS defaults (F9/F10) -> UEFI diagnostics (F2)
 [image]               Install stick -> Windows Setup (Wi-Fi typed at OOBE network screen)
 [first logon]         C:\ProvisionKit\ (baked in image) + Tools stick (config, results)
                       state.json (local) --> stages --> result.json (Tools stick \results + C:\ProgramData)
 [sync]                Tools stick \results\*.json --(adapter, idempotent put)--> central store --> Excel tracker (pull)
```

Direction rules: build-plane writes data, target-plane only reads it; results flow one way (laptop/stick to store); store never writes back (matches the anti-feature "bidirectional sync"). Secrets flow only from builder-local gitignored config or the Tools stick to the running process; never into repo, image, or result records.

---

## 3. Vendor interface

### 3.1 Contract (6 required operations + 3 required helpers)

| Operation (descriptor key) | Plane | Input | Output | HP implementation (today / planned) |
|----------------------------|-------|-------|--------|--------------------------------------|
| `ListModels` | Build | optional filter text | objects `{ Vendor, ModelId, DisplayName, PlatformIds[], ProfilePath }` | Profiles + `Get-HPDeviceDetails -Name '840 G5' -Like` / `-Platform` (HPCMSL, HIGH) |
| `GetVendorPack` | Build | model, OS, release | pack folder + manifest (`PackKind='vendor'`) | `Get-HPSoftpaqList -Category Driverpack` then download; availability per model is uneven, so must report "none published" (needs HP-phase research) |
| `NewCustomPack` | Build | model, OS, release, excludes | pack folder + manifest (`PackKind='custom'`) | Existing Drivers stage: `Get-HPSoftpaqList -Category Driver` + `Select-BaselineSoftpaq` + `New-HPBuildDriverPack` (the existing code already does this; `New-HPDriverPack` is HP's curated variant, same admin requirement) |
| `GetFirmware` | Build | model | firmware set: Windows-flash SoftPaq (+CVA data) **and** a declarative USB stage tree | Existing Firmware stage + new `Get-FirmwareStickLayout` |
| `InstallDrivers` | Target | pack path, platform | per-INF results (tolerant) | pnputil per-folder with harmless-code map (existing `-OkCodes 0,3010,259,-536870365`) |
| `InstallFirmware` | Target | manifest firmware list | per-item results | CVA `SilentInstall` + `ReturnCodes` from manifest; BIOS last; BitLocker suspend limited to `$env:SystemDrive` |
| `GetDeviceIdentity` | Target | none | `{ Vendor, Model, PlatformId, Serial, BiosVersion, BiosDateUtc }` | CIM `Win32_BIOS/ComputerSystem/BaseBoard` (platform ID is `Win32_BaseBoard.Product`, already used in the installer) |
| `GetInstalledFirmwareVersion` | Target | none | normalized `{ Family, Version }` | the missing `ConvertTo-HPBiosVersion` the tests expect |
| `GetFirmwareStickLayout` | Build | model + firmware set | list of `{ RelativePath, Source, Sha256 }` + `Verified` metadata | HP: `Hewlett-Packard\BIOS\Current` / `\New` (see section 7, unverified) |

Optional (capability flags in descriptor): `TestLockState` (BIOS password set, etc.; HP exposes `HP_BIOSPassword` via WMI `root\HP\InstrumentedBIOS` without a module), `GetBiosSettings`.

### 3.2 Mechanism: descriptor + command map, no PowerShell classes

```powershell
# vendors/hp/vendor.psd1  (data only)
@{
    Name         = 'HP'
    Manufacturer = '^(HP|Hewlett-Packard)\b'          # matched against Win32_ComputerSystem.Manufacturer
    BuildModule  = 'HP.Build.psm1'                     # imports HPCMSL lazily; builder only
    TargetModule = 'HP.Target.psm1'                    # CIM/pnputil only; ships to stick/image
    Commands     = @{
        ListModels = 'Get-HpKitModel';   GetVendorPack = 'Get-HpKitVendorPack'; NewCustomPack = 'New-HpKitCustomPack'
        GetFirmware = 'Get-HpKitFirmware'; InstallDrivers = 'Install-HpKitDriver'; InstallFirmware = 'Install-HpKitFirmware'
        GetDeviceIdentity = 'Get-HpKitDeviceIdentity'; GetInstalledFirmwareVersion = 'Get-HpKitInstalledFirmware'
        GetFirmwareStickLayout = 'Get-HpKitFirmwareLayout'
    }
    Capabilities = @('VendorPack', 'CustomPack', 'UsbFlashLayout', 'WindowsFlash', 'LockState')
}
```

Core resolves a vendor from the descriptor (`Get-KitVendor -Name HP` or by matching manufacturer) and calls `Invoke-KitVendorCommand -Vendor $v -Op InstallDrivers @params`.

Why not classes/interfaces: Pester docs state that on Windows PowerShell 5.1 class definitions are cached per session and break `Mock`; module-reload also behaves badly with classes in 5.1. Descriptor + convention is mockable, diff-friendly and works on stock 5.1. (HIGH for the Pester statement, Context7 `/pester/docs`.)

Adding Dell/Lenovo = new `vendors/<name>/` folder with a descriptor, two modules and profiles. No change to core, engine, stick publisher or tests, because the **contract test** (section 12) is data-driven over `vendors/*/vendor.psd1`.

### 3.3 Capability reality for the other vendors (so the interface does not over-fit HP)

- Dell: published `DriverPackCatalog.cab` (`downloads.dell.com/catalog/`) gives per-model driver packs; BIOS F12 "BIOS Flash Update" takes a vendor `.exe` placed at the USB root (FAT32). Layout is flat, unlike HP's folder tree. (MEDIUM, Dell KB.)
- Lenovo: `catalogv2.xml` (`download.lenovo.com/cdrt/td/`) lists per-model SCCM driver packs; BIOS flash from USB uses the vendor "bootable CD"/`mkusbkey` route or Windows utility, FAT32/FAT16 only. (LOW-MEDIUM.)
- Consequence: `GetFirmwareStickLayout` must return an arbitrary declarative tree (flat for Dell, folder tree for HP, generated image for Lenovo), and `GetVendorPack`/`NewCustomPack` must be allowed to answer "not available" without failing the build. Capability flags handle both.

---

## 4. Repo layout and migration map

```
/
|- Build-Kit.ps1                  master build (builder plane)
|- Provision.ps1                  operator entry: -Mode Assess|Deploy [-Context Manual|FirstLogon] [-Unattended]
|- Publish-Sticks.ps1             copy + validate the two stick layouts
|- bootstrap/Start.ps1            the tiny irm|iex stub
|- core/                          ProvisionKit.Core.psd1/.psm1 (+ private/*.ps1 dot-sourced)
|   |- Output.ps1 Clock.ps1 Native.ps1 Config.ps1 Stick.ps1 Online.ps1 Result.ps1 Sync.ps1
|   |- Layout.ps1 Unattend.ps1 IsoServicing.ps1 Engine.ps1 Hash.ps1
|   `- store/ FolderStore.psm1 (tests/dev) + <chosen>.psm1
|- vendors/
|   |- hp/ vendor.psd1 HP.Build.psm1 HP.Target.psm1 layouts/hp-usb-flash.layout.psd1
|   `- _template/                 skeleton + README, excluded from contract run
|- profiles/hp/elitebook-840-g6.psd1, elitebook-840-g5.psd1
|- checks/                        one file per check family (Spec, Disk, Battery, Bios, Activation, Atera, Drivers, Account, Lock)
|- config/defaults.psd1           committed, no secrets
|- config/site.example.psd1       committed template; real file is gitignored
|- schema/result.v1.md|.json      documented record schema
|- tests/ unit/ contract/ golden/ bench/
|- src/                           legacy; strangler-migrate, then delete
`- docs/
```

Migration (strangler, one slice per phase, tests stay green): `New-WindowsInstallIso` and `Select-InstallImage` to `core/IsoServicing.ps1`; `Select-OsRelease`, `Select-BaselineSoftpaq`, `Split-SoftpaqCommand`, `ConvertTo-ReturnCodeMap` to `vendors/hp/HP.Build.psm1`; Build script body becomes `Get-HpKitFirmware` / `New-HpKitCustomPack`; Install script body splits into core install engine (manifest-driven pnputil/firmware runner) + `HP.Target.psm1` (BIOS version parse, platform check). Keep `Install-HPDriverBaseline.ps1` as a thin wrapper so the existing SOP in `docs/` keeps working during migration. Packs stop carrying a copy of the installer: **packs are data, code lives once in the kit** (kills defect 2's root cause).

---

## 5. Build output layout (separate per vendor and model)

```
<OutputRoot>\                                   default C:\ProvisionKit_Staging  (gitignored; keep HP_Staging ignored too)
  <vendor>\<model-id>\<platform>-<os>-<release>\          e.g. hp\elitebook-840-g6\8549-win11-24H2\
      manifest.json                             schema v2 (below)
      Drivers\vendor\...    Drivers\custom\...             both pack kinds can coexist; manifest says which is active
      Firmware\<spid>\...                       Windows-flash fallback + CVA install data (as today)
      Stage\                                    ready-to-copy vendor USB tree (what Publish-Sticks copies)
  _images\<vendor-set>_<isoBuild>\              e.g. hp-840-g5+g6_26300.9457\
      <name>.iso  image.manifest.json           lists member packages + SHA-256 of each + ISO SHA-256
  _sticks\TOOLS\  _sticks\INSTALL\              assembled views, byte-identical to what is copied to the sticks
```

`manifest.json` v2 keeps all existing fields (`Profile, Platform, Os, OsVer, BuiltUtc, HPCMSL, Drivers, Firmware, Excluded`) and adds `SchemaVersion`, `Vendor`, `ModelId`, `PackKind` (`vendor|custom`), `ToolVersions` (vendor tool versions, replaces the HP-only `HPCMSL` key), `BuiltBy` kit version, `ImageGroup` / `CompatibleWith` (neighbour models), `StageLayout` (hash list of the Stage tree). Provenance goes into the per-serial result so a laptop can be traced to a build.

Rules: nothing is ever written to a path that does not start with `<vendor>\<model-id>`; per-stage `Reset-Directory` (already in the build script) applies only inside that package dir; stick assembly is derived from the manifest, never hand-copied.

### 5.1 G5 + G6 shared image: store drivers per platform, not merged

Inject **one DISM `/Add-Driver /Recurse` per platform folder** (`Drivers\<platform>\...`), looping over member packages, never one merged folder. Reasons: (a) two generations ship the same driver family at different versions; keeping them in separate folders keeps INF provenance and lets one folder fail without losing the other; (b) Windows PnP ranks by hardware ID anyway, so non-matching INFs just sit in the driver store (engineering judgement, MEDIUM; confirm on both models); (c) runtime selection by platform ID stays possible for stick-hosted packs. The existing ISO script already treats a non-zero installer exit as fatal; for the union case make it per-folder and tolerate-with-WARN for "does not apply" results (the installer already whitelists `259` and `-536870365` for pnputil; verify DISM's behaviour on a bad INF in a `/Recurse` run, unverified).

Do **not** bake firmware into the ISO (today it copies `Firmware\` into `C:\HP\Baseline`): firmware is stick-delivered pre-Windows; the Windows fallback reads from the Tools stick. Smaller image, one source of truth.

---

## 6. Master build vs provisioning script

| Aspect | `Build-Kit.ps1` (master build) | `Provision.ps1` (Assess/Deploy) |
|--------|--------------------------------|---------------------------------|
| Runs on | Builder PC, admin, internet | Target laptop, admin, internet optional |
| Vendor plane | `Build.psm1` (HPCMSL ok) | `Target.psm1` only |
| Inputs | `-Vendor`, `-Model` (multi), `-PackKind vendor\|custom\|both`, `-IsoPath` or `src/iso` discovery, `-OutputRoot`, `-Publish` | `-Mode Assess\|Deploy` (menu if omitted; default Assess), `-Context Manual\|FirstLogon`, `-Unattended` |
| Output | package dirs, image(s), staged stick trees, validated sticks | one result JSON per run, console summary |
| Interactivity | ISO listing + confirm (as spec), model multi-select | one menu at most; everything else flags |
| Safety | `SupportsShouldProcess` / `-WhatIf` end to end (already the pattern) | Assess guaranteed read-only (see 6.2) |

### 6.1 One engine, three entry points

First logon must not be a second implementation. `Provision.ps1 -Mode Deploy -Context FirstLogon -Unattended` is what the image runs; the operator's manual/recovery path is `-Context Manual` (interactive prompts allowed, firmware gate may offer Windows fallback). Same stage table, same result writer.

### 6.2 Stage table (the ordering lives in data, enforced by the engine)

```powershell
# core/Engine.ps1  (declarative; each Run is a function, not inline code)
$Stages = @(
  @{ Order=10; Name='Identify';       Kind='ReadOnly'; Modes='Assess','Deploy'; Online=$false; OnFail='Abort' }
  @{ Order=20; Name='AssessChecks';   Kind='ReadOnly'; Modes='Assess','Deploy'; Online=$false; OnFail='Warn'  }
  @{ Order=30; Name='FirmwareGate';   Kind='ReadOnly'; Modes='Deploy';          Online=$false; OnFail='Gate'  }  # warn/stop; Manual may offer fallback
  @{ Order=35; Name='FirmwareFallback'; Kind='Mutating'; Modes='Deploy';        Online=$false; OnFail='Warn'; Requires='Context=Manual + operator opt-in' }
  @{ Order=40; Name='LocalAccount';   Kind='Mutating'; Modes='Deploy';          Online=$false; OnFail='Warn'  }
  @{ Order=50; Name='Drivers';        Kind='Mutating'; Modes='Deploy';          Online=$false; OnFail='Warn'  }
  @{ Order=60; Name='OnlineGate';     Kind='ReadOnly'; Modes='Deploy';          Online=$true;  OnFail='Defer' }
  @{ Order=70; Name='Atera';          Kind='Mutating'; Modes='Deploy';          Online=$true;  OnFail='Defer'; Requires='Gate.Atera' }
)
# Terminal phase, NOT in the table, always runs last, even if a stage threw:
#   Verify (ReadOnly) -> Persist (writes result JSON only) -> Sync (network, never fails the run)
```

Enforcement points (each gets a Pester test):
- **Assess read-only:** the engine refuses to invoke any `Kind='Mutating'` stage in Assess; additionally an AST allow-list test scans Assess-reachable functions for forbidden commands (`Set-*`, `Add-*`, `Remove-*`, `Start-Process`, `pnputil`, `net`, writes outside the results path). The existing tests already use the AST-extraction technique.
- **Verify always last:** `try { run stages } finally { Verify; Persist; Sync }`; failure in a stage becomes a recorded status, not an early exit.
- **Resumable:** `C:\ProgramData\ProvisionKit\state.json` records per-stage `{status, attempts, lastUtc}`; stages are idempotent; a re-run skips `Pass` stages. Reboots (driver, rename) re-enter via the same entry with `-Resume`.
- **Pre-Windows steps cannot be scripted** (flash, defaults reset, UEFI diagnostics are manual per PROJECT.md). The engine can only *observe* them: installed BIOS vs profile minimum, key BIOS settings via WMI read (HP: `HP_BIOSSetting`; bulk reset exists only in HPCMSL and is not available on targets), plus operator attestations captured as `manual.*` fields in the record (diagnostics pass/fail prompt at first logon).

---

## 7. USB stick layouts

Two sticks, two roles. **Discover sticks by marker file, never by "first USB volume" or drive letter.**

### 7.1 Tools stick (single FAT32 volume)

```
<TOOLS>:\                         FAT32. HP's UEFI diagnostics must run from a FAT/FAT32 volume labeled HP_TOOLS (or EFI); HP also says not to put other data there (MEDIUM, HP support/community)
  Hewlett-Packard\BIOS\Current\   <vendor BIOS .bin/.sig as HP's own "Create recovery USB" tool writes them>   [verify]
  Hewlett-Packard\BIOS\New\       <active BIOS for F10 USB flash>                                              [verify]
  <HP UEFI diagnostics tree>      capture exactly what HP's "install to USB" writes; snapshot it as a manifest  [verify]
  results\                        <serial>_<runUtc>.json   (kept at root: matches the existing "results folder" and operator habit)
  ProvisionKit\
     .tools                       marker file (stick discovery)
     kit\                         core, vendors, profiles, checks, bootstrap, Provision.ps1, kit.json (version + hashes)
     firmware\hp\<platform>\      firmware-manifest.json + Windows flash tool (fallback source of truth)
     config\site.psd1             gitignored secrets/config, copied by the builder
     sync\<storeId>.ledger.json   cache of uploaded resultIds (see section 9)
     logs\
  Start.cmd                       self-elevating launcher: powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProvisionKit\kit\Provision.ps1" %*
```

Decisions and caveats:
1. **Label.** Milestone 1 is HP only, so label the volume `HP_TOOLS`. When Dell/Lenovo arrive, either a per-vendor stick label or a second partition is needed; that is why discovery is by marker and not label. (LOW: Windows 10 1703+ mounts multiple partitions on removable sticks, firmware visibility of a second partition untested; do not rely on it.)
2. **Do not hand-craft vendor trees.** Capture-and-replay: run HP's own installer ("install to USB" for diagnostics; "Create Recovery USB flash drive" in the BIOS SoftPaq's HP BIOS Update and Recovery tool, which writes the `Hewlett-Packard\BIOS\Current` tree) on the builder, snapshot the resulting tree into a layout manifest with SHA-256, and have `GetFirmwareStickLayout` return it. Community sources disagree on `Current` vs `New` for F10 flash (`Hewlett-Packard\BIOS\New` per HP forum answers; `Current` is what the recovery tool writes), which is plausibly the 2026-10-05 failure. Treat both as unverified until bench-tested on a real 840 G5 and G6, and record the result in the layout file (`Verified = @{ Model; Bios; Date; By }`). Publisher refuses to publish a layout with no `Verified` block unless `-AllowUnverified`.
3. **Multi-model collisions.** HP's folder names are fixed, so two models' BIOS files may share `New\`. Avoid the question: keep all BIOS files in `ProvisionKit\firmware\hp\<platform>\` and have `Provision.ps1` offer "prepare stick for this laptop's BIOS flash" (`Publish-FirmwareStage`), which uses the same layout writer + validator to place exactly the detected model's files. Output tells the operator in green/yellow/red whether the stage is valid. (Design recommendation, MEDIUM; costs one menu item, removes ambiguity.)
4. **Post-publish validator (the incident countermeasure).** `Test-StickLayout` re-reads the stick, checks every required path exists, hashes match the manifest, no stray `.bin` outside the expected folder, volume is FAT32 and label is correct. Runs at publish time and again at the start of every `Provision.ps1` run from the stick (cheap; catches a stick modified in the field).

### 7.2 Install stick

```
<INSTALL>:\                        bootable Windows installer written from the built ISO
  ProvisionKit\.install            marker
  ProvisionKit\packs\<vendor>\<model-id>\<platform>\{vendor|custom}\   packs (data only) for post-install pnputil, newer than what is baked into the ISO
  ProvisionKit\image.manifest.json
```

Open design point (FAT32 4 GB file limit): a Windows 11 `install.wim` is normally larger than 4 GB, so a plain FAT32 copy cannot hold it. Three options: (a) split to `install.swm` with DISM (`Split-WindowsImage`) onto FAT32, keeping the stick universally UEFI-bootable and shareable with data folders (note `*.swm` is already in `.gitignore`, so this was anticipated); (b) NTFS/exFAT with a UEFI-capable boot shim written by a third-party tool; (c) a multiboot tool that boots the ISO file from a data partition. Architecture requirement is only: *the Install stick boots Windows Setup and carries `ProvisionKit\` data folders*. Recommendation: evaluate (a) first (no third-party tool); decide in the USB phase with a bench boot test on both models. (MEDIUM; engineering judgement.)

---

## 8. First-logon orchestration and online gating

### 8.1 Where each piece runs

| Hook | Context | Use for | Not for |
|------|---------|---------|---------|
| ISO servicing (offline DISM) | build time | inject driver INFs per platform folder; stage `C:\ProvisionKit\` (kit + manifests, no firmware, no secrets) | secrets, firmware |
| `specialize` pass `RunSynchronous` | SYSTEM, before OOBE, **no network** (Wi-Fi not entered yet) | machine policy that must exist before first logon, e.g. `net accounts /maxpwage:unlimited` | anything online, firmware, long installs (slows first boot) |
| `oobeSystem` `FirstLogonCommands` | local `User`, first logon, network available if Wi-Fi was entered | launch `Provision.ps1 -Mode Deploy -Context FirstLogon -Unattended` | multi-minute work hidden from the operator; keep one visible console |
| `SetupComplete.cmd` | not used | n/a | The existing code already documents it is skipped on PCs with an OEM key (every 840 G6) |

Answer file is **generated** (`New-KitUnattend -Features ...` in core), parsed as XML in tests (the existing test already parses the embedded XML), and written into `Windows\Panther\unattend.xml`; the build refuses to overwrite an existing one (existing behaviour, keep). It must now also carry the `oobeSystem` account + autologon pieces.

### 8.2 Sequence (inside the single visible console)

```
 1 Pre-flight      elevated? start transcript (redacting secrets); load config; find Tools stick by marker; if absent -> results go to C:\ProgramData only, sync later
 2 Identify        vendor module GetDeviceIdentity; profile lookup by (vendor, platformId); unknown platform -> WARN, generic checks only
 3 -- OFFLINE PHASE (no network needed) ---------------------------------------------
   LocalAccount    ensure User exists, blank password, no forced change, no expiry (mechanism: see 8.3)
   Drivers         InstallDrivers from C:\ProvisionKit pack (+ Install-stick pack if present and newer); tolerant; reboot-required recorded, not acted on
   (record)        clock sanity: local UTC vs trusted source if any
 4 -- ONLINE GATE ---------------------------------------------------------------------
   Wait-Online     real HTTPS request to the Atera endpoint (any HTTP response = reachable; TLS/DNS/timeout = not), poll 5-10 s, bounded wait (config, default a few minutes), operator hotkey to skip; show countdown line
   gate result     recorded in the result: { atera: ok|no, store: ok|no, clockSkewSeconds, probedUtc }
 5 Atera           ONLY if gate.atera ok. Silent install with customer-specific properties from config; hard timeout; then check service AteraAgent Running. Gate not ok -> status Deferred (WARN), installer never launched
 6 Verify          all checks, including Atera (and Splashtop as info: pushed after first check-in, may lag -> WARN not FAIL)
 7 Persist         write immutable result JSON: Tools stick \results\ AND C:\ProgramData\ProvisionKit\results\
 8 Sync            if store gate ok: upload (section 9). Else Deferred. Never changes the verdict
```

Gate rules (each testable):
- **No Atera launch without a passing gate in the same run.** Enforced inside the Atera stage function (precondition), not only by stage order, so the manual path cannot bypass it.
- **"Connected" is not online.** NLA/`Test-NetConnection` to anything is insufficient (captive portals, dead uplinks). Because the probe is HTTPS to the real host, a captive portal produces a TLS name mismatch exception and correctly counts as not reachable. Atera documents outbound TCP 443/8883 and hosts such as `agent-api.atera.com` (HIGH, from FEATURES.md research).
- **Gate per destination.** Atera and the store are different hosts; one `Test-Endpoint` helper, two named probes.
- **Clock is part of "online".** Used laptops with a dead CMOS battery have wrong dates; TLS validation then fails and `runUtc` is wrong. The probe reads the HTTP `Date` header, computes skew, tries `w32tm /resync` when skew exceeds a threshold, and records `clock.skewSeconds` and `clock.trusted`. Result timestamps use `local UTC + measured offset` when a probe succeeded. (Engineering judgement, MEDIUM; high payoff, ties directly to the "newer than the store" sync rule.)
- **Always force TLS 1.2** on Windows PowerShell 5.1 before any web call (existing build script already does for the Gallery).

### 8.3 Blank-password `User` (mechanism evidence)

Evidence (LOW-MEDIUM, one GitHub issue plus Microsoft Q&A): blank `Password/Value` in both `LocalAccount` and `AutoLogon` works for autologon; **password expiry (default max age 42 days) applies to blank passwords too and an expired password breaks autologon**, so `net accounts /maxpwage:unlimited` in the **specialize** pass is the reliable pre-logon fix; per-user `PasswordNeverExpires` set from `FirstLogonCommands` works only because the account exists by then (Microsoft Q&A: commands in the wrong pass run before the account exists). Recommended belt and braces: specialize `net accounts /maxpwage:unlimited`; first-logon `Set-LocalUser User -PasswordNeverExpires $true` and `net user User /logonpasswordchg:no`. `net user User *` prompts and is unusable unattended. `LimitBlankPasswordUse` blocks network logons for blank-password accounts (console unaffected). **Bench-test in a Hyper-V Gen 2 VM before an ISO ships.** Record the accepted trade-off in the result (`account.blankPassword=true`).

---

## 9. Result record, sync, and the store seam

### 9.1 Record schema (v1) - immutable, one file per run

File name: `<serial-sanitized>_<yyyyMMddTHHmmssZ>.json` (filesystem-safe, sortable). Never edited after write; sync state lives elsewhere.

```json
{
  "schemaVersion": 1,
  "resultId": "5CG1234ABC_20261005T100200Z_a3f1",
  "runUtc": "2026-10-05T10:02:00Z",
  "startedUtc": "2026-10-05T09:41:12Z",
  "mode": "Deploy",
  "context": "FirstLogon",
  "clock": { "trusted": true, "skewSeconds": 2 },
  "tool": { "kitVersion": "1.0.0", "source": "stick|web|image", "profile": "hp/elitebook-840-g6@1", "packBuild": "8549-win11-24H2@2026-10-04T18:00:00Z", "packKind": "custom" },
  "device": { "vendor": "HP", "model": "HP EliteBook 840 G6", "platformId": "8549", "serial": "5CG1234ABC",
              "biosVersion": "R70 Ver. 01.36.00", "cpu": "Intel Core i5-8365U", "ramGB": 16, "disk": { "bus": "NVMe", "sizeGB": 238 }, "osBuild": "26300.9457" },
  "gates": { "atera": "ok", "store": "no", "probedUtc": "2026-10-05T09:58:40Z" },
  "stages": [ { "name": "Drivers", "status": "Warn", "detail": "3 INF skipped (259)", "startedUtc": "...", "seconds": 212 } ],
  "checks": [ { "id": "bios.current", "status": "Pass", "value": "01.36.00", "expected": ">=01.36.00" } ],
  "manual":  { "diagnostics": "Pass", "biosDefaultsReset": "attested" },
  "verdict": "Warn"
}
```

Rules: status vocabulary `Pass|Warn|Fail|Info|Skipped|Deferred`; verdict = worst non-ignored; every timestamp is a pre-formatted string `yyyy-MM-ddTHH:mm:ssZ` (validator rejects other formats); **allow-list only** (no BitLocker keys, Wi-Fi data, passwords, full product keys; the current "last 5 chars of key" is reduced to `keyMatch`); `resultId = serial_runUtc_4hex` is the idempotency key.

Windows PowerShell 5.1 serialization traps to cover with golden tests: `ConvertTo-Json` renders `DateTime` as `\/Date(...)\/` (so never pass DateTime), default `-Depth 2` truncates nested objects (always pass `-Depth 6`), one-element arrays can collapse (force arrays), `Set-Content -Encoding UTF8` writes a BOM (use `[IO.File]::WriteAllText` with `UTF8Encoding($false)`; the existing build writes `manifest.json` with BOM), and `Test-Json` does not exist in 5.1 (hand-written `Test-KitResult`). (Known 5.1 behaviours, MEDIUM-HIGH.)

### 9.2 Store adapter seam (the store choice is a separate research output; the seam must not leak it)

| Function | Required | Meaning |
|----------|----------|---------|
| `Test-KitStore` | yes | real request to the store host (same probe helper as Atera) |
| `Send-KitStoreResult -Record` | yes | idempotent put keyed by `resultId`; returns `Created`, `Exists`, or `Failed(reason, retryable)` |
| `Get-KitStoreLatest` | optional (`CanList`) | map `serial -> latest runUtc` (needs a read credential on the laptop; omit when using a write-only credential) |
| flatten | in adapter | full JSON plus flat columns for the tracker (`serial, runUtc, verdict, mode, model, platformId, bios, ...`); the "latest per serial" view is derived store-side by max(`runUtc`), never by arrival order |

### 9.3 Sync algorithm ("upload anything newer than what the store has")

The stick is the carrier, so no per-laptop "uploaded" flag can be trusted; dedupe is therefore **server-side idempotency first, watermark as optimization, ledger as cache**.

```
Sync-KitResults:
  if not Test-KitStore:                       return Deferred            # WARN, never throws, never blocks Verify
  files  = *.json in Tools:\results (skip .sync); sort ascending by runUtc (parsed as UTC, not by file name/mtime)
  valid  = files that pass Test-KitResult; invalid -> move to results\_quarantine\, WARN (never delete)
  if adapter.CanList:  remote = Get-KitStoreLatest
        candidates = valid where serial not in remote OR runUtc > remote[serial]       # the literal "newer than store" rule
        (+ optional -IncludeHistory: also records whose resultId the store lacks)
  else:                candidates = valid where resultId not in ledger[storeId]          # ledger travels with the stick
  budget: max N records and T seconds per run; per request timeout; retry 5xx/timeouts 3x with exponential backoff + jitter; no retry on 4xx except 408/429
  for r in candidates (oldest first):
        outcome = Send-KitStoreResult r
        if outcome in (Created, Exists): ledger.add(r.resultId)      # atomic write: temp file + rename
        else: record failure, continue
  report: "uploaded n, already there m, failed k, deferred d"   -> WARN if k>0; verdict of the current run unchanged
```

Why this shape: idempotent put makes retries, re-runs on other laptops and a lost ledger safe; oldest-first keeps partial progress monotonic; the store computes latest-per-serial from `runUtc`, so out-of-order arrival is harmless. The one data-loss hazard is a laptop whose clock is in the past having its *newer* result judged "older than the store" under the watermark rule, so the clock-trust logic in 8.2 is load-bearing and the watermark path must never be the only dedupe when `clock.trusted=false` (upload those regardless). Background sync stays optional (a detached `Start-Process` plus log, no service or scheduled task); default is synchronous with a short time budget.

---

## 10. Run-time config and secret injection

Layers, lowest to highest precedence:

1. `config/defaults.psd1` (committed, no secrets: thresholds, endpoint host names that are public, timeouts)
2. Tools stick `ProvisionKit\config\site.psd1` (gitignored; **the** carrier for Atera installer location/properties, store URL/token, customer-specific values)
3. `C:\ProgramData\ProvisionKit\config.psd1` (optional per-machine override for bench use, gitignored by definition since it is outside the repo)
4. Parameters / environment (`-AteraMsiPath`, `$env:PK_*`) for one-offs

Mechanics:
- `Get-KitConfig` merges layers into one object and records *which layer* each key came from (for the result's `tool` block, values excluded).
- **Registered redaction:** every secret-class key is registered with the logging layer; the transcript/log writer scrubs those values. Pass secrets to installers via `Start-Process -ArgumentList` and avoid verbose echo and MSI verbose logs that print properties (delete or avoid `/l*v` for the Atera step).
- Builder side: `Build-Kit`/`Publish-Sticks` copy `config/local/site.psd1` (gitignored) onto the Tools stick; nothing from `config/local` is ever written into an ISO, image, or `_images` output.
- Missing config degrades gracefully: no Atera config means Atera stage = `Skipped` with a yellow line; no store config means Sync = `Deferred`.
- Guardrails in repo: `.gitignore` entries for `config/local/`, `*.local.psd1`, `site.psd1`, `secrets/`; committed `site.example.psd1` with fake values; **secret scan** (gitleaks pre-commit + CI) from day one, because history cannot be cleaned later; tests assert `defaults.psd1` contains no keys matching a secret list.
- Stick loss mitigation (design, not a promise): store credential should be write-only/scoped and rotatable (store research); the Atera installer link should be treated as revocable. Optionally encrypt `site.psd1` with a typed passphrase later; not in milestone 1 (overbuild).

---

## 11. `irm <url> | iex` bootstrap

Constraints: `iex` runs text, so there is no `$PSScriptRoot`, no `param()` block at top level, and execution policy does not apply to the piped text but **does apply to any `.ps1` it later dot-sources** (stock Windows 11 client defaults to Restricted), so the stub sets process-scope Bypass. Windows PowerShell 5.1 needs TLS 1.2 forced.

Design:

```
stub (served from a stable URL under the project owner's control, e.g. GitHub Pages or raw on a tag-pinned path; short because it is typed on a phone):
  1. [Net.ServicePointManager]::SecurityProtocol = Tls12 ; Set-ExecutionPolicy -Scope Process Bypass -Force
  2. not admin -> relaunch elevated (Start-Process powershell -Verb RunAs ...) with the same one-liner
  3. find Tools stick by marker -> read ProvisionKit\kit\kit.json (stick version)
  4. online? GET  https://github.com/<o>/<r>/releases/latest/download/kit.json   (stable redirect URL, no API rate limit; avoid api.github.com: 60 req/h per IP, shop NATs share an IP)
        { version, sha256, url, minStickVersion }   newer than stick copy -> download kit.zip to %ProgramData%\ProvisionKit\dl,
        verify SHA-256 against kit.json, Expand-Archive to kit\<version>.new, atomic rename; (optional) mirror verified kit onto stick so offline copy catches up
     offline or any failure -> use stick copy, WARN "running stick version x"
  5. $env:PK_* / splatted params -> & kit\Provision.ps1 @params  (menu if none)
```

What the web route may pull: scripts, core, vendor modules, profiles, schema, layout manifests, `firmware-manifest.json` (versions + hashes + vendor URLs). What it must not: secrets (never, public repo), ISO, driver packs, BIOS binaries, UEFI diagnostics (size, licensing, and these are stick/build artifacts; an optional runtime download of a Windows flash tool straight from the vendor with a manifest hash is acceptable but not required). Pin to **tagged releases** with a hash manifest, never `main`. Honest threat model: the hash lives in the same repo as the payload, so it protects against corruption and CDN/TLS interception, **not** against repo or account compromise; mitigate with 2FA, protected tags, and later signed release assets. Parameter passing through `iex` is awkward: support `$env:PK_MODE`-style variables or the documented `& ([scriptblock]::Create((irm $u))) -Mode Assess` form. Update-check must be time-boxed (a few seconds) so a dead shop link never stalls the run.

---

## 12. Testing strategy

Principle: **everything with side effects goes through a core seam function so tests can mock it**, and the same code runs under Windows PowerShell 5.1 in CI (Pester 6 supports 5.1 and 7.4+; the user rules already target v6).

| Layer | What | How |
|-------|------|-----|
| Static | Syntax/compat, secrets | PSScriptAnalyzer (with compatibility rules targeting 5.1) + gitleaks pre-commit and CI; fail on any finding (no suppressions, per user rule) |
| Unit (pure) | OS/release selection, softpaq selection, return-code map, config merge, result validator, stage table order, gate decisions, unattend generator (parse XML), layout validator | Pester with `TestDrive`; no admin, offline (existing style) |
| Seams | `Get-KitUtcNow`, `Invoke-KitNative` (pnputil/dism/net), `Invoke-KitWeb`, `Get-KitStickVolume`, CIM reads | Mock these, not raw cmdlets; wraps the existing `Invoke-Tool` idea |
| Contract | each `vendors/*/vendor.psd1`: descriptor valid, every mapped command exported, required parameters present, outputs carry required properties | `BeforeDiscovery` over the folder list (Pester 6 throws on an empty `-ForEach`, which is fine because HP always exists); `_template` excluded |
| Engine | order; **Verify and Persist run last even when a stage throws**; Assess calls zero Mutating stages; Atera installer `Should -Invoke ... -Times 0` when gate fails; resume skips Pass stages | mocks + `Should -Invoke` |
| Sync | out-of-order, duplicates, partial failure, lost ledger, untrusted clock, corrupt file quarantined, empty stick, 429/5xx retry | fake adapter (`FolderStore`) with scripted outcomes |
| Golden | result JSON byte layout: UTC `Z` strings, no BOM, arrays, depth, schema validation | committed fixtures |
| Layout | build a layout from fake files into `TestDrive`, validate; **negative test that reproduces the incident** (file in wrong folder fails validation) | no hardware needed |
| Bootstrap | hash mismatch aborts; offline falls back to stick; TLS 1.2 set; no secrets in the stub | mock web seam |
| Bench (tag `Bench`, manual, excluded from CI) | Hyper-V Gen 2 VM running the generated ISO (blank password, autologon, first-logon pipeline, online-gate); real 840 G5 and G6 for BIOS USB layout, UEFI diagnostics on the same stick, DISM union behaviour | checklist with results written into `layouts/*.layout.psd1` `Verified` blocks |

Pester 6 migration notes that hit the existing suite: unmatched `-ParameterFilter` mocks no longer fall through to the real command (the current `Mock Get-CimInstance ... -ParameterFilter` tests need a default mock), duplicate `BeforeAll`/`BeforeEach` in one block are errors, and `Assert-MockCalled` is removed (use `Should -Invoke`). CI: GitHub Actions `windows-latest` with `shell: powershell` for 5.1 (MEDIUM, from general knowledge; confirm in the CI phase). Do not run ISO-servicing or DISM-heavy tests on the builder by default; the IMAPI2 ISO test already works in `TestDrive`.

---

## 13. Patterns to follow

1. **Data-driven stages and layouts.** Orders, gates, USB trees are declared data; code interprets them. Makes the incident class testable.
2. **Descriptor + command map for vendors** (section 3.2); no classes on 5.1.
3. **Packs are data, code ships once.** No copying installers into packs.
4. **Immutable records, external ledgers.** Result files never change; sync state is a separate cache.
5. **Idempotent-by-key writes** (`resultId`), watermarks only as optimization.
6. **Tolerant by default, loud in the result.** Harmless exit codes map to Warn; the record keeps the raw codes.
7. **Capture-and-replay vendor layouts** with SHA-256 manifests and a `Verified` block.
8. **One engine, many entry points** (stick, `irm|iex`, image first logon).
9. **Read-only guarantee tested structurally** (engine refusal + AST allow-list).
10. **Phone-width output.** `Write-Status` wraps at ~44 columns; color only via one function; data stays in objects/JSON (the user rules allow `Write-Host` only for UI text).

## 14. Anti-patterns to avoid

| Anti-pattern | Why bad | Instead |
|--------------|---------|---------|
| Firmware flash in the specialize pass (current) | Violates mandated order; flashing mid-install; no network, no operator view | Firmware pre-Windows from Tools stick; Windows fallback only in manual Deploy |
| Copying `Install-*.ps1` into every package and image (current) | Code copies drift (defects 1 and 2) | Single kit, packs are data |
| "First USB volume" for results (current) | Two sticks; wrong stick gets results | Marker-file discovery |
| Local-time, overwrite-per-serial `.txt` (current) | No history, merge ambiguity across sites | Immutable UTC JSON, ledger-based sync |
| Vendor/model rules inside the audit script (current Dell/Lenovo regexes in `Test-DeviceBaseline.ps1`) | Vendor knowledge in neutral code | Profiles + vendor `GetDeviceIdentity`/checks |
| Hand-typed vendor folder paths | The 2026-10-05 failure mode | Layout manifest, validator, `Verified` gate |
| Secrets in image, ISO, repo, result, or transcript | Leaks with every laptop | Run-time config from Tools stick, redaction |
| Auto-update from `main` | A bad commit breaks every shop run | Tagged release + hash, stick fallback |
| Stage logic that throws to end the run | Skips Verify and the record | Convert to status; engine's `finally` terminal phase |
| `Read-Host` deep inside functions | Untestable, blocks unattended first logon | Prompts only at the entry layer; everything else takes parameters |
| PowerShell classes for the vendor interface | Cached definitions break Mock and reload on 5.1 | Descriptor + command map |
| Background agent or scheduled-task sync | Overbuild; stock laptop is handed over | Synchronous sync with budget (optional detached run) |

## 15. Scalability considerations

| Concern | Today (1 operator, 2 models) | A few vendors / ~10 models | Many sites |
|---------|------------------------------|----------------------------|------------|
| Vendors | HP module only, contract + template | add folder per vendor | same |
| Image variants | one union ISO per neighbour group (`ImageGroup` in profile) | per group; ISO build is the slow step (~2x ISO size scratch, DISM) so cache by `image.manifest.json` hash | same |
| Stick capacity | FAT32 stick holds BIOS + diagnostics + kit + results easily | Install stick packs per model grow; prune by profile | same |
| Results volume | hundreds of small JSON files; ledger keeps sync O(new) | enforce per-run budget; quarantine folder pruning | store partitioning is store-side |
| Store | adapter seam | same | adapter swap only |

---

## 16. Suggested build order (dependencies)

```
core foundations ──┬─> vendor contract + HP Target ──┬─> Result record + checks + Assess ──┬─> Stage engine + Deploy + online gate + Atera ─┐
(Output, Clock,    │                                 │                                      │                                                ├─> Unattend + first-logon + ISO integration ─> VM bench
 Native, Config,   │                                 └─> HP Build (manifest v2, layouts) ──>│ Publish-Sticks + layout validator              │
 Stick, secret     │                                                                         └─> Store adapter + Sync (store decision gates real adapter; FolderStore first)
 scan, drift fixes)└─────────────────────────────────────────────────────────────────────────────────────────────> Bootstrap + release packaging (after engine is stable)
                                                                                    Custom/latest pack + G5/G6 union (after layouts and manifest v2; highest uncertainty)
```

1. **Foundation and repair.** Repo skeleton, core seams (Output, UTC clock, native wrapper, config/secrets, stick discovery), secret scan + `.gitignore`, fix the three drift defects, get the existing Pester suite green on 5.1 under Pester 6. Everything else depends on this; the secret scan must precede any config work.
2. **Vendor contract + HP Target module + profiles.** `GetDeviceIdentity`, installed-firmware parse, tolerant install; contract tests; `_template`.
3. **Build plane + output layout + firmware layout + stick publisher.** Manifest v2, vendor/model folders, `Get-FirmwareStickLayout`, `Test-StickLayout`, `Publish-Sticks`. Highest operational value (incident fix) and independent of the engine. Includes bench verification of HP BIOS USB layout and UEFI diagnostics co-residence.
4. **Result record + check library + Assess mode.** Refactor `Test-DeviceBaseline.ps1` into checks; JSON writer; read-only guarantee tests.
5. **Stage engine + Deploy + online gate + Atera.** Needs 2 and 4 and config; adds state/resume, firmware gate with BitLocker-suspend fallback.
6. **Store adapter + sync.** Seam and `FolderStore` right after 4 (unblocks sync tests); real adapter when the store decision lands.
7. **Unattend generator + first-logon + ISO integration.** Needs 5; includes the blank-password mechanism and VM bench; per-platform union injection.
8. **Bootstrap + release packaging.** After the engine stabilizes; kit.json/hash tooling.
9. **Custom/latest packs, vendor pack, G5+G6 overlap analysis.** Highest uncertainty; research first.

## 17. Research flags

| Item | Why it needs verification | When |
|------|---------------------------|------|
| Exact HP BIOS USB tree (`Current` vs `New`, `.bin`/`.sig`, multi-model coexistence) | Conflicting community answers; caused the live incident | Phase 3, bench on real 840 G5 and G6 |
| HP UEFI diagnostics USB tree and whether it can share a volume with BIOS tree and scripts | HP says `HP_TOOLS`/`EFI` FAT volume, advises no extra data; no folder tree found | Phase 3 |
| Install-stick boot method for a >4 GB `install.wim` | FAT32 limit; SWM split vs third-party boot shim | Phase 7 (USB) |
| FirstLogonCommands elevation and blank-password autologon behaviour on build 26300 | Mechanism evidence is thin | Phase 7, Hyper-V bench |
| DISM `/Add-Driver /Recurse` behaviour with non-matching or bad INF in a union folder | Tolerance assumption | Phase 7/9 |
| `GetVendorPack` availability per HP model (`-Category Driverpack`) | Uneven per platform | Phase 9 |
| Store capability set (write-only, `CanList`, idempotent create) | Drives the sync path used | Store research |
| `releases/latest/download` redirect behaviour from PS 5.1 and `Expand-Archive` on large zips | General knowledge, not verified here | Phase 8 |

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Grounding in existing `src/` | HIGH | Read directly; defects confirmed by grep |
| Vendor interface / two-plane split | MEDIUM-HIGH | Derived from existing code shape plus HP CMSL docs; Dell/Lenovo only sketched (LOW) |
| Output layout, stage engine, sync algorithm | MEDIUM | Engineering design; standard idempotent store-and-forward |
| USB layouts | LOW-MEDIUM | HP label and FAT32 facts from HP pages; folder trees unverified; bench required |
| First-logon / unattend mechanics | MEDIUM | Corroborated by Microsoft Q&A and docs summaries; needs VM bench |
| `irm | iex` bootstrap | MEDIUM | Sound known constraints; integrity limits stated honestly |
| Testing strategy | MEDIUM-HIGH | Pester 6 on 5.1 confirmed in Pester docs |

## Sources

- HP Client Management Script Library docs via Context7 `/websites/developers_hp_hp-client-management_doc` (HIGH): `Get-HPBIOSUpdates` (-Download/-Flash/-BitLocker/-Offline, UEFI + 64-bit PowerShell required), `New-HPDriverPack`, `New-HPBuildDriverPack`, `Get-HPSoftpaqList -Category Driverpack`, `Get-HPDeviceDetails`, `HP_BIOSSetting`/`HP_BIOSPassword` WMI classes. https://developers.hp.com/hp-client-management/doc/new-hpdriverpack , https://developers.hp.com/hp-client-management/doc/new-hpbuilddriverpack , https://developers.hp.com/hp-client-management/doc/get-hpbiosupdates (direct fetch returned 403; content via Context7)
- Pester docs via Context7 `/pester/docs` (HIGH): v6 supports Windows PowerShell 5.1 and 7.4+; default-mock rule; class caching breaks Mock on 5.1. https://pester.dev/docs/migrations/v5-to-v6
- HP, Testing for hardware failures (USB then drive then built-in search order): https://support.hp.com/us-en/document/ish_2854458-2733239-16 (MEDIUM-HIGH); HP_TOOLS FAT/FAT32 label requirement and "no extra data" advice from search summaries of HP PC Hardware Diagnostics UEFI guides (MEDIUM)
- HP BIOS update/recovery: https://support.hp.com/us-en/document/ish_4208192-2358829-16 (Create Recovery USB flash drive flow); HP community threads on `Hewlett-Packard\BIOS\New` / `Current`: https://h30434.www3.hp.com/t5/Notebook-Boot-and-Lockup/BIOS-RECOVERY-FOLDER-FILE-STRUCTURE/td-p/9405793 , https://h30434.www3.hp.com/t5/Desktops-Archive-Read-Only/Upgrading-BIOS-outside-of-Windows/td-p/8273589 (MEDIUM; forum, direct fetch blocked)
- Dell BIOS flash from USB / F12: https://www.dell.com/support/kbdoc/en-us/000123870/how-to-flash-the-bios-on-a-dell-desktop-or-notebook-with-a-usb-thumb-drive ; Dell driver pack catalog: https://www.dell.com/support/kbdoc/en-us/000122176/driver-pack-catalog (MEDIUM)
- Lenovo BIOS USB flash and catalogs: https://tojaj.com/lenovo-biosuefi-update-from-usb-stick-i-e-without-bootable-cd/ ; https://www.deploymentresearch.com/links-to-vendor-model-and-driver-catalogs/ (LOW-MEDIUM)
- Blank password, expiry and autologon in unattend: https://github.com/a11ign/a11ign/issues/1933 (LOW-MEDIUM, single issue); https://learn.microsoft.com/en-us/answers/questions/1347161/set-password-never-expires-for-a-local-user-in-the (MEDIUM)
- Unattend pass ordering and FirstLogonCommands semantics: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-firstlogoncommands-synchronouscommand (HIGH)
- Project inputs read directly: `.planning/PROJECT.md`, `.planning/research/FEATURES.md`, `src/*.ps1`, `src/*.psm1`, `src/profiles/hp-elitebook-840-g6.psd1`, `src/HPDriverBaseline.Tests.ps1`
