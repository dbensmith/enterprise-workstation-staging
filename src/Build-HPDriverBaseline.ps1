#Requires -Version 5.1

<#
.SYNOPSIS
Build a repeatable HP driver + firmware baseline package from the HP SoftPaq catalog.

.DESCRIPTION
One catalog query per stage, filtered by a per-model profile (profiles\*.psd1):
  Drivers  - DPB-eligible 'Driver - *' SoftPaqs, extracted to INF folders (New-HPBuildDriverPack).
  Firmware - 'BIOS' and 'Firmware' SoftPaqs, downloaded, signature-checked, extracted, with
             their CVA silent-install command and return codes recorded in manifest.json.
The package also gets Install-HPDriverBaseline.ps1, which applies it online (pnputil + firmware)
or offline (DISM /Add-Driver into a mounted image). Re-running refreshes the package in place.

.PARAMETER ProfilePath
Per-model profile (.psd1) with Name, Platform, Os, OsVer, DriverExclude, FirmwareExclude.

.PARAMETER OutputRoot
Parent folder for packages; each lands in <OutputRoot>\<Platform>-<os>-<release>.

.PARAMETER OsVer
Overrides the profile's OsVer. Must be a release HP indexes for the platform.

.PARAMETER Stage
Drivers, Firmware, or both (default). A partial run keeps the other stage's manifest entries.

.EXAMPLE
.\Build-HPDriverBaseline.ps1
Build the EliteBook 840 G6 baseline against HP's newest indexed Windows 11 release.

.EXAMPLE
.\Build-HPDriverBaseline.ps1 -OsVer 24H2 -Stage Firmware -WhatIf
Show what the firmware stage would download for a pinned 24H2 catalog.

.OUTPUTS
None. Writes the package folder and an Included/Excluded summary to the information stream.

.NOTES
Requires admin (except with -WhatIf) and HPCMSL, which is installed from the PowerShell Gallery if missing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ProfilePath = (Join-Path $PSScriptRoot 'profiles\hp-elitebook-840-g6.psd1'),

    [string]$OutputRoot = 'C:\HP_Staging',

    [string]$OsVer,

    [ValidateSet('Drivers', 'Firmware')]
    [string[]]$Stage = @('Drivers', 'Firmware')
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'HPDriverBaseline.psm1') -Force

function Initialize-HPCMSL {
    if (Get-Module -ListAvailable -Name HPCMSL) {
        Import-Module HPCMSL
        return
    }

    Write-Information 'Installing HPCMSL from the PowerShell Gallery...'
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # Windows PowerShell 5.1 defaults to TLS 1.0/1.1, which the Gallery rejects.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
    $install = @{ Name = 'HPCMSL'; Scope = 'AllUsers'; Force = $true }
    # -AcceptLicense only exists in PowerShellGet 2.x+; inbox 1.0.0.1 on 5.1 lacks it.
    if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) { $install.AcceptLicense = $true }
    Install-Module @install
    Import-Module HPCMSL
}

function Reset-Directory {
    # Empty a stage's output so SoftPaqs superseded since the last build don't linger.
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Recreate empty directory')) { return }
    if (Test-Path $Path) { Remove-Item -Path $Path -Recurse -Force }
    $null = New-Item -Path $Path -ItemType Directory -Force
}

function Select-SoftpaqSummary {
    process { [pscustomobject]@{ Id = $_.id; Name = $_.Name; Version = $_.Version; Category = $_.Category; ReleaseDate = $_.ReleaseDate } }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# New-HPBuildDriverPack and SoftPaq self-extraction both require elevation. -WhatIf only reads the catalog.
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Run from an elevated PowerShell session (or add -WhatIf to preview the selection).'
}

$baseline = Import-PowerShellDataFile -Path $ProfilePath
Initialize-HPCMSL

$requestedOsVer = if ($OsVer) { $OsVer } else { $baseline.OsVer }
$osRelease = Select-OsRelease -OsList (Get-HPDeviceDetails -Platform $baseline.Platform -OSList) -Os $baseline.Os -OsVer $requestedOsVer
Write-Information "$($baseline.Name) [$($baseline.Platform)]: building against HP catalog $($baseline.Os) $osRelease"

$packageDir = Join-Path $OutputRoot ('{0}-{1}-{2}' -f $baseline.Platform, $baseline.Os, $osRelease)
$manifestPath = Join-Path $packageDir 'manifest.json'
$query = @{ Platform = $baseline.Platform; Os = $baseline.Os; OsVer = $osRelease; Quiet = $true }

