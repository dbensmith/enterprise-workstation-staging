# Test fixture: the target-plane half of a complete vendor. Each command echoes its operation and parameters.

function Install-FixtureKitDriver {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [string]$OfflineImagePath
    )
    [pscustomobject]@{ Operation = 'InstallDrivers'; PackagePath = $PackagePath; OfflineImagePath = $OfflineImagePath }
}

function Install-FixtureKitFirmware {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath
    )
    [pscustomobject]@{ Operation = 'InstallFirmware'; PackagePath = $PackagePath }
}

function Get-FixtureKitDeviceIdentity {
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
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{ Family = 'F00'; Version = [version]'1.0.0' }
}

Export-ModuleMember -Function Install-FixtureKitDriver, Install-FixtureKitFirmware, Get-FixtureKitDeviceIdentity, Get-FixtureKitInstalledFirmware
