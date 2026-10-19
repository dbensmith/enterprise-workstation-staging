#Requires -Version 5.1
<#
.SYNOPSIS
The kit's single entry point on the laptop: audit the unit, or install a baseline package.

.DESCRIPTION
Run it through Run.cmd, which starts Windows PowerShell 5.1 with a process-scope execution policy.
  -Mode Audit    (default) run the device audit and save its result file.
  -Mode Install  apply the package at -PackagePath through the common module and the vendor's module.
The Assess/Deploy menu arrives in a later phase; this script only dispatches on -Mode.

.PARAMETER Mode
Audit or Install.

.PARAMETER PackagePath
The package folder (holds manifest.json). Required for -Mode Install.

.PARAMETER OutFile
Audit only: where to save the result file (a folder gets <serial>.txt inside it).

.PARAMETER Vendor
Install only: vendor name. Defaults to the manifest's Vendor, then to the laptop's manufacturer.

.PARAMETER LogPath
Install only: write a transcript of the install to this file.

.PARAMETER SkipFirmware
Install only: drivers only.

.PARAMETER Force
Install only: apply even if the board's platform ID does not match the package.

.EXAMPLE
.\Run.cmd -Mode Install -PackagePath D:\Packages\hp\840-g6\win11-24H2 -WhatIf
Rehearses an install without changing anything.

.EXAMPLE
.\Run.cmd -Mode Audit -OutFile D:\results
Runs the audit and saves <serial>.txt under D:\results.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit', 'Install')][string]$Mode = 'Audit',
    [string]$PackagePath,
    [string]$OutFile,
    [string]$Vendor,
    [string]$LogPath,
    [switch]$SkipFirmware,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'core\Kit.Core.psd1') -Force

if ($Mode -eq 'Audit') {
    $auditArgs = @{}
    if ($OutFile) { $auditArgs.OutFile = $OutFile }
    & (Join-Path $PSScriptRoot 'Test-DeviceBaseline.ps1') @auditArgs
    exit 0
}

if (-not $PackagePath) {
    throw '-PackagePath is required for -Mode Install.'
}

$installArgs = @{ PackagePath = $PackagePath; WhatIf = [bool]$WhatIfPreference }
if ($Vendor) { $installArgs.Vendor = $Vendor }
if ($LogPath) { $installArgs.LogPath = $LogPath }
if ($SkipFirmware) { $installArgs.SkipFirmware = $true }
if ($Force) { $installArgs.Force = $true }

& (Join-Path $PSScriptRoot 'Install-DriverBaseline.ps1') @installArgs
exit $LASTEXITCODE
