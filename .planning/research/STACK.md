# Technology Stack

**Project:** Enterprise Workstation Staging (modular, vendor-neutral laptop provisioning; HP first, Dell/Lenovo later)
**Researched:** 2026-10-05
**Scope:** Stack dimension only. The existing `src/` tooling (HPCMSL baseline build, IMAPI2 ISO build, installer, audit, Pester tests) is not re-researched; this file says what to keep, what to add, and what to avoid.
**Overall confidence:** MEDIUM-HIGH. Versions were checked against PowerShell Gallery / vendor pages on 2026-10-05. Items marked "bench-verify" could not be proven from documentation and must be confirmed on a real 840 G5 and 840 G6 before being relied on.

Confidence legend: HIGH = vendor/official doc or file shipped in this repo's `HP_Staging`; MEDIUM = multiple secondary sources agree, or official doc read via search summary; LOW = single source, forum, or inference.

Research method note: the `gsd_run query research-plan` / `research-store` cache seam was not used, because the session's safety rules restrict shell use and writes to this research folder. All findings came from Context7, WebSearch/WebFetch and local file reads. No vendor tool was executed.

---

## Recommended Stack

### Core Runtime and Tooling (build PC and target laptop)

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| Windows PowerShell | 5.1 (inbox) | All scripts, target and builder | Project constraint. Every dependency below was checked for a 5.1 minimum. Do not use PS 7 syntax (`??`, `?:`, `&&`, `ForEach-Object -Parallel`) | HIGH |
| Dism PowerShell module | inbox (System32) | Offline image servicing: `Mount-WindowsImage`, `Add-WindowsDriver -Recurse`, `Dismount-WindowsImage -Save`, `Export-WindowsImage`, `Split-WindowsImage` | Ships with Windows 10/11, loads in 5.1, no ADK. MS support matrix: a Windows 11 host services Windows 11 images | HIGH (matrix), MEDIUM (26200 host servicing a 26300 image is not explicitly documented; bench-verify once) |
| IMAPI2 / IMAPI2FS COM | inbox | Build a dual-boot BIOS+UEFI ISO without `oscdimg`/ADK | Already in `New-HPBaselineIso.ps1`; keep. Use UDF so >4 GB `install.wim` fits in the ISO | HIGH (existing, validated) |
| Pester | **6.2.0** (2026-09-09) | Unit tests, vendor-interface contract tests | Min PS 5.1 on the Gallery page; Pester 6 supports exactly Windows PowerShell 5.1 and PS 7.4+. Classic `Should -Be` still works, so existing `HPDriverBaseline.Tests.ps1` carries over. Removed in v6: `Assert-MockCalled`, `Assert-VerifiableMock`, `-Focus`; `-ForEach @()` now fails discovery. Windows ships Pester 3.4.0, so the builder needs `Install-Module Pester -Force -SkipPublisherCheck`. Builder only, never targets | HIGH |
| PSScriptAnalyzer | 1.25.0 (2026-03-20) | Lint PS 5.1 code (builder/CI) | Min PS 5.1. Fix findings; never suppress rules (user policy) | HIGH |
| gitleaks | **v8.30.1** (2026-03-21) | Secret scanning (pre-commit + CI + one-time history scan) | MIT, single Go binary. v8.30 adds decoding (base64/hex/percent) and archive scanning. Use the 8.19+ command forms `gitleaks git --pre-commit --staged` and `gitleaks git` / `gitleaks dir`; `protect`/`detect` are deprecated | HIGH |
| pre-commit (framework) | current | Run the gitleaks hook locally | Hook: `repo: https://github.com/gitleaks/gitleaks`, `rev: v8.30.1`, `id: gitleaks` | MEDIUM |

