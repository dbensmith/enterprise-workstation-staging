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

    # Write a fake SoftPaq package the way the firmware stage leaves it: one image and the flash tool files around it,
    # all made of run-time bytes. -PasswordFile adds a BIOS password file that the fallback must never take.
    # Returns the package folder, the SoftPaq folder, the image path and hashes (upper case, as Get-FileHash writes
    # them) and the SoftPaq executable path and hash.
    function Write-FakeBiosPackage {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$ModelId,
            [Parameter(Mandatory)][string]$OsFolder,
            [Parameter(Mandatory)][string]$SoftPaq,
            [Parameter(Mandatory)][string]$Bin,
            [switch]$PasswordFile
        )
        $package = Join-Path $Root "hp\$ModelId\$OsFolder"
        $folder = Join-Path $package "Firmware\$SoftPaq"
        $null = New-Item -Path (Join-Path $folder 'data') -ItemType Directory -Force
        $image = Join-Path $folder $Bin
        [IO.File]::WriteAllBytes($image, [Text.Encoding]::ASCII.GetBytes("fake bios image $ModelId $Bin"))
        $exe = Join-Path $folder "$SoftPaq.exe"
        [IO.File]::WriteAllBytes($exe, [Text.Encoding]::ASCII.GetBytes("fake softpaq executable $SoftPaq"))
        foreach ($name in 'HpFirmwareUpdRec64.exe', 'HpFirmwareUpdRec.txt', 'contents.txt', 'Bios Flash.htm', 'data\HpFirmwareUpdRec.cva') {
            [IO.File]::WriteAllBytes((Join-Path $folder $name), [Text.Encoding]::ASCII.GetBytes("fake $name of $ModelId"))
        }
        if ($PasswordFile) {
            [IO.File]::WriteAllBytes((Join-Path $folder 'HPQPswd1.bin'), [Text.Encoding]::ASCII.GetBytes("fake password file of $ModelId"))
        }
        [pscustomobject]@{
            PackagePath = $package
            Folder      = $folder
            Image       = $image
            Sha256      = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
            Sha384      = (Get-FileHash -LiteralPath $image -Algorithm SHA384).Hash
            Exe         = $exe
            ExeSha256   = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        }
    }

    # One Get-HPBIOSUpdates row as HPCMSL 1.9.0 returns it (Ver without the leading zero).
    function Get-FakeCatalogEntry {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Ver,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Bin,
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

    It 'has eight groups in candidate order with the source kinds of the research default' {
        @($script:layout.Groups.Id) | Should -Be @('F10-New', 'F10-New-ESP', 'Diag-Current', 'Diag-Current-ESP', 'Diag-Tree', 'Esc-DEVFW', 'Esc-DEVFW-ESP', 'Win-Fallback')
        @($script:layout.Groups.Folder) | Should -Be @(
            'Hewlett-Packard\BIOS\New', 'EFI\HP\BIOS\New', 'Hewlett-Packard\BIOS\Current', 'EFI\HP\BIOS\Current'
            'EFI\HP', 'HP\DEVFW', 'EFI\HP\DEVFW', 'firmware\hp\{Platform}'
        )
        @($script:layout.Groups.SourceKind) | Should -Be @('BiosImage', 'BiosImage', 'BiosImage', 'BiosImage', 'Captured', 'FlashImage', 'FlashImage', 'WindowsFlashTool')
        @($script:layout.Groups.Default) | Should -Be @($true, $true, $true, $true, $true, $false, $false, $true)
        @($script:layout.Groups.Closed) | Should -Be @($true, $true, $true, $true, $false, $true, $true, $true)
    }

    It 'gives every group its own Verified block that is not verified' {
        @($script:layout.Groups) | Should -HaveCount 8
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

        It 'lists the six BIOS and flash image entries in layout order, then the fallback files, and none for the captured tree' {
            $image = @($script:result.Entries | Where-Object Group -NE 'Win-Fallback')
            @($image.RelativePath) | Should -Be @(
                'Hewlett-Packard\BIOS\New\R70_013600.bin'
                'EFI\HP\BIOS\New\R70_013600.bin'
                'Hewlett-Packard\BIOS\Current\R70_013600.bin'
                'EFI\HP\BIOS\Current\R70_013600.bin'
                'HP\DEVFW\firmware.bin'
                'EFI\HP\DEVFW\firmware.bin'
            )
            @($image.Group) | Should -Be @('F10-New', 'F10-New-ESP', 'Diag-Current', 'Diag-Current-ESP', 'Esc-DEVFW', 'Esc-DEVFW-ESP')
            @($script:result.Entries) | Should -HaveCount 12
            @($script:result.Entries.Group | Select-Object -Last 6 | Select-Object -Unique) | Should -Be @('Win-Fallback')
        }

        It 'points every image entry at the package image with its size and lower case SHA-256' {
            foreach ($entry in @($script:result.Entries | Where-Object Group -NE 'Win-Fallback')) {
                $entry.SourcePath | Should -Be $script:pkg.Image
                $entry.Size | Should -Be ([IO.FileInfo]$script:pkg.Image).Length
                $entry.Sha256 | Should -BeExactly $script:pkg.Sha256.ToLowerInvariant()
            }
        }

        It 'records the catalog SHA-384 in lower case as the vendor hash of every image entry' {
            foreach ($entry in @($script:result.Entries | Where-Object Group -NE 'Win-Fallback')) {
                $entry.VendorHash.Algorithm | Should -Be 'SHA384'
                $entry.VendorHash.Value | Should -BeExactly $script:pkg.Sha384.ToLowerInvariant()
                $entry.VendorHash.Source | Should -Be 'Get-HPBIOSUpdates -All'
            }
        }
    }

    Context 'the Windows flash fallback of the 840 G6' {
        BeforeEach {
            $script:pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin -PasswordFile
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384)
            $script:result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            $script:fallback = @($script:result.Entries | Where-Object Group -EQ 'Win-Fallback')
        }

        It 'lists the six tool files, sub-folders kept, sorted without regard to case' {
            @($script:fallback.RelativePath) | Should -Be @(
                'firmware\hp\8549\Bios Flash.htm'
                'firmware\hp\8549\contents.txt'
                'firmware\hp\8549\data\HpFirmwareUpdRec.cva'
                'firmware\hp\8549\HpFirmwareUpdRec.txt'
                'firmware\hp\8549\HpFirmwareUpdRec64.exe'
                'firmware\hp\8549\R70_013600.bin'
            )
        }

        It 'leaves out the SoftPaq self-extractor and the BIOS password file' {
            $script:fallback.RelativePath | Should -Not -Contain 'firmware\hp\8549\sp174025.exe'
            $script:fallback.RelativePath | Should -Not -Contain 'firmware\hp\8549\HPQPswd1.bin'
            foreach ($entry in $script:result.Entries) {
                $entry.SourcePath | Should -Not -BeLike '*sp174025.exe'
                $entry.SourcePath | Should -Not -BeLike '*Pswd*'
            }
        }

        It 'names the password file once in Notes and says it was left out' {
            @($script:result.Notes) | Should -HaveCount 1
            $script:result.Notes[0] | Should -BeLike '*HPQPswd1.bin*'
            $script:result.Notes[0] | Should -BeLike 'Left out*'
        }

        It 'gives every file its source path, size, lower case SHA-256 and no vendor hash' {
            foreach ($entry in $script:fallback) {
                Test-Path -LiteralPath $entry.SourcePath -PathType Leaf | Should -BeTrue
                $entry.Size | Should -Be ([IO.FileInfo]$entry.SourcePath).Length
                $entry.Sha256 | Should -BeExactly (Get-FileHash -LiteralPath $entry.SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
                $entry.VendorHash | Should -BeNullOrEmpty
            }
        }

        It 'reads the sub-folder file from its place in the package' {
            $cva = $script:fallback | Where-Object RelativePath -EQ 'firmware\hp\8549\data\HpFirmwareUpdRec.cva'
            $cva.SourcePath | Should -Be (Join-Path $script:pkg.Folder 'data\HpFirmwareUpdRec.cva')
        }

        It 'keeps the BIOS and flash image entries as they were' {
            $image = @($script:result.Entries | Where-Object Group -NE 'Win-Fallback')
            $image | Should -HaveCount 6
            foreach ($entry in $image) { $entry.SourcePath | Should -Be $script:pkg.Image }
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
            @($result.Entries) | Should -HaveCount 12
        }
    }

    Context 'when the download cannot be trusted' {
        BeforeEach {
            $script:pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384)
        }

        It 'throws, naming the platform and model, for an empty catalog' {
            $script:catalog = @()
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike '*8549*'
            $message | Should -BeLike '*840-g6*'
            $message | Should -BeLike '*no BIOS update*'
        }

        It 'throws, naming the file, for a catalog entry with no SHA-384' -ForEach @(
            @{ Value = '' }
            @{ Value = $null }
        ) {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $Value)
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike '*R70_013600.bin*'
            $message | Should -BeLike '*SHA-384*'
        }

        It 'throws, naming the file, for a catalog file name with <Name>' -ForEach @(
            @{ Name = 'a path separator'; Bin = '..\x.bin' }
            @{ Name = 'a forward slash'; Bin = 'sub/R70_013600.bin' }
            @{ Name = 'a wildcard'; Bin = 'R70_*.bin' }
            @{ Name = 'a drive prefix'; Bin = 'C:R70_013600.bin' }
        ) {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin $Bin -Sha384 $script:pkg.Sha384)
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike "*$Bin*"
            $message | Should -BeLike '*plain file name*'
        }

        It 'throws for a catalog entry with no file name' {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin '' -Sha384 $script:pkg.Sha384)
            { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath } | Should -Throw '*plain file name*'
        }

        It 'throws, naming the file and telling to run the firmware stage, when the image is missing' {
            Remove-Item -LiteralPath $script:pkg.Image
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike '*R70_013600.bin*'
            $message | Should -BeLike '*run the firmware stage first*'
        }

        It 'throws the same message when the package has no Firmware folder at all' {
            $empty = Join-Path $script:root 'hp\840-g6\empty'
            $null = New-Item -Path $empty -ItemType Directory -Force
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $empty }
            $message | Should -BeLike '*R70_013600.bin*'
            $message | Should -BeLike '*run the firmware stage first*'
        }

        It 'throws, listing both folders, when the image sits in two SoftPaq folders' {
            $copyDir = Join-Path $script:pkg.PackagePath 'Firmware\sp999999'
            $null = New-Item -Path $copyDir -ItemType Directory
            Copy-Item -LiteralPath $script:pkg.Image -Destination $copyDir
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike '*R70_013600.bin*'
            $message | Should -BeLike '*sp174025*'
            $message | Should -BeLike '*sp999999*'
        }

        It 'throws, naming the file and the family, when a G6 image is offered to the G5' {
            $g5Package = Write-FakeBiosPackage -Root $script:root -ModelId 840-g5 -OsFolder win11-22H2 -SoftPaq sp157750 -Bin R70_013600.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $g5Package.Sha384)
            $message = Get-ThrownMessage -Action {
                Get-HPKitFirmwareStickLayout -ModelProfile $script:g5 -PackagePath $g5Package.PackagePath -WarningAction SilentlyContinue
            }
            $message | Should -BeLike '*R70_013600.bin*'
            $message | Should -BeLike '*Q78*'
        }

        It 'throws, naming the file and the version, when the SHA-384 differs from the catalog' {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 ('C' * 96))
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike '*R70_013600.bin*'
            $message | Should -BeLike '*does not match the HP catalog hash for 1.36.00*'
        }

        It 'accepts a catalog SHA-384 written in either case' {
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384.ToLowerInvariant())
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            @($result.Entries) | Should -HaveCount 12
        }

        It 'changes nothing on disk' {
            # Folder timestamps are updated lazily by NTFS, so folders are compared by name and files by name, size and time.
            $snapshot = {
                @(Get-ChildItem -LiteralPath $script:root -Recurse -Force | Sort-Object -Property FullName |
                        ForEach-Object {
                            if ($_.PSIsContainer) { '{0}|folder' -f $_.FullName }
                            else { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
                        })
            }
            $before = & $snapshot
            $null = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            $after = & $snapshot
            $before | Should -Not -BeNullOrEmpty
            $after | Should -Be $before
        }
    }

    Context 'the 840 G5 and G6 together' {
        It 'never share a destination path and keep the file name each one ships' {
            $g6Package = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $g5Package = Write-FakeBiosPackage -Root $script:root -ModelId 840-g5 -OsFolder win11-22H2 -SoftPaq sp157750 -Bin Q78_013100.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $g6Package.Sha384)
            $g6 = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $g6Package.PackagePath
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.31.00' -Bin 'Q78_013100.bin' -Sha384 $g5Package.Sha384 -Date '2025-04-30')
            $g5 = Get-HPKitFirmwareStickLayout -ModelProfile $script:g5 -PackagePath $g5Package.PackagePath -WarningAction SilentlyContinue

            # The two Esc-DEVFW groups copy the image to the fixed name firmware.bin, so they would collide by design;
            # they are off by default (that folder holds one model only). Every BIOS image group keeps the shipped name.
            $g5Bios = @($g5.Entries | Where-Object { $_.Group -ne 'Win-Fallback' -and $_.RelativePath -notlike '*\firmware.bin' })
            $g6Bios = @($g6.Entries | Where-Object { $_.Group -ne 'Win-Fallback' -and $_.RelativePath -notlike '*\firmware.bin' })
            $g5Bios | Should -HaveCount 4
            $g6Bios | Should -HaveCount 4
            @($g5Bios.RelativePath | Where-Object { $g6Bios.RelativePath -contains $_ }) | Should -HaveCount 0
            foreach ($path in $g5Bios.RelativePath) { $path | Should -BeLike '*\Q78_013100.bin' }
            foreach ($path in $g6Bios.RelativePath) { $path | Should -BeLike '*\R70_013600.bin' }
            $g5Bios[0].Sha256 | Should -Not -Be $g6Bios[0].Sha256
        }

        It 'keep their Windows fallback files in separate platform folders' {
            $g6Package = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $g5Package = Write-FakeBiosPackage -Root $script:root -ModelId 840-g5 -OsFolder win11-22H2 -SoftPaq sp157750 -Bin Q78_013100.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $g6Package.Sha384)
            $g6 = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $g6Package.PackagePath
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.31.00' -Bin 'Q78_013100.bin' -Sha384 $g5Package.Sha384 -Date '2025-04-30')
            $g5 = Get-HPKitFirmwareStickLayout -ModelProfile $script:g5 -PackagePath $g5Package.PackagePath -WarningAction SilentlyContinue

            $g5Fallback = @($g5.Entries | Where-Object Group -EQ 'Win-Fallback')
            $g6Fallback = @($g6.Entries | Where-Object Group -EQ 'Win-Fallback')
            $g5Fallback | Should -HaveCount 6
            $g6Fallback | Should -HaveCount 6
            foreach ($path in $g5Fallback.RelativePath) { $path | Should -BeLike 'firmware\hp\83B2\*' }
            foreach ($path in $g6Fallback.RelativePath) { $path | Should -BeLike 'firmware\hp\8549\*' }
            @($g5Fallback.RelativePath | Where-Object { $g6Fallback.RelativePath -contains $_ }) | Should -HaveCount 0
        }
    }
}

# Last on purpose: Test-KitVendorContract re-imports the HP build module and removes it again, which would
# detach the mocks of the Describe above from the module the tests call.
Describe 'HP descriptor' {
    It 'maps GetFirmwareStickLayout to Get-HPKitFirmwareStickLayout and satisfies the vendor contract' {
        $descriptor = Join-Path $PSScriptRoot '..\kit\vendors\hp\vendor.psd1'
        (Import-PowerShellDataFile -LiteralPath $descriptor).Commands.GetFirmwareStickLayout | Should -Be 'Get-HPKitFirmwareStickLayout'
        @(Test-KitVendorContract -DescriptorPath $descriptor) | Should -HaveCount 0
    }
}
