---
title: HP EliteBook 840 G6 Driver & Firmware Baseline SOP
description: Build and apply a repeatable HP EliteBook 840 G6 (platform 8549) Windows 11 driver and BIOS baseline with HPCMSL. Covers the build script, online (pnputil + silent BIOS flash) and offline (DISM) apply modes, building a driver-preloaded install ISO with New-HPBaselineIso.ps1, why Win11 25H2/26H2 use the 24H2 catalog, per-model profiles, and bugs fixed in the earlier ad-hoc script.
aliases:
  - HP EliteBook 840 G6 Driver & Firmware Baseline SOP
tags:
  - automation
  - hardware
  - windows
type: How-to guide
audience: technical
created: "2026-09-28T12:51:15+08:00"
linter-yaml-title-alias: HP EliteBook 840 G6 Driver & Firmware Baseline SOP
updated: "2026-09-28T17:31:44+08:00"
---
# HP EliteBook 840 G6 Driver & Firmware Baseline SOP

## Overview

One folder brings every EliteBook 840 G6 to the same known-good state. It holds the right hardware drivers and the latest BIOS, so Wi-Fi, audio, the webcam, the fingerprint reader and the touchpad all work after a fresh Windows install without hunting for downloads. Build the folder once, copy it to a USB stick, and run one command on each laptop. Rebuild it whenever HP publishes updates.

Technically: [`scripts/hp-driver-baseline/`](../scripts/hp-driver-baseline/) uses the HP Client Management Script Library (HPCMSL) to query HP's SoftPaq catalog for platform `8549`. It extracts drivers into INF folders and stages signature-checked firmware SoftPaqs. It writes a `manifest.json` recording exactly what was included, what was excluded and why, and how to install each firmware item silently.

## Package layout

| Path | Contents |
| --- | --- |
| `Drivers/` | INF/SYS/CAT driver folders from `New-HPBuildDriverPack` (DISM- and pnputil-ready) |
| `Firmware/spNNNNNN/` | SoftPaq `.exe` plus extracted payload (e.g. `HpFirmwareUpdRec.exe` for BIOS) |
| `manifest.json` | Platform, catalog OS release, HPCMSL version, included/excluded SoftPaqs, firmware silent commands + return codes |
| `Install-HPDriverBaseline.ps1` | Standalone applier (no HPCMSL needed on target) |

Package folder name: `<OutputRoot>\<Platform>-<os>-<release>`, e.g. `C:\HP_Staging\8549-win11-24H2`.

## Build the package

Prerequisite: HPCMSL. The script installs it from the PowerShell Gallery if it is missing. PowerShell 7 is preferred; on Windows PowerShell 5.1 the script also forces TLS 1.2 and installs the NuGet provider.

From an **elevated** PowerShell session (driver pack building and SoftPaq extraction both require admin):

```powershell
cd scripts\hp-driver-baseline

# Preview the selection without downloading (works unelevated)
.\Build-HPDriverBaseline.ps1 -WhatIf

# Build to C:\HP_Staging\8549-win11-<release>
.\Build-HPDriverBaseline.ps1

# Refresh only one stage; the manifest keeps the other stage's entries
.\Build-HPDriverBaseline.ps1 -Stage Firmware
```

Re-running is idempotent: each stage's folder is emptied first, so SoftPaqs HP has superseded don't linger.

### Selection rules

- **Drivers**: `Get-HPSoftpaqList -Category Driver` (server-side; returns every `Driver - *` subcategory and excludes `Dock - *`), then only HP's driver-pack-eligible (`DPB`) SoftPaqs, minus the profile's `DriverExclude`.
- **Firmware**: `-Category BIOS, Firmware`, minus `FirmwareExclude`. Only SoftPaqs HP flags as silent-capable (`SSM`) with a silent command in their CVA metadata are auto-installed. Others (e.g. the Samsung PM991 SSD firmware) are staged but must be run by hand.

Dry run on 2026-09-28 against the 24H2 catalog: 21 drivers, BIOS `sp174025` (R70 `1.36.00`), Samsung SSD firmware `sp149654` (manual). Excluded: AMD Video (sibling dGPU), DisplayLink (dock), HP Hotkey Support UWP, XMM7262 WWAN (not DPB).

## Apply the package

Both modes need an elevated session on the machine running them.

### Online: running 840 G6

