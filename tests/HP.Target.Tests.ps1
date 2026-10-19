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
