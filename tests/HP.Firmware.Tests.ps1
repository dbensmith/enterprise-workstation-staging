BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\builder\vendors\hp\HP.Build.psm1') -Force

    $script:hpLayout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\kit\vendors\hp\layouts\hp-usb-flash.layout.psd1'))

    # HPCMSL is not installed on the builder PC and Pester can only mock a command that exists, so the resolver
    # runs against a stand-in module with HP's command and parameter names. The names belong to HPCMSL, so the
    # stand-in is generated from this table instead of being written as functions that the style rules would
    # judge as ours. Each command returns its bound parameters; the tests mock Get-HPBIOSUpdates.
    function Import-HPCMSLStandIn {
        $spec = [ordered]@{
            'Get-HPBIOSUpdates' = 'param($Platform, [switch]$Latest, [switch]$All)'
        }
        $source = foreach ($name in $spec.Keys) {
            "function $name { $($spec[$name]); process { [pscustomobject]`$PSBoundParameters } }"
        }
        $null = New-Module -Name HPCMSL -ScriptBlock ([scriptblock]::Create($source -join "`n")) | Import-Module -Global -Force
    }

    # Write a fake SoftPaq package the way the firmware stage leaves it, with one image made of run-time bytes.
    # Returns the package folder, the image path and the image hashes (upper case, as Get-FileHash writes them).
    function Write-FakeBiosPackage {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$ModelId,
            [Parameter(Mandatory)][string]$OsFolder,
            [Parameter(Mandatory)][string]$SoftPaq,
            [Parameter(Mandatory)][string]$Bin
        )
        $package = Join-Path $Root "hp\$ModelId\$OsFolder"
        $folder = Join-Path $package "Firmware\$SoftPaq"
        $null = New-Item -Path $folder -ItemType Directory -Force
        $image = Join-Path $folder $Bin
        [IO.File]::WriteAllBytes($image, [Text.Encoding]::ASCII.GetBytes("fake bios image $ModelId $Bin"))
        [pscustomobject]@{
            PackagePath = $package
            Image       = $image
            Sha256      = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
            Sha384      = (Get-FileHash -LiteralPath $image -Algorithm SHA384).Hash
        }
    }

    # One Get-HPBIOSUpdates row as HPCMSL 1.9.0 returns it (Ver without the leading zero).
    function Get-FakeCatalogEntry {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Ver,
            [Parameter(Mandatory)][string]$Bin,
            [AllowEmptyString()][string]$Sha384,
            [object]$Date = '2026-06-13'
        )
        [pscustomobject]@{ Ver = $Ver; Date = $Date; Bin = $Bin; Sha384 = $Sha384; RollbackAllowed = $true; Importance = 'Recommended'; Dependency = '' }
    }

    # The message a script block throws, or $null when it does not throw.
    function Get-ThrownMessage {
        [CmdletBinding()]
        param([Parameter(Mandatory)][scriptblock]$Action)
        try { & $Action } catch { return $_.Exception.Message }
        $null
    }
}

Describe 'HP USB flash layout file' {
    BeforeAll {
        $script:layout = Get-KitFirmwareLayout -Path $script:hpLayout
    }

    It 'loads through Get-KitFirmwareLayout with the HP_TOOLS label on FAT32' {
        $script:layout.VolumeLabel | Should -Be 'HP_TOOLS'
        $script:layout.FileSystem | Should -Be 'FAT32'
    }

    It 'has seven groups in candidate order with the source kinds of the research default' {
        @($script:layout.Groups.Id) | Should -Be @('F10-New', 'F10-New-ESP', 'Diag-Current', 'Diag-Current-ESP', 'Diag-Tree', 'Esc-DEVFW', 'Esc-DEVFW-ESP')
        @($script:layout.Groups.Folder) | Should -Be @(
            'Hewlett-Packard\BIOS\New', 'EFI\HP\BIOS\New', 'Hewlett-Packard\BIOS\Current', 'EFI\HP\BIOS\Current'
            'EFI\HP', 'HP\DEVFW', 'EFI\HP\DEVFW'
        )
        @($script:layout.Groups.SourceKind) | Should -Be @('BiosImage', 'BiosImage', 'BiosImage', 'BiosImage', 'Captured', 'FlashImage', 'FlashImage')
        @($script:layout.Groups.Default) | Should -Be @($true, $true, $true, $true, $true, $false, $false)
        @($script:layout.Groups.Closed) | Should -Be @($true, $true, $true, $true, $false, $true, $true)
    }

    It 'gives every group its own Verified block that is not verified' {
        @($script:layout.Groups) | Should -HaveCount 7
        foreach ($group in $script:layout.Groups) {
            $group.Verified.Status | Should -BeFalse
            @($group.Verified.Model) | Should -HaveCount 0
        }
    }

    It 'lists the one diagnostics capture' {
        @($script:layout.Captures) | Should -HaveCount 1
        $script:layout.Captures[0].Name | Should -Be 'diagnostics-sp171653'
        $script:layout.Captures[0].PackageId | Should -Be 'sp171653'
        $script:layout.Captures[0].Version | Should -Be '10.8.5.0'
    }

    It 'is pure ASCII' {
        [IO.File]::ReadAllBytes($script:hpLayout) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty
    }
}

