BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'HPDriverBaseline.psm1') -Force

    # Fixtures mirror live HPCMSL 1.9.0 output for platform 8549 (2026-09-28).
    $script:osList = @(
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 10'; OperatingSystemRelease = '22H2'; BuildNumber = '19045' }
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '23H2'; BuildNumber = '22631' }
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '24H2'; BuildNumber = '26100' }
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '21H2'; BuildNumber = '22000' }
    )
    $script:drivers = @(
        [pscustomobject]@{ id = 'sp174163'; Name = 'Realtek High-Definition (HD) Audio Driver'; DPB = $true }
        [pscustomobject]@{ id = 'sp152918'; Name = 'AMD Video Driver and Control Panel'; DPB = $true }
        [pscustomobject]@{ id = 'sp168736'; Name = 'HP Hotkey Support - UWP'; DPB = $true }
        [pscustomobject]@{ id = 'sp109038'; Name = 'HP XMM7262 WWAN Driver'; DPB = $false }
        [pscustomobject]@{ id = 'sp153128'; Name = 'Intel NIC Driver'; DPB = $true }
    )
}

Describe 'Select-OsRelease' {
    It 'picks the newest release by build number, not list order' {
        Select-OsRelease -OsList $osList -Os win11 | Should -Be '24H2'
    }
    It 'honours a pinned release HP indexes' {
        Select-OsRelease -OsList $osList -Os win11 -OsVer '23H2' | Should -Be '23H2'
    }
    It 'rejects a release HP does not index (25H2 on 8549)' {
        { Select-OsRelease -OsList $osList -Os win11 -OsVer '25H2' } | Should -Throw '*Available: 23H2, 24H2, 21H2*'
    }
    It 'filters by OS family' {
        Select-OsRelease -OsList $osList -Os win10 | Should -Be '22H2'
    }
}

Describe 'Select-BaselineSoftpaq' {
    It 'drops non-DPB SoftPaqs and profile excludes by name substring' {
        $r = Select-BaselineSoftpaq -Softpaq $drivers -Exclude 'AMD Video', 'hotkey support' -RequireDriverPack
        $r.Included.id | Should -Be @('sp174163', 'sp153128')
        ($r.Excluded | Where-Object Id -EQ 'sp109038').Reason | Should -BeLike '*DPB=false*'
        ($r.Excluded | Where-Object Id -EQ 'sp168736').Reason | Should -BeLike "*'hotkey support'*"
    }
    It 'matches an exact SoftPaq id' {
        $r = Select-BaselineSoftpaq -Softpaq $drivers -Exclude 'sp153128'
        $r.Included.id | Should -Not -Contain 'sp153128'
    }
    It 'keeps non-DPB SoftPaqs when DPB is not required (firmware)' {
        (Select-BaselineSoftpaq -Softpaq $drivers).Included.Count | Should -Be 5
    }
    It 'accepts an empty catalog' {
        (Select-BaselineSoftpaq -Softpaq @()).Included | Should -BeNullOrEmpty
    }
}

