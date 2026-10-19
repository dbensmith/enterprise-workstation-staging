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

Describe 'HP driver install' {
    BeforeAll {
        Mock Invoke-KitTool -ModuleName HP.Target { }
        $script:driverPackage = Join-Path $TestDrive 'driver-pkg'
        $null = New-Item -Path (Join-Path $script:driverPackage 'Drivers') -ItemType Directory -Force
        $script:emptyPackage = Join-Path $TestDrive 'empty-pkg'
        $null = New-Item -Path $script:emptyPackage -ItemType Directory -Force
    }

    It 'injects the drivers into an offline image with DISM' {
        $result = Install-HPKitDriver -PackagePath $script:driverPackage -OfflineImagePath 'C:\Mount\install'
        $expected = @('/Image:C:\Mount\install', '/Add-Driver', "/Driver:$script:driverPackage\Drivers", '/Recurse') -join '|'
        Should -Invoke Invoke-KitTool -ModuleName HP.Target -Exactly 1 -ParameterFilter { $FilePath -eq 'dism.exe' -and ($ArgumentList -join '|') -eq $expected }
        $result.Operation | Should -Be 'InstallDrivers'
        $result.Mode | Should -Be 'Offline'
        $result.Result | Should -Be 'SUCCESS'
    }
    It 'stages and installs the drivers online with pnputil' {
        $result = Install-HPKitDriver -PackagePath $script:driverPackage
        $expected = @('/add-driver', "$script:driverPackage\Drivers\*.inf", '/subdirs', '/install') -join '|'
        Should -Invoke Invoke-KitTool -ModuleName HP.Target -Exactly 1 -ParameterFilter {
            $FilePath -eq 'pnputil.exe' -and ($ArgumentList -join '|') -eq $expected -and
            ($OkCode -contains 0) -and ($OkCode -contains 3010) -and ($OkCode -contains 259) -and ($OkCode -contains -536870365)
        }
        $result.Mode | Should -Be 'Online'
        $result.Result | Should -Be 'SUCCESS'
    }
    It 'skips cleanly when the package has no Drivers folder' {
        $result = Install-HPKitDriver -PackagePath $script:emptyPackage
        Should -Invoke Invoke-KitTool -ModuleName HP.Target -Exactly 0
        @($result).Count | Should -Be 1
        $result.Result | Should -Be 'SKIPPED'
    }
    It 'passes -WhatIf through to the native tool wrapper' {
        $null = Install-HPKitDriver -PackagePath $script:driverPackage -WhatIf
        Should -Invoke Invoke-KitTool -ModuleName HP.Target -Exactly 1 -ParameterFilter { $WhatIf }
    }
    It 'does not pass -WhatIf when it was not asked for' {
        $null = Install-HPKitDriver -PackagePath $script:driverPackage
        Should -Invoke Invoke-KitTool -ModuleName HP.Target -Exactly 0 -ParameterFilter { $WhatIf }
    }
    It 'lets a failing tool propagate' {
        Mock Invoke-KitTool -ModuleName HP.Target { throw 'pnputil.exe failed: exit 1' }
        { Install-HPKitDriver -PackagePath $script:driverPackage } | Should -Throw '*pnputil.exe failed*'
    }
}