Describe 'Get-HPKitFirmwareStickLayout' {
    BeforeAll {
        $script:g6 = Get-KitProfile -Vendor HP -ModelId 840-g6
        $script:g5 = Get-KitProfile -Vendor HP -ModelId 840-g5
        Import-HPCMSLStandIn
    }
    AfterAll {
        Remove-Module -Name HPCMSL -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:catalog = @()
        Mock Initialize-HPCMSL -ModuleName HP.Build {}
        Mock Get-HPBIOSUpdates -ModuleName HP.Build { $script:catalog }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    Context 'for the 840 G6' {
        BeforeEach {
            $script:pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $latest = Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384
            $older = Get-FakeCatalogEntry -Ver '1.35.00' -Bin 'R70_013500.bin' -Sha384 ('A' * 96) -Date '2026-01-02'
            $script:catalog = @($latest, $older)
            $script:result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
        }

        It 'returns the vendor result contract for the model' {
            $script:result.PSObject.TypeNames | Should -Contain 'Kit.FirmwareStickLayout'
            $script:result.Operation | Should -Be 'GetFirmwareStickLayout'
            $script:result.Vendor | Should -Be 'HP'
            $script:result.ModelId | Should -Be '840-g6'
            $script:result.Name | Should -Be 'HP EliteBook 840 G6'
            $script:result.PlatformId | Should -Be '8549'
            $script:result.PlatformVerified | Should -BeTrue
            $script:result.BiosFamily | Should -Be 'R70'
            $script:result.WindowsFlash | Should -BeNullOrEmpty
            @($script:result.Notes) | Should -HaveCount 0
            $script:result.LayoutPath | Should -Be $script:hpLayout
        }

        It 'reports the latest BIOS with the version formatted two digits per part' {
            $script:result.LatestBios.Version | Should -Be '01.36.00'
            $script:result.LatestBios.Date | Should -Be '2026-06-13'
            $script:result.LatestBios.PackageId | Should -Be 'sp174025'
            $script:result.LatestBios.File | Should -Be 'R70_013600.bin'
            $script:result.LatestBios.DependencyMinimum | Should -BeNullOrEmpty
        }

        It 'asks the catalog for every BIOS of the profile platform' {
            Should -Invoke Get-HPBIOSUpdates -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Platform -eq '8549' -and $All }
        }

        It 'lists the six BIOS and flash image entries in layout order and none for the captured tree' {
            @($script:result.Entries.RelativePath) | Should -Be @(
                'Hewlett-Packard\BIOS\New\R70_013600.bin'
                'EFI\HP\BIOS\New\R70_013600.bin'
                'Hewlett-Packard\BIOS\Current\R70_013600.bin'
                'EFI\HP\BIOS\Current\R70_013600.bin'
                'HP\DEVFW\firmware.bin'
                'EFI\HP\DEVFW\firmware.bin'
            )
            @($script:result.Entries.Group) | Should -Be @('F10-New', 'F10-New-ESP', 'Diag-Current', 'Diag-Current-ESP', 'Esc-DEVFW', 'Esc-DEVFW-ESP')
        }

        It 'points every entry at the package image with its size and lower case SHA-256' {
            foreach ($entry in $script:result.Entries) {
                $entry.SourcePath | Should -Be $script:pkg.Image
                $entry.Size | Should -Be ([IO.FileInfo]$script:pkg.Image).Length
                $entry.Sha256 | Should -BeExactly $script:pkg.Sha256.ToLowerInvariant()
            }
        }

        It 'records the catalog SHA-384 in lower case as the vendor hash of every entry' {
            foreach ($entry in $script:result.Entries) {
                $entry.VendorHash.Algorithm | Should -Be 'SHA384'
                $entry.VendorHash.Value | Should -BeExactly $script:pkg.Sha384.ToLowerInvariant()
                $entry.VendorHash.Source | Should -Be 'Get-HPBIOSUpdates -All'
            }
        }
    }

    Context 'catalog versions' {
        BeforeEach {
            $script:pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
        }

        It 'picks the highest version whatever the list order (1.9 is below 1.36)' {
            $latest = Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384
            $older = Get-FakeCatalogEntry -Ver '1.9.00' -Bin 'R70_010900.bin' -Sha384 ('B' * 96)
            $script:catalog = @($older, $latest)
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            $result.LatestBios.File | Should -Be 'R70_013600.bin'
            $result.LatestBios.Version | Should -Be '01.36.00'
        }

        It 'formats a catalog version with no third part as 01.36.00' {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384)
            (Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath).LatestBios.Version | Should -Be '01.36.00'
        }

        It 'formats a catalog date that is a date object as yyyy-MM-dd' {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384 -Date ([datetime]'2026-06-13'))
            (Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath).LatestBios.Date | Should -Be '2026-06-13'
        }
    }

    Context 'for the 840 G5' {
        It 'returns the unverified platform id without throwing' {
            $pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g5 -OsFolder win11-22H2 -SoftPaq sp157750 -Bin Q78_013100.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.31.00' -Bin 'Q78_013100.bin' -Sha384 $pkg.Sha384 -Date '2025-04-30')
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g5 -PackagePath $pkg.PackagePath -WarningAction SilentlyContinue
            $result.PlatformId | Should -Be '83B2'
            $result.PlatformVerified | Should -BeFalse
            $result.BiosFamily | Should -Be 'Q78'
            $result.LatestBios.Version | Should -Be '01.31.00'
            $result.LatestBios.PackageId | Should -Be 'sp157750'
            Should -Invoke Get-HPBIOSUpdates -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Platform -eq '83B2' }
        }
    }

    Context 'with -LayoutPath' {
        It 'honours a copy of the layout and returns its path' {
            $pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $pkg.Sha384)
            $copy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.layout.psd1')
            Copy-Item -LiteralPath $script:hpLayout -Destination $copy
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $pkg.PackagePath -LayoutPath $copy
            $result.LayoutPath | Should -Be $copy
            @($result.Entries) | Should -HaveCount 6
        }
    }
}
