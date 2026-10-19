# Test fixture: the build-plane half of a complete vendor. Each command echoes its operation and parameters.

function Get-FixtureKitModel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{ Operation = 'ListModels'; ModelId = 'fixture-1' }
}

function Save-FixtureKitVendorPack {
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
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$ModelProfile,
        [Parameter(Mandatory)][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Build custom pack')) {
        [pscustomobject]@{ Operation = 'NewCustomPack'; ModelProfile = $ModelProfile; OsVer = $OsVer; OutputPath = $OutputPath }
    }
}

function Save-FixtureKitFirmware {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$ModelProfile,
        [Parameter(Mandatory)][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )
    [pscustomobject]@{ Operation = 'GetFirmware'; ModelProfile = $ModelProfile; OsVer = $OsVer; OutputPath = $OutputPath }
}

Export-ModuleMember -Function Get-FixtureKitModel, Save-FixtureKitVendorPack, New-FixtureKitCustomPack, Save-FixtureKitFirmware