Describe 'HP firmware install' {
    BeforeAll {
        # Get-BitLockerVolume and Suspend-BitLocker exist only where the BitLocker module is installed; Pester needs a command to mock.
        $script:definedStubs = @()
        foreach ($stub in 'Get-BitLockerVolume', 'Suspend-BitLocker') {
            if (-not (Get-Command -Name $stub -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Function:\global:$stub" -Value { param($MountPoint, $RebootCount) }
                $script:definedStubs += $stub
            }
        }

        $newItem = {
            param($Id, $Category, $Path, $File, [bool]$Auto, [bool]$Reboot)
            [ordered]@{
                Id             = $Id
                Name           = "Item $Id"
                Version        = '1.0'
                Category       = $Category
                Path           = $Path
                AutoInstall    = $Auto
                RebootRequired = $Reboot
                Devices        = @()
                SilentInstall  = @{ File = $File; Arguments = '-s' }
                ReturnCodes    = @{
                    '3010' = @{ Result = 'SUCCESS'; Message = 'Restart required' }
                    '290'  = @{ Result = 'CANCEL'; Message = 'BitLocker is on' }
                }
            }
        }
        $newPackage = {
            param($Name, $Items, $Files)
            $root = Join-Path $TestDrive $Name
            $null = New-Item -Path $root -ItemType Directory -Force
            foreach ($file in $Files) { $null = New-Item -Path (Join-Path $root $file) -ItemType File -Force }
            ConvertTo-Json -InputObject @{ Firmware = @($Items) } -Depth 8 | Set-Content -Path (Join-Path $root 'manifest.json')
            $root
        }

        # The BIOS is listed first on purpose: the install order must not follow the manifest order.
        $bios = & $newItem 'bios1' 'BIOS - System Firmware' 'Firmware/bios1' 'HpFirmwareUpdRec64.exe' $true $true
        $nic = & $newItem 'nic1' 'Firmware' 'Firmware/nic1' 'setup.exe' $true $false
        $ssd = & $newItem 'ssd1' 'Firmware' 'Firmware/ssd1' 'ssd.exe' $false $false
        $script:package = & $newPackage 'fw-pkg' @($bios, $nic, $ssd) @('Firmware\bios1\HpFirmwareUpdRec64.exe', 'Firmware\nic1\setup.exe', 'Firmware\ssd1\ssd.exe')
        $script:missingPackage = & $newPackage 'fw-missing' @($nic) @()
        $escape = & $newItem 'evil1' 'Firmware' '..\outside' 'evil.exe' $true $false
        $script:escapePackage = & $newPackage 'fw-escape' @($escape) @('..\outside\evil.exe')
        $script:noRebootPackage = & $newPackage 'fw-noreboot' @($nic) @('Firmware\nic1\setup.exe')

        Mock Start-Process -ModuleName HP.Target {
            $script:launched.Add($FilePath)
            [pscustomobject]@{ ExitCode = $script:exitCodes[(Split-Path -Path (Split-Path -Path $FilePath -Parent) -Leaf)] }
        }
        Mock Get-FirmwareSkipReason -ModuleName HP.Target { }
        Mock Get-BitLockerVolume -ModuleName HP.Target { [pscustomobject]@{ ProtectionStatus = 'On' } }
        Mock Suspend-BitLocker -ModuleName HP.Target { }
    }
    BeforeEach {
        $script:launched = [System.Collections.Generic.List[string]]::new()
        $script:exitCodes = @{ bios1 = 0; nic1 = 0; ssd1 = 0; evil1 = 0 }
    }
    AfterAll {
        foreach ($stub in $script:definedStubs) { Remove-Item -Path "Function:\global:$stub" }
    }

    It 'reports a manual-only item as MANUAL without launching it' {
        $results = @(Install-HPKitFirmware -PackagePath $script:package)
        $manual = $results | Where-Object Id -EQ 'ssd1'
        $manual.Result | Should -Be 'MANUAL'
        $manual.Operation | Should -Be 'InstallFirmware'
        $script:launched | Should -Not -Contain (Join-Path $script:package 'Firmware\ssd1\ssd.exe')
    }
    It 'runs the BIOS last' {
        $null = Install-HPKitFirmware -PackagePath $script:package
        $script:launched.Count | Should -Be 2
        Split-Path -Path $script:launched[0] -Leaf | Should -Be 'setup.exe'
        Split-Path -Path $script:launched[1] -Leaf | Should -Be 'HpFirmwareUpdRec64.exe'
    }
    It 'maps exit code <code> to <expected>' -ForEach @(
        @{ code = 0; expected = 'SUCCESS' }
        @{ code = 3010; expected = 'SUCCESS' }
        @{ code = 290; expected = 'CANCEL' }
        @{ code = 7; expected = 'FAILURE' }
    ) {
        $script:exitCodes.nic1 = $code
        $result = Install-HPKitFirmware -PackagePath $script:package | Where-Object Id -EQ 'nic1'
        $result.Result | Should -Be $expected
        $result.ExitCode | Should -Be $code
    }
    It 'reports a missing executable as FAILURE without launching it' {
        $result = Install-HPKitFirmware -PackagePath $script:missingPackage
        $result.Result | Should -Be 'FAILURE'
        $result.Detail | Should -BeLike '*executable not found*'
        Should -Invoke Start-Process -ModuleName HP.Target -Exactly 0
    }
    It 'reports a path outside the package Firmware folder as FAILURE without launching it' {
        $result = Install-HPKitFirmware -PackagePath $script:escapePackage
        $result.Result | Should -Be 'FAILURE'
        Should -Invoke Start-Process -ModuleName HP.Target -Exactly 0
    }
    It 'reports a launch error as FAILURE' {
        Mock Start-Process -ModuleName HP.Target { throw 'access denied' }
        $result = Install-HPKitFirmware -PackagePath $script:noRebootPackage
        $result.Result | Should -Be 'FAILURE'
        $result.Detail | Should -BeLike '*access denied*'
    }
    It 'skips an item the gate flags, and does not suspend BitLocker for it' {
        Mock Get-FirmwareSkipReason -ModuleName HP.Target { 'BIOS 1.36.0 already current (package 1.36.0)' } -ParameterFilter { $Firmware.Category -like 'BIOS*' }
        $results = @(Install-HPKitFirmware -PackagePath $script:package)
        $bios = $results | Where-Object Id -EQ 'bios1'
        $bios.Result | Should -Be 'SKIPPED'
        $bios.Detail | Should -BeLike '*already current*'
        Should -Invoke Start-Process -ModuleName HP.Target -Exactly 1
        Should -Invoke Suspend-BitLocker -ModuleName HP.Target -Exactly 0
    }
    It 'suspends BitLocker on the system drive for one reboot when the BIOS will run' {
        $null = Install-HPKitFirmware -PackagePath $script:package
        Should -Invoke Suspend-BitLocker -ModuleName HP.Target -Exactly 1 -ParameterFilter { $MountPoint -eq $env:SystemDrive -and $RebootCount -eq 1 }
    }
    It 'does not suspend BitLocker when protection is off' {
        Mock Get-BitLockerVolume -ModuleName HP.Target { [pscustomobject]@{ ProtectionStatus = 'Off' } }
        $null = Install-HPKitFirmware -PackagePath $script:package
        Should -Invoke Suspend-BitLocker -ModuleName HP.Target -Exactly 0
    }
    It 'does not suspend BitLocker when no item that will run needs a reboot' {
        $null = Install-HPKitFirmware -PackagePath $script:noRebootPackage
        Should -Invoke Suspend-BitLocker -ModuleName HP.Target -Exactly 0
    }
    It 'warns and carries on when BitLocker cannot be suspended' {
        Mock Suspend-BitLocker -ModuleName HP.Target { throw 'no TPM' }
        $results = @(Install-HPKitFirmware -PackagePath $script:package -WarningAction SilentlyContinue)
        ($results | Where-Object Id -EQ 'bios1').Result | Should -Be 'SUCCESS'
    }
    It 'runs nothing and suspends nothing under -WhatIf' {
        $null = Install-HPKitFirmware -PackagePath $script:package -WhatIf
        Should -Invoke Start-Process -ModuleName HP.Target -Exactly 0
        Should -Invoke Suspend-BitLocker -ModuleName HP.Target -Exactly 0
    }
}
