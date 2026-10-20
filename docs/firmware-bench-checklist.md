# Firmware bench checklist (FW-06)

Optional. Use it only if you have the hardware. This checklist is for anyone who later gets a real HP EliteBook 840 G6 and a real 840 G5. FW-06 is deferred: there is no 840 G5 or 840 G6 available today, and nothing here has been run on a real laptop.

## 1. What this proves and what you need

FW-06 stays open until the Verified blocks below are filled for a real G5 and a real G6.

This checklist proves that HP's pre-Windows menus read the BIOS images and diagnostics from the folders that `builder\Build-ToolsStick.ps1` stages on the Tools stick. Until it is run, every group in the layout is unverified and the build prints a yellow `not bench-verified` line for each one.

You need:

- The builder PC, in an elevated Windows PowerShell 5.1 window.
- A FAT32 USB stick of 8 GB or more, and a second scratch stick for the capture in section 3.
- One real HP EliteBook 840 G6 and one real HP EliteBook 840 G5.
- AC power on the laptop for the whole flash.
- The BIOS setup password, if one is set.

The 840 G6 must already be on BIOS 01.35.02 or later. The staged 01.36.00 image declares that minimum, and flash return code 1602 means the dependency is not satisfied. If the G6 is older, flash 01.35.02 first with HP's Windows tool.

Menu names below come from HP documents and community reports. They may read differently on the unit. Write down what the unit really shows.

## 2. Build the stick

The ordering rule is: format, then capture, then stage. HP's diagnostics installer may rename the volume to HP_TOOLS or format it, so the capture must come before the build writes anything you want to keep.

1. Insert the Tools stick. Check its drive letter in File Explorer. The steps below use `E:`; replace it with the real letter. The next step erases that drive.
2. Format the Tools stick from an elevated prompt:

   ```text
   format E: /FS:FAT32 /V:HP_TOOLS /Q
   ```

3. Do the capture in section 3 on a scratch stick. Do it the first time, and again for each new HP diagnostics release.
4. Run the build command at the repo root:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File builder\Build-ToolsStick.ps1 -Vendor HP -Model 840-g5,840-g6 -TargetPath E:\ -DiagnosticsSource staging\hp\captures\diagnostics-sp171653
   ```

5. The very first run also adds `-NewDiagnosticsSnapshot`. Later runs leave it off.
6. Expect green PASS lines, a yellow `not bench-verified` line per group, and a final READY.
7. If anything is red, the line names the file. Fix it and run again.
8. To re-check any stick without building, run `-ValidateOnly -TargetPath E:\` on its own:

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File builder\Build-ToolsStick.ps1 -ValidateOnly -TargetPath E:\
   ```

9. One stick per model, if you prefer: add `-FlashModel 840-g6` (or `840-g5`). That stages one model plus the DEVFW groups.
10. Eject with Safely Remove Hardware.

## 3. Capture HP's UEFI diagnostics (once per HP release)

