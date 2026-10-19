#Requires -Version 5.1
<#
.SYNOPSIS
Apply a driver and firmware baseline package to this laptop, whatever the vendor.

.DESCRIPTION
Runs from the kit folder and takes the package as a parameter. Standalone: no vendor build tool is
needed on the laptop. The vendor comes from -Vendor, else the package manifest's Vendor, else the
laptop's manufacturer, and every vendor step runs through the common module's vendor interface.
  Online  (default): stage and install the drivers, then run the auto-install firmware items
                     (BIOS last). Refuses to run on a different platform unless -Force.
  Offline (-OfflineImagePath): inject the drivers into a mounted Windows image. Firmware is skipped;
                     it cannot be serviced offline.
-LogPath keeps a transcript of the whole run, written even when the run fails.
Exit code 0 = all good, 1 = at least one step failed. Reboot after an online run.
The installer never reads the run-time config, so nothing secret can reach the transcript.

.PARAMETER PackagePath
The package root (the folder that holds manifest.json).

.PARAMETER OfflineImagePath
A mounted Windows image folder. When given, drivers are injected into it and firmware is skipped.

.PARAMETER SkipFirmware
Install drivers only.

.PARAMETER Force
Apply even if the board's platform ID does not match the manifest.

.PARAMETER LogPath
Write a transcript of the run to this file (appended).

.PARAMETER Vendor
Vendor name (for example HP). Defaults to the manifest's Vendor, then to the laptop's manufacturer.

.EXAMPLE
.\Install-DriverBaseline.ps1 -PackagePath D:\Packages\hp\840-g6\win11-24H2 -WhatIf
Lists the steps without running them.

.EXAMPLE
.\Install-DriverBaseline.ps1 -PackagePath D:\Packages\hp\840-g6\win11-24H2 -OfflineImagePath C:\Mount\install
Injects the drivers into a mounted image.

.EXAMPLE
.\Install-DriverBaseline.ps1 -PackagePath C:\Kit\package -LogPath C:\Kit\firstboot.log
The first-boot form: install and keep a transcript.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path (Join-Path $_ 'manifest.json') -PathType Leaf })]
    [string]$PackagePath,

    [Alias('Path', 'ImagePath')]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$OfflineImagePath,

    [switch]$SkipFirmware,

    # Apply even if the board's platform ID does not match the manifest.
    [switch]$Force,

    [string]$LogPath,

    [string]$Vendor
)

$ErrorActionPreference = 'Stop'

function Show-InstallMessage {
    # Progress text. Windows PowerShell 5.1 leaves the information stream out of a transcript, so this writes to
    # the host, which the transcript keeps; first-boot logs then show what the run did.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message
    )
    Write-Host $Message
}

# Start-Transcript honours -WhatIf, so a rehearsal would otherwise leave no log.
if ($LogPath) { $null = Start-Transcript -Path $LogPath -Append -WhatIf:$false }
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIfPreference) {
        throw 'Run from an elevated session (Run.cmd elevates for you), or add -WhatIf.'
    }

    Import-Module (Join-Path $PSScriptRoot 'core\Kit.Core.psd1') -Force

    $packageRoot = (Resolve-Path -LiteralPath $PackagePath).ProviderPath
    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Raw | ConvertFrom-Json
    $script:failures = 0

    $kitVendor = if ($Vendor) {
        Get-KitVendor -Name $Vendor
    }
    elseif ($manifest.Vendor) {
        Get-KitVendor -Name $manifest.Vendor
    }
    else {
        Get-KitVendor -Manufacturer (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
    }

    Show-InstallMessage "Baseline: $($manifest.Profile) [$($manifest.Platform)] $($manifest.Os) $($manifest.OsVer), built $($manifest.BuiltUtc) (vendor $($kitVendor.Name))"

    # Preference variables do not reach module functions, so -WhatIf travels in the parameter table.
    $stepParameters = @{ PackagePath = $packageRoot; WhatIf = [bool]$WhatIfPreference }

    if ($OfflineImagePath) {
        $stepParameters.OfflineImagePath = $OfflineImagePath
        try {
            $null = Invoke-KitVendorCommand -Vendor $kitVendor -Operation InstallDrivers -Parameters $stepParameters
        }
        catch {
            Write-Error $_.Exception.Message -ErrorAction Continue
            $script:failures++
        }
        exit [int]($script:failures -gt 0)
    }

    Set-Service winmgmt -StartupType Automatic
    $svc = Get-Service winmgmt -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Start-Service winmgmt
    }

    $identity = Invoke-KitVendorCommand -Vendor $kitVendor -Operation GetDeviceIdentity
    if ($identity.PlatformId -ne $manifest.Platform -and -not $Force) {
        throw "This board is platform '$($identity.PlatformId)'; package targets '$($manifest.Platform)'. Use -Force to override."
    }

    try {
        foreach ($row in @(Invoke-KitVendorCommand -Vendor $kitVendor -Operation InstallDrivers -Parameters $stepParameters)) {
            if ($row.Result -eq 'FAILURE') {
                Write-Error "FAIL $($row.Name): $($row.Detail)" -ErrorAction Continue
                $script:failures++
            }
            else {
                Show-InstallMessage "$($row.Result) $($row.Name): $($row.Detail)"
            }
        }
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        $script:failures++
    }

    if (-not $SkipFirmware) {
        foreach ($row in @(Invoke-KitVendorCommand -Vendor $kitVendor -Operation InstallFirmware -Parameters $stepParameters)) {
            if ($row.Result -eq 'FAILURE') {
                Write-Error "FAIL $($row.Id) $($row.Name): $($row.Detail)" -ErrorAction Continue
                $script:failures++
            }
            else {
                Show-InstallMessage "$($row.Result) $($row.Id) $($row.Name): $($row.Detail)"
            }
        }
    }

    Show-InstallMessage "Done with $script:failures failure(s). Reboot to finish driver and firmware installation."
    exit [int]($script:failures -gt 0)
}
finally {
    if ($LogPath) { $null = Stop-Transcript }
}
