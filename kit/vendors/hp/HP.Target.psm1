#Requires -Version 5.1
# HP target-plane commands. Runs on a stock laptop from the Tools stick or the image: CIM, registry, pnputil.exe, dism.exe and package firmware executables only. Never import HPCMSL here.

Import-Module (Join-Path $PSScriptRoot '..\..\core\Kit.Core.psd1')

function ConvertTo-HPBiosVersion {
    <#
    .SYNOPSIS
    Parse an HP BIOS string into its family and version.

    .DESCRIPTION
    Reads both the SMBIOS form ('R70 Ver. 01.36.00') and the SoftPaq name form
    ('HP BIOS and System Firmware (R70) 1.36.00'). Both give Family 'R70' and Version 1.36.0.
    Text that holds no family and version returns nothing.

    .PARAMETER Text
    The BIOS string to parse. May be empty.

    .EXAMPLE
    ConvertTo-HPBiosVersion 'R70 Ver. 01.36.00'
    Returns Family R70 and Version 1.36.0.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Family (string) and Version (version), or nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text
    )

    if ($Text -cmatch '\b(?<family>[A-Z]\d{2})\b.*?(?<ver>\d{1,2}\.\d{2}\.\d{2})') {
        [pscustomobject]@{
            Family  = $Matches['family']
            Version = [version]$Matches['ver']
        }
    }
}

function Get-HPKitInstalledFirmware {
    <#
    .SYNOPSIS
    Read the installed BIOS family and version of this PC.

    .DESCRIPTION
    Parses Win32_BIOS.SMBIOSBIOSVersion with ConvertTo-HPBiosVersion. Returns nothing when the
    string cannot be parsed.

    .EXAMPLE
    Get-HPKitInstalledFirmware
    Returns Family R70 and Version 1.36.0 on an EliteBook 840 G6 with BIOS R70 Ver. 01.36.00.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Family and Version, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $bios = Get-CimInstance -ClassName Win32_BIOS
    ConvertTo-HPBiosVersion -Text "$($bios.SMBIOSBIOSVersion)"
}

function Get-FirmwareSkipReason {
    <#
    .SYNOPSIS
    Say why a firmware item does not need to run on this PC, or return nothing when it does.

    .DESCRIPTION
    A BIOS item (Category starting with 'BIOS') is skipped when the installed BIOS has the same
    family and a version greater than or equal to the package's. An unparseable or other-family
    installed BIOS never skips: HP's updater decides. An item with a device list is skipped with
    exactly 'no matching device in this PC' when none of its hardware IDs is present. Any other
    item returns nothing without reading CIM.

    .PARAMETER Firmware
    One Firmware entry of the package manifest (Id, Name, Version, Category, Devices).

    .EXAMPLE
    Get-FirmwareSkipReason $manifest.Firmware[0]
    Returns 'BIOS 1.36.0 already current (package 1.36.0)' when the BIOS is up to date.

    .OUTPUTS
    System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][object]$Firmware
    )

    if ($Firmware.Category -like 'BIOS*') {
        $installed = Get-HPKitInstalledFirmware
        $package = ConvertTo-HPBiosVersion -Text "$($Firmware.Name) $($Firmware.Version)"
        if ($installed -and $package -and $installed.Family -ceq $package.Family -and $installed.Version -ge $package.Version) {
            return 'BIOS {0} already current (package {1})' -f $installed.Version, $package.Version
        }
        return
    }

    $devices = @($Firmware.Devices | Where-Object { $_ })
    if ($devices.Count -gt 0) {
        $present = @(Get-CimInstance -ClassName Win32_PnPEntity | ForEach-Object { $_.HardwareID } | Where-Object { $_ })
        $found = $devices | Where-Object { $present -contains $_ }
        if (-not $found) {
            return 'no matching device in this PC'
        }
    }
}

function Get-HPKitDeviceIdentity {
    <#
    .SYNOPSIS
    Describe this laptop: vendor, model, serial, BIOS string and board platform ID.

    .DESCRIPTION
    Reads Win32_ComputerSystem, Win32_BIOS and Win32_BaseBoard. PlatformId is the board product
    (for example 8549), falling back to the registry BaseBoardProduct value when CIM has none.
    Every string is trimmed.

    .EXAMPLE
    Get-HPKitDeviceIdentity
    Returns Vendor HP, Model 'HP EliteBook 840 G6', PlatformId 8549 and the serial number.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Vendor, Manufacturer, Model, PlatformId, Serial, BiosVersion.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue

    $platformId = "$($board.Product)".Trim()
    if (-not $platformId) {
        $platformId = "$(Get-ItemPropertyValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BaseBoardProduct' -ErrorAction SilentlyContinue)".Trim()
    }

    [pscustomobject]@{
        Vendor       = 'HP'
        Manufacturer = "$($system.Manufacturer)".Trim()
        Model        = "$($system.Model)".Trim()
        PlatformId   = $platformId
        Serial       = "$($bios.SerialNumber)".Trim()
        BiosVersion  = "$($bios.SMBIOSBIOSVersion)".Trim()
    }
}

Export-ModuleMember -Function ConvertTo-HPBiosVersion, Get-FirmwareSkipReason, Get-HPKitInstalledFirmware, Get-HPKitDeviceIdentity
