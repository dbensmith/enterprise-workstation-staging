BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    $script:coreManifest = Join-Path $script:corePath 'Kit.Core.psd1'
    Import-Module $script:coreManifest -Force
}

Describe 'Kit.Core module' {
    It 'imports and exports the ISO servicing functions' {
        $names = (Get-Command -Module Kit.Core).Name
        $names | Should -Contain 'Select-InstallImage'
        $names | Should -Contain 'New-WindowsInstallIso'
    }
    It 'pins the manifest export list for the whole phase, in order' {
        $expected = @(
            'Select-InstallImage', 'New-WindowsInstallIso'
            'Get-KitRoot', 'Get-KitPackagePath'
            'ConvertTo-KitCommandLine', 'Invoke-KitTool'
            'Get-KitVendor', 'Test-KitVendorContract', 'Invoke-KitVendorCommand'
            'Get-KitProfile', 'Get-KitVerifiedValue'
            'Get-KitConfig'
            'Get-KitPublishFile'
        )
        (Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport | Should -Be $expected
    }
    It 'names no vendor in any file under kit/core' {
        $hits = foreach ($file in Get-ChildItem -Path $script:corePath -File -Recurse) {
            $number = 0
            foreach ($line in Get-Content -LiteralPath $file.FullName) {
                $number++
                if ($line -cmatch '\bHP\b|HPCMSL|Hewlett|SoftPaq') { '{0}:{1}: {2}' -f $file.Name, $number, $line.Trim() }
            }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Select-InstallImage' {
    BeforeAll {
        $script:pro = [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Pro' }
        $script:multi = @(
            [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }
            $pro
        )
    }
    It 'uses the only image when no edition is given (Pro-only ISO)' {
        (Select-InstallImage -Image @($pro)).ImageName | Should -Be 'Windows 11 Pro'
    }
    It 'selects by exact name from multi-edition media' {
        (Select-InstallImage -Image $multi -Edition 'Windows 11 Pro').ImageName | Should -Be 'Windows 11 Pro'
    }
    It 'requires -Edition when there are several images' {
        { Select-InstallImage -Image $multi } | Should -Throw '*choose one with -Edition*Windows 11 Home; Windows 11 Pro*'
    }
    It 'rejects an unknown edition' {
        { Select-InstallImage -Image @($pro) -Edition 'Windows 11 Home' } | Should -Throw "*'Windows 11 Home' not found*"
    }
}

Describe 'New-WindowsInstallIso' {
    BeforeAll {
        $script:media = Join-Path $TestDrive 'media'
        $null = New-Item "$media\boot", "$media\efi\microsoft\boot", "$media\sources" -ItemType Directory
        [IO.File]::WriteAllBytes("$media\boot\etfsboot.com", [byte[]]::new(4096))
        [IO.File]::WriteAllBytes("$media\efi\microsoft\boot\efisys.bin", [byte[]]::new(1474560))
        Set-Content "$media\sources\hello.txt" 'baseline'
        $script:iso = New-WindowsInstallIso -MediaPath $media -Path (Join-Path $TestDrive 'out.iso') -VolumeName 'TEST_LABEL'

        # First 12 bytes of each El Torito catalog entry, as hex.
        $script:catalog = & {
            $r = [IO.BinaryReader]::new([IO.File]::OpenRead($iso.FullName))
            try {
                $r.BaseStream.Position = 17 * 2048 + 0x47
                $r.BaseStream.Position = [long]$r.ReadUInt32() * 2048
                $bytes = $r.ReadBytes(128)
                0..3 | ForEach-Object { ($bytes[($_ * 32)..($_ * 32 + 11)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }
            }
            finally { $r.Dispose() }
        }
    }
    It 'writes a BIOS entry: no emulation, 8-sector load (etfsboot.com)' {
        $catalog[0].Substring(0, 5) | Should -Be '01 00'
        $catalog[1].Substring(0, 23) | Should -Be '88 00 00 00 00 00 08 00'
    }
    It 'writes a final UEFI section with a 1-sector load size, matching Microsoft media' {
        $catalog[2].Substring(0, 11) | Should -Be '91 EF 01 00'
        $catalog[3].Substring(0, 23) | Should -Be '88 00 00 00 00 00 01 00'
    }
    It 'fails fast when a boot file is missing' {
        $bare = Join-Path $TestDrive 'bare'
        $null = New-Item $bare -ItemType Directory
        { New-WindowsInstallIso -MediaPath $bare -Path (Join-Path $TestDrive 'bare.iso') } | Should -Throw '*Boot file missing*etfsboot.com'
    }
}

Describe 'Get-KitPackagePath' {
    It 'returns the lowercase vendor, model and os-release folders under the output root' {
        Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId 840-g6 -Os win11 -OsVer 24H2 |
            Should -Be (Join-Path $TestDrive 'hp\840-g6\win11-24H2')
    }
    It 'keeps the 840-g5 and 840-g6 packages apart under one vendor folder' {
        $g5 = Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId 840-g5 -Os win11 -OsVer 24H2
        $g6 = Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId 840-g6 -Os win11 -OsVer 24H2
        $g5 | Should -Not -Be $g6
        Split-Path -Path (Split-Path -Path $g5 -Parent) -Parent | Should -Be (Split-Path -Path (Split-Path -Path $g6 -Parent) -Parent)
        Split-Path -Path (Split-Path -Path $g5 -Parent) -Parent | Should -Be (Join-Path $TestDrive 'hp')
    }
    It 'lowercases the vendor and keeps the case of the other segments' {
        $path = Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId EliteBook-840G6 -Os Win11 -OsVer 24H2
        $path | Should -BeExactly (Join-Path $TestDrive 'hp\EliteBook-840G6\Win11-24H2')
    }
    It 'creates nothing on disk' {
        $path = Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId 840-g6 -Os win11 -OsVer 24H2
        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'hp') | Should -BeFalse
    }
    It 'rejects the ModelId <ModelId>' -ForEach @(
        @{ ModelId = '' }
        @{ ModelId = '..' }
        @{ ModelId = 'a\b' }
        @{ ModelId = 'a/b' }
        @{ ModelId = '.hidden' }
    ) {
        { Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId $ModelId -Os win11 -OsVer 24H2 } | Should -Throw
    }
    It 'rejects an empty OsVer' {
        { Get-KitPackagePath -OutputRoot $TestDrive -Vendor HP -ModelId 840-g6 -Os win11 -OsVer '' } | Should -Throw
    }
}

Describe 'Get-KitRoot' {
    It 'returns the kit folder, the parent of kit/core' {
        $expected = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\kit')).Path
        Get-KitRoot | Should -Be $expected
    }
}
