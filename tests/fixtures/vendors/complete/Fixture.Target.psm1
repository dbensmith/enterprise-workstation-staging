# Test fixture: the target-plane half of a complete vendor. Each command echoes its operation and parameters.

function Install-FixtureKitDriver {
    <#
    .SYNOPSIS
    Fixture stand-in for the InstallDrivers operation.
    .PARAMETER PackagePath
    Folder of the driver package.
    .PARAMETER OfflineImagePath
    Offline image to service, if any.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [string]$OfflineImagePath
    )
    [pscustomobject]@{ Operation = 'InstallDrivers'; PackagePath = $PackagePath; OfflineImagePath = $OfflineImagePath }
}

function Install-FixtureKitFirmware {
    <#
    .SYNOPSIS
    Fixture stand-in for the InstallFirmware operation.
    .PARAMETER PackagePath
    Folder of the firmware package.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath
    )
    [pscustomobject]@{ Operation = 'InstallFirmware'; PackagePath = $PackagePath }
}

function Get-FixtureKitDeviceIdentity {
    <#
    .SYNOPSIS
    Fixture stand-in for the GetDeviceIdentity helper.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{
        Vendor       = 'Fixture'
        Manufacturer = 'Fixture Inc'
        Model        = 'Fixture Model'
        PlatformId   = '0000'
        Serial       = 'FIXTURE0001'
        BiosVersion  = 'F00 Ver. 01.00.00'
    }
}

function Get-FixtureKitInstalledFirmware {
    <#
    .SYNOPSIS
    Fixture stand-in for the GetInstalledFirmwareVersion helper.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{ Family = 'F00'; Version = [version]'1.0.0' }
}

Export-ModuleMember -Function Install-FixtureKitDriver, Install-FixtureKitFirmware, Get-FixtureKitDeviceIdentity, Get-FixtureKitInstalledFirmware
