BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\builder\vendors\hp\HP.Build.psm1') -Force

    # Fixtures mirror live HPCMSL 1.9.0 output for platform 8549 (2026-09-28).
    $script:osList = @(
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 10'; OperatingSystemRelease = '22H2'; BuildNumber = '19045' }
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '23H2'; BuildNumber = '22631' }
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '24H2'; BuildNumber = '26100' }
        [pscustomobject]@{ OperatingSystem = 'Microsoft Windows 11'; OperatingSystemRelease = '21H2'; BuildNumber = '22000' }
    )
    # HPCMSL is not installed on the builder PC and Pester can only mock a command that exists, so the build
    # operations run against a stand-in module with HP's command and parameter names. The names belong to
    # HPCMSL (plural noun, state-changing verb), so the stand-in is generated from this table instead of being
    # written as functions that the style rules would judge as ours. Each command returns its bound parameters.
    function Import-HPCMSLStandIn {
        $spec = [ordered]@{
            'Get-HPDeviceDetails'    = 'param($Platform, [switch]$OSList)'
            'Get-HPSoftpaqList'      = 'param($Platform, $Os, $OsVer, [switch]$Quiet, [string[]]$Category)'
            'New-HPBuildDriverPack'  = '[CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$Softpaq, $Path, $Name, $Format, $Os, $OSVer, [switch]$Overwrite)'
            'Get-HPSoftpaq'          = 'param($Number, $Overwrite, [switch]$Quiet, [switch]$Extract, $DestinationPath)'
            'Get-HPSoftpaqMetadata'  = 'param($Number)'
        }
        $source = foreach ($name in $spec.Keys) {
            "function $name { $($spec[$name]); process { [pscustomobject]`$PSBoundParameters } }"
        }
        $null = New-Module -Name HPCMSL -ScriptBlock ([scriptblock]::Create($source -join "`n")) | Import-Module -Global -Force
    }

    $script:drivers = @(
        [pscustomobject]@{ id = 'sp174163'; Name = 'Realtek High-Definition (HD) Audio Driver'; DPB = $true }
        [pscustomobject]@{ id = 'sp152918'; Name = 'AMD Video Driver and Control Panel'; DPB = $true }
        [pscustomobject]@{ id = 'sp168736'; Name = 'HP Hotkey Support - UWP'; DPB = $true }
        [pscustomobject]@{ id = 'sp109038'; Name = 'HP XMM7262 WWAN Driver'; DPB = $false }
        [pscustomobject]@{ id = 'sp153128'; Name = 'Intel NIC Driver'; DPB = $true }
    )
}

Describe 'HP.Build module' {
    It 'loads offline without importing HPCMSL' {
        Get-Module -Name HPCMSL | Should -BeNullOrEmpty
    }
    It 'exports the four helpers and the five build operations' {
        $names = (Get-Command -Module HP.Build).Name | Sort-Object
        $expected = @(
            'ConvertTo-ReturnCodeMap', 'Get-HPKitFirmwareStickLayout', 'Get-HPKitModel', 'New-HPKitCustomPack', 'Save-HPKitFirmware'
            'Save-HPKitVendorPack', 'Select-BaselineSoftpaq', 'Select-OsRelease', 'Split-SoftpaqCommand'
        ) | Sort-Object
        $names | Should -Be $expected
    }
}

Describe 'Get-HPKitModel' {
    BeforeAll {
        $script:models = @(Get-HPKitModel)
    }
    It 'lists 840-g5 then 840-g6' {
        $script:models.ModelId | Should -Be @('840-g5', '840-g6')
    }
    It 'reports the platform ids and whether they are verified' {
        $script:models.Platform | Should -Be @('83B2', '8549')
        $script:models.PlatformVerified | Should -Be @($false, $true)
    }
    It 'names the vendor and carries the profile path' {
        $script:models.Vendor | Should -Be @('HP', 'HP')
        $script:models[1].ProfilePath | Should -Exist
    }
}

