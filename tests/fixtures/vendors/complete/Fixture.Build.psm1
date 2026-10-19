# Test fixture: the build-plane half of a complete vendor. The pack and firmware operations write a tiny package
# under the staging root and return the vendor-neutral build result; the rest echo their operation and parameters.

Import-Module (Join-Path $PSScriptRoot '..\..\..\..\kit\core\Kit.Core.psd1')

function Get-FixtureKitModel {
    <#
    .SYNOPSIS
    Fixture stand-in for the ListModels operation.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{ Operation = 'ListModels'; ModelId = 'fixture-1' }
}

function Save-FixtureKitVendorPack {
    <#
    .SYNOPSIS
    Fixture stand-in for the GetVendorPack operation.
    .PARAMETER ModelProfile
    Model profile object.
    .PARAMETER OsVer
    OS release.
    .PARAMETER OutputPath
    Output folder.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$ModelProfile,
        [Parameter(Mandatory)][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )
    [pscustomobject]@{ Operation = 'GetVendorPack'; ModelProfile = $ModelProfile; OsVer = $OsVer; OutputPath = $OutputPath }
}

function New-FixtureKitCustomPack {
    <#
    .SYNOPSIS
    Fixture stand-in for the NewCustomPack operation.
    .PARAMETER ModelProfile
    Model profile object.
    .PARAMETER OsVer
    OS release.
    .PARAMETER OutputPath
    Output folder.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $osRelease = if ($OsVer) { $OsVer } else { '24H2' }
    $packageDir = Get-KitPackagePath -OutputRoot $OutputPath -Vendor Fixture -ModelId $ModelProfile.ModelId -Os $ModelProfile.Os -OsVer $osRelease
    $driverDir = Join-Path $packageDir 'Drivers'
    if ($PSCmdlet.ShouldProcess($driverDir, 'Write the fixture driver')) {
        $null = New-Item -Path $driverDir -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $driverDir 'fixture.inf') -Value '; fixture driver'
    }
    [pscustomobject]@{
        Operation    = 'NewCustomPack'
        PackagePath  = $packageDir
        OsVer        = $osRelease
        PackKind     = 'custom'
        Drivers      = @([pscustomobject]@{ Id = 'fx001'; Name = 'Fixture driver'; Version = '1.0'; Category = 'Driver - Fixture'; ReleaseDate = '2026-01-01' })
        Excluded     = @()
        ToolVersions = @{ FixtureTool = '1.0' }
    }
}

function Save-FixtureKitFirmware {
    <#
    .SYNOPSIS
    Fixture stand-in for the GetFirmware operation.
    .PARAMETER ModelProfile
    Model profile object.
    .PARAMETER OsVer
    OS release.
    .PARAMETER OutputPath
    Output folder.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $osRelease = if ($OsVer) { $OsVer } else { '24H2' }
    $packageDir = Get-KitPackagePath -OutputRoot $OutputPath -Vendor Fixture -ModelId $ModelProfile.ModelId -Os $ModelProfile.Os -OsVer $osRelease
    $firmwareDir = Join-Path $packageDir 'Firmware\fx100'
    if ($PSCmdlet.ShouldProcess($firmwareDir, 'Write the fixture firmware')) {
        $null = New-Item -Path $firmwareDir -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $firmwareDir 'readme.txt') -Value 'fixture firmware'
    }
    [pscustomobject]@{
        Operation    = 'GetFirmware'
        PackagePath  = $packageDir
        OsVer        = $osRelease
        Firmware     = @([pscustomobject]@{
                Id             = 'fx100'
                Name           = 'Fixture firmware'
                Version        = '1.0'
                Category       = 'Firmware'
                ReleaseDate    = '2026-01-01'
                Path           = 'Firmware/fx100'
                AutoInstall    = $false
                SilentInstall  = $null
                RebootRequired = $false
                Devices        = @()
                ReturnCodes    = [ordered]@{}
            })
        Excluded     = @()
        ToolVersions = @{ FixtureTool = '1.0' }
    }
}

Export-ModuleMember -Function Get-FixtureKitModel, Save-FixtureKitVendorPack, New-FixtureKitCustomPack, Save-FixtureKitFirmware
