BeforeDiscovery {
    # The export list is data: one It per name, read from the manifest rather than copied into the test.
    $script:manifestNames = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1')).FunctionsToExport |
            ForEach-Object { @{ Name = $_ } })
}

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
            'Get-KitFirmwareLayout', 'Test-FirmwareTarget', 'Test-FirmwareStage', 'Show-FirmwareStageFinding'
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

Describe 'Native command wrapper' {
    Context 'ConvertTo-KitCommandLine' {
        It 'escapes <Name>' -ForEach @(
            @{ Name = 'plain arguments unchanged'; Arguments = @('/add-driver', 'C:\d\*.inf', '/subdirs'); Expected = '/add-driver C:\d\*.inf /subdirs' }
            @{ Name = 'an empty argument as two quotes'; Arguments = @(''); Expected = '""' }
            @{ Name = 'a value with a space by quoting it'; Arguments = @('C:\Program Files\x'); Expected = '"C:\Program Files\x"' }
            @{ Name = 'a trailing backslash by doubling it'; Arguments = @('C:\dir with space\'); Expected = '"C:\dir with space\\"' }
            @{ Name = 'embedded quotes with a backslash'; Arguments = @('say "hi"'); Expected = '"say \"hi\""' }
            @{ Name = 'a backslash before a quote by doubling it'; Arguments = @('a\"b c'); Expected = '"a\\\"b c"' }
        ) {
            ConvertTo-KitCommandLine -ArgumentList $Arguments | Should -BeExactly $Expected
        }
        It 'returns an empty string for no arguments' {
            ConvertTo-KitCommandLine -ArgumentList @() | Should -BeExactly ''
        }
    }

    Context 'Invoke-KitTool' {
        It 'returns without a warning for exit 0' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 0 }'))
            Invoke-KitTool -FilePath 'tool.exe' -WarningVariable warned -WarningAction SilentlyContinue
            $warned | Should -BeNullOrEmpty
        }
        It 'warns once and does not throw for the accepted exit 3010' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 3010 }'))
            Invoke-KitTool -FilePath 'tool.exe' -WarningVariable warned -WarningAction SilentlyContinue
            @($warned).Count | Should -Be 1
            $warned[0].Message | Should -BeLike '*exit 3010 (accepted)*'
        }
        It 'throws for an exit code outside OkCode' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 5 }'))
            { Invoke-KitTool -FilePath 'tool.exe' } | Should -Throw '*failed: exit 5*'
        }
        It 'honours a custom OkCode list' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 259 }'))
            Invoke-KitTool -FilePath 'tool.exe' -OkCode 0, 259 -WarningVariable warned -WarningAction SilentlyContinue
            @($warned).Count | Should -Be 1
            $warned[0].Message | Should -BeLike '*exit 259 (accepted)*'
        }
        It 'passes the escaped command line as ArgumentList' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 0 }'))
            Invoke-KitTool 'dism.exe' '/add-driver', 'C:\my drivers\*.inf'
            Should -Invoke Start-Process -ModuleName Kit.Core -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'dism.exe' -and $ArgumentList -ceq '/add-driver "C:\my drivers\*.inf"'
            }
        }
        It 'omits ArgumentList when there are no arguments' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 0 }'))
            Invoke-KitTool 'tool.exe'
            Should -Invoke Start-Process -ModuleName Kit.Core -Times 1 -Exactly -ParameterFilter { $null -eq $ArgumentList }
        }
        It 'starts no process under -WhatIf' {
            Mock Start-Process -ModuleName Kit.Core -MockWith ([scriptblock]::Create('[pscustomobject]@{ ExitCode = 0 }'))
            Invoke-KitTool 'tool.exe' '/x' -WhatIf
            Should -Invoke Start-Process -ModuleName Kit.Core -Times 0 -Exactly
        }
    }
}

Describe 'Get-KitPublishFile' {
    BeforeAll {
        # A throwaway kit that holds every kind of file the list must keep or drop.
        $script:fakeKit = Join-Path $TestDrive 'kit'
        foreach ($relative in 'Run.cmd', 'core\a.ps1', 'vendors\x\vendor.psd1', 'config.example.psd1', 'config.local.psd1',
            'vendors\x\site.local.psd1', 'results\serial.txt', 'vendors\x\results\y.txt', 'apps\Results\z.txt') {
            $file = Join-Path $script:fakeKit $relative
            $null = New-Item -Path (Split-Path -Path $file -Parent) -ItemType Directory -Force
            Set-Content -LiteralPath $file -Value 'x'
        }
        $script:listed = @(Get-KitPublishFile -Root $script:fakeKit)
        $script:realList = @(Get-KitPublishFile)
    }
    It 'lists exactly the publishable files, sorted by relative path' {
        @($script:listed.RelativePath) | Should -Be @('config.example.psd1', 'core\a.ps1', 'Run.cmd', 'vendors\x\vendor.psd1')
    }
    It 'gives each entry an existing full name' {
        foreach ($entry in $script:listed) {
            $entry.FullName | Should -Exist
            $entry.FullName | Should -Be (Join-Path (Resolve-Path -LiteralPath $script:fakeKit).Path $entry.RelativePath)
        }
    }
    It 'types each entry Kit.PublishFile' {
        foreach ($entry in $script:listed) { $entry.PSObject.TypeNames | Should -Contain 'Kit.PublishFile' }
    }
    It 'never lists a local settings file or anything under a results folder at any depth' {
        $names = @($script:listed.RelativePath)
        $names | Should -Not -Contain 'config.local.psd1'
        $names | Should -Not -Contain 'vendors\x\site.local.psd1'
        @($names | Where-Object { $_ -match '(^|\\)results(\\|$)' }) | Should -BeNullOrEmpty
    }
    It 'defaults to the real kit folder and lists its launcher, installer and core manifest' {
        $names = @($script:realList.RelativePath)
        $names | Should -Contain 'Run.cmd'
        $names | Should -Contain 'Install-DriverBaseline.ps1'
        $names | Should -Contain 'core\Kit.Core.psd1'
    }
    It 'lists no local settings file and no results path from the real kit folder' {
        @($script:realList.RelativePath | Where-Object { $_ -match '\.local\.psd1$' -or $_ -match '(^|\\)results(\\|$)' }) | Should -BeNullOrEmpty
    }
}

Describe 'Kit.Core exports' {
    It 'resolves <Name> as a Kit.Core function' -ForEach $script:manifestNames {
        Get-Command -Module Kit.Core -CommandType Function -Name $Name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports exactly the functions the manifest lists' {
        $listed = @((Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport | Sort-Object)
        @((Get-Module -Name Kit.Core).ExportedFunctions.Keys | Sort-Object) | Should -Be $listed
    }
}
