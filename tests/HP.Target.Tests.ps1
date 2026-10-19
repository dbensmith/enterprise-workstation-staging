BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\vendors\hp\HP.Target.psm1') -Force
}

Describe 'HP firmware version parsing' {
    BeforeAll {
        # A CIM call no test expects must fail loudly instead of reading the builder's own hardware.
        Mock Get-CimInstance -ModuleName HP.Target { throw "unexpected CIM call $ClassName" }
        # The mock body runs after this block returns, so it reads a script variable each It sets, not a closure.
        Mock Get-CimInstance -ModuleName HP.Target { [pscustomobject]@{ SMBIOSBIOSVersion = $script:installedBios } } -ParameterFilter { $ClassName -eq 'Win32_BIOS' }
    }

    It 'parses SMBIOS and SoftPaq BIOS strings to the same family/version' {
        $installed = ConvertTo-HPBiosVersion 'R70 Ver. 01.36.00'
        $package = ConvertTo-HPBiosVersion 'HP BIOS and System Firmware (R70) 1.36.00'
        $installed.Family | Should -Be 'R70'
        $installed.Version | Should -Be ([version]'1.36.0')
        $package.Version | Should -Be $installed.Version
        ConvertTo-HPBiosVersion 'unknown' | Should -BeNullOrEmpty
    }
    It 'reads the installed BIOS family and version from Win32_BIOS' {
        $script:installedBios = 'R70 Ver. 01.36.00'
        $installed = Get-HPKitInstalledFirmware
        $installed.Family | Should -Be 'R70'
        $installed.Version | Should -Be ([version]'1.36.0')
    }
    It 'parses the G5 BIOS family Q78' {
        $script:installedBios = 'Q78 Ver. 01.31.00'
        $installed = Get-HPKitInstalledFirmware
        $installed.Family | Should -Be 'Q78'
        $installed.Version | Should -Be ([version]'1.31.0')
    }
    It 'returns nothing for an empty string' {
        ConvertTo-HPBiosVersion '' | Should -BeNullOrEmpty
    }
    It 'does not load HPCMSL on import' {
        Get-Module -Name HPCMSL | Should -BeNullOrEmpty
    }
}

Describe 'HP firmware skip gate' {
    BeforeAll {
        Mock Get-CimInstance -ModuleName HP.Target { throw "unexpected CIM call $ClassName" }
        $script:bios = [pscustomobject]@{ Id = 'sp174025'; Name = 'HP BIOS and System Firmware (R70)'; Version = '1.36.00'; Category = 'BIOS - System Firmware'; Devices = @() }
        $script:ssd = [pscustomobject]@{ Id = 'sp149654'; Name = 'Samsung SSD Firmware update'; Version = 'HPS8NFXV'; Category = 'Firmware'; Devices = @('PCI\VEN_144D&DEV_A809&SUBSYS_A809144D') }
        $script:plain = [pscustomobject]@{ Id = 'sp100001'; Name = 'Generic firmware'; Version = '1.0'; Category = 'Firmware'; Devices = @() }
        # The mock body runs after this block returns, so it reads a script variable each It sets, not a closure.
        Mock Get-CimInstance -ModuleName HP.Target { [pscustomobject]@{ SMBIOSBIOSVersion = $script:installedBios } } -ParameterFilter { $ClassName -eq 'Win32_BIOS' }
        Mock Get-CimInstance -ModuleName HP.Target { [pscustomobject]@{ HardwareID = $script:presentHardwareIds } } -ParameterFilter { $ClassName -eq 'Win32_PnPEntity' }
    }
    BeforeEach {
        $script:installedBios = $null
        $script:presentHardwareIds = $null
    }

    It 'skips the BIOS when the installed version is <installed> (same or newer)' -ForEach @(
        @{ installed = 'R70 Ver. 01.36.00' }
        @{ installed = 'R70 Ver. 01.37.00' }
    ) {
        $script:installedBios = $installed
        Get-FirmwareSkipReason $script:bios | Should -BeLike '*already current*'
    }
    It 'runs the BIOS updater when the installed BIOS is <installed>' -ForEach @(
        @{ installed = 'R70 Ver. 01.29.00' }   # older
        @{ installed = 'garbage' }             # unparseable: let HP's updater decide
        @{ installed = 'S70 Ver. 01.50.00' }   # other family: let HP's updater decide
    ) {
        $script:installedBios = $installed
        Get-FirmwareSkipReason $script:bios | Should -BeNullOrEmpty
    }
    It 'skips device-specific firmware when no matching device is present' {
        $script:presentHardwareIds = @('PCI\VEN_8086&DEV_15BE&SUBSYS_8549103C&REV_30')
        Get-FirmwareSkipReason $script:ssd | Should -Be 'no matching device in this PC'
    }
    It 'keeps device-specific firmware when the device is present' {
        $script:presentHardwareIds = @('PCI\VEN_144D&DEV_A809&SUBSYS_A809144D&REV_00', 'PCI\VEN_144D&DEV_A809&SUBSYS_A809144D')
        Get-FirmwareSkipReason $script:ssd | Should -BeNullOrEmpty
    }
    It 'matches device IDs case-insensitively' {
        $script:presentHardwareIds = @('pci\ven_144d&dev_a809&subsys_a809144d')
        Get-FirmwareSkipReason $script:ssd | Should -BeNullOrEmpty
    }
    It 'does not skip firmware with no device list and makes no CIM call' {
        Get-FirmwareSkipReason $script:plain | Should -BeNullOrEmpty
        Should -Invoke Get-CimInstance -ModuleName HP.Target -Exactly 0
    }
}

Describe 'HP device identity' {
    BeforeAll {
        Mock Get-CimInstance -ModuleName HP.Target { throw "unexpected CIM call $ClassName" }
        Mock Get-CimInstance -ModuleName HP.Target { [pscustomobject]@{ Manufacturer = 'HP'; Model = 'HP EliteBook 840 G6' } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock Get-CimInstance -ModuleName HP.Target { [pscustomobject]@{ SerialNumber = ' 5CG0000000 '; SMBIOSBIOSVersion = 'R70 Ver. 01.36.00' } } -ParameterFilter { $ClassName -eq 'Win32_BIOS' }
        Mock Get-CimInstance -ModuleName HP.Target { [pscustomobject]@{ Product = $script:boardProduct } } -ParameterFilter { $ClassName -eq 'Win32_BaseBoard' }
        Mock Get-ItemPropertyValue -ModuleName HP.Target { '83B2' }
    }

    It 'reports the laptop from CIM' {
        $script:boardProduct = '8549'
        $identity = Get-HPKitDeviceIdentity
        $identity.Vendor | Should -Be 'HP'
        $identity.Manufacturer | Should -Be 'HP'
        $identity.Model | Should -Be 'HP EliteBook 840 G6'
        $identity.Serial | Should -Be '5CG0000000'
        $identity.BiosVersion | Should -Be 'R70 Ver. 01.36.00'
        $identity.PlatformId | Should -Be '8549'
        Should -Invoke Get-ItemPropertyValue -ModuleName HP.Target -Exactly 0
    }
    It 'falls back to the registry BaseBoardProduct when Win32_BaseBoard has no product' {
        $script:boardProduct = ''
        (Get-HPKitDeviceIdentity).PlatformId | Should -Be '83B2'
        Should -Invoke Get-ItemPropertyValue -ModuleName HP.Target -Exactly 1 -ParameterFilter { $Name -eq 'BaseBoardProduct' -and $Path -eq 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' }
    }
}