### HP Driver and Firmware Tooling (build PC only)

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| HPCMSL (HP Client Management Script Library) | **1.9.0** (2026-08-18) | `Get-HPDeviceDetails`, `Get-HPSoftpaqList`, `Get-HPSoftpaq`, `New-HPDriverPack`, `Get-HPBIOSUpdates` | Min PS 5.1; bundles 15 sub-modules (HP.Softpaq, HP.Firmware, HP.ClientManagement, etc.), all 1.9.0. Install on the builder only (project forbids module installs on targets). Pin `-RequiredVersion` in the build script and record it in the build manifest | HIGH |
| `New-HPDriverPack` | in HPCMSL | Custom pack of each model's latest individual drivers | Syntax: `-Platform <4-hex> -Os win10/win11 -OSVer <e.g. 24H2> -Path <dir> -UnselectList <names/spNNN> -RemoveOlder -Format NoCompressedFile\|ZIP\|WIM -Url -Overwrite -TempDownloadPath -WhatIf`. Needs admin; not supported in ISE. Output = INF driver folders plus `manifest.json` (softpaq numbers). Source: HP HPIA reference files at `https://hpia.hpcloud.hp.com/ref/` with fallback `https://ftp.hp.com/pub/caps-softpaq/cmit/imagepal/ref/` | HIGH |
| `Get-HPSoftpaqList` | in HPCMSL | Enumerate softpaqs per platform for overlap analysis | `-Platform -Os -OsVer -Category -Format json`. Not supported in WinPE | HIGH |
| `Get-HPDeviceDetails` | in HPCMSL | Platform ID to name and back; `-OSList` shows which OS/OSVer values HP supports for the platform | Run `Get-HPDeviceDetails -Platform 8549 -OSList` before choosing `-OSVer`; the docs list values only up to "25H2, etc.", so for a 26H2 base image use the newest value HP actually lists | HIGH (cmdlet), MEDIUM (26H2 value) |
| `Get-HPBIOSUpdates` | in HPCMSL | Latest BIOS version/bin per platform, `-Download`, `-Check` | `-Platform` works for look-up/download. `-Flash` cannot take `-Platform`; requires UEFI boot, 64-bit PS, Windows 10 1709+ | HIGH |
| HP Firmware Pack softpaqs | G6: sp174025 (R70 01.36.00, in `HP_Staging`); G5: sp157750 (Q78 01.31.00, 2025-04-30) | BIOS `.bin` plus Windows flash tool `HpFirmwareUpdRec64.exe` | Source of truth for both the pre-Windows files and the Windows fallback. The G6 package contents are verified from this repo's staged copy | HIGH (G6), MEDIUM (G5 version: HP release page via fetch) |
| HP PC Hardware Diagnostics UEFI | **10.8.4.0**, sp167305 (2025-12-11) | Latest UEFI diagnostics for the Tools stick | Latest found on HP FTP; HP's F2 search order is USB, then hard drive, then BIOS built-in, so the stick copy wins over the older built-in. Re-check for a newer sp at each build | HIGH (version, search order), LOW (exact subfolder tree, see Firmware section) |
| Windows flash tool | `HpFirmwareUpdRec64.exe` (from the firmware softpaq) | Fallback BIOS flash from Windows | Options per HP's own doc: `-f<bin>`, `-p<pwfile>`, `-s` silent, `-b` auto-suspend BitLocker-with-TPM, `-?`. `-r` (no auto-restart) is used by this repo and BiosSledgehammer but is not in the shipped doc; confirm with `-?`. Existing code already handles exit 290 (BitLocker on) | HIGH |

### Unattended Setup and ISO

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| `autounattend.xml` (Microsoft-Windows-Shell-Setup, oobeSystem + specialize) | n/a | Local account `User`, autologon, first-logon launcher | See "Unattended Setup" below | HIGH/MEDIUM per item |
| `FirstLogonCommands` | n/a | Launch the single first-logon orchestrator | Runs after logon, before the desktop, elevated for an admin account, works with OEM keys. **Use this, not SetupComplete.cmd** | HIGH |
| `Split-WindowsImage` | inbox (Dism module) | Split `install.wim` into `.swm` (e.g. `-FileSize 3800`) | Needed only if the Install stick is FAT32 | HIGH |

### Online Gate / Atera

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| `Invoke-WebRequest -UseBasicParsing` plus `System.Net.Sockets.TcpClient` | inbox | Real reachability check for Atera | Atera allow-list is documented (hosts below). `-UseBasicParsing` avoids the IE-engine dependency on a fresh Windows | MEDIUM-HIGH |

---

## Platform IDs and G5/G6 Driver Overlap

**Detect:** the platform ID is the 4-hex `Product` field of `Win32_BaseBoard` (HPCMSL `Get-HPDeviceProductID` is just a wrapper). Use `Get-CimInstance Win32_BaseBoard` on targets so no module is needed (WMIC is being removed from Windows 11 images; do not use it). HIGH.

