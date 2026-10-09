# Domain Pitfalls

**Domain:** Windows laptop provisioning toolkit (HP EliteBook 840 G5/G6 first; Dell/Lenovo later), PowerShell 5.1, USB-driven, unreliable shop networks
**Researched:** 2026-10-05
**Overall confidence:** MEDIUM-HIGH. HP flash behaviour is grounded in the HP SoftPaq documentation already staged in this repo (HIGH). Windows setup behaviour is grounded in Microsoft Learn (HIGH). Some HP BIOS menu behaviour and G5-specific facts come from HP community threads and need one hardware test (MEDIUM/LOW, flagged inline).

**Tool-strategy note:** The `research-plan` / `research-store` seam was not run. The environment's safety rules limit shell use to read-only and restrict writes to `.planning/research/`, and the seam writes a temp input file and a cache. Research used WebSearch/WebFetch/Context7/Read/Grep instead. Confidence tags below are assigned by judgement: HIGH = vendor/Microsoft docs or local vendor files, MEDIUM = multiple consistent secondary sources, LOW = single forum/blog.

## Phase Key (suggested; roadmap may rename)

| Tag | Scope |
|-----|-------|
| P1 | Repo foundation: module layout, `.gitignore`, secret scan, runtime config loader |
| P2 | Firmware staging: Tools stick layout and validation (BIOS, UEFI diagnostics, flash tools) |
| P3 | Driver packs and model selection (G5/G6, platform ID, custom packs) |
| P4 | Image build: source ISO, slipstream, ISO output, Install stick |
| P5 | Unattended setup and first-logon orchestration (account, order, reboots, Atera, online check) |
| P6 | Verify, results format |
| P7 | `irm \| iex` web bootstrap and auto-update |
| P8 | Dell/Lenovo vendor modules (later) |

---

## Critical Pitfalls

Mistakes that cause rewrites, bricked or locked laptops, leaked secrets, or silently wrong results.

### Pitfall 1: BIOS files staged for the wrong flash path (the 2026-10-05 incident class)

**What goes wrong:** HP has several different USB-driven flash/recovery entry points, and each one looks in a different folder with different file-name rules. Files placed for one path are invisible to the others. A stick that "has the BIOS on it" still gives "no BIOS file found".

