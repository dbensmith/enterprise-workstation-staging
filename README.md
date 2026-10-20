# Enterprise Workstation Staging

Stage a driver and firmware baseline for business laptops, put it on a bootable Windows ISO, and audit each unit after it is imaged.

## Start here

Three commands. The first two run on the builder PC from an elevated Command Prompt at the repo root. The third runs on the laptop.

1. Build the driver and firmware package for one model. The output lands in `staging\hp\840-g6\win11-<release>\`. Add `-WhatIf` to preview. Use `-Model 840-g5` for the G5.

   ```text
   Build.cmd -Vendor HP -Model 840-g6
   ```

2. Build a Windows ISO that carries those drivers and installs the rest at first boot.

   ```text
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File builder\iso\New-BaselineIso.ps1 -IsoPath <Windows ISO> -PackagePath staging\hp\840-g6\win11-24H2
   ```

3. On the laptop, copy the `kit\` folder to the Tools stick and run this from the stick. It audits the unit by default. `Run.cmd -Mode Install -PackagePath <package folder>` installs drivers and firmware instead.

   ```text
   Run.cmd
   ```

## Where is everything

`kit/` is what travels. It is copied verbatim to the Tools stick and parts of it go into the ISO. `builder/` stays on the PC and is never copied.

```text
Build.cmd                          PC launcher for the package build
Test-Kit.ps1                       the gate: secret scan, lint, tests

kit/                               Tools stick content
kit/Run.cmd, kit/Run.ps1           the laptop's one command (Audit or Install)
kit/Install-DriverBaseline.ps1     vendor-neutral installer
kit/Test-DeviceBaseline.ps1        device audit
kit/config.example.psd1            settings template
kit/core/                          common module (Kit.Core)
kit/vendors/hp/                    HP target module and descriptor
kit/vendors/hp/layouts/            HP Tools stick layout and diagnostics snapshot
kit/profiles/hp/                   per-model profiles (840-g5, 840-g6)
kit/apps/                          third-party installer packages

builder/                           PC only, never copied
builder/Build-DriverBaseline.ps1   vendor-neutral package build
builder/Build-ToolsStick.ps1       Tools stick firmware build (BIOS, diagnostics, flash tool)
builder/iso/New-BaselineIso.ps1    ISO builder
builder/vendors/hp/                HP catalog and download steps

tests/                             Pester suites and fixtures
docs/                              procedures
docs/firmware-bench-checklist.md   bench steps for FW-06
scripts/cloud-init.sh              sets up a cloud session for development
staging/                           git-ignored output
staging/<vendor>/<model>/<os>-<release>/   Drivers/, Firmware/ and manifest.json only
```

A package holds data only. The installer is not copied into it. One copy lives in `kit/`.

## Tools stick firmware

Stage BIOS images, HP's UEFI diagnostics and the Windows flash tool on the Tools stick, in the folders HP's pre-Windows tools read. Run it on the builder PC from an elevated Command Prompt at the repo root, with a FAT32 stick inserted (replace E:\ with its drive letter).

The first run needs a one-time capture of HP's UEFI diagnostics: follow section 3 of docs/firmware-bench-checklist.md, put the captured tree in staging\hp\captures\diagnostics-sp171653, and add -NewDiagnosticsSnapshot to this first run. It records the snapshot file next to the layout; review it and commit it.

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File builder\Build-ToolsStick.ps1 -Vendor HP -Model 840-g5,840-g6 -TargetPath E:\ -DiagnosticsSource staging\hp\captures\diagnostics-sp171653 -NewDiagnosticsSnapshot
```

Later runs leave -NewDiagnosticsSnapshot off and verify the capture against the committed snapshot; without the capture the build stops red with FW-05:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File builder\Build-ToolsStick.ps1 -Vendor HP -Model 840-g5,840-g6 -TargetPath E:\ -DiagnosticsSource staging\hp\captures\diagnostics-sp171653
```

It checks the stick before downloading, prints green, yellow and red lines, and ends with READY or NOT READY; every red line names the file. To re-check a stick without building, run the script with only -ValidateOnly -TargetPath E:\ . Yellow 'not bench-verified' lines are expected: the layout has not been proven on a real 840 G5 or 840 G6, and requirement FW-06 is deferred because no such hardware is available. The bench steps are optional for anyone who later has the hardware. They, and the one-time capture of HP's diagnostics, are in docs/firmware-bench-checklist.md.

## Settings (third-party installers)

Third-party installers are PSAppDeployToolkit packages, one folder per app under `kit/apps/`. The package layout is in `kit/apps/README.md`. Vendor binaries and download links never go in git.

To set the values the installers need, copy `kit\config.example.psd1` to `kit\config.local.psd1`, next to `Run.cmd`, and fill it in. Git ignores `config.local.psd1`. It is never copied into an image: the ISO builder stages only the files that `Get-KitPublishFile` lists.

## Device audit from the web

From an elevated PowerShell on a networked laptop:

```powershell
irm https://raw.githubusercontent.com/dbensmith/enterprise-workstation-staging/main/kit/Test-DeviceBaseline.ps1 | iex
```

The URL tracks `main`, so it always serves the current file. This long URL is interim: it is typed by hand, so a much shorter one is a research priority (see `BOOT-04` in `.planning/REQUIREMENTS.md`).

The audit moved into `kit/`. The link published before this change no longer works. Replace any saved copy of the old command with the line above.

Saving the `.txt`: interactively the script asks where to save. Enter accepts the default: the removable drive it ran from, else the earliest removable letter. Non-interactively it saves to that default without asking. `-OutFile <file or folder>` answers the question up front. With `irm | iex`, set `$env:PK_OUTFILE = 'D:\results'` first.

## Developing

Windows PowerShell 5.1 only. Once per machine:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -InstallTools
```

Once per clone, because the setting is local and not versioned:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -InstallHook
```

`-InstallHook` sets `core.hooksPath` to `.githooks` for this clone. After that every commit runs the secret scan, the lint and the tests first. Expect a few minutes.

Run `Test-Kit.ps1` for the full gate. Run `Test-Kit.ps1 -ScanHistory` to scan the whole git history for secrets. Lint findings are fixed in the code. Nothing is suppressed.

For a cloud session on Linux, run `bash scripts/cloud-init.sh`. It installs PowerShell 7, the pinned Pester and PSScriptAnalyzer, and gitleaks. `Test-Kit.ps1` itself needs Windows PowerShell 5.1, so in the cloud run Pester and PSScriptAnalyzer directly. The script prints the two commands.

## Old packages

Anything built before this layout under `HP_Staging\` (packages and ISOs) is obsolete. Each of those packages carries its own copy of the old installer, and the first-boot command in the old ISOs cannot bind to its parameters. Do not use them to make sticks. Rebuild with `Build.cmd`. Leave the old folders alone: nothing migrates.