```powershell
.\Install-HPDriverBaseline.ps1 -WhatIf   # show every step
.\Install-HPDriverBaseline.ps1           # then reboot
```

1. Refuses to run unless the board's platform ID (`Win32_BaseBoard.Product`) is `8549` (`-Force` overrides).
2. Runs `pnputil /add-driver Drivers\*.inf /subdirs /install`, then prints a **driver report**:
   - how many packages were newly added to the driver store, counted from the `oem*.inf` files before and after the run;
   - every present device that still isn't working (`ConfigManagerErrorCode` ≠ 0; code `28` = no driver), excluding devices the user disabled.
3. For each firmware item, BIOS last:
   - **Skips** it when the item is device-specific and no matching device is present. It checks the CVA `[Devices]` hardware IDs against `Win32_PnPEntity`, so the Samsung PM991 SSD firmware is only offered on units with that SSD.
   - **Skips the BIOS** when the installed version is the same or newer. It compares the SMBIOS version (e.g. `R70 Ver. 01.36.00`) with the SoftPaq's version, and the BIOS family (`R70`) must match.
   - If the version can't be determined, it **runs HP's updater** and lets it decide (it exits `282` on the same version). Unknown state never skips an update.
   - Warns about firmware that is applicable but manual-only (no silent install).
   - Runs the rest with HP's CVA silent command and reports the exit code using HP's own return-code text (`3010` = success, reboot to flash).
4. Exits `1` if any step failed. `-LogPath <file>` writes a transcript.

Use `-SkipFirmware` for a drivers-only pass.

**Why a re-run is fast:** pnputil skips packages that are already in the driver store. That applies to every package on a PC installed from the baseline ISO, where they were injected into the image.

The report's "0 new package(s)" plus "all present devices have a working driver" is the confirmation. The package itself was checked: all 21 SoftPaq folders contain INF drivers (293 INFs), and none is installer-only.

It deliberately omits the Microsoft Store companion apps that some drivers pair with (Realtek Audio Console, Intel Graphics Command Center, and similar). Hardware works without them.

**BitLocker:** handled by HP's own silent command. `HpFirmwareUpdRec -r -b -s`, where `-b` means "if BitLocker with TPM is in use, automatically suspend it" (`HpFirmwareUpdRec.txt`). So BitLocker is only suspended when a flash actually happens.

> [!WARNING]
> If a BIOS setup password is set, the silent BIOS flash exits `128`. Flash those units manually, or clear the password first.

### Offline: Windows image

```powershell
dism /Mount-Image /ImageFile:D:\sources\install.wim /Index:1 /MountDir:C:\Mount\install
.\Install-HPDriverBaseline.ps1 -ImagePath C:\Mount\install
dism /Unmount-Image /MountDir:C:\Mount\install /Commit
```

This runs `dism /Add-Driver /Recurse` only. Firmware cannot be serviced offline, so run the online mode once after first boot to bring the BIOS to baseline.

## Build a pre-loaded install ISO

`New-HPBaselineIso.ps1` wraps the offline mode into a finished, bootable ISO. Windows installs with every 840 G6 driver already in place, with no post-install driver step. It needs an elevated session (DISM image servicing) and **nothing to install**. The ISO is written with IMAPI2, the disc-image engine built into Windows, so the Windows ADK / `oscdimg.exe` is not required.

```powershell
cd scripts\hp-driver-baseline
$iso = 'D:\Sources\26300.9457.260913-0631.26H2_GE_RELEASE_SVC_IM_CLIENTPRO_OEMRET_X64FRE_EN-US.ISO'

.\New-HPBaselineIso.ps1 -IsoPath $iso -WhatIf   # resolve edition + build, copy nothing
.\New-HPBaselineIso.ps1 -IsoPath $iso           # -> C:\HP_Staging\<iso name>_HP8549.iso
```

What it does:

1. Mounts the ISO read-only and picks the image in `install.wim`/`.esd`. This source ISO is **Pro-only** (one image, Windows 11 Pro 26300.9457), so no `-Edition` is needed. Multi-edition media requires `-Edition '<exact name>'`; a missing or wrong name fails in seconds and lists the available editions.
2. Copies the media to `-WorkRoot` (default `C:\HP_Staging\IsoBuild`). A `.wim` is serviced in place. An `.esd` is first converted to WIM, because DISM can't service ESD.
3. Mounts the image and runs the package's own `Install-HPDriverBaseline.ps1 -ImagePath`. That's the same code path as the manual offline mode above. Unless `-NoFirstBoot`, it also sets up the first-boot run (next section).
4. Commits, then does a single export into `sources\install.wim`. The export keeps only the chosen edition and drops the orphaned data a WIM commit leaves behind.
5. With `-BootDriver sp144910`, it also adds Intel RST to `boot.wim` index 2 (Windows Setup). Only needed for units whose disk is in RAID mode; AHCI units boot Setup with in-box drivers.
6. Builds a UEFI + legacy BIOS bootable UDF ISO. It keeps the source volume label and the ISO's own `efisys.bin`, which shows the "Press any key to boot from CD" prompt.
7. Deletes the work folder (`-KeepWorkDir` keeps it) and returns the ISO path, size, edition, build and SHA-256.

Safety: every image mount is discarded if a step fails, so no stale mounts are left. The script refuses a `-WorkRoot` it didn't create, and refuses to start while a mount is left under it.

### First-boot run

Laptops installed from the ISO bring their own firmware up to baseline, with no one running a script. While the image is mounted, the ISO build does two things:

1. Copies `manifest.json`, `Install-HPDriverBaseline.ps1` and `Firmware\` to `C:\HP\Baseline` in the image. Drivers are already injected, so they are not copied.
2. Writes `Windows\Panther\unattend.xml` with a single **specialize-pass** `RunSynchronous` command. Microsoft documents this as the way to embed an answer file in an offline image. The command runs:

   ```text
   powershell.exe -ExecutionPolicy Bypass -File %SystemDrive%\HP\Baseline\Install-HPDriverBaseline.ps1 -LogPath %SystemDrive%\HP\Baseline\firstboot.log
   ```

During Setup, after the image is applied and before OOBE (the region/account screens), the installer runs once as SYSTEM:

- it checks the platform;
- it reports any devices still missing a driver;
- it runs out-of-date firmware. The BIOS flash is staged and applies on Setup's next reboot.

It runs under the image's built-in Windows PowerShell 5.1; every script is parse-checked under 5.1 by the test suite.

Why not the usual `SetupComplete.cmd`: Microsoft says it "is disabled when using OEM product keys, except on Enterprise editions". Every 840 G6 has an OEM Windows Pro key in its firmware, so it would silently never run. An answer-file command has no such restriction.

After install, check **`C:\HP\Baseline\firstboot.log`**. It records the driver report and every firmware decision (CURRENT / MANUAL / OK / FAIL). On a non-8549 PC the platform check stops it, and that is logged too.

Limits:

- The script refuses to overwrite an answer file already present in the image. This source ISO has none, and no `autounattend.xml` at the ISO root.
- An `autounattend.xml` on the install USB would take precedence over the image's answer file. The first-boot command would then need merging into it.
- `-NoFirstBoot` builds a drivers-only ISO.
- Not yet tested by an actual install. Confirm the log on the first laptop before building more.

### ISO writer verification

`New-WindowsInstallIso` (in `HPDriverBaseline.psm1`) was verified on 2026-09-28 by rebuilding this source ISO's unmodified media. It did not boot the result in a VM or on hardware.

- **Boot catalog:** byte-identical to Microsoft's. There is a BIOS entry (no emulation, 8-sector `etfsboot.com`) and a final UEFI section (platform `0xEF`, 1-sector load of `efisys.bin`). IMAPI2 writes the UEFI load size as 2880 sectors, so the helper patches it to Microsoft's value of 1.
- **Contents:** all 968 files match by path and size, on a UDF volume with the original label.
- **`install.wim`:** the 7.4 GB file is SHA-256-identical after the round trip.
- **Speed:** 7.8 GB written in about 11 s.

Two IMAPI2 constraints the helper handles:

- **Path length:** IMAPI2 uses legacy Win32 paths (260-character limit), and Windows media nests about 150 characters deep (`sources\replacementmanifests\…`). Keep `-WorkRoot` short. The default is fine, and a long root fails fast with a clear error rather than IMAPI2's bare "path not found".
- **File handles:** IMAPI2's COM objects hold file handles. The helper closes and releases them before returning; otherwise the work folder can't be deleted.

> [!NOTE]
> The output ISO boots with Microsoft's 2011-signed boot files, like the source ISO. Units that have revoked that CA (optional BlackLotus mitigation) need 2023-signed boot media, which this script does not produce. The UDF ISO has no 4 GB file limit, but a FAT32 USB stick does. Use Rufus or split the WIM (`dism /Split-Image … /FileSize:3800`) if writing to FAT32.

## Newer Windows releases (25H2, 26H2)

`Get-HPDeviceDetails -Platform 8549 -OSList` tops out at Windows 11 **24H2 (26100)**, so `Get-HPSoftpaqList -OsVer 25H2` has no catalog to read. With `OsVer` empty, the profile picks the newest release HP indexes. That means 24H2 today, and newer releases automatically if HP ever adds them.

Drivers built for 24H2 install on 25H2 (26200), which shares the 26100 servicing branch. The 26H2 ISO in use (build **26300**) is labelled `GE_RELEASE`, the same Germanium platform as 24H2, so the same DCH drivers are expected to apply.

`New-HPBaselineIso.ps1` prints the image build next to the catalog release so the gap stays visible. After the first install, check Device Manager for unknown devices before rolling it to more units.

## Adding another model

Copy `profiles/hp-elitebook-840-g6.psd1`, set `Name`, `Platform` (from `Get-HPDeviceDetails -Name '*model*'`), `Os` and the exclude lists, then:

```powershell
.\Build-HPDriverBaseline.ps1 -ProfilePath .\profiles\<model>.psd1
```

Exclude entries match a SoftPaq id exactly (`sp152918`) or a name substring (`AMD Video`), the same semantics as HPCMSL's `-UnselectList`.

> [!NOTE]
> Platform `8549` is shared by the 840 G6, 840 G6 Healthcare Edition, 850 G6, and ZBook 14u/15u G6. The 840 G6 profile excludes the AMD Radeon driver because the 840 G6 is UMA-only (Intel UHD 620). Make a separate profile before using this package on 850 G6 / ZBook 15u G6 units with discrete graphics.

## Tests

```powershell
Invoke-Pester scripts\hp-driver-baseline
Invoke-ScriptAnalyzer -Path scripts\hp-driver-baseline -Recurse
```

Pester covers OS-release resolution, include/exclude selection, CVA command parsing and return-code mapping, with fixtures taken from live platform `8549` catalog data. PSScriptAnalyzer reports no findings.

## Review of the earlier ad-hoc script

The original hand-written script (2026-09-28 session notes) looked complete but produced an empty driver pack. Issues found and fixed, verified against the live catalog with HPCMSL 1.9.0:

| Issue | Impact | Fix |
| --- | --- | --- |
| `$_.Category -eq 'Driver'`: real categories are `Driver - Audio`, `Driver - Chipset`, etc. | **0 of 49 SoftPaqs matched**; no drivers staged, despite the "driver staging complete" note | Server-side `-Category Driver` |
| `$_.Category -in 'BIOS','Firmware'`: BIOS category is `BIOS - System Firmware` | BIOS SoftPaq missed; only the model-specific Samsung SSD firmware staged | Server-side `-Category BIOS, Firmware` |
| Separate `Get-HPBIOSUpdates -Download` `.bin` | Redundant copy of what the BIOS SoftPaq already contains | Removed; BIOS SoftPaq extracted with its flasher |
| Firmware `.exe` downloaded but never extracted, no install command | No repeatable way to apply; BitLocker would block silent flash (`290`) | Extract, record CVA silent command/return codes; HP's `-b` switch suspends BitLocker |
| Name regex (`Wolf`, `Sure`, `Diagnostic`…) on a driver-only list | Dead patterns; the only live hit was Hotkey | Short, commented, per-model exclude list |
| `DPB -eq 'true'` string compare on a `[bool]` | Worked only by PowerShell coercion | Boolean test |
| Hard-coded `24H2` with no check | Silent breakage when the catalog changes | Validated against `-OSList`; newest release by default |
| Corrupted syntax (`\vert{}` for `\|`, merged lines, missing spaces in `Join-Path$BasePath`) | Script would not parse | Rewritten |
| "Intel ME firmware binaries" and "AX200/AC9560" in the notes | No ME firmware SoftPaq exists in the 8549 Win11 catalog; the WLAN driver is a single Intel package | Rely on `manifest.json` for what is actually staged |