# Carry forward sections for stages not run this time, so a partial rebuild keeps a complete manifest.
$previous = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw | ConvertFrom-Json }
$manifest = [ordered]@{
    Profile   = $baseline.Name
    Platform  = $baseline.Platform
    Os        = $baseline.Os
    OsVer     = $osRelease
    BuiltUtc  = (Get-Date).ToUniversalTime().ToString('o')
    HPCMSL    = (Get-Module HPCMSL).Version.ToString()
    Drivers   = @($previous.Drivers | Where-Object { $_ })
    Firmware  = @($previous.Firmware | Where-Object { $_ })
    Excluded  = @($previous.Excluded | Where-Object { $_ -and $_.Stage -notin $Stage })
}

if ('Drivers' -in $Stage) {
    $selection = Select-BaselineSoftpaq -Softpaq @(Get-HPSoftpaqList @query -Category Driver) -Exclude $baseline.DriverExclude -RequireDriverPack
    if (-not $selection.Included) { throw 'Driver selection is empty; check the profile excludes and catalog.' }
    $manifest.Drivers = @($selection.Included | Select-SoftpaqSummary)
    $manifest.Excluded += @($selection.Excluded | Select-Object *, @{ n = 'Stage'; e = { 'Drivers' } })

    $driverDir = Join-Path $packageDir 'Drivers'
    Reset-Directory $driverDir
    if ($PSCmdlet.ShouldProcess($driverDir, "Build driver pack from $($selection.Included.Count) SoftPaqs")) {
        # The pack lands in <Path>\<Name>, so build into the package root to get <package>\Drivers.
        # HPCMSL's own "JSON is truncated" warning here is harmless: it's its internal Drivers\manifest.json.
        $null = $selection.Included | New-HPBuildDriverPack -Path $packageDir -Name 'Drivers' -Format NoCompressedFile -Os $baseline.Os -OSVer $osRelease -Overwrite
    }
}

if ('Firmware' -in $Stage) {
    $selection = Select-BaselineSoftpaq -Softpaq @(Get-HPSoftpaqList @query -Category BIOS, Firmware) -Exclude $baseline.FirmwareExclude
    $manifest.Excluded += @($selection.Excluded | Select-Object *, @{ n = 'Stage'; e = { 'Firmware' } })

    $firmwareDir = Join-Path $packageDir 'Firmware'
    Reset-Directory $firmwareDir

    $manifest.Firmware = @(foreach ($sp in $selection.Included) {
            $number = $sp.id -replace '^sp', ''
            $extractDir = Join-Path $firmwareDir $sp.id
            if ($PSCmdlet.ShouldProcess($sp.id, "Download + extract '$($sp.Name)' $($sp.Version)")) {
                # With -DestinationPath, HPCMSL also saves the .exe there (it joins -SaveAs onto it), so no -SaveAs.
                Get-HPSoftpaq -Number $number -Overwrite yes -Quiet -Extract -DestinationPath $extractDir
            }

            $meta = Get-HPSoftpaqMetadata -Number $number
            $silent = $meta.'Install Execution'.SilentInstall
            $entry = $sp | Select-SoftpaqSummary
            $entry | Add-Member -NotePropertyMembers ([ordered]@{
                    Path           = "Firmware/$($sp.id)"
                    # Only HP's SSM-flagged (silent-supported) SoftPaqs are auto-applied; others are staged for a technician.
                    AutoInstall    = [bool]($sp.SSM -and $silent)
                    SilentInstall  = $(if ($silent) { Split-SoftpaqCommand $silent })  # $() so Windows PowerShell 5.1 parses it
                    RebootRequired = $meta.General.SystemMustBeRebooted -eq '1'
                    # CVA [Devices] hardware IDs (e.g. a specific SSD model); the installer skips the item when none is present.
                    Devices        = @($meta.Devices.Keys | Where-Object { $_ -ne '_body' })
                    ReturnCodes    = ConvertTo-ReturnCodeMap $meta.ReturnCode
                })
            $entry
        })
}

if ($PSCmdlet.ShouldProcess($packageDir, 'Write manifest.json and Install-HPDriverBaseline.ps1')) {
    $null = New-Item -Path $packageDir -ItemType Directory -Force
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8
    Copy-Item -Path (Join-Path $PSScriptRoot 'Install-HPDriverBaseline.ps1') -Destination $packageDir -Force
}

Write-Information "`nIncluded:"
@($manifest.Drivers) + @($manifest.Firmware) | Format-Table Id, Category, Version, Name -AutoSize | Out-String | Write-Information
Write-Information 'Excluded:'
$manifest.Excluded | Format-Table Stage, Id, Name, Reason -AutoSize | Out-String | Write-Information
Write-Information "Package: $packageDir"