| Entry point | Folder on a FAT/FAT32 partition | File rules | Confidence |
|-------------|--------------------------------|------------|------------|
| Esc Startup Menu > "Update System and Supported Device Firmware", or F10 > Update System BIOS > "...Using Local Media" | `\HP\DEVFW\` or `\EFI\HP\DEVFW\` | file MUST be named exactly `firmware.bin` | HIGH (HP `Bios Flash.htm` in `HP_Staging\...\sp174025`) |
| Crisis recovery (power-on auto-recovery / Win+B) | `\EFI\HP\BIOS\Current\` | the SoftPaq `.bin`; only versions the platform's rollback policy allows | HIGH (same file) |
| Older F10 "Update BIOS Using Local Media" and F2 UEFI Diagnostics firmware management | `\Hewlett-Packard\BIOS\New\` (also seen under `\EFI\HP\BIOS\New\`); `.bin` plus signature (`.sig`/`.s12`); `\Hewlett-Packard\BIOS\Current\` used by the "Create Recovery USB" layout | binary and signature must travel together | MEDIUM (HP community threads, HP support page summaries) |
| Windows fallback (`HpFirmwareUpdRec64.exe`) | `.bin` in the same folder as the exe, or `-f<folder\file>` | exe locates `*.BIN` in its own folder by default | HIGH |

**Why it happens:** The SoftPaq payload is `R70_013600.bin` plus `R70_013600.inf` and the tools. Nothing in it says which of the menu paths wants which layout. Hand-copying to "the BIOS folder" guesses one layout. Also, the HP USB layout is chosen by the BIOS menu the operator happens to open, which on a phone-guided workflow is not controlled.

**Consequences:** Operator loses minutes per unit at the shop; units get purchased with stale BIOS; downstream steps (defaults, UEFI diagnostics) run against the wrong firmware.

**Prevention:**
- Do not hand-author the layout. Generate it with the vendor tool in a sandbox (`HpFirmwareUpdRec64.exe` > "Create Recovery USB flash drive"), diff the result, and treat that output as the golden template the build script reproduces.
- Stage one `firmware.bin` under `\HP\DEVFW\` AND `\EFI\HP\DEVFW\`, plus the `.bin` under `\EFI\HP\BIOS\Current\`, plus the `Hewlett-Packard\BIOS\New\` layout with signatures, so every menu path finds a file. Cheap redundancy beats a per-menu decision on a phone.
- Add a `Test-ToolsStick` validator: asserts every expected path, file name (case-insensitive), SHA-256 against the SoftPaq, FAT32 file system, a single partition, and that no extra BIOS bins sit in a searched folder. Run it as the last step of every build and print green/red.
- Make hardware acceptance the exit criterion: one 840 G5 and one 840 G6 must flash from the stick via the documented menu path before the phase is accepted. Write the operator's exact key sequence into the SOP (Esc, then which menu).
- Record the exact BIOS menu names per BIOS version; HP renames them across generations.

**Detection (warning signs):** "Update BIOS Using Local Media" greyed out or reports no file; the BIOS shows the update menu but lists nothing; HpFirmwareUpdRec returns 260 (no HP_TOOLS/EFI partition) or 9191 (unknown file).

**Phase:** P2 (layout + validator + hardware acceptance).

### Pitfall 2: Two G5/G6 BIOS families on one stick

**What goes wrong:** G6 uses the R70 ROM family (this repo's staged SoftPaq: `R70_013600.bin`, v01.36.00); the 840 G5 uses the Q78 family (HP SoftPaq sp157750, v01.31.00 dated 2025-04-30, "Q78 family ROM", MEDIUM: newer G5 versions may exist). HP's own note: when a SoftPaq supports multiple families the tool "packs both files together when creating BIOS Update USB key, which will not result in a successful update"; you must delete the non-matching `.bin` files. `firmware.bin` can only be one file per folder, so a single static Tools stick cannot serve both models through the `DEVFW` path.

**Why it happens:** "One stick for both models" is a natural requirement, and the folder-per-model layout used for build outputs does not map to what the BIOS searches.

**Consequences:** Wrong-family image rejected (safe, but stalls the flow) or, worse, an assumed-safe path that a tool does not validate. Third-party experience (BIOS Sledgehammer README, MEDIUM) warns that some HP ME updaters do not check model and can brick (five Caps Lock blinks, board replacement). Signed BIOS capsules validate, but do not assume it for every payload type.

**Prevention:**
- Keep per-model folders on the stick (`\Firmware\8549\...`, `\Firmware\83B2\...`) and have the Provisioning script/operator tool "activate" one model by copying the matching file into the BIOS-searched paths (and clearing the other). Because the pre-Windows flash cannot run a script, make the active model a build-time/`Set-ActiveModel` choice and label the stick state in a `ACTIVE_MODEL.txt` and in the volume label.
- Alternative if activation is too error-prone: the Tools stick carries both families under `EFI\HP\BIOS\Current\` only after a hardware test proves the BIOS ignores the non-matching family. HP documents the opposite for the HP tool, so treat as untested until proven.
- Never use any HP ME/Thunderbolt/other firmware updater outside its model-checked SoftPaq silent-install path.

**Detection:** Flash menu offers a version lower than installed; exit 259 from HpFirmwareUpdRec ("family does not match ROM", MEDIUM).

**Phase:** P2 (activation design), P3 (platform-ID selection).

### Pitfall 3: BIOS version and downgrade/rollback rules misread

**What goes wrong:** HP firmware has a "BIOS Rollback Policy" (Unrestricted vs Restricted) and a "Minimum BIOS Version" setting; later BIOS releases tighten this. Community reports (LOW-MEDIUM) say downgrades across a cut line are blocked on G5 (1.15 to 1.14) and G6 (1.05 to 1.04). `Get-HPBIOSUpdates -Offline` requires a BIOS password or payload file for downgrades (HPCMSL docs, HIGH). The crisis-recovery doc states only allowable BIOS versions may be used for recovery if restrictions apply (HIGH).

**Consequences:** A stick holding an older image than the unit has either does nothing, errors "denied by system policy", or loops. Version comparison by string (e.g. `"R70 Ver. 01.13.00"` vs file `01.36.00`) gives wrong answers; BIOS Sledgehammer notes HP version parsing limits (only major.minor in some places).

**Prevention:**
- Define one rule: the toolkit never downgrades. Read installed version from `Win32_BIOS.SMBIOSBIOSVersion` / F10 System Information, parse numerics, compare as `[version]`. If installed >= staged, report "up to date" (green) and skip.
- Treat HpFirmwareUpdRec exit 282 (same version) as success/yellow, never red. Use HP's CVA `[ReturnCode]` map when present (existing `ConvertTo-ReturnCodeMap` already does).
- Keep a per-model `MinimumBiosVersion` for the build; fail the build if the staged file is below it.
- Re-flash after a SoftPaq refresh should be idempotent.

**Detection:** "BIOS update denied by system policy"; exit 282; same version after multiple reboots.

**Phase:** P2 and P6 (verify reads BIOS version).

### Pitfall 4: Used laptops arrive BIOS-password-locked, Sure-Admin-managed, or on low battery

**What goes wrong:** Used business laptops commonly carry a BIOS setup password or HP Sure Admin enrolment. HpFirmwareUpdRec prompts for the password even in silent mode if none is supplied (`-p<file>` needed; HP doc HIGH). F10 and the defaults reset are also blocked. HP BIOS flash also expects AC power (MEDIUM; confirm on G5/G6).

**Consequences:** Unattended flash hangs on a prompt nobody sees (especially inside setup passes). Operator learns at the end of a long sequence. Money spent on a locked unit.

**Prevention:**
- Make "BIOS password set / Sure Admin enabled" an Assess-step check and a stop-or-warn gate before purchase (read via CIM/BCU where available; otherwise ask the operator to try F10 as the first check).
- Every spawned process gets a timeout (`Start-Process -PassThru`, `WaitForExit(ms)`, kill + red result). The current `Install-HPDriverBaseline.ps1` uses `Start-Process -Wait` with no timeout; a password prompt would hang Windows setup silently.
- Check AC power and battery before flashing.

**Detection:** Install script never returns; firmware step shows no exit code; F10 asks for password.

**Phase:** P2, P5.

### Pitfall 5: BIOS defaults reset after flash disturbs Secure Boot, TPM, BitLocker, and boot mode

**What goes wrong:** The mandated order is flash then "reset BIOS to defaults" then UEFI diagnostics then image. Four separate hazards sit in that reset.
1. **Secure Boot certificates.** Resetting restores the firmware's built-in default Secure Boot database. The Microsoft 2011 certificates begin expiring June to October 2026 and devices need the 2023 certificates (Microsoft, HIGH). If Windows media or the diagnostics boot with a 2023-signed boot manager while the reset database only has the 2011 CA, Secure Boot blocks the boot (MEDIUM, multiple sources). Older firmware (the G5 line's last BIOS I could find is 2025) may not include 2023 certificates (LOW; verify). The G6 BIOS history for v01.35.02 says it adds the 2023 certificates and an ownership state: if certificates are added, disabled or cleared, "HP BIOS claims ownership of the policies to prevent Secure Boot changes when the system restarts" (HIGH, local History.txt).
2. **HP April 2026 BIOS incident.** An HP business-PC BIOS update (reported 01.04.05 Rev A) caused BitLocker recovery loops and incomplete 2023 certificate hand-off; HP's guidance was to enable "Enable MS UEFI CA Key", "Microsoft UEFI CA 2023", "Microsoft Option ROM UEFI CA 2023" (MEDIUM; HP acknowledged 2026-05-11). After a defaults reset, those toggles may be off again.
3. **BitLocker/TPM.** BIOS changes alter TPM PCR measurements; BDE seals to them, so recovery is demanded (HP `Bios Flash.htm`, HIGH). Defaults reset is one more PCR change after the flash. "Restore Defaults" is not "Clear TPM", but HP's menu names are close, and clearing the TPM destroys sealed keys.
4. **Boot mode and storage mode.** Defaults can flip boot mode (UEFI vs UEFI-hybrid/CSM), SATA mode, and USB boot options. A dual BIOS/UEFI USB offers both legacy and UEFI entries; picking the legacy entry installs MBR layout and Windows 11 setup refuses or an unattend written for GPT breaks (MEDIUM, domain knowledge). Changing SATA/RAID mode after Windows is installed can cause `INACCESSIBLE_BOOT_DEVICE`.

**Why it happens:** Defaults reset is manual (out of scope to automate), so the result is whatever the operator selected on a small screen, and nothing reads it back.

**Consequences:** Boot failures at the diagnostics or Windows-setup step; later BitLocker recovery prompts on customer units with no recoverable key (blank-password local accounts do not back up keys); wrong boot mode silently installs the wrong layout.

**Prevention:**
- Spell the reset menu path out in the SOP ("Apply Defaults and Exit" on the specific BIOS version; never "Clear TPM" or "Restore Security Settings to Factory Defaults" unless intended).
- After defaults, check and set: UEFI native boot, Secure Boot ON, the three 2023-CA toggles ON, TPM ON. Verify them read-only in the Verify step. Reading HP BIOS settings without installing a module is possible through the `root\HP\InstrumentedBIOS` CIM classes on stock Windows when the HP WMI provider is present (MEDIUM; test on a clean image). Also log `Confirm-SecureBootUEFI`, `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\UEFICA2023Status`, firmware type, and TPM state.
- Do a boot test of the final Install stick on a defaults-reset G5 and G6 with Secure Boot ON. If the build uses the source ISO's boot files, check whether the media's boot manager is 2011- or 2023-signed and whether a matching firmware database exists. The media includes both families of boot files in current releases (MEDIUM; confirm in the 26300 ISO).
- Keep order strict: defaults before imaging; never reset defaults after Windows is installed.

**Detection:** "Secure Boot Violation" at stick boot; only a legacy entry boots; BitLocker recovery screen after first Windows reboot; `UEFICA2023Status` not `Updated`.

**Phase:** P2 (SOP, stick), P4 (boot media check), P6 (verify read-back).

### Pitfall 6: BitLocker suspend scoped or counted wrongly

**What goes wrong:** (a) `Suspend-BitLocker -RebootCount 1` is current practice in `Install-HPDriverBaseline.ps1`. Microsoft's guidance for firmware updates that reboot several times is a count greater than 2 or manual resume (MEDIUM, Microsoft Learn). HP's own doc says the flash can reset several times; a count of 1 can expire before the flash completes. (b) HpFirmwareUpdRec `-b` handles BitLocker with TPM, and the existing code notes silent mode returns 290 while protection is on. (c) Suspension applies per volume: scope it to the Windows system drive only, as PROJECT.md requires; do not suspend or touch data volumes. (d) Suspending protects the next boot only; it does not help after a later firmware change.

**Consequences:** Recovery prompt after flash; or protection left suspended forever on a delivered unit (security regression nobody noticed).

**Prevention:**
- Suspend only `$env:SystemDrive` and capture the key protector info to the result record before suspending (keys are secrets: write to the stick's secure results, never to git).
- Prefer `-b` for HpFirmwareUpdRec so the tool owns suspension; if suspending yourself use a higher RebootCount, and resume explicitly (`Resume-BitLocker`) after the post-flash boot, then verify `ProtectionStatus`.
- Treat "BitLocker already off" as success, not warn.
- Windows 11 24H2+ turns on device encryption by default only for Microsoft/work-account sign-in; local-account setups (this toolkit's flow) are not auto-encrypted and no key is saved (MEDIUM). Verify records encryption state so a unit is never delivered half-encrypted.

**Detection:** Recovery screen after flash; `Get-BitLockerVolume` shows `Suspended` days later.

**Phase:** P2 (Windows fallback), P5, P6.

### Pitfall 7: Image flashes the BIOS itself, breaking the mandated order

**What goes wrong:** In the existing code, `Add-FirstBootRun` copies the baseline `Firmware` folder into the image and the specialize-pass command runs `Install-HPDriverBaseline.ps1`, which runs auto-install firmware (BIOS last) unless `-SkipFirmware` is set. That would flash the BIOS after the defaults reset and after imaging, violating the order and re-triggering PCR changes and a possible BIOS reset while Windows setup is mid-flight.

**Prevention:** The image first-boot must pass `-SkipFirmware` and not carry the firmware folder. Firmware belongs to the Tools stick and the Windows fallback only. Add a Pester test that the generated unattend never invokes firmware.

**Phase:** P4, P5.

### Pitfall 8: Mixing G5 and G6 drivers in one image

**What goes wrong:** HP's driver pack matrix lists the same pack for both 840 G5 and G6 (sp114161 6.00 A1, 2021; HIGH), which makes a "one image for both" idea attractive, but that is an old pack and the real risks are elsewhere.
- Same INF names with different versions, or differently named INFs for the same function, grow the driver store and can pick surprising winners (PnP chooses by rank then date/version, so an older HP INF can outrank a newer inbox/Windows Update driver).
- Software-ish SoftPaqs (hotkeys, control apps) are installers without PnP ranking and do not check hardware unless the CVA does.
- Firmware-class INFs: the staged G6 BIOS INF (`R70_013600.inf`, `Class = Firmware`, `UEFI\RES_{7136F763-...}`) is a Windows capsule update. Bulk `pnputil /add-driver *.inf /subdirs /install` over a tree that contains firmware-class INFs can stage a UEFI capsule flash on next reboot. The current driver tree may include such INFs (for example `FwUpdateDriver.inf`, `FiboConfigSrvEx.inf` for the WWAN modem, ME/Thunderbolt firmware drivers).
- The installer's platform guard (`$board -ne $manifest.Platform` throws unless `-Force`) will reject a combined image on the other model.
- Wi-Fi and storage: the chosen generation's Wi-Fi/Ethernet and any storage (Intel RST/VMD) boot drivers must be present before OOBE or the network screen and disk detection fail.

**Consequences:** Unexpected capsule flash after setup, BitLocker/Secure Boot changes, unexplained driver regressions, doubled image size, first-boot failures on the "other" model.

**Prevention:**
- Choose the pack by platform ID at install time (`Win32_BaseBoard.Product`: 83B2 for G5, 8549 for G6; HIGH for IDs). Keep `Drivers\<platformId>\...` side by side and install only the matching folder; do not feed both to DISM `/Recurse` offline.
- Exclude `Class = Firmware` INFs from the bulk install (filter by INF class, not folder name) and install firmware only via the deliberate firmware step.
- Make the guard accept a set of platform IDs (`Platforms = @('83B2','8549')`) per image, and refuse unknown ones.
- Inject only boot-critical and network drivers into `boot.wim`/`install.wim` offline; stage the rest and install by platform at first logon.
- For the custom pack route, `New-HPDriverPack` filters by `-Platform`, `-Os win10|win11`, `-OSVer`; the HP reference data may not list the newest OS build (26H2/26300), so pin to the newest HP-supported OS version and test (LOW-MEDIUM; use `-WhatIf` to list contents first).
- Prefer per-INF `pnputil` for actionable exit codes (see Pitfall 18).

**Detection:** `pnputil /enum-drivers` shows firmware-class or duplicate providers; device manager yellow bangs on one model only; unexpected reboot flashes.

**Phase:** P3 (selection, class filter), P4 (what goes in the WIM).

### Pitfall 9: Blank-password local account side effects

**What goes wrong:** A blank password is accepted as a trade-off, but the default policy `Accounts: Limit local account use of blank passwords to console logon only` (`HKLM\SYSTEM\CurrentControlSet\Control\Lsa\LimitBlankPasswordUse = 1`) keeps blank-password accounts console-only (Microsoft, HIGH). Consequences:
- No RDP and no network logon (SMB, admin shares, WinRM, PsExec) with that account.
- `runas` fails with 1327 and scheduled tasks configured "Run whether user is logged on or not" fail with 0x8007052F (HIGH/MEDIUM).
- Splashtop with "Require Windows login" cannot authenticate a blank-password account; the usual fixes are disabling that option and using a security code, or setting a password (Splashtop support, MEDIUM).
- Atera's own agent runs as SYSTEM and is unaffected.
- Do not "fix" these by setting `LimitBlankPasswordUse = 0`; that turns the trade-off into network-reachable passwordless admin on delivered laptops.
- Unattend quirk: leaving `<Password><Value>` empty or omitting it can be treated as "not set", and the account is then prompted at OOBE or first logon; the reported working patterns are an explicit empty `<Value></Value>` with `<PlainText>true</PlainText>`, or creating the account outside the unattend and removing the prompt (MEDIUM).
- Policy trap: `net user User ""` fails if `net accounts` minimum password length is above 0 on the base image. `net user User *` prompts and cannot run unattended (as PROJECT.md notes).
- `net user User /logonpasswordchg:no` clears "must change at next logon"; `Set-LocalUser -PasswordNeverExpires` is a different flag (expiry). `net user User /passwordreq:no` marks the password as not required. The "forced password creation at second logon" symptom is the must-change flag or an unset password, so test the candidates on the real 26300 image rather than assuming.
- Autologon: autologon with a blank password works via the `AutoLogon` unattend element but is limited by `LogonCount`; reboots in the first-logon sequence need either a sufficient count or a persistent autologon that is removed at the end (Pitfall 12).
- Windows 11 passwordless-mode and Hello prompts may nag; UAC elevation for a standard (non-admin) blank-password user needs an admin credential prompt that a blank-password admin cannot satisfy (LOW; decide whether `User` is Administrator and test).

**Prevention:**
- Write a post-condition test in Verify: account exists, password blank by `net user User` (or LogonUser test locally), must-change flag off, `LimitBlankPasswordUse = 1` still set, autologon removed (or intentionally kept), min password length 0.
- Run every automated step as SYSTEM (RunOnce/SYSTEM scheduled task) or in the interactive session, never as "User via credentials".
- Document the trade-off in the SOP: reachable only at the console; operator hands over with a note recommending the customer set a password.

**Detection:** First logon shows a "create a password" screen; task scheduler 0x8007052F; Splashtop asks for Windows credentials that cannot be satisfied.

**Phase:** P5 (account mechanism test), P6 (verify).

### Pitfall 10: Unattended first-logon ordering, reboots, and answer-file placement

**What goes wrong:**
- `FirstLogonCommands` run once, at the first logon of the (admin) account. Microsoft's page states the commands now start at the same time and no longer wait for the previous command to finish (HIGH). Order numbers are not a sequencer.
- A reboot mid-sequence means anything not already done never runs again. `SetupComplete.cmd`'s own doc warns "You can't reboot the system and resume running SetupComplete.cmd... this will put the system in a bad state" (HIGH).
- `SetupComplete.cmd` is disabled when the PC has an OEM product key, except on Enterprise/Server (Microsoft, HIGH). Used HP laptops carry firmware OEM keys. The existing code already uses an answer-file specialize command for this reason.
- The specialize pass runs before OOBE, so the Wi-Fi typed at the OOBE network screen is not available there. Offline steps (drivers, account) fit specialize; network-dependent steps cannot.
- Two answer files fight: the repo currently writes `Windows\Panther\unattend.xml` into the image and refuses to overwrite one. Adding a media-root `autounattend.xml` for the `oobeSystem` pass makes Setup pick one by search order (media, then registry/`Panther`) and cache it, so one file silently wins and the other's passes never run (MEDIUM; confirm in `Panther\setupact.log`).
- A media-root answer file with disk configuration wipes disk 0 the moment the stick is booted on any laptop, including a machine you did not intend to image.
- The Wi-Fi password the operator types at OOBE stays on the laptop as a saved WLAN profile (retrievable with `netsh wlan show profile name=... key=clear`). It is "not in the image" but is on every delivered unit.
- An unattended Win11 OOBE that can reach the network may force a Microsoft account screen. `oobe\bypassnro` was removed in newer builds; the unattend answer-file route (LocalAccounts plus `HideOnlineAccountScreens`) remains, but must be tested on build 26300 (MEDIUM).

**Prevention:**
- One answer file, one location, all passes. Put one sequencing `FirstLogonCommand` that starts a single orchestrator script with a state file (`C:\ProgramData\<toolkit>\state.json`: step, attempt, last result). On reboot, resume via an HKLM `RunOnce` entry or a SYSTEM scheduled task at startup (no stored password needed).
- Idempotent steps: each step checks "already done" so a retry after reboot is safe.
- Visible progress: the operator needs to see which step is running on the screen, with green/yellow/red lines, and a hard overall timeout that ends in a red summary rather than a blank wait.
- Confirm-to-wipe before partitioning, or an explicit "WIPE THIS DISK" prompt in the setup flow (keep the unattended part after the confirmation).
- At the end of the run (after Verify), remove the shop WLAN profile (`netsh wlan delete profile name=* ` or the specific SSID) and the autologon, and log both.
- Keep the account password and any tokens out of the unattend; `C:\Windows\Panther\unattend.xml` retains plaintext/base64 values and is not always scrubbed (Microsoft/security write-ups; the cache marks removed data `SENSITIVE_DATA_DELETED` only if processing completes) (MEDIUM).

**Detection:** Steps missing after a reboot; Atera installs ran before network; stuck on "Getting ready"; `setupact.log` shows a different answer file than expected.

**Phase:** P4 (answer-file placement), P5 (orchestrator, resume, cleanup).

### Pitfall 11: Atera MSI started offline blocks the whole chain

**What goes wrong:** Per PROJECT.md the Atera MSI asks for an install token when offline. A silent-install run that hangs on that dialog, or a `msiexec` that returns 1602/1603, freezes or fails first-logon orchestration. Atera also installs prerequisites from the network and expects outbound 443 and 8883 to several Atera, AWS IoT, Azure Blob, and .NET download hosts (Atera support firewall list, MEDIUM; the .NET download hosts are on that list, so an install-time download is inferred).

**Consequences:** Hang with no visible cause; or a half-installed agent that never checks in; operator thinks the unit is fine.

**Prevention:**
- Gate on a real online check (Pitfall 12) with retries and backoff before launching, and never launch the MSI without the gate passing.
- Start with `msiexec /i ... /qn` (no UI), wrap with `Start-Process -PassThru` and a hard timeout (about 10 minutes); on timeout kill `msiexec` and report red "Atera install timed out - run again online".
- Treat `3010`/`1641` as success with reboot pending; `1618` (another install in progress) as retry.
- Verify afterwards: `AteraAgent` service Running AND a check-in signal, not just the service. The existing audit already treats Splashtop appearing as proof of a check-in, which can take minutes: poll with a timeout, make "Splashtop not yet present" yellow, not red.
- The MSI file and its download link (which embed customer/account identifiers) come from the Tools stick or runtime parameter, never the repo.

**Detection:** `msiexec` still running after minutes; token dialog in a hidden session; service installed but no heartbeat.

**Phase:** P5, P6.

### Pitfall 12: "Network connected" is not "internet works"

**What goes wrong:** Windows can show a Wi-Fi link or Ethernet link while behind a captive portal, a filtered shop network, or a wrong clock. NCSI uses a plain-HTTP probe to a Microsoft host precisely so a gateway can intercept it (Microsoft, HIGH), so "connected" proves little about HTTPS reachability. A dead CMOS battery (common on used units) leaves the clock wrong, and TLS certificate validation then fails even though the network is fine (MEDIUM). A captive portal can answer HTTP 200 or 302 to anything.

**Consequences:** Atera install attempted when they cannot succeed; verification marked red for the wrong reason.

**Prevention:**
- Define "online" as: DNS resolves, a TLS handshake succeeds to the specific hosts the next step needs (for Atera at minimum its agent API host), and the response is the expected kind (any real HTTP status from the right host counts; an HTML portal page or a TLS error does not). Test the Atera hosts that the agent actually needs, including 443; optionally test 8883.
- Compare the HTTP `Date` header to the local UTC clock; warn when skew exceeds a few minutes and offer/perform a clock sync (`w32tm /resync`) before TLS-dependent steps; record the skew in the result.
- Always set `[Net.ServicePointManager]::SecurityProtocol` to include TLS 1.2 at script start, and use short timeouts (5 to 10 s) with 3 retries and backoff.
- Put the online check in one function used by every step (Atera, auto-update) and cache the positive result for the shortest sensible window only.

**Detection:** Link shows connected but `Invoke-WebRequest` times out or errors with a TLS/clock message; `Date` header differs by hours or years.

**Phase:** P5 (gate).

### Pitfall 13: Install media size and file-system limits (FAT32 4 GB)

**What goes wrong:** The ISO builder (`New-WindowsInstallIso`) deliberately creates a UDF-only image because `install.wim` exceeds 4 GB (code comment, HIGH). That is fine for an ISO, but the "Install" USB must be FAT32 for HP's UEFI to boot it natively. A file larger than 4 GB cannot be stored on FAT32, so neither the `.iso` itself nor an extracted `sources\install.wim` fits. exFAT/NTFS sticks do not boot natively on stock UEFI firmware (a signed UEFI file-system driver shim such as Rufus' UEFI:NTFS is needed, and Secure Boot trust of that shim is a separate question given the CA transition; LOW).

**Consequences:** The build "works", the stick cannot be made or will not boot; operator discovers at the shop.

**Prevention:**
- Make the Install stick a staged media tree, not a copied ISO file: extract the final ISO to FAT32 and replace `sources\install.wim` with split files `install.swm`, `install2.swm`, ... produced by `DISM /Split-Image /ImageFile:... /SWMFile:...\install.swm /FileSize:3800` (Windows Setup uses split files automatically; MEDIUM-HIGH). Split must run on the final exported WIM; ESD images cannot be split this way, so export WIM, not ESD.
- Keep the UDF ISO as the archival/VM artifact only, and say so in docs.
- Size budget: both models' packs plus split WIM must fit the stick (FAT32 formatting in Windows' UI historically caps at 32 GB, so buy or format accordingly). Keep per-model packs outside `\sources` and in short paths (MAX_PATH of 260 characters applies to `DISM /Add-Driver /Recurse` and Setup; SoftPaq folder trees are deep).
- Validator checks: file system is FAT32, no file over 4 GiB - 1 byte, split WIM parts present, hashes match.
- Re-check `-gitignore` has `*.swm` (it currently does).

**Detection:** Copy error "file too large for the destination"; Setup says it cannot find install image; stick not offered in boot menu.

**Phase:** P4.

### Pitfall 14: Secrets leaking via git history, results, logs, and artifacts

**What goes wrong:** The repository "may be public or shared". Current history is tiny (two commits, no secret patterns found by a read-only `git log -G` scan other than docs text), but the new features add exactly the dangerous items.
- The Atera MSI and its download link, BIOS password `.bin` files from `HpqPswd`, and Wi-Fi details.
- `.gitignore` currently covers `HP_Staging/`, ISOs/WIMs/ESDs/SWMs and logs, but not `*.msi`, `*.bin`, `config*.local.*`, `results/`, `*.json` results, `.env`, `secrets/`, or `Tools/`/`Install/` stick mirror folders.
- Logs and transcripts record command lines (MSI properties, tokens) and the typed Wi-Fi password if it is ever echoed. `firstboot.log` is ignored but a new transcript name may not be.
- Deleting a secret from the repo does not remove it: history, forks, PR diffs, and caches keep it; revoke/rotate first, scrub later (git-filter-repo/BFG after rotation) (MEDIUM, consistent sources).
- Results contain serial numbers and hostnames and may include BitLocker key IDs or recovery keys if careless.

**Prevention:**
- Add a runtime config loader (`config.local.psd1` gitignored, or stick `config\`, or parameters) and a committed `config.example.psd1` with placeholders only.
- Expand `.gitignore` now, before new files exist; add pre-commit and CI secret scan (gitleaks or similar) with a custom rule set for Atera URLs, and the `HpqPswd` password file names; test it with a canary secret.
- Redact in a single logging function; transcripts are off by default or scrub-filtered.
- Never put the BitLocker recovery key in the results schema that syncs; if needed it goes to a local-only file.
- If anything leaks, rotate first (Atera token/link), then rewrite history.

**Detection:** Scanner hit; strings like `integratorLogin`, `AccountId` in diff; unexpected files in `git status`.

**Phase:** P1 (first), then every phase that adds a config value.

### Pitfall 15: `irm | iex` supply chain, truncation, and PowerShell 5.1 specifics

**What goes wrong:**
- Auto-updating from a branch means any push (or account compromise) runs as admin on every laptop. Mutable refs (`main`, tags) can be repointed; commit SHAs cannot (consistent with common supply-chain guidance, MEDIUM). `raw.githubusercontent.com` is CDN-cached for about five minutes, so "I just pushed the fix" is not live yet (MEDIUM).
- A dropped connection can deliver a truncated script; `iex` happily runs the partial text.
- PowerShell 5.1 defaults: older .NET configurations negotiate TLS 1.0/1.1 and fail with "Could not create SSL/TLS secure channel" until `[Net.ServicePointManager]::SecurityProtocol` includes `Tls12` (MEDIUM). Stock Win11 usually works, but set it explicitly and fail clearly. `Build-HPDriverBaseline.ps1` already does; `Test-DeviceBaseline.ps1` does not.
- `iex` of a string has no `$PSScriptRoot`, no `param()` binding, and a UTF-8 BOM or non-ASCII smart quotes/dashes in the file can break parsing in 5.1 depending on how the text is decoded. Keep source ASCII-only.
- Phone workflow: a long `raw.githubusercontent.com/...` URL is miserable to type, and a third-party URL shortener is one more link in the supply chain.
- `Invoke-RestMethod` and `Invoke-WebRequest` on 5.1 need `-UseBasicParsing` for `Invoke-WebRequest` on machines where the IE first-run engine is not configured (stock Windows 11: usually fine but still add it).

**Prevention:**
- The short `irm` line fetches only a small bootstrap that downloads a pinned release (tag pointing at a commit SHA, or a release asset) plus a signed/hashed manifest (SHA-256), verifies hashes, then executes. The bootstrap pins; the manifest is updated by a deliberate release step, not by every push. Branch protection and 2FA on the repo.
- Wrap the script body so it runs only if fully parsed: define `function Main { ... }` and call `Main` as the very last line; a truncated download then defines nothing harmful.
- Use a custom short domain or a GitHub Pages short path under your control for the typed URL, not a public shortener.
- Decide the web-route scope: online-only convenience for Assess/verify; not for flashing or imaging (those must be stick-based and offline-capable).
- Fall back to the stick copy if the web fetch fails; record which version ran in the result.

**Detection:** Different hash than the manifest; syntax error at line 1 with odd characters; works on one laptop and not another (TLS defaults).

**Phase:** P7 (also P1 for the version-stamp convention).

---

## Moderate Pitfalls

### Pitfall 17: USB stick handling (FAT32 is fragile; the HP diagnostics installer erases it)

**What goes wrong:** The HP PC Hardware Diagnostics UEFI USB installer erases the target drive, formats FAT32, and creates the `HP_TOOLS` partition; HP advises against putting other data there because the partition is not backed up (HP support, MEDIUM-HIGH). Build order matters: write diagnostics first, add BIOS images/scripts after, or the build wipes them. FAT32 has no journal, so pulling the stick mid-write corrupts the `results` folder. F2 diagnostics are searched USB first, then the hard drive, then built-in BIOS (HP user guide, MEDIUM), which is how the "latest version from the stick" requirement works, but only if the stick is FAT32 and present at F2.

**Prevention:** Stick builder is order-aware and idempotent; run the HP installer step first, never again on a stick that holds results; call `Write-VolumeCache` after writing results and tell the operator to eject (or accept a "safe to remove" green line); keep results in small per-run files; add a nightly-style integrity check (`chkdsk` is overkill; validate JSON parse on read and quarantine bad files instead of crashing the sync).

**Detection:** `results` files with zero bytes; stick asks to be scanned and fixed.

**Phase:** P2, P6.

### Pitfall 18: Treating harmless exit codes as failures (and vice versa)

**What goes wrong:** Hard-coded `if ($LASTEXITCODE -ne 0)` makes common success paths red; blanket "ignore all" hides real failures. Use one central table.

| Tool | Code | Meaning | Show as |
|------|------|---------|---------|
| robocopy | 0 | nothing to copy | green |
| robocopy | 1, 2, 3 | files copied / extras / both | green |
| robocopy | 4 to 7 | mismatches present (bitmask combos) | yellow |
| robocopy | 8 or more | failures (16 = fatal) | red (use `$LASTEXITCODE`, never `$?`, since success returns 1) |
| pnputil | 0 | ok | green |
| pnputil | 259 | no device matches or better driver already present | green/yellow ("staged, nothing to install") |
| pnputil | 3010 | success, reboot required | yellow ("reboot pending", not failure) |
| pnputil | 1641 | reboot initiated by `/reboot` | yellow |
| DISM / setup tools | 3010 | reboot required | yellow |
| msiexec | 0, 3010, 1641 | ok / reboot / reboot started | green or yellow |
| msiexec | 1618 | another install running | retry, then red |
| msiexec | 1602, 1603 | cancelled / fatal | red |
| HpFirmwareUpdRec | 0, 3010 | ok / pending reboot | green / yellow |
| HpFirmwareUpdRec | 282 | same version already installed (MEDIUM) | green ("up to date") |
| HpFirmwareUpdRec | 290 | BitLocker on in silent mode (existing code note) | yellow, then suspend and retry |
| HpFirmwareUpdRec | 259, 260, 9191 | family mismatch, no HP_TOOLS/EFI partition, unknown file (MEDIUM) | red |
| HP SoftPaq CVA | per `[ReturnCode]` | vendor-declared SUCCESS/FAILURE/CANCEL | use CVA map (already implemented) |

Further points:
- Microsoft says `pnputil /add-driver *.inf /subdirs` returns non-actionable codes and recommends one INF at a time for meaningful return values (HIGH). The existing bulk call also whitelists `-536870365` (0xE0000223, unverified meaning in this research; confirm against `setupapi.dev.log`).
- PS 5.1: with `$ErrorActionPreference = 'Stop'` plus `2>&1`, a native command's stderr lines become terminating errors; run native tools through one wrapper that captures streams and exit code separately.
- `powershell -File x.ps1` returns the script's `exit N`; `-Command` collapses to 0/1.
- Yellow means "do something later" (reboot, retry online); red means "stop and look". Rolling up a run: any red is red; otherwise any yellow is yellow.

**Prevention:** One `Invoke-Tool` wrapper with an `OkCodes`/`WarnCodes` table per tool defined in the vendor module (HP returns different codes than Dell/Lenovo, and per-SoftPaq CVA maps override). Unit-test the table (the repo already has Pester tests for the CVA map).

**Phase:** P1 (wrapper), reused P3 to P6.

### Pitfall 19: Platform detection and the "tolerate non-matching drivers" requirement

**What goes wrong:** The "tolerate drivers that don't match the hardware" requirement is real (bulk pnputil returns 259 and device-specific errors), but treating every error as ignorable hides a genuinely missing Wi-Fi or storage driver. Platform detection by model name is fragile ("EliteBook 840 G5 Healthcare Edition" or regional names); use the board ID.

**Prevention:** Read `Win32_BaseBoard.Product` (fallback to the BIOS registry value, as the existing script does) to select a profile; if unknown, stop with an actionable red message instead of guessing; after drivers install, enumerate devices with problem codes (`Get-PnpDevice -Status Error`) and show them yellow/red by class (network and storage = red; fingerprint/modem = yellow).

**Phase:** P3, P6.

### Pitfall 20: Source ISO selection and image content drift

**What goes wrong:** The base ISO is a specific build (26300.9457, labelled Win11 Pro 26H2). Scanning `src/iso/`, listing and asking confirmation can silently pick the wrong or stale ISO; `Select-InstallImage` edition mismatch; HP driver reference data may lack the OS version, so the pack contains no matching drivers; builds are not reproducible.

**Prevention:** Show build number, edition, SHA-256 and size and require an explicit confirm (flag to skip for CI); write a build manifest (ISO hash, driver SoftPaq list and versions, BIOS versions, toolkit commit) into the image and into every result so a failing unit can be traced to its build; fail the build when driver count for the platform is zero.

**Phase:** P4.

---

## Minor Pitfalls

### Pitfall 21: Console output unreadable on a phone
**What goes wrong:** Wide tables and color-only status wrap badly on a phone terminal/remote view; `Write-Host` is the only place colors work, and tools that color by regex on bracketed tags (as the existing audit does) break when a line contains two tags.
**Prevention:** One status per line, fixed prefix `[OK]`, `[WARN]`, `[FAIL]` with text that does not rely on color, under 60 columns, a one-line summary last.

### Pitfall 22: Auto-update and the repo layout move scripts under running processes
**What goes wrong:** Refactoring into shared plus per-vendor modules breaks relative paths (`$PSScriptRoot`, `Join-Path` assumptions) and the stick copy of scripts, while the `irm` route has no `$PSScriptRoot` at all.
**Prevention:** A single `Get-ToolkitRoot` resolver (USB, repo checkout, or downloaded temp folder), tested in all three contexts, introduced in P1.

### Pitfall 23: Vendor interface designed around HP only
**What goes wrong:** An interface with HP-shaped verbs (SoftPaq, CVA) leaks into shared code; Dell (DCU, Command | Update, DSU) and Lenovo (Update Retriever, Thin Installer) differ in catalog, firmware flash entry points, and exit codes.
**Prevention:** Keep the shared contract to the six verbs in PROJECT.md (list models, fetch vendor pack, build custom pack, fetch firmware, install drivers, install firmware) with returned objects, not strings; vendor-specific exit-code and staging-layout tables live in the module (the pre-Windows flash layout is vendor-specific, which is Pitfall 1 again).
**Phase:** P1, P8.

### Pitfall 24: Assess step touching the unit
**What goes wrong:** "Assess (read-only)" run from a stick on a laptop pre-purchase still leaves traces (logs on disk, USB first-run, results folder writes) and can trigger BitLocker prompts if it reboots.
**Prevention:** Assess writes only to the stick, never reboots, never changes BIOS or Windows state; label the log as read-only.
**Phase:** P6.

---

## Phase-Specific Warnings

| Phase | Likely Pitfall | Mitigation |
|-------|---------------|------------|
| P1 | Secrets committed; `.gitignore` too narrow; ad hoc exit-code handling | Expand `.gitignore` and add secret scan before new files; `Invoke-Tool` wrapper with code tables; `Get-ToolkitRoot` |
| P2 | Wrong BIOS folder or file name; two ROM families; HP diagnostics installer wipes stick | Generate layout from `HpFirmwareUpdRec64` "Create Recovery USB"; validator; per-model activation; real G5+G6 hardware flash test; build order: diagnostics first |
| P2 | Downgrade/rollback/version string compare | Never downgrade; numeric compare; 282 = up to date |
| P3 | G5/G6 mixing; firmware-class INFs in bulk install; OS version missing in HP data | Pick by platform ID; filter `Class = Firmware`; `New-HPDriverPack -WhatIf` first; per-INF pnputil |
| P4 | Installer cannot be FAT32 (WIM over 4 GB); answer-file collisions; Secure Boot boot-manager vs firmware DB | Split WIM to `.swm`; extract to FAT32; one answer file; test boot on defaults-reset G5 and G6 with Secure Boot ON |
| P4/P5 | Image flashes BIOS in specialize pass | `-SkipFirmware`; do not copy Firmware into the image; Pester test |
| P5 | FirstLogonCommands not sequenced or resumable; SetupComplete skipped on OEM key | Single orchestrator with state file; RunOnce/SYSTEM task; idempotent steps |
| P5 | Blank-password side effects | Run as SYSTEM; keep `LimitBlankPasswordUse = 1`; test mechanism on build 26300; Splashtop credential option |
| P5 | Atera started offline; "connected" is not online | Real HTTPS check to Atera hosts, clock-skew check, MSI timeout, retry |
| P5 | Wi-Fi PSK left on delivered unit; autologon left on | Cleanup step; verify removal |
| P6 | BitLocker/Secure Boot state unknown at delivery | Verify reads encryption, Secure Boot, `UEFICA2023Status`, BIOS settings |
| P7 | Branch-tracking auto-update; truncated `iex`; TLS defaults | Pin to release plus hash manifest; `Main` called last; set TLS 1.2; ASCII-only source |

## Research Flags for Roadmap

- P2 needs a hardware test on one 840 G5 and one 840 G6 before the layout is accepted; the exact menu text and which folder each BIOS version reads cannot be settled from documents alone. Find out which menu the five failed units used.
- P4/P5 need a throwaway-VM-plus-real-hardware pass on build 26300: blank-password mechanism, OOBE local-account path, answer-file precedence, Secure Boot boot-manager variant.
- P3 needs a check of what HP's catalog actually offers for `OSVer` 26H2 and for the G5 (Q78) family's latest BIOS and whether it includes the 2023 certificates.
- Other items are standard patterns that do not need separate research (exit-code tables, FAT32 split WIM, TLS 1.2, secret scanning).

## Sources

- Local HP SoftPaq documentation in `HP_Staging\8549-win11-24H2\Firmware\sp174025\` (`Bios Flash.htm`, `HpFirmwareUpdRec.txt`, `History.txt`, `contents.txt`, `R70_013600.inf`): HIGH. Defines DEVFW/firmware.bin and EFI\HP\BIOS\current layouts, BitLocker/PCR guidance, multi-family warning, 2023 certificate ownership state.
- Microsoft Learn: Add a Custom Script to Windows Setup (SetupComplete.cmd disabled with OEM key, no reboot-resume) https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup : HIGH
- Microsoft Learn: FirstLogonCommands (run once, now start concurrently) https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-firstlogoncommands : HIGH
- Microsoft Learn: PnPUtil return values (259, 3010, 1641, per-INF advice) https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-return-values : HIGH
- Microsoft Learn: Accounts: Limit local account use of blank passwords to console logon only https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/accounts-limit-local-account-use-of-blank-passwords-to-console-logon-only : HIGH
- Microsoft Learn: Suspend-BitLocker; Surface firmware/BitLocker guidance (RebootCount > 2 for firmware) https://learn.microsoft.com/en-us/powershell/module/bitlocker/suspend-bitlocker : MEDIUM-HIGH
- Microsoft Learn: Captive portal detection (NCSI uses plain HTTP) https://learn.microsoft.com/en-us/windows-hardware/drivers/mobilebroadband/captive-portals : HIGH
- Microsoft Windows IT Pro blog and support: Secure Boot certificates expire June 2026 https://techcommunity.microsoft.com/blog/windows-itpro-blog/act-now-secure-boot-certificates-expire-in-june-2026/4426856 : HIGH
- HP developer docs via Context7 (HPCMSL `Get-HPBIOSUpdates`, `New-HPDriverPack`) /websites/developers_hp_hp-client-management_doc : HIGH
- HP driver pack matrix (G5 and G6 share sp114161) https://ftp.hp.com/pub/caps-softpaq/cmit/HP_Driverpack_Matrix_x64.html : HIGH
- HP SoftPaq sp157750 (Q78 family, 840 G5 v01.31.00) https://ftp.hp.com/pub/softpaq/sp157501-158000/sp157750.html : HIGH
- HP BIOS April 2026 BitLocker loop: https://www.windowslatest.com/2026/05/26/hp-admits-its-latest-bios-update-is-bricking-windows-11-with-bitlocker-loop-blocking-secure-boot-2023-fix/ and https://www.stellarinfo.com/blog/fix-hp-bios-update-triggers-bitlocker-loop/ : MEDIUM
- HP support: Prepare for new Windows Secure Boot certificates https://support.hp.com/us-en/document/ish_13070353-13070429-16 (fetch timed out; cited via search summary): MEDIUM
- HP community and gists for `Hewlett-Packard\BIOS\New`, `EFI\HP\BIOS\New`, rollback and error 46 (https://h30434.www3.hp.com, https://gist.github.com/eNV25/c8001491dc0440656ff7b0ae18993ba1): MEDIUM-LOW (pages mostly 403 to fetch; used via search summaries)
- System Center Dudes, HpFirmwareUpdRec with SCCM (switches, 282/260/9191, HP_TOOLS) https://www.systemcenterdudes.com/how-to-update-hp-bios-using-latest-hpfirmwareupdrec-with-sccm/ : MEDIUM
- BIOS Sledgehammer README (rollback policy, ME firmware mis-flash warning, exit 3010) https://github.com/texhex/BiosSledgehammer/blob/master/README.md : MEDIUM
- Atera firewall settings and agent requirements https://support.atera.com/hc/en-us/articles/360015461139-Firewall-settings-for-Atera-s-integrations : MEDIUM (token prompt behaviour is as reported in PROJECT.md, not independently confirmed)
- Splashtop support (blank password and Windows login requirement) https://support-splashtopbusiness.splashtop.com/hc/en-us/community/posts/207639043-No-password-on-remote-unit- : MEDIUM
- DISM split-image for FAT32 (Microsoft WinPE single-USB doc, NinjaOne, others) https://learn.microsoft.com/hr-hr/windows-hardware/manufacture/desktop/winpe--use-a-single-usb-key-for-winpe-and-a-wim-file---wim?view=windows-11 : MEDIUM-HIGH
- TLS 1.2 on PowerShell 5.1 and raw.githubusercontent.com caching (community threads): MEDIUM
- Secret removal from git history (rotate first, scrub second): MEDIUM, consistent across sources
- Local repo inspection (`src/Install-HPDriverBaseline.ps1`, `src/New-HPBaselineIso.ps1`, `src/HPDriverBaseline.psm1`, `src/Test-DeviceBaseline.ps1`, `.gitignore`, `git log`): HIGH for what the existing code does