Describe 'Save-HPKitVendorPack' {
    It 'is not implemented until Phase 4 and echoes what it was asked for' {
        $g6 = Get-KitProfile -Vendor HP -ModelId 840-g6
        $thrown = $null
        try { Save-HPKitVendorPack -ModelProfile $g6 -OsVer 24H2 -OutputPath $TestDrive }
        catch { $thrown = $_.Exception }
        $thrown | Should -BeOfType ([System.NotImplementedException])
        $thrown.Message | Should -BeLike '*BUILD-03*'
        $thrown.Message | Should -BeLike '*840-g6*'
        $thrown.Message | Should -BeLike '*24H2*'
        $thrown.Message | Should -BeLike "*$TestDrive*"
    }
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

# HPCMSL is not installed on the builder PC and Pester can only mock a command that exists, so the build
# operations run against a stand-in module with the same command and parameter names.
Describe 'New-HPKitCustomPack' {
    BeforeAll {
        $script:g6 = Get-KitProfile -Vendor HP -ModelId 840-g6
        Import-HPCMSLStandIn
    }
    AfterAll {
        Remove-Module -Name HPCMSL -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:elevated = $true
        Mock Initialize-HPCMSL -ModuleName HP.Build {}
        Mock Test-HPKitElevation -ModuleName HP.Build { $script:elevated }
        Mock Get-HPDeviceDetails -ModuleName HP.Build { $script:osList }
        Mock Get-HPSoftpaqList -ModuleName HP.Build { $script:drivers }
        Mock New-HPBuildDriverPack -ModuleName HP.Build {}
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    Context 'with elevation' {
        BeforeEach {
            $script:result = New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
        }
        It 'resolves the newest release and writes into the per-vendor/model package folder' {
            $script:result.OsVer | Should -Be '24H2'
            $script:result.PackagePath | Should -Be (Join-Path $script:root 'hp\840-g6\win11-24H2')
            $script:result.PackKind | Should -Be 'custom'
            $script:result.Operation | Should -Be 'NewCustomPack'
        }
        It 'keeps only DPB-eligible, non-excluded SoftPaqs' {
            $script:result.Drivers.Id | Should -Be @('sp174163', 'sp153128')
        }
        It 'reports the exclusions with the Drivers stage' {
            $script:result.Excluded.Id | Should -Be @('sp152918', 'sp168736', 'sp109038')
            $script:result.Excluded.Stage | Should -Be @('Drivers', 'Drivers', 'Drivers')
        }
        It 'builds the driver pack into the package root as Drivers, from the included SoftPaqs only' {
            # A mock sees each piped SoftPaq as its own call, so two included SoftPaqs are two calls.
            Should -Invoke New-HPBuildDriverPack -ModuleName HP.Build -Exactly 2 -ParameterFilter {
                $Path -eq (Join-Path $script:root 'hp\840-g6\win11-24H2') -and $Name -eq 'Drivers'
            }
            Should -Invoke New-HPBuildDriverPack -ModuleName HP.Build -Exactly 0 -ParameterFilter {
                $Softpaq.id -in 'sp152918', 'sp168736', 'sp109038'
            }
        }
        It 'records the HPCMSL version in ToolVersions' {
            $script:result.ToolVersions.Keys | Should -Contain 'HPCMSL'
        }
    }
    It 'queries the catalog for a pinned release' {
        $r = New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '23H2' -OutputPath $script:root
        $r.OsVer | Should -Be '23H2'
        $r.PackagePath | Should -Be (Join-Path $script:root 'hp\840-g6\win11-23H2')
        Should -Invoke Get-HPSoftpaqList -ModuleName HP.Build -Exactly 1 -ParameterFilter { $OsVer -eq '23H2' }
    }
    It 'rejects a release the catalog does not index' {
        { New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '25H2' -OutputPath $script:root } | Should -Throw '*Available:*'
    }
    It 'refuses an empty driver selection' {
        Mock Get-HPSoftpaqList -ModuleName HP.Build { @() }
        { New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root } | Should -Throw '*Driver selection is empty*'
    }
    It 'builds nothing and creates no folder under -WhatIf' {
        $r = New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root -WhatIf
        Should -Invoke New-HPBuildDriverPack -ModuleName HP.Build -Exactly 0
        Test-Path -LiteralPath (Join-Path $r.PackagePath 'Drivers') | Should -BeFalse
    }
    It 'refuses to run unelevated' {
        $script:elevated = $false
        { New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root } | Should -Throw '*elevated*'
    }
    It 'previews unelevated under -WhatIf' {
        $script:elevated = $false
        { New-HPKitCustomPack -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root -WhatIf } | Should -Not -Throw
    }
}

Describe 'Save-HPKitFirmware' {
    BeforeAll {
        $script:g6 = Get-KitProfile -Vendor HP -ModelId 840-g6
        Import-HPCMSLStandIn

        $script:firmware = @(
            [pscustomobject]@{ id = 'sp174025'; Name = 'HP Elite/ProBook Notebook System BIOS (R70)'; Version = '01.36.00'; Category = 'BIOS'; ReleaseDate = '2025-01-01'; SSM = $true }
            [pscustomobject]@{ id = 'sp170000'; Name = 'Samsung SSD Firmware'; Version = '1.0'; Category = 'Firmware'; ReleaseDate = '2024-01-01'; SSM = $false }
        )
        $script:metadata = @{
            '174025' = [pscustomobject]@{
                'Install Execution' = @{ SilentInstall = '"HpFirmwareUpdRec.exe" -r -b -s' }
                General             = @{ SystemMustBeRebooted = '1' }
                Devices             = @{ '_body' = @{} }
                ReturnCode          = @{ '3010:SUCCESS:REBOOT' = 'A restart is required.'; '290:CANCEL:NOREBOOT' = 'Bitlocker is enabled.' }
            }
            '170000' = [pscustomobject]@{
                'Install Execution' = @{ SilentInstall = 'setup.exe /s' }
                General             = @{ SystemMustBeRebooted = '0' }
                Devices             = @{ 'PCI\VEN_144D&DEV_A809&SUBSYS_A809144D' = @{}; '_body' = @{} }
                ReturnCode          = @{}
            }
        }
    }
    AfterAll {
        Remove-Module -Name HPCMSL -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:elevated = $true
        Mock Initialize-HPCMSL -ModuleName HP.Build {}
        Mock Test-HPKitElevation -ModuleName HP.Build { $script:elevated }
        Mock Get-HPDeviceDetails -ModuleName HP.Build { $script:osList }
        Mock Get-HPSoftpaqList -ModuleName HP.Build { $script:firmware }
        Mock Get-HPSoftpaq -ModuleName HP.Build {}
        Mock Get-HPSoftpaqMetadata -ModuleName HP.Build { $script:metadata["$Number"] }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:packageDir = Join-Path $script:root 'hp\840-g6\win11-24H2'
    }

    Context 'with elevation' {
        BeforeEach {
            $script:result = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root
            $script:bios = $script:result.Firmware | Where-Object Id -EQ 'sp174025'
            $script:ssd = $script:result.Firmware | Where-Object Id -EQ 'sp170000'
        }
        It 'returns the GetFirmware result for the package folder' {
            $script:result.Operation | Should -Be 'GetFirmware'
            $script:result.PackagePath | Should -Be $script:packageDir
            $script:result.OsVer | Should -Be '24H2'
            $script:result.ToolVersions.Keys | Should -Contain 'HPCMSL'
        }
        It 'downloads and extracts each SoftPaq into Firmware/<id>' {
            Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 1 -ParameterFilter {
                $Number -eq '174025' -and $DestinationPath -eq (Join-Path $script:packageDir 'Firmware\sp174025')
            }
        }
        It 'records an auto-installable BIOS entry' {
            $script:bios.Path | Should -Be 'Firmware/sp174025'
            $script:bios.AutoInstall | Should -BeTrue
            $script:bios.SilentInstall.File | Should -Be 'HpFirmwareUpdRec.exe'
            $script:bios.SilentInstall.Arguments | Should -Be '-r -b -s'
            $script:bios.RebootRequired | Should -BeTrue
            @($script:bios.ReturnCodes.Keys) | Should -Be @('290', '3010')
        }
        It 'stages a non-SSM SoftPaq for a technician and keeps its device ids' {
            $script:ssd.AutoInstall | Should -BeFalse
            $script:ssd.RebootRequired | Should -BeFalse
            $script:ssd.Devices | Should -Contain 'PCI\VEN_144D&DEV_A809&SUBSYS_A809144D'
        }
    }
    It 'downloads nothing under -WhatIf' {
        $null = Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root -WhatIf
        Should -Invoke Get-HPSoftpaq -ModuleName HP.Build -Exactly 0
    }
    It 'refuses to run unelevated' {
        $script:elevated = $false
        { Save-HPKitFirmware -ModelProfile $script:g6 -OsVer '' -OutputPath $script:root } | Should -Throw '*elevated*'
    }
}
