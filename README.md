# Enterprise Workstation Staging

Automation, driver baselining, ISO image engineering, and device audit tooling for enterprise workstations and fleet deployments.

## Overview

This repository provides an automated workflow to stage, deploy, and verify known-good Windows environments across enterprise hardware:

1. **Driver & Firmware Baselining (`src/Build-HPDriverBaseline.ps1`)**: Queries HP's SoftPaq catalog via HPCMSL (HP Client Management Script Library) for target hardware platforms, extracts DCH drivers into INF trees, and stages firmware updates with metadata (`manifest.json`).
2. **Automated ISO Image Engineering (`src/New-HPBaselineIso.ps1`)**: Services a clean Windows installation ISO (WIM/ESD), injects the driver tree offline via DISM, embeds an unattended first-boot baseline installer, and builds a bootable dual BIOS/UEFI UDF ISO using native Windows IMAPI2 (no Windows ADK or `oscdimg` required).
3. **Target Baseline Installer (`src/Install-HPDriverBaseline.ps1`)**: Standalone applier executed either online on target hardware (injects drivers via `pnputil`, checks hardware ID matches, safely suspends BitLocker, flashes BIOS) or offline via DISM.
4. **Post-Imaging Device Audit (`src/Test-DeviceBaseline.ps1`)**: Comprehensive quality-assurance audit tool that verifies hardware specs (serial number, CPU, RAM channel configuration, boot disk, BIOS version), OS edition, Windows digital activation status, and RMM connectivity (Atera agent and Splashtop check-in).

---

## Directory Structure

```text
enterprise-workstation-staging/
├── README.md                                # Repository documentation and usage guide
├── .gitignore                               # Ignores ISOs, WIMs, and staging output
├── docs/                                    # Standard operating procedures and architecture
│   └── hp-elitebook-840-g6-driver-baseline.md
├── src/                                     # Automation scripts, modules, and profiles
│   ├── Build-HPDriverBaseline.ps1           # Builds driver & firmware baseline packages
│   ├── New-HPBaselineIso.ps1                # Rebuilds Windows ISO with injected drivers
│   ├── Install-HPDriverBaseline.ps1         # Standalone baseline applier (online/offline)
│   ├── Test-DeviceBaseline.ps1              # Post-imaging device QA audit script
│   ├── HPDriverBaseline.psm1                # Shared module helpers
│   ├── HPDriverBaseline.Tests.ps1           # Pester test suite
│   └── profiles/                            # Per-platform hardware definitions
│       └── hp-elitebook-840-g6.psd1         # Profile for HP Platform 8549
└── HP_Staging/                              # Local build output (excluded from git)
    ├── <Platform>-<os>-<release>/           # Staged baseline package (Drivers, Firmware, manifest)
    └── <iso-name>_HP<Platform>.iso          # Built ISO
```

---

## Quickstart

### 1. Build a Driver Baseline Package

From an elevated PowerShell session:

```powershell
cd src
# Preview SoftPaq selection
.\Build-HPDriverBaseline.ps1 -WhatIf

# Build baseline to HP_Staging\<platform>-<os>-<release>
.\Build-HPDriverBaseline.ps1 -OutputRoot ..\HP_Staging
```

### 2. Generate a Bootable Windows Installation ISO

```powershell
cd src
$iso = 'D:\Sources\Win11_24H2_English_x64.iso'

.\New-HPBaselineIso.ps1 `
    -IsoPath $iso `
    -PackagePath ..\HP_Staging\8549-win11-24H2 `
    -OutputPath ..\HP_Staging\Win11_24H2_HP8549.iso
```

### 3. Apply Baseline on a Running Workstation

```powershell
cd HP_Staging\8549-win11-24H2
# Verify execution plan
.\Install-HPDriverBaseline.ps1 -WhatIf

# Apply drivers and schedule BIOS update
.\Install-HPDriverBaseline.ps1
```

### 4. Post-Imaging QA Audit

Run on the freshly staged machine:

```powershell
# Run audit as Administrator
.\Test-DeviceBaseline.ps1
```

Or download and run the latest version straight from `main` (the URL tracks the branch, so it always serves the current file), from an elevated PowerShell. This long URL is interim: the bootstrap URL is typed by hand, so a much shorter one is a research priority (see `BOOT-04` in `.planning/REQUIREMENTS.md`):

```powershell
irm https://raw.githubusercontent.com/dbensmith/enterprise-workstation-staging/main/src/Test-DeviceBaseline.ps1 | iex
```

Saving the `.txt`: interactively the script asks where to save (Enter accepts the default: the removable drive it ran from, else the earliest removable letter). Non-interactively it saves to that default without asking. `-OutFile <file or folder>` answers the question up front; with `irm | iex` use `$env:PK_OUTFILE = 'D:\results'` first.
