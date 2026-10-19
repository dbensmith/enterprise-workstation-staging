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

Export-ModuleMember -Function ConvertTo-HPBiosVersion, Get-HPKitInstalledFirmware
