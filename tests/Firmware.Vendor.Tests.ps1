BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    $script:vendorsFolder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\vendors'))
    $script:fixtureLayout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1'))
    $script:m1Path = Join-Path $PSScriptRoot 'fixtures\profiles\fixture\m1.psd1'
    Import-Module (Join-Path $script:vendorsFolder 'complete\Fixture.Build.psm1') -Force

    # The message a script block throws, or $null when it does not throw.
    function Get-ThrownMessage {
        [CmdletBinding()]
        param([Parameter(Mandatory)][scriptblock]$Action)
        try { & $Action } catch { return $_.Exception.Message }
        $null
    }

    function Get-LowerHash {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][ValidateSet('SHA256', 'SHA384')][string]$Algorithm
        )
        (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
    }
}

AfterAll {
    foreach ($module in 'Fixture.Target', 'Fixture.Build') { Remove-Module -Name $module -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-FixtureKitFirmwareStickLayout' {
    BeforeAll {
        $script:m1 = Get-KitProfile -Path $script:m1Path
        $script:root = Join-Path $TestDrive 'fixture-root'
        $script:build = Save-FixtureKitFirmware -ModelProfile $script:m1 -OsVer '24H2' -OutputPath $script:root
        $script:result = Get-FixtureKitFirmwareStickLayout -ModelProfile $script:m1 -PackagePath $script:build.PackagePath
    }

    It 'has GetFirmware write the fake image at run time under Firmware\fx100' {
        $image = Join-Path $script:build.PackagePath 'Firmware\fx100\F00_000100.bin'
        $image | Should -Exist
        [IO.File]::ReadAllText($image) | Should -Be 'fixture bios m1'
    }

    It 'returns the vendor result contract for the model' {
        $script:result.PSObject.TypeNames | Should -Contain 'Kit.FirmwareStickLayout'
        $script:result.Operation | Should -Be 'GetFirmwareStickLayout'
        $script:result.Vendor | Should -Be 'Fixture'
        $script:result.ModelId | Should -Be 'm1'
        $script:result.Name | Should -Be 'Fixture Model 1'
        $script:result.PlatformId | Should -Be '0000'
        $script:result.PlatformVerified | Should -BeTrue
        $script:result.BiosFamily | Should -Be 'F00'
        $script:result.LatestBios.File | Should -Be 'F00_000100.bin'
        $script:result.LatestBios.Version | Should -Be '01.00.00'
        $script:result.LatestBios.PackageId | Should -Be 'fx100'
        $script:result.LayoutPath | Should -Be $script:fixtureLayout
        @($script:result.Notes) | Should -HaveCount 0
    }

    It 'lists entries in layout order with the names the vendor ships and nothing for the captured group' {
        @($script:result.Entries.RelativePath) | Should -Be @(
            'Vendor\BIOS\New\F00_000100.bin'
            'Vendor\BIOS\Current\F00_000100.bin'
            'firmware\fx\0000\F00_000100.bin'
            'firmware\fx\0000\readme.txt'
            'FX\DEVFW\firmware.bin'
        )
        @($script:result.Entries.Group) | Should -Be @('G-New', 'G-Current', 'G-Win', 'G-Win', 'G-Dev')
    }

    It 'points every entry at a real source file with its size and lower case SHA-256' {
        foreach ($entry in $script:result.Entries) {
            $entry.SourcePath | Should -Exist
            $entry.Size | Should -Be ([IO.FileInfo]$entry.SourcePath).Length
            $entry.Sha256 | Should -BeExactly (Get-LowerHash -Path $entry.SourcePath -Algorithm SHA256)
        }
    }

    It 'carries the vendor SHA-384 on the BIOS and flash image entries' {
        $image = Join-Path $script:build.PackagePath 'Firmware\fx100\F00_000100.bin'
        $expected = Get-LowerHash -Path $image -Algorithm SHA384
        foreach ($entry in @($script:result.Entries | Where-Object Group -In 'G-New', 'G-Current', 'G-Dev')) {
            $entry.VendorHash.Algorithm | Should -Be 'SHA384'
            $entry.VendorHash.Value | Should -BeExactly $expected
            $entry.VendorHash.Source | Should -Not -BeNullOrEmpty
        }
    }

    It 'copies the same bytes to firmware.bin for the flash image group' {
        $flash = $script:result.Entries | Where-Object Group -EQ 'G-Dev'
        $new = $script:result.Entries | Where-Object Group -EQ 'G-New'
        $flash.Sha256 | Should -BeExactly $new.Sha256
        $flash.Size | Should -Be $new.Size
    }

    It 'returns the Windows flash block with one success return code' {
        $script:result.WindowsFlash.Path | Should -Be 'firmware\fx\0000'
        $script:result.WindowsFlash.SilentInstall | Should -Be 'fx.exe /s'
        @($script:result.WindowsFlash.ReturnCodes.Keys) | Should -Be @('0')
        $script:result.WindowsFlash.ReturnCodes['0'] | Should -Be 'SUCCESS'
    }

    It 'uses the layout given by -LayoutPath and returns its path' {
        $copy = Join-Path $TestDrive 'copy.layout.psd1'
        Copy-Item -LiteralPath $script:fixtureLayout -Destination $copy
        $other = Get-FixtureKitFirmwareStickLayout -ModelProfile $script:m1 -PackagePath $script:build.PackagePath -LayoutPath $copy
        $other.LayoutPath | Should -Be $copy
        @($other.Entries) | Should -HaveCount 5
    }

    It 'throws a message naming the image when the package holds none' {
        $empty = Join-Path $TestDrive 'empty-package'
        $null = New-Item -Path $empty -ItemType Directory
        $message = Get-ThrownMessage -Action { Get-FixtureKitFirmwareStickLayout -ModelProfile $script:m1 -PackagePath $empty }
        $message | Should -BeLike '*F00_000100.bin*'
    }
}

Describe 'GetFirmwareStickLayout contract entry' {
    BeforeAll {
        $script:contract = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot '..\kit\core\VendorContract.psd1')
        $script:operations = @($script:contract.Operations)
        $script:names = @($script:operations | ForEach-Object { $_.Name })
    }

    It 'holds nine entries' {
        $script:operations | Should -HaveCount 9
    }

    It 'is a Build operation with the three pinned parameters' {
        $entry = $script:operations | Where-Object { $_.Name -eq 'GetFirmwareStickLayout' }
        @($entry) | Should -HaveCount 1
        $entry.Kind | Should -Be 'Operation'
        $entry.Plane | Should -Be 'Build'
        @($entry.Parameters) | Should -Be @('ModelProfile', 'PackagePath', 'LayoutPath')
    }

    It 'sits directly after GetFirmware' {
        $script:names.IndexOf('GetFirmwareStickLayout') | Should -Be ($script:names.IndexOf('GetFirmware') + 1)
    }
}