1. In a browser, download the HP UEFI diagnostics SoftPaq sp171653 (version 10.8.5.0).
2. Do not extract it with `Get-HPSoftpaq -Extract`. It hung in research.
3. Insert a scratch FAT32 stick. Not the Tools stick.
4. Run the SoftPaq's installer. Choose the USB option. Let it finish.
5. Copy everything from the scratch stick except `System Volume Information` into `staging\hp\captures\diagnostics-sp171653\`. That folder must now contain `EFI\HP\...`.
6. The first time, add `-NewDiagnosticsSnapshot` to the build command in section 2.
7. Review the diff of `kit\vendors\hp\layouts\captures\diagnostics-sp171653.snapshot.psd1` and commit it. Later builds verify against it.
8. When HP publishes a newer diagnostics SoftPaq, update the Captures entry in `kit\vendors\hp\layouts\hp-usb-flash.layout.psd1` (Name, PackageId, Version, Snapshot) and capture again.

## 4. Bench: HP EliteBook 840 G6

Flash only this unit's own family image. Keep the laptop on AC power.

1. Note the BIOS version before: ______
2. Insert the built stick and try each menu in the table. Fill the Result column.

| Menu | What to do | Group expected | Result |
| --- | --- | --- | --- |
| F10 BIOS setup | Update System BIOS, local media. Community reports say Hewlett-Packard\BIOS\New or EFI\HP\BIOS\New | F10-New, F10-New-ESP | |
| F2 System Diagnostics | Firmware Management, BIOS Update, Select BIOS Image to Apply, HP_TOOLS USB drive. Reports say ...\BIOS\Current | Diag-Current, Diag-Current-ESP | |
| Esc menu | Update System and Supported Device Firmware, Using Local Media. Reads HP\DEVFW\firmware.bin, only on a stick built with `-FlashModel` | Esc-DEVFW, Esc-DEVFW-ESP | |
| F2 System Diagnostics | Read the diagnostics version. It must be 10.8.5.0, not the older built-in version | Diag-Tree | |

3. To learn which folder a menu really reads, rename one candidate folder at a time (for example Hewlett-Packard\BIOS\New to New_x), retry the menu, then rename it back. `-ValidateOnly` fails while folders are renamed, so rebuild afterwards.
4. Note whether the picker also listed the 840 G5 image, and whether it refused it.
5. After the flash, read the BIOS version again: ______

## 5. Bench: HP EliteBook 840 G5

Flash only this unit's own family image. Keep the laptop on AC power.

1. Note the BIOS version before: ______
2. Insert the built stick and try each menu in the table. Fill the Result column.

| Menu | What to do | Group expected | Result |
| --- | --- | --- | --- |
| F10 BIOS setup | Update System BIOS, local media. Community reports say Hewlett-Packard\BIOS\New or EFI\HP\BIOS\New | F10-New, F10-New-ESP | |
| F2 System Diagnostics | Firmware Management, BIOS Update, Select BIOS Image to Apply, HP_TOOLS USB drive. Reports say ...\BIOS\Current | Diag-Current, Diag-Current-ESP | |
| Esc menu | Update System and Supported Device Firmware, Using Local Media. Reads HP\DEVFW\firmware.bin, only on a stick built with `-FlashModel` | Esc-DEVFW, Esc-DEVFW-ESP | |
| F2 System Diagnostics | Read the diagnostics version. It must be 10.8.5.0, not the older built-in version | Diag-Tree | |

3. Rename folders one at a time as in section 4 to learn which folder a menu reads.
4. Note whether the picker also listed the 840 G6 image, and whether it refused it.
5. After the flash, read the BIOS version again: ______
6. In Windows, run this and expect 83B2:

   ```text
   (Get-CimInstance Win32_BaseBoard).Product
   ```

7. If it matches, set PlatformVerified to `$true` in `kit\profiles\hp\840-g5.psd1`. Update the `@($false, $true)` expectation in `tests\HP.Build.Tests.ps1` in the same commit.

## 6. Other things to confirm

No automated test covers these. Write down what you see.

1. Both model images are listed, and the wrong family is refused (research assumption A2).
2. Images without signature companions are accepted (A3).
3. HP's installer relabels or reformats the stick (A4). Note what happened on the scratch stick.
4. The extra folders `kit\`, `results\` and `firmware\` do not stop F2 or the pickers (A5). Build once with `-IncludeKit` to test this.
5. A file copied onto the FAT32 stick keeps working (A9).
6. The label HP_TOOLS was set by the build, and `-ValidateOnly` accepts a real FAT32 volume. The offline gate cannot format a volume.
7. HP's own `HpFirmwareUpdRec64.exe -w` output has the same SHA-256 as the staged `firmware.bin`.
8. The Windows fallback in `firmware\hp\<platform>\` runs with the silent command recorded in the manifest.

## 7. Record the result

Each group in `kit\vendors\hp\layouts\hp-usb-flash.layout.psd1` has a Verified block. This is the format:

```powershell
Verified = @{ Status = $true; Model = @('840-g6'); Bios = '01.36.00'; Date = '2026-11-02'; By = 'Benjamin' }
```

1. For each group that worked on a unit, set Status to `$true`.
2. Fill Model (an array of model ids), Bios (the version flashed), Date (yyyy-MM-dd) and By.
3. Edit one block per group.
4. Run the build or `-ValidateOnly` again. The yellow count falls.
5. The manifest `verified` becomes true when every staged group is verified.

## 8. Prune and close

1. Delete the groups that did not work, but only after both models are tested. Remove the whole group block, rebuild, and mark the row removed in Appendix A.
2. FW-06 closes when a real G5 and a real G6 each flashed from the stick through the pre-Windows menu and the Verified blocks are recorded.
3. Then, and only then, tick FW-06 in `.planning/REQUIREMENTS.md`.

## Appendix A. Layout groups

| Group | Folder | Staged by default | Menu to try | Result |
| --- | --- | --- | --- | --- |
| F10-New | Hewlett-Packard\BIOS\New | yes | F10 BIOS setup | |
| F10-New-ESP | EFI\HP\BIOS\New | yes | F10 BIOS setup | |
| Diag-Current | Hewlett-Packard\BIOS\Current | yes | F2 System Diagnostics | |
| Diag-Current-ESP | EFI\HP\BIOS\Current | yes | F2 System Diagnostics | |
| Diag-Tree | EFI\HP | yes | F2 System Diagnostics | |
| Esc-DEVFW | HP\DEVFW | no | Esc menu | |
| Esc-DEVFW-ESP | EFI\HP\DEVFW | no | Esc menu | |
| Win-Fallback | firmware\hp\{Platform} | yes | Windows | |