Describe 'Split-SoftpaqCommand' {
    It 'splits a quoted executable' {
        $c = Split-SoftpaqCommand '"HpFirmwareUpdRec.exe" -r -b -s'
        $c.File | Should -Be 'HpFirmwareUpdRec.exe'
        $c.Arguments | Should -Be '-r -b -s'
    }
    It 'splits an unquoted executable with no arguments' {
        $c = Split-SoftpaqCommand 'setup.exe'
        $c.File | Should -Be 'setup.exe'
        $c.Arguments | Should -Be ''
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

Describe 'Install-HPDriverBaseline firmware gating' {
    BeforeAll {
        # The installer is standalone (copied into packages/images), so load its helpers from its AST.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-HPDriverBaseline.ps1'), [ref]$null, [ref]$null)
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'ConvertTo-HPBiosVersion', 'Get-FirmwareSkipReason' }, $true) |
            ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

        $script:bios = [pscustomobject]@{ Id = 'sp174025'; Name = 'HP BIOS and System Firmware (R70)'; Version = '1.36.00'; Category = 'BIOS - System Firmware'; Devices = @() }
        $script:ssd = [pscustomobject]@{ Id = 'sp149654'; Name = 'Samsung SSD Firmware update'; Version = 'HPS8NFXV'; Category = 'Firmware'; Devices = @('PCI\VEN_144D&DEV_A809&SUBSYS_A809144D') }
        # The mock body runs after this block returns, so it reads a script variable each It sets, not a closure.
        Mock Get-CimInstance { [pscustomobject]@{ SMBIOSBIOSVersion = $script:installedBios } } -ParameterFilter { $ClassName -eq 'Win32_BIOS' }
    }
    BeforeEach { $script:presentHardwareIds = $null }

    It 'parses SMBIOS and SoftPaq BIOS strings to the same family/version' {
        $installed = ConvertTo-HPBiosVersion 'R70 Ver. 01.36.00'
        $package = ConvertTo-HPBiosVersion 'HP BIOS and System Firmware (R70) 1.36.00'
        $installed.Family | Should -Be 'R70'
        $installed.Version | Should -Be ([version]'1.36.0')
        $package.Version | Should -Be $installed.Version
        ConvertTo-HPBiosVersion 'unknown' | Should -BeNullOrEmpty
    }
    It 'skips the BIOS when the installed version is <installed> (same or newer)' -ForEach @(
        @{ installed = 'R70 Ver. 01.36.00' }
        @{ installed = 'R70 Ver. 01.37.00' }
    ) {
        $script:installedBios = $installed
        Get-FirmwareSkipReason $bios | Should -BeLike '*already current*'
    }
    It 'runs the BIOS updater when the installed BIOS is <installed>' -ForEach @(
        @{ installed = 'R70 Ver. 01.29.00' }   # older
        @{ installed = 'garbage' }             # unparseable: let HP's updater decide
        @{ installed = 'S70 Ver. 01.50.00' }   # other family: let HP's updater decide
    ) {
        $script:installedBios = $installed
        Get-FirmwareSkipReason $bios | Should -BeNullOrEmpty
    }
    It 'skips device-specific firmware when no matching device is present' {
        Mock Get-CimInstance { [pscustomobject]@{ HardwareID = @('PCI\VEN_8086&DEV_15BE&SUBSYS_8549103C&REV_30') } } -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' }
        Get-FirmwareSkipReason $ssd | Should -Be 'no matching device in this PC'
    }
    It 'keeps device-specific firmware when the device is present' {
        Mock Get-CimInstance { [pscustomobject]@{ HardwareID = @('PCI\VEN_144D&DEV_A809&SUBSYS_A809144D&REV_00', 'PCI\VEN_144D&DEV_A809&SUBSYS_A809144D') } } -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' }
        Get-FirmwareSkipReason $ssd | Should -BeNullOrEmpty
    }
}

Describe 'New-HPBaselineIso first-boot answer file' {
    It 'is well-formed and runs the installer in the specialize pass' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'New-HPBaselineIso.ps1'), [ref]$null, [ref]$null)
        $text = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '*<unattend*' }, $true)[0].Value
        $xml = [xml]$text
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        $pass = Select-Xml -Xml $xml -XPath '//u:settings' -Namespace $ns
        $pass.Node.pass | Should -Be 'specialize'
        (Select-Xml -Xml $xml -XPath '//u:RunSynchronousCommand/u:Path' -Namespace $ns).Node.InnerText | Should -BeLike '*Install-HPDriverBaseline.ps1 -LogPath*'
    }
}

Describe 'ConvertTo-ReturnCodeMap' {
    It 'parses CVA return codes, sorted numerically, skipping non-code keys' {
        $map = ConvertTo-ReturnCodeMap @{
            '3010:SUCCESS:REBOOT'  = 'A restart is required to complete the install.'
            '290:CANCEL:NOREBOOT'  = 'Bitlocker is enabled and utility is running in silent mode.'
            '259:FAILURE:NOREBOOT' = 'Returned due to internal failure'
            '_body'                = @{}
        }
        @($map.Keys) | Should -Be @('259', '290', '3010')
        $map['3010'].Reboot | Should -BeTrue
        $map['290'].Result | Should -Be 'CANCEL'
    }
    It 'returns an empty map for missing metadata' {
        (ConvertTo-ReturnCodeMap $null).Count | Should -Be 0
    }
}
