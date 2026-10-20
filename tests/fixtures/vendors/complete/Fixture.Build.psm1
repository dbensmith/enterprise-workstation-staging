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
        # A run-time image: tests never commit a .bin, they let this operation write one into TestDrive.
        $imageBytes = [Text.Encoding]::ASCII.GetBytes('fixture bios ' + $ModelProfile.ModelId)
        [IO.File]::WriteAllBytes((Join-Path $firmwareDir ($ModelProfile.BiosFamily + '_000100.bin')), $imageBytes)
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

function Get-FixtureKitFirmwareStickLayout {
    <#
    .SYNOPSIS
    Fixture stand-in for the GetFirmwareStickLayout operation.

    .DESCRIPTION
    Reads the firmware package the fixture GetFirmware operation wrote and the fixture layout, and returns the
    vendor result contract: one entry per file the layout asks this vendor for. It only reads.

    .PARAMETER ModelProfile
    Model profile object.

    .PARAMETER PackagePath
    The package folder the GetFirmware operation returned.

    .PARAMETER LayoutPath
    Layout file to use. Empty means the fixture layout under tests\fixtures\firmware.

    .EXAMPLE
    Get-FixtureKitFirmwareStickLayout -ModelProfile $modelProfile -PackagePath $package.PackagePath

    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [Parameter(Mandatory)][string]$PackagePath,
        [AllowEmptyString()][string]$LayoutPath
    )
    if (-not $LayoutPath) {
        $LayoutPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\firmware\fixture.layout.psd1'))
    }
    $layout = Get-KitFirmwareLayout -Path $LayoutPath

    $imageName = $ModelProfile.BiosFamily + '_000100.bin'
    $packageDir = Join-Path $PackagePath 'Firmware\fx100'
    $imagePath = Join-Path $packageDir $imageName
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw "Fixture BIOS image $imageName was not found under $packageDir; run the firmware stage first."
    }
    $platformId = [string]$ModelProfile.Platform
    $imageHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA384).Hash.ToLowerInvariant()

    $newEntry = {
        param([string]$RelativePath, [string]$SourcePath, [string]$GroupId, [bool]$WithVendorHash)
        $vendorHash = $null
        if ($WithVendorHash) {
            $vendorHash = [pscustomobject]@{ Algorithm = 'SHA384'; Value = $imageHash; Source = 'fixture catalog' }
        }
        [pscustomobject]@{
            RelativePath = $RelativePath
            SourcePath   = $SourcePath
            Group        = $GroupId
            Size         = ([IO.FileInfo]$SourcePath).Length
            Sha256       = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
            VendorHash   = $vendorHash
        }
    }

    $entries = foreach ($group in $layout.Groups) {
        $folder = $group.Folder.Replace('{Platform}', $platformId)
        switch ($group.SourceKind) {
            'BiosImage' { & $newEntry "$folder\$imageName" $imagePath $group.Id $true }
            'FlashImage' { & $newEntry "$folder\firmware.bin" $imagePath $group.Id $true }
            'WindowsFlashTool' {
                $root = (Resolve-Path -LiteralPath $packageDir).ProviderPath
                foreach ($file in (Get-ChildItem -LiteralPath $packageDir -Recurse -File | Sort-Object -Property FullName)) {
                    $relative = $file.FullName.Substring($root.Length).TrimStart('\')
                    & $newEntry "$folder\$relative" $file.FullName $group.Id $false
                }
            }
            'Captured' { }
            default { throw "Layout group $($group.Id) uses source kind $($group.SourceKind), which the fixture vendor cannot resolve." }
        }
    }

    [pscustomobject]@{
        PSTypeName       = 'Kit.FirmwareStickLayout'
        Operation        = 'GetFirmwareStickLayout'
        Vendor           = 'Fixture'
        LayoutPath       = $layout.Path
        ModelId          = $ModelProfile.ModelId
        Name             = $ModelProfile.Name
        PlatformId       = $platformId
        PlatformVerified = [bool]$ModelProfile.PlatformVerified
        BiosFamily       = $ModelProfile.BiosFamily
        LatestBios       = [pscustomobject]@{ Version = '01.00.00'; Date = '2026-01-01'; PackageId = 'fx100'; File = $imageName; DependencyMinimum = '' }
        WindowsFlash     = [pscustomobject]@{
            Path          = "firmware\fx\$platformId"
            SilentInstall = 'fx.exe /s'
            ReturnCodes   = [ordered]@{ '0' = 'SUCCESS' }
        }
        Entries          = @($entries)
        Notes            = @()
    }
}

Export-ModuleMember -Function Get-FixtureKitModel, Save-FixtureKitVendorPack, New-FixtureKitCustomPack, Save-FixtureKitFirmware, Get-FixtureKitFirmwareStickLayout
