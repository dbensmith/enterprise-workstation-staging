BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\builder\vendors\hp\HP.Build.psm1') -Force

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

Describe 'HP.Build module' {
    It 'loads offline without importing HPCMSL' {
        Get-Module -Name HPCMSL | Should -BeNullOrEmpty
    }
    It 'exports exactly the four build helpers' {
        $names = (Get-Command -Module HP.Build).Name | Sort-Object
        $names | Should -Be @('ConvertTo-ReturnCodeMap', 'Select-BaselineSoftpaq', 'Select-OsRelease', 'Split-SoftpaqCommand')
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
