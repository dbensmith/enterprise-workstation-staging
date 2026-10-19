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
