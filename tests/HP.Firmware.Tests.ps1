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
            'Get-HPBIOSUpdates'     = 'param($Platform, [switch]$Latest, [switch]$All)'
            'Get-HPSoftpaqMetadata' = 'param($Number)'
            'Get-HPDeviceDetails'   = 'param($Platform, [switch]$OSList)'
            'Get-HPSoftpaqList'     = 'param($Platform, $Os, $OsVer, [switch]$Quiet, [string[]]$Category)'
            'Get-HPSoftpaq'         = 'param($Number, $Overwrite, [switch]$Quiet, [switch]$Extract, $DestinationPath)'
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

    # The CVA of a SoftPaq as Get-HPSoftpaqMetadata returns it: the hash of the executable (upper case in the real CVA),
    # the silent install command, the return codes and, when asked for, the Dependency section.
    function Get-FakeCva {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [AllowEmptyString()][string]$ExeSha256 = '',
            [hashtable]$Dependency
        )
        $cva = [ordered]@{
            Softpaq             = @{ SoftPaqSHA256 = $ExeSha256 }
            'Install Execution' = @{ SilentInstall = '"HpFirmwareUpdRec.exe" -r -b -s' }
            ReturnCode          = @{ '3010:SUCCESS:REBOOT' = 'A restart is required.'; '1602:CANCEL:NOREBOOT' = 'Flash failed due to dependency not satisfied.' }
        }
        if ($Dependency) { $cva['Dependency'] = $Dependency }
        [pscustomobject]$cva
    }

    # The SHA-256 of a text as bytes, in upper case as Get-FileHash and the HP CVA write it.
    function Get-TextSha256 {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Text)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            -join ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Text)) | ForEach-Object { $_.ToString('X2') })
        }
        finally {
            $sha.Dispose()
        }
    }

    # The part of a GetFirmware result that a second, reusing run must reproduce, as text to compare.
    function Get-FirmwareShape {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][object]$Result)
        $Result.Firmware | Select-Object -Property Id, Path, AutoInstall, SilentInstall, ReturnCodes | ConvertTo-Json -Depth 6
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
        $script:metadata = @{}
        Mock Initialize-HPCMSL -ModuleName HP.Build {}
        Mock Get-HPBIOSUpdates -ModuleName HP.Build { $script:catalog }
        Mock Get-HPSoftpaqMetadata -ModuleName HP.Build { $script:metadata["$Number"] }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    Context 'for the 840 G6' {
        BeforeEach {
            $script:pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256 }
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
            $script:result.WindowsFlash.Path | Should -Be 'firmware\hp\8549'
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
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256 }
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

    Context 'the CVA metadata of the 840 G6' {
        BeforeEach {
            $script:pkg = Write-FakeBiosPackage -Root $script:root -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:pkg.Sha384)
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256 -Dependency @{ MinimumBIOSVersion_R70 = '01.35.02' } }
        }

        It 'records how to run the Windows flash tool and what its return codes mean' {
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            $result.WindowsFlash.Path | Should -Be 'firmware\hp\8549'
            $result.WindowsFlash.SilentInstall | Should -Be '"HpFirmwareUpdRec.exe" -r -b -s'
            ($result.WindowsFlash.ReturnCodes -is [System.Collections.Specialized.OrderedDictionary]) | Should -BeTrue
            @($result.WindowsFlash.ReturnCodes.Keys) | Should -Be @('1602', '3010')
            $result.WindowsFlash.ReturnCodes['1602'] | Should -Be 'CANCEL'
            $result.WindowsFlash.ReturnCodes['3010'] | Should -Be 'SUCCESS:REBOOT'
        }

        It 'asks for the metadata by the SoftPaq number without the sp prefix, once' {
            $null = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            Should -Invoke Get-HPSoftpaqMetadata -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Number -eq '174025' }
        }

        It 'records the BIOS the latest image needs first and adds no Note for it' {
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            $result.LatestBios.DependencyMinimum | Should -Be '01.35.02'
            @($result.Notes) | Should -HaveCount 0
        }

        It 'leaves the dependency empty for a family the section does not name' {
            $g5Package = Write-FakeBiosPackage -Root $script:root -ModelId 840-g5 -OsFolder win11-22H2 -SoftPaq sp157750 -Bin Q78_013100.bin
            $script:catalog = @(Get-FakeCatalogEntry -Ver '1.31.00' -Bin 'Q78_013100.bin' -Sha384 $g5Package.Sha384 -Date '2025-04-30')
            $script:metadata = @{ '157750' = Get-FakeCva -ExeSha256 $g5Package.ExeSha256 -Dependency @{ MinimumBIOSVersion_R70 = '01.35.02' } }
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g5 -PackagePath $g5Package.PackagePath -WarningAction SilentlyContinue
            $result.LatestBios.DependencyMinimum | Should -BeNullOrEmpty
        }

        It 'leaves the dependency empty when the SoftPaq declares none' {
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256 }
            (Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath).LatestBios.DependencyMinimum | Should -BeNullOrEmpty
        }

        It 'formats a dependency written as 1.35.2 as 01.35.02' {
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256 -Dependency @{ MinimumBIOSVersion_R70 = '1.35.2' } }
            (Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath).LatestBios.DependencyMinimum | Should -Be '01.35.02'
        }

        It 'keeps a dependency that is not a version as text and adds a Note' {
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256 -Dependency @{ MinimumBIOSVersion_R70 = 'latest' } }
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            $result.LatestBios.DependencyMinimum | Should -Be 'latest'
            @($result.Notes) | Should -HaveCount 1
            $result.Notes[0] | Should -BeLike "*'latest'*"
        }

        It 'accepts the CVA hash of the SoftPaq executable in lower case' {
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 $script:pkg.ExeSha256.ToLowerInvariant() }
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            @($result.Notes) | Should -HaveCount 0
        }

        It 'throws, naming the executable, when its SHA-256 differs from the CVA' {
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 ('A' * 64) }
            $message = Get-ThrownMessage -Action { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath }
            $message | Should -BeLike '*sp174025.exe*'
            $message | Should -BeLike '*does not match the HP CVA hash*'
        }

        It 'succeeds with a Note when the executable is not in the package' {
            Remove-Item -LiteralPath $script:pkg.Exe
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            @($result.Notes) | Should -HaveCount 1
            $result.Notes[0] | Should -BeLike '*sp174025.exe is not cached*not rechecked*'
        }

        It 'succeeds with a Note when HP published no SHA-256' {
            $script:metadata = @{ '174025' = Get-FakeCva -ExeSha256 '' }
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            @($result.Notes) | Should -HaveCount 1
            $result.Notes[0] | Should -BeLike '*published no SHA-256*sp174025.exe*'
        }

        It 'lets a failing metadata call stop the build' {
            Mock Get-HPSoftpaqMetadata -ModuleName HP.Build { throw 'HP server unreachable' }
            { Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath } | Should -Throw '*HP server unreachable*'
        }

        It 'has no WindowsFlash block when the layout stages no flash tool' {
            $text = @'
@{
    SchemaVersion = 1
    VolumeLabel   = 'HP_TOOLS'
    FileSystem    = 'FAT32'
    Groups        = @(
        @{ Id = 'F10-New'; Folder = 'Hewlett-Packard\BIOS\New'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
    )
}
'@
            $small = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.layout.psd1')
            [IO.File]::WriteAllText($small, $text, [Text.Encoding]::ASCII)
            $result = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath -LayoutPath $small
            $result.WindowsFlash | Should -BeNullOrEmpty
            @($result.Entries) | Should -HaveCount 1
        }

        It 'changes nothing on disk' {
            $snapshot = {
                @(Get-ChildItem -LiteralPath $script:root -Recurse -Force -File | Sort-Object -Property FullName |
                        ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks })
            }
            $before = & $snapshot
            $null = Get-HPKitFirmwareStickLayout -ModelProfile $script:g6 -PackagePath $script:pkg.PackagePath
            & $snapshot | Should -Be $before
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

Describe 'Save-HPKitFirmware download reuse' {
    BeforeAll {
        $script:g6 = Get-KitProfile -Vendor HP -ModelId 840-g6
        Import-HPCMSLStandIn
        $script:osList = @([pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '24H2'; BuildNumber = '26100' })
        $script:firmware = @(
            [pscustomobject]@{ id = 'sp174025'; Name = 'HP Elite/ProBook Notebook System BIOS (R70)'; Version = '01.36.00'; Category = 'BIOS'; ReleaseDate = '2025-01-01'; SSM = $true }
            [pscustomobject]@{ id = 'sp170000'; Name = 'Samsung SSD Firmware'; Version = '1.0'; Category = 'Firmware'; ReleaseDate = '2024-01-01'; SSM = $false }
        )
    }
    AfterAll {
        Remove-Module -Name HPCMSL -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        # The CVA hash of each SoftPaq is the SHA-256 of the exact bytes the mocked download writes.
        $script:metadata = @{
            '174025' = [pscustomobject]@{
                Softpaq             = @{ SoftPaqSHA256 = Get-TextSha256 -Text 'fake softpaq 174025' }
                'Install Execution' = @{ SilentInstall = '"HpFirmwareUpdRec.exe" -r -b -s' }
                General             = @{ SystemMustBeRebooted = '1' }
                Devices             = @{ '_body' = @{} }
                ReturnCode          = @{ '3010:SUCCESS:REBOOT' = 'A restart is required.'; '290:CANCEL:NOREBOOT' = 'Bitlocker is enabled.' }
            }
            '170000' = [pscustomobject]@{
                Softpaq             = @{ SoftPaqSHA256 = Get-TextSha256 -Text 'fake softpaq 170000' }
                'Install Execution' = @{ SilentInstall = 'setup.exe /s' }
                General             = @{ SystemMustBeRebooted = '0' }
                Devices             = @{ '_body' = @{} }
                ReturnCode          = @{}
            }
        }
        Mock Initialize-HPCMSL -ModuleName HP.Build {}
        Mock Test-HPKitElevation -ModuleName HP.Build { $true }
        Mock Get-HPDeviceDetails -ModuleName HP.Build { $script:osList }
        Mock Get-HPSoftpaqList -ModuleName HP.Build { $script:firmware }
        Mock Get-HPSoftpaqMetadata -ModuleName HP.Build { $script:metadata["$Number"] }
        Mock Get-HPSoftpaq -ModuleName HP.Build {
            $null = New-Item -Path $DestinationPath -ItemType Directory -Force
            [IO.File]::WriteAllBytes((Join-Path $DestinationPath "sp$Number.exe"), [Text.Encoding]::ASCII.GetBytes("fake softpaq $Number"))
            [IO.File]::WriteAllBytes((Join-Path $DestinationPath 'extracted.dat'), [Text.Encoding]::ASCII.GetBytes("fake payload $Number"))
        }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:firmwareDir = Join-Path $script:root 'hp\840-g6\win11-24H2\Firmware'
    }

    It 'downloads each SoftPaq once on the first run and reuses both on the second' {
        $first = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 2
        $second = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root -InformationVariable info
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 2
        Get-FirmwareShape -Result $second | Should -Be (Get-FirmwareShape -Result $first)
        $line = @($info | ForEach-Object { [string]$_.MessageData })
        @($line | Where-Object { $_ -like '*reusing*' }) | Should -HaveCount 2
    }

    It 'keeps the folder of a selected SoftPaq and its extracted files when it reuses it' {
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        Join-Path $script:firmwareDir 'sp174025\sp174025.exe' | Should -Exist
        Join-Path $script:firmwareDir 'sp174025\extracted.dat' | Should -Exist
    }

    It 'downloads again, into an emptied folder, when the cached executable differs from the CVA hash' {
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        [IO.File]::WriteAllBytes((Join-Path $script:firmwareDir 'sp174025\sp174025.exe'), [Text.Encoding]::ASCII.GetBytes('tampered'))
        [IO.File]::WriteAllText((Join-Path $script:firmwareDir 'sp174025\stale.txt'), 'stale', [Text.Encoding]::ASCII)
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 2 -ParameterFilter { $Number -eq '174025' }
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Number -eq '170000' }
        Test-Path -LiteralPath (Join-Path $script:firmwareDir 'sp174025\stale.txt') | Should -BeFalse
        (Get-FileHash -LiteralPath (Join-Path $script:firmwareDir 'sp174025\sp174025.exe') -Algorithm SHA256).Hash | Should -Be $script:metadata['174025'].Softpaq.SoftPaqSHA256
    }

    It 'always downloads when the CVA has no Softpaq section' {
        $script:metadata['174025'] = [pscustomobject]@{
            'Install Execution' = @{ SilentInstall = '"HpFirmwareUpdRec.exe" -r -b -s' }
            General             = @{ SystemMustBeRebooted = '1' }
            Devices             = @{ '_body' = @{} }
            ReturnCode          = @{}
        }
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 2 -ParameterFilter { $Number -eq '174025' }
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Number -eq '170000' }
    }

    It 'removes the folder of a SoftPaq that is no longer selected' {
        $old = Join-Path $script:firmwareDir 'sp111111'
        $null = New-Item -Path $old -ItemType Directory -Force
        [IO.File]::WriteAllText((Join-Path $old 'old.txt'), 'old', [Text.Encoding]::ASCII)
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        Test-Path -LiteralPath $old | Should -BeFalse
        Join-Path $script:firmwareDir 'sp174025' | Should -Exist
        Join-Path $script:firmwareDir 'sp170000' | Should -Exist
    }

    It 'removes nothing and downloads nothing under -WhatIf' {
        $old = Join-Path $script:firmwareDir 'sp111111'
        $null = New-Item -Path $old -ItemType Directory -Force
        [IO.File]::WriteAllText((Join-Path $old 'old.txt'), 'old', [Text.Encoding]::ASCII)
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root -WhatIf
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 0
        Join-Path $old 'old.txt' | Should -Exist
        Join-Path $script:firmwareDir 'sp174025' | Should -Not -Exist
    }
}