| Model | Platform ID | BIOS family / latest found | Confidence |
|-------|-------------|----------------------------|------------|
| EliteBook 840 G5 | **83B2** (also maps 846 G5, 850 G5, ZBook 14u/15u G5) | Q78, 01.31.00 (sp157750, 2025-04-30) | MEDIUM (ID from HPCMSL-related search results; confirm with `Get-HPDeviceDetails -Platform 83B2`) |
| EliteBook 840 G6 (and Healthcare Edition) | **8549** (matches `SUBSYS_8549103C` PCI strings on 840 G6 and this repo's profile) | R70, 01.36.00 (staged sp174025) | HIGH for 840 G6; LOW for which sibling G6 models share 8549 |

**What HP publishes:** HP's driver-pack matrix lists no Windows 11 24H2/25H2 entry for either model. The "HP Elite/ZBook 8x0 G6 Driver Pack" is sp114161 v6.00 dated 2021-06-09 (Win10 21H1/20H2/2004; the matrix extends it to Win11 22H2/23H2). The G5 pack is older still. The published packs are 5 or more years stale, which confirms the requirement for a custom pack. HIGH (G6 page fetched); LOW for the exact G5 pack number (the matrix fetch returned identical rows for both models, so treat it as unreliable).

**Overlap approach (do not guess from model names; compute it):**
1. `New-HPDriverPack -Platform 83B2 -Os win11 -OSVer <v> -Path <tmp> -WhatIf` and same for `8549`; or `Get-HPSoftpaqList -Platform ... -Format json`. Capture softpaq number and version per platform.
2. Intersect on softpaq number and version. Identical entries go to `Drivers\common\spNNNNNN\`; platform-only or version-conflicting entries go to `Drivers\<platformId>\spNNNNNN\`.
3. Offline injection (`Add-WindowsDriver -Recurse`) of the union is safe: PnP only binds a driver whose hardware ID matches, so non-matching INFs simply do not install. Do not flatten both platforms into one folder where the same INF name exists in two versions; keep per-platform folders and choose by platform ID at first logon.
4. Online/first-logon: `pnputil /add-driver <folder>\*.inf /subdirs /install` for `common` plus the detected platform's folder; map harmless exit codes (259, 3010) to WARN (existing behavior).
5. Record the softpaq manifest per pack in the build output so a laptop traces to a build.

Expected, not verified: both are 8th-gen Intel U-series business laptops, so chipset/serial-IO/graphics/ME packages should overlap heavily; the Wi-Fi/audio/fingerprint components are the likely differences. Treat as a hypothesis the step-1 diff will confirm or refute. LOW until computed.

---

## Firmware: Exact USB Layouts (the 2026-10-05 incident)

### HP: what is proven vs not

Proven from the HP firmware softpaq's own `Bios Flash.htm` (copyright 2026, in `HP_Staging/.../sp174025`) and `contents.txt`:
- Package contents are `xxx_xxxxxx.bin` (firmware image, here `R70_013600.bin`), `xxx_xxxxxx.inf`, `HpFirmwareUpdRec.exe`/`64.exe`, `BCUsignature32/64.dll`, `HpqPswd*.exe`. For G6 there is no `.sig` file in the package. HIGH.
- **F10 / Esc Startup Menu "Update System and Supported Device Firmware Using Local Media"** reads `HP\DEVFW\` or `EFI\HP\DEVFW\` on USB or HDD, and **the file must be named `firmware.bin`**. If nothing is on USB, it looks on the hard drive. HIGH that the doc says this; **bench-verify that the 2018/2019 R70/Q78 BIOS implements this menu path** (the sentence is written for "HP Business Desktop systems" and the feature may be newer than these laptops).
- **Crisis recovery:** copy the `.bin` to `EFI\HP\BIOS\current` on a FAT/FAT32 partition and power on. `HpFirmwareUpdRec` itself populates this location when a Tools partition or `\EFI` path exists. HIGH.
- Several models support more than one BIOS family. A pack that bundles more than one `.bin` in the staging folder "will not result in a successful update"; delete the non-matching `.bin` files. HIGH. This is the most likely cause class for wrong-file failures.
- Windows flash: run the 64-bit tool next to its `.bin`; `-?` lists options; BitLocker auto-suspend with `-b`. HIGH.

Corroborated by multiple secondary sources (MEDIUM): the classic F10 menu "Update System BIOS > Select BIOS Image to Apply > HP_TOOLS-USB Drive > Hewlett-Packard > BIOS > New > `<family>_<version>.bin`" on EliteBook-era business notebooks; the "Create Recovery USB" option of the HP Windows tool writes `\Hewlett-Packard\BIOS\Current\<bin>` and operators copy it to `\Hewlett-Packard\BIOS\New\`. The volume must be FAT/FAT32. Several forum posts conflict between `Current` and `New`, which is exactly why this must be bench-proven, not assumed.

### Recommended Tools-stick layout (stage a superset, then prove it)

One FAT32 volume, **label `HP_TOOLS`** (the HP diagnostics installer renames the USB partition to `HP_TOOLS`, and the BIOS file picker shows it as `HP_TOOLS-USB Drive`). MEDIUM.

```
HP_TOOLS (FAT32)
\Hewlett-Packard\BIOS\New\Q78_013100.bin          # 840 G5 family file, original name
\Hewlett-Packard\BIOS\New\R70_013600.bin          # 840 G6 family file, original name
\Hewlett-Packard\BIOS\Current\                    # empty by default; crisis-recovery copy target (see below)
\Hewlett-Packard\BIOSUpdate\                      # created by the HP diagnostics/BIOS installer; keep as produced
\Hewlett-Packard\SystemDiags\                     # UEFI diagnostics tree produced by sp167305
\EFI\HP\BIOS\Current\<family bins>                # optional copy for crisis recovery (HP doc path)
\HP\DEVFW\firmware.bin                            # ONE model only ("active model" at build time); DEVFW needs the fixed name
\Firmware\<platformId>\...                        # Windows fallback: HpFirmwareUpdRec64.exe, BCUsignature64.dll, ONE matching .bin/.inf per platform folder
\Scripts\ ...                                     # project scripts, local config, firmware-manifest.json
\results\                                         # per-serial result JSON
```

Rules the builder must enforce (and a post-build "stick doctor" re-checks on any laptop in Assess):
1. Keep the vendor file name inside `BIOS\New` (family-prefixed), so G5 and G6 coexist and the BIOS rejects a wrong-family pick. Use `firmware.bin` only under `HP\DEVFW` (single model), generated for a build-time `-ActiveModel`.
2. Exactly one `.bin` per `Firmware\<platformId>` Windows-fallback folder (the tool picks `*.BIN` in its folder). Choose the family from `Win32_BIOS.SMBIOSBIOSVersion` (starts with `Q78` or `R70`).
3. FAT32 only (not exFAT/NTFS). Format with `format X: /FS:FAT32` for sticks over 32 GB.
4. Write `layout.manifest.json` (path, size, SHA-256) at build time; the doctor verifies hashes and paths and prints green/yellow/red.
5. **Hardware acceptance test before shipping the layout (phase gate):** on one 840 G5 and one 840 G6, prove (a) F10 > Update System BIOS > local media finds each file, (b) the Esc Startup Menu local-media path with `HP\DEVFW\firmware.bin`, (c) crisis recovery from `\EFI\HP\BIOS\Current`. Record which paths worked in `docs/` and delete the paths that do not.

Do not try to script "Create Recovery USB": the shipped tool has no CLI for it (options are only `-f -p -s -b -?`).

### HP UEFI diagnostics on USB (what F2 loads)

- F2 at boot searches **USB flash drive, then hard drive, then BIOS built-in**; if the full UEFI package is not found, the older black-screen built-in appears. HIGH (HP support doc).
- Requires a FAT/FAT32 partition named **`HP_TOOLS` or `EFI`**; installing to USB renames the USB partition to `HP_TOOLS`. HIGH (HP sp release note).
- Tree created on the volume: `\Hewlett-Packard\SystemDiags\` (diagnostics) and `\Hewlett-Packard\BIOSUpdate\`, `\Hewlett-Packard\BIOS\{Current,New,Previous}`; on an internal ESP the same lives at `\EFI\HP\SystemDiags\` (files such as `SystemDiags.efi`, `HpUefiSupport.dll`, `UEFIDefinitions.json`). MEDIUM (secondary sources; exact filenames vary by version). The installer generates files, so copying from a 7-Zip extraction is not reliable.
- This means **diagnostics and BIOS flash share one HP_TOOLS volume with one `Hewlett-Packard` root**, so the two "Tools stick" jobs do not conflict. Extra folders (`Scripts`, `results`) are harmless on the same FAT32 volume.
- Build step: run `sp167305.exe` once against the stick (interactive, operator or bench), snapshot the resulting `Hewlett-Packard\SystemDiags` tree into the layout manifest, and verify the new version shows on F2 on both models. Automating the installer silently is unverified.

### Dell and Lenovo equivalents (deferred modules; research for the interface)

| Vendor | Pre-Windows flash | Windows fallback | Catalog / pack source | Notes | Confidence |
|--------|-------------------|------------------|-----------------------|-------|------------|
| Dell | F12 one-time boot > "BIOS Flash Update" ("BIOS Update" on 2020+ models) > "Flash from file". BIOS `.exe` (e.g. `Latitude_3410_3510.exe`) on a FAT32 USB root; no folder layout; key need not be bootable | Run the same BIOS `.exe` in Windows (suspend BitLocker first); Dell Command \| Update CLI `/applyUpdates -updateType=bios` | `DriverPackCatalog.cab` at `https://downloads.dell.com/catalog/DriverPackCatalog.cab` (signed XML; per pack `format`, `hashMD5`, `path`, `dellVersion`, `type` Win/WinPE, `SupportedSystems` systemID/name, `SupportedOperatingSystems`). Match on SystemName/systemID (systemID is not exposed by WMI) | Dell flashes from the EXE itself, so "wrong folder" cannot occur; the risk is the wrong model's EXE | HIGH (F12 flow, catalog), MEDIUM (CLI) |
| Dell tooling | n/a | Dell Command \| Update **5.7.2** (Sept 2026) requires **.NET Desktop Runtime 10.0.8+**, which is not on stock Windows; keep DCU build-side or use offline catalog (`/configure -catalogLocation=<xml> -allowXML=enable`, then `/applyUpdates`). Dell Client Command Suite = Command \| Update, Configure, Monitor, PowerShell Provider (`DellBIOSProvider` **2.10.2**, 2026-07-14, min PS 3.0) | Prefer DriverPack catalog CABs for the vendor pack; for a "latest individual drivers" custom pack, Dell has no `New-HPDriverPack` equivalent, so use DCU against an offline catalog or per-device DUPs | Custom pack on Dell is materially harder than on HP | MEDIUM |
| Lenovo | ThinkPad BIOS is delivered as a bootable CD ISO (El Torito) that is not directly USB-bootable; converting needs extra tooling (e.g. `geteltorito`, or Lenovo's `mkusbkey.bat` for some packages; FAT32/FAT16 only). No documented folder layout | **WINUPTP.exe** under Windows (`/s` silent, `/r` reboot, `/w` password); ThinkCentre `FLASH.CMD`/`WFlash2.exe` (`/quiet`, `/sccm`); ThinkStation `AFUWINx64.exe`. Copy to local disk first; never flash from a network path | Update Retriever **5.08.03.92** (2026-02-20), Thin Installer (winget shows 1.04.02.0024, likely stale), System Update Suite; catalog `https://download.lenovo.com/cdrt/td/catalogv2.xml` (product Model/Family/OS, machine-type = first 4 chars of `Win32_ComputerSystemProduct.Name`) | For Lenovo the Windows flash is the primary path, the pre-Windows route the fallback | MEDIUM |

Interface implication: `FetchFirmware`/`InstallFirmware` must return a *flash plan* object (method = `PreOsLayout` or `WindowsTool`, files, target paths, validators), because HP needs a multi-path layout, Dell needs a single EXE, and Lenovo needs a Windows tool.

---

## Unattended Setup

### Facts that change the design

1. **`SetupComplete.cmd` is disabled when an OEM product key is used (except Enterprise editions/Windows Server).** MS Learn, "Add a Custom Script to Windows Setup". The base ISO is `...OEMRET...CLIENTPRO` and used business laptops carry OEM firmware keys, so a first-logon launcher in SetupComplete may silently never run. Use `FirstLogonCommands` (the Learn page says unattend-based scripts work with OEM keys). HIGH.
2. `FirstLogonCommands` run after logon and before the desktop, with elevation if the account is an administrator; if the account is not an admin and UAC is on, they may prompt or not run. Current docs say all `SynchronousCommand` entries now start at the same time (order is no longer a barrier). So: **one** command that launches one orchestrator (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\<tool>\FirstLogon.ps1`), and sequence inside the script. HIGH.
3. `SetupComplete.cmd`, when it does run, is SYSTEM, cannot reboot-and-resume, and Setup ignores its exit codes. Not needed here.
4. Wi-Fi: leave the OOBE wireless/network screen visible (do not set `HideWirelessSetupInOOBE`), so the operator types the password there; the profile is created on the target after imaging and never exists in the image. MEDIUM.

### Local account `User`, blank password, no forced change

Root cause (MEDIUM-HIGH): an account created from an answer file without a password gets the standard "must change password at next logon / password expired" state; with Windows' default max password age, an expired blank password also breaks autologon and stops first-logon commands from running (documented in a public provisioning issue where the fix was `net accounts /maxpwage:unlimited` in the **specialize** pass). That is the "forced password creation at second logon".

Recommended layered mechanism (all non-interactive, PS 5.1):

| Step | Pass / when | Command or XML | Why |
|------|-------------|----------------|-----|
| 1 | `oobeSystem`, Shell-Setup `UserAccounts/LocalAccounts` | `<LocalAccount><Name>User</Name><Group>Administrators</Group><Password><Value></Value><PlainText>true</PlainText></Password></LocalAccount>` (group per project decision) | Creates the account with an empty password |
| 2 | `oobeSystem`, `AutoLogon` | `<Enabled>true</Enabled><LogonCount>1</LogonCount><Username>User</Username><Password><Value></Value><PlainText>true</PlainText></Password>` | Auto first logon so `FirstLogonCommands` fire |
| 3 | **`specialize`**, `Microsoft-Windows-Deployment` `RunSynchronousCommand` | `net accounts /maxpwage:unlimited` | Machine-wide: removes expiry before any account exists. The decisive fix |
| 4 | First-logon script (elevated) | `Set-LocalUser -Name User -PasswordNeverExpires $true`; then clear the must-change flag with `$u=[ADSI]'WinNT://./User,user'; $u.PasswordExpired=0; $u.SetInfo()`; belt and braces `net user User /logonpasswordchg:no` and `net user User /passwordreq:no` | `/logonpasswordchg:{yes\|no}` controls "change password at next logon" (default NO). ADSI `PasswordExpired=0` clears pwdLastSet=0 |
| 5 | Verify step | `Get-LocalUser User \| Select PasswordExpires,PasswordRequired,PasswordLastSet`, `[ADSI]...PasswordExpired` | Fails loudly if any of 3/4 did not take; the account state goes into the result JSON |

- `net user User *` prompts and is unusable; `net user User ""` also sets blank non-interactively but is only a fallback if step 1 did not apply the password. Local policy `Minimum password length` must be 0 (default on stock Pro); check, because a non-zero minimum rejects blank.
- Do not use `wmic useraccount ... PasswordExpires=false` from FirstLogonCommands (a Microsoft Q&A thread shows FirstLogon in this pass can execute before the account exists; Microsoft's own answer there is a `secedit` policy import, which is also an acceptable alternative to step 3).
- Accepted trade-off to document in each result: Windows default policy "Accounts: Limit local account use of blank passwords to console logon only" blocks network/RDP logon for blank-password accounts; console, Atera and Splashtop are unaffected. Hello/PIN sign-in is not available for a blank-password account.
- Confidence: step 3 MEDIUM-HIGH (one public incident plus the documented default-expiry mechanism); steps 4-5 MEDIUM (standard APIs, **bench-verify on a Win11 26H2 install: reboot twice and sign in manually**).

### XML hygiene
A bare `--` inside an XML comment makes the whole `autounattend.xml` invalid and Setup silently ignores it (seen in the same public issue). Add a Pester test that loads the file with `[xml]` and validates required nodes.

---

## ISO Build and Install Media (no ADK)

- Keep IMAPI2FS for the ISO artifact (UDF so the large `install.wim` is allowed). Dual boot = two `BootOptions` entries (BIOS: `etfsboot.com`, platform 0x00; UEFI: `efisys.bin`, platform 0xEF), the same structure `oscdimg -bootdata:2#p0,e,b...#pEF,e,b...` produces. Existing code does this; do not rewrite. MEDIUM (existing validated code; details from memory plus oscdimg parity).
- DISM servicing on 5.1 via the inbox Dism module (`Mount-WindowsImage -Path -ImagePath -Index`, `Add-WindowsDriver -Recurse`, `Dismount-WindowsImage -Save`, always in `try/finally` with `-Discard` on failure; stale mounts cause `0xc1420127`). Use a local scratch dir, never a network path. HIGH.
- **Finding for the roadmap:** the Install stick cannot hold the >4 GB ISO file on FAT32, and a UEFI machine will not boot NTFS/exFAT without extra shims. Recommended: the Install stick is **FAT32 with the extracted ISO contents and `install.wim` split by `Split-WindowsImage -FileSize 3800` into `install.swm`/`install2.swm`**, `autounattend.xml` at the stick root (Setup auto-discovers it), plus per-model packs and scripts. Keep the `.iso` as a build artifact on the PC. UEFI-only is sufficient for 840 G5/G6; legacy boot (needs `bootsect`) can be dropped. MEDIUM (design inference from FAT32 limits; bench-verify a Secure Boot boot from the stick).
- Builder-side check: servicing a build-26300 image from a 26200 host. MS' platform matrix says a Windows 11 host services Windows 11 images, but newer-than-host builds are not explicitly covered, so run one mount/inject/dismount smoke test early. MEDIUM.

---

## Atera Online Check (no install token)

Atera documents these outbound requirements: TCP 443 and 8883; hosts by name only (no IPs): `agent-api.atera.com`, `agent-api-v2.atera.com`, `agenthb.atera.com`, `app.atera.com`, `appcdn.atera.com`, `ps.atera.com`, `pubsub.atera.com`, `ps.pndsn.com`, `pubsub.pubnub.com`, `atera.pubnubapi.com`, `builds.dotnet.microsoft.com`, `dotnetcli.azureedge.net`, `download.visualstudio.microsoft.com`, plus several `*.blob.core.windows.net` and `*.servicebus.windows.net` hosts. MEDIUM-HIGH (Atera support page, read through search because direct fetch returned 403).

Recommended gate (all three must pass, bounded retry with backoff, then WARN and defer; never start the MSI):
1. `Invoke-WebRequest -UseBasicParsing https://agent-api.atera.com -TimeoutSec 8`; **any HTTP response, including 4xx, counts as reachable** (HTTP-level failure vs DNS/TLS/timeout failure is what matters).
2. TCP connect to `pubsub.atera.com:8883` with a 5 s timeout via `TcpClient` (shop firewalls often drop 8883 while 443 works).
3. `https://builds.dotnet.microsoft.com` reachable (the agent pulls .NET during install).
Set `[Net.ServicePointManager]::SecurityProtocol = Tls12` explicitly. This also catches captive portals: a portal returns a page for a host that should not answer, so check the response is not a redirect to a different domain. Reuse the same helper (host list as a parameter) for the results store. MEDIUM.

---

## Secrets and Repository Hygiene

| Item | Choice | Notes |
|------|--------|-------|
| Local scanning | pre-commit with `gitleaks` hook at `rev: v8.30.1`; local equivalent `gitleaks git --pre-commit --staged` | Add a project `.gitleaks.toml` (extend defaults) with custom rules: Atera installer URL and `IntegratorLogin`/`CompanyId`/`AccountId` MSI properties, Wi-Fi `<keyMaterial>`, `net user ... <password>` patterns |
| CI | GitHub Actions step that downloads the pinned gitleaks release binary, verifies its checksum, and runs `gitleaks git` | **Do not use `gitleaks/gitleaks-action` for an organization-owned repo**: it needs a license key for organizations (personal accounts are exempt). The CLI is MIT and free. HIGH |
| One-time history scan | `gitleaks git` over full history before the repo is made public or shared | The requirement covers history, not just the working tree. The repo was previously not a git repo (environment now reports git), so the scan is cheap now and expensive later |
| Platform scanning | Enable GitHub secret scanning with push protection if available for the repo tier | Backstop only |
| Ignore list | `.gitignore`: `local.config.psd1`, `*.msi`, `results/`, `HP_Staging/`, `*.iso`, `*.wim`, `*.swm`, `.env*` | Ship `local.config.example.psd1` with placeholders only |
| Lint | PSScriptAnalyzer 1.25.0 in CI; fix findings (no disabling) | Per user policy |

---

## `irm | iex` from GitHub

- Windows PowerShell 5.1 has the `irm` and `iex` aliases. Force TLS 1.2 first. Use `Invoke-RestMethod`, which does not depend on the IE engine; if `Invoke-WebRequest` is ever used on a fresh Windows, add `-UseBasicParsing`. HIGH.
- A short bootstrapper must come from `raw.githubusercontent.com`, which works anonymously only for a **public** repo (a private raw URL needs a token, which violates the no-credentials constraint). The project must therefore decide that the repo is public, or accept stick-only distribution. HIGH.
- Pin to a tag or commit SHA in the URL (`.../<tag>/bootstrap.ps1`), not `main`; raw content is cached by GitHub's CDN for minutes, so a "fix" on `main` is not instantly visible. MEDIUM.
- Bootstrapper behavior: tiny (under ~50 lines), downloads the tagged release zip (`https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.zip`) to `%TEMP%`, verifies a SHA-256 published in the *release notes or a separate signed manifest* (a hash in the same repo adds no trust), extracts, then runs the script from disk. Check for a newer tag via `https://api.github.com/repos/<owner>/<repo>/releases/latest` (unauthenticated limit is about 60 requests/hour per IP, and a shop NAT shares it, so cache the answer and fall back silently to the on-stick copy).
- **Web route may pull:** scripts, modules, vendor-module code, profile `.psd1` files, small manifests. **Must not pull:** drivers, BIOS binaries, ISO, Atera MSI/link (vendor licensing, size, and secrets). HP softpaqs are fetched from HP's own CDN with the SHA-256 in the manifest. MEDIUM.
- AV/EDR may flag a download-and-`iex` cradle; test on a stock Defender-on machine. LOW.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Custom HP driver pack | HPCMSL `New-HPDriverPack` | HP Image Assistant run on each target; manual softpaq assembly | HPIA on targets is a second tool to ship and offline-fragile; HPCMSL builds the same pack once on the builder with a `manifest.json` |
| First-logon launcher | `FirstLogonCommands` (single orchestrator) | `SetupComplete.cmd` | Disabled for OEM keys on non-Enterprise editions |
| ISO build | IMAPI2 (existing) | `oscdimg` (ADK) | ADK excluded by project; IMAPI2 already works |
| Install media | FAT32 stick with split WIM | ISO file on stick; NTFS/exFAT stick | FAT32 4 GB per-file limit; NTFS/exFAT will not UEFI-boot without shims |
| Pester | 6.2.0 | 5.x, inbox 3.4.0 | 6.x supports 5.1 and is current; 3.4.0 is obsolete and conflicts |
| Secret scan CI | gitleaks CLI | `gitleaks-action` | License key needed for organization repos |
| Dell driver source | DriverPackCatalog.cab + vendor packs | DCU on the target | DCU 5.7.2 needs .NET Desktop Runtime 10 not present on stock Windows |
| BIOS reset to defaults | Manual F9/F10 plus WMI verify (out of scope to automate) | HPCMSL `Set-HPBIOSSettingDefaults` on targets | Would need the module on the target; if the user later accepts carrying HPCMSL via `Save-Module` on the Tools stick and `Import-Module` from that path, it is not a module install, but it is a decision to confirm |

## What NOT to Use

- **`SetupComplete.cmd`** as the only post-setup hook (silently skipped with OEM keys).
- **`net user User *`** (interactive) and **`wmic`** (being removed from Windows 11 images; use CIM).
- **`irm https://.../main/... | iex`** unpinned, or from a private repo.
- **`gitleaks-action`** on an organization repo; deprecated `gitleaks detect`/`protect` forms.
- **Installing HPCMSL or Pester on target laptops** (project constraint); builder only.
- **Dell Command | Update on stock targets** (needs .NET Desktop Runtime 10).
- **Flat-copying both G5 and G6 packs into one folder** where INF names collide.
- **Hand-assembling the HP diagnostics tree** from an archive extraction (installer generates files).
- **Staging more than one `.bin` in a single HP Windows-flash folder**, and putting only a `firmware.bin` for one model on a two-model stick without saying which model it is.

## Installation (builder only)

```powershell
# Windows PowerShell 5.1, elevated, on the BUILD PC (never the target laptop)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module HPCMSL -RequiredVersion 1.9.0 -Scope AllUsers -AcceptLicense -Force   # pulls HP.* 1.9.0
Install-Module Pester -RequiredVersion 6.2.0 -Force -SkipPublisherCheck               # replaces inbox 3.4.0 for tests
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force
# Secret scanning: install gitleaks v8.30.1 (release binary) and `pip install pre-commit`
```

(Commands are documentation for the roadmap; none were executed during research.)

## Open Items to Verify on Hardware (feed phase research flags)

1. Which BIOS-from-USB paths the 840 G5 (Q78) and 840 G6 (R70) F10/Esc menus honor: `Hewlett-Packard\BIOS\New`, `HP\DEVFW\firmware.bin`, `EFI\HP\DEVFW`, and crisis `EFI\HP\BIOS\Current`. This is the incident's root question.
2. Exact `sp167305` output tree on a `HP_TOOLS` USB and that F2 shows 10.8.4.0 on both models.
3. G5 vs G6 softpaq diff via `New-HPDriverPack -WhatIf` for `83B2` and `8549`; valid `-OSVer` for a 26H2 image from `Get-HPDeviceDetails -OSList`.
4. Blank-password `User` survives two reboots and manual sign-in on a 26H2 install (steps 3-5 above).
6. Secure Boot boot from a FAT32 split-WIM Install stick; DISM mount of a 26300 image on a 26200 builder.
7. Whether a newer gitleaks or Diagnostics UEFI than the versions above exists at build time (these were the latest found 2026-10-05).

## Sources

HIGH
- HPCMSL 1.9.0, PowerShell Gallery (min PS 5.1; 15 dependent modules): https://www.powershellgallery.com/packages/HPCMSL
- HPCMSL docs via Context7 (`New-HPDriverPack`, `Get-HPSoftpaqList`, `Get-HPDeviceDetails`, `Get-HPDeviceProductID`, `Get-HPBIOSUpdates`, `Get-HPSoftpaq`): https://developers.hp.com/hp-client-management/doc/new-hpdriverpack (HP developer pages return HTTP 403 to direct fetch; read through Context7 `/websites/developers_hp_hp-client-management_doc`)
- HP firmware softpaq docs staged in this repo: `HP_Staging/8549-win11-24H2/Firmware/sp174025/{Bios Flash.htm, HpFirmwareUpdRec.txt, contents.txt, History.txt}`
- HP softpaq pages: https://ftp.hp.com/pub/softpaq/sp167001-167500/sp167305.html (Diagnostics UEFI 10.8.4.0), https://ftp.hp.com/pub/softpaq/sp157501-158000/sp157750.html (Q78 01.31.00), https://ftp.hp.com/pub/softpaq/sp114001-114500/sp114161.html (8x0 G6 driver pack)
- HP driver pack matrix: https://ftp.hp.com/pub/caps-softpaq/cmit/HP_Driverpack_Matrix_x64.html
- Microsoft, Add a Custom Script to Windows Setup (SetupComplete + OEM keys): https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup
- Microsoft, FirstLogonCommands: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-firstlogoncommands
- Microsoft, DISM supported platforms: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-supported-platforms ; Split-WindowsImage: https://learn.microsoft.com/en-us/powershell/module/dism/split-windowsimage
- Pester 6.2.0 and 6.0.0 release notes: https://www.powershellgallery.com/packages/Pester , https://github.com/pester/Pester/releases/tag/6.0.0 ; install notes: https://pester.dev/docs/introduction/installation
- PSScriptAnalyzer 1.25.0: https://www.powershellgallery.com/packages/PSScriptAnalyzer ; DellBIOSProvider 2.10.2: https://www.powershellgallery.com/packages/DellBIOSProvider
- Dell, Driver Pack Catalog: https://www.dell.com/support/kbdoc/en-us/000122176/driver-pack-catalog ; Flashing BIOS from F12: https://www.dell.com/support/kbdoc/en-us/000128928/flashing-the-bios-from-the-f12-one-time-boot-menu
- Lenovo CDRT BIOS deployment guide: https://docs.lenovocdrt.com/ref/bios/bios_guide/
- gitleaks releases: https://github.com/gitleaks/gitleaks/releases

MEDIUM
- HP Hardware Diagnostics UEFI USB/search-order docs and community tree descriptions: https://support.hp.com/us-en/document/ish_2854458-2733239-16 ; https://dvdkon.ggu.cz/blogpost/hp_ex360_bios_update/ ; https://gist.github.com/eNV25/c8001491dc0440656ff7b0ae18993ba1
- HP `Hewlett-Packard\BIOS\New` / `Current` conventions (forum and how-to sources, conflicting on Current vs New): https://www.easeus.com/backup-recovery/hp-bios-update.html ; https://h30434.www3.hp.com/t5/Business-Notebooks/Bios-update-HP-Elitebook-840-G3/td-p/6036736 (403 to fetch; search summary only)
- Atera firewall settings (via search summary; page 403 to fetch): https://support.atera.com/hc/en-us/articles/360015461139-Firewall-settings-for-Atera-s-integrations
- Dell Command | Update 5.x release notes and CLI search results: https://www.dell.com/support/manuals/en-us/command-update/dcu_rn/release-summary?guid=guid-0ff2b3c9-7e82-4561-8e09-4227ce140212&lang=en-us
- Public report of the expired-blank-password / `net accounts /maxpwage:unlimited` in `specialize`: https://github.com/a11ign/a11ign/issues/1933 ; Microsoft Q&A on FirstLogon timing and secedit: https://learn.microsoft.com/en-us/answers/questions/1347161/set-password-never-expires-for-a-local-user-in-the
- gitleaks-action license rule and deprecated commands: https://github.com/gitleaks/gitleaks-action ; https://github.com/Chris-Wolfgang/repo-template/pull/548
- BiosSledgehammer (HpFirmwareUpdRec `-s -r -b -p` usage): https://github.com/texhex/BiosSledgehammer

LOW
- Platform ID 83B2 sibling list, Lenovo Thin Installer version (winget listing), Dell `/s /f` BIOS EXE switches (not verified; omitted from recommendations).