Describe 'GetFirmwareStickLayout through the vendor dispatcher' {
    BeforeAll {
        $script:fixtureVendor = Get-KitVendor -Name Fixture -VendorRoot $script:vendorsFolder
        $script:dispatchProfile = Get-KitProfile -Path $script:m1Path
    }

    It 'accepts the operation name and reaches the fixture command' {
        $built = Invoke-KitVendorCommand -Vendor $script:fixtureVendor -Operation GetFirmware -Parameters @{
            ModelProfile = $script:dispatchProfile; OsVer = '24H2'; OutputPath = (Join-Path $TestDrive 'dispatch')
        }
        $result = Invoke-KitVendorCommand -Vendor $script:fixtureVendor -Operation GetFirmwareStickLayout -Parameters @{
            ModelProfile = $script:dispatchProfile; PackagePath = $built.PackagePath; LayoutPath = ''
        }
        $result.Operation | Should -Be 'GetFirmwareStickLayout'
        $result.Vendor | Should -Be 'Fixture'
        $result.LayoutPath | Should -Be $script:fixtureLayout
        @($result.Entries) | Should -HaveCount 5
    }
}

Describe 'Vendor descriptors against the nine-entry contract' {
    It 'reports no violation for the complete fixture' {
        @(Test-KitVendorContract -DescriptorPath (Join-Path $script:vendorsFolder 'complete\vendor.psd1')) | Should -HaveCount 0
    }

    It 'reports exactly one violation, MissingOperation InstallDrivers, for the missing-op fixture' {
        $found = @(Test-KitVendorContract -DescriptorPath (Join-Path $script:vendorsFolder 'missing-op\vendor.psd1'))
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'MissingOperation'
        $found[0].Operation | Should -Be 'InstallDrivers'
    }
}