Describe 'Test-HPKitSoftpaqCache' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:dir -ItemType Directory
        $exe = Join-Path $script:dir 'sp1.exe'
        [IO.File]::WriteAllBytes($exe, [Text.Encoding]::ASCII.GetBytes('exe bytes'))
        $script:hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    }

    It 'is false for an empty expected hash, even with extracted files' {
        [IO.File]::WriteAllText((Join-Path $script:dir 'a.dat'), 'a', [Text.Encoding]::ASCII)
        InModuleScope HP.Build -Parameters @{ Dir = $script:dir } {
            Test-HPKitSoftpaqCache -Directory $Dir -Id sp1 -ExpectedSha256 ''
        } | Should -BeFalse
    }

    It 'is false when the executable is missing' {
        [IO.File]::WriteAllText((Join-Path $script:dir 'a.dat'), 'a', [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath (Join-Path $script:dir 'sp1.exe')
        InModuleScope HP.Build -Parameters @{ Dir = $script:dir; Hash = $script:hash } {
            Test-HPKitSoftpaqCache -Directory $Dir -Id sp1 -ExpectedSha256 $Hash
        } | Should -BeFalse
    }

    It 'is false when the executable hashes to another value' {
        [IO.File]::WriteAllText((Join-Path $script:dir 'a.dat'), 'a', [Text.Encoding]::ASCII)
        InModuleScope HP.Build -Parameters @{ Dir = $script:dir; Hash = ('0' * 64) } {
            Test-HPKitSoftpaqCache -Directory $Dir -Id sp1 -ExpectedSha256 $Hash
        } | Should -BeFalse
    }

    It 'is false when the folder holds only the executable' {
        InModuleScope HP.Build -Parameters @{ Dir = $script:dir; Hash = $script:hash } {
            Test-HPKitSoftpaqCache -Directory $Dir -Id sp1 -ExpectedSha256 $Hash
        } | Should -BeFalse
    }

    It 'is true when the hash matches in either case and another file exists' {
        $null = New-Item -Path (Join-Path $script:dir 'data') -ItemType Directory
        [IO.File]::WriteAllText((Join-Path $script:dir 'data\a.dat'), 'a', [Text.Encoding]::ASCII)
        InModuleScope HP.Build -Parameters @{ Dir = $script:dir; Hash = $script:hash } {
            Test-HPKitSoftpaqCache -Directory $Dir -Id sp1 -ExpectedSha256 $Hash
        } | Should -BeTrue
        InModuleScope HP.Build -Parameters @{ Dir = $script:dir; Hash = $script:hash.ToLowerInvariant() } {
            Test-HPKitSoftpaqCache -Directory $Dir -Id sp1 -ExpectedSha256 $Hash
        } | Should -BeTrue
    }
}

Describe 'Initialize-HPCMSL' {
    BeforeAll {
        # Install-Module and Install-PackageProvider belong to PowerShellGet and PackageManagement, which the test run may
        # not find, and Pester can only mock a command that exists. Stand-ins with the same names and parameters, generated
        # from this table, make them mockable; nothing is installed.
        $spec = [ordered]@{
            'Install-Module'          = 'param($Name, $RequiredVersion, $Scope, [switch]$Force, [switch]$AcceptLicense)'
            'Install-PackageProvider' = 'param($Name, $MinimumVersion, [switch]$Force)'
        }
        $source = foreach ($name in $spec.Keys) {
            "function $name { $($spec[$name]); process { [pscustomobject]`$PSBoundParameters } }"
        }
        $null = New-Module -Name PSGetStandIn -ScriptBlock ([scriptblock]::Create($source -join "`n")) | Import-Module -Global -Force
    }
    AfterAll {
        Remove-Module -Name PSGetStandIn -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:installed = $true
        $script:powerShellGet = [version]'2.2.5'
        Mock Test-HPKitHPCMSLInstalled -ModuleName HP.Build { $script:installed }
        Mock Get-HPKitPowerShellGetVersion -ModuleName HP.Build { $script:powerShellGet }
        Mock Import-Module -ModuleName HP.Build {}
        Mock Install-Module -ModuleName HP.Build {}
        Mock Install-PackageProvider -ModuleName HP.Build {}
    }

    It 'imports an installed HPCMSL and neither probes PowerShellGet nor installs' {
        InModuleScope HP.Build { Initialize-HPCMSL }
        Should -Invoke Import-Module -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Name -eq 'HPCMSL' }
        Should -Invoke Get-HPKitPowerShellGetVersion -ModuleName HP.Build -Exactly 0
        Should -Invoke Install-Module -ModuleName HP.Build -Exactly 0
    }

    It 'stops with the fix, before any install, when PowerShellGet is older than 2.0.0' {
        $script:installed = $false
        $script:powerShellGet = [version]'1.0.0.1'
        $message = Get-ThrownMessage -Action { InModuleScope HP.Build { Initialize-HPCMSL } }
        $message | Should -BeLike '*PowerShellGet*'
        $message | Should -BeLike '*1.0.0.1*'
        $message | Should -BeLike "*Install-Module PowerShellGet -Force*"
        Should -Invoke Install-Module -ModuleName HP.Build -Exactly 0
        Should -Invoke Install-PackageProvider -ModuleName HP.Build -Exactly 0
        Should -Invoke Import-Module -ModuleName HP.Build -Exactly 0
    }

    It 'treats a missing PowerShellGet as too old' {
        $script:installed = $false
        $script:powerShellGet = $null
        $message = Get-ThrownMessage -Action { InModuleScope HP.Build { Initialize-HPCMSL } }
        $message | Should -BeLike '*no PowerShellGet*'
        $message | Should -BeLike "*Install-Module PowerShellGet -Force*"
        Should -Invoke Install-Module -ModuleName HP.Build -Exactly 0
    }

    It 'installs HPCMSL pinned to 1.9.0 and then imports it when PowerShellGet is 2.0.0 or newer' {
        $script:installed = $false
        InModuleScope HP.Build { Initialize-HPCMSL }
        Should -Invoke Install-Module -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Name -eq 'HPCMSL' -and $RequiredVersion -eq '1.9.0' }
        Should -Invoke Import-Module -ModuleName HP.Build -Exactly 1 -ParameterFilter { $Name -eq 'HPCMSL' }
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
