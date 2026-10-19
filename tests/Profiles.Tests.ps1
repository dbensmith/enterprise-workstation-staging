BeforeAll {
    $script:coreManifest = Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1'
    Import-Module $script:coreManifest -Force

    # A complete, valid profile for a made-up vendor, as key -> source text. Tests drop or replace keys.
    function Get-TestProfileLine {
        param([string]$Vendor = 'Acme', [string]$ModelId = 'm1')
        [ordered]@{
            SchemaVersion    = '1'
            Vendor           = "'$Vendor'"
            ModelId          = "'$ModelId'"
            Name             = "'Acme M1'"
            Platform         = "'1234'"
            PlatformVerified = '$true'
            BiosFamily       = "'F01'"
            Os               = "'win11'"
            OsVer            = "''"
            DriverExclude    = "@('Widget')"
            FirmwareExclude  = '@()'
            PackSelection    = "@{ Preferred = 'Custom'; Allowed = @('Custom', 'Vendor') }"
            FirmwareMinimum  = "@{ Version = '01.02.03'; SoftPaq = 'sp1'; Verified = `$true; Source = 'test' }"
            BiosDefaults     = "@{ Settings = @{ 'Secure Boot' = 'Enable' }; Verified = `$true; Source = 'test' }"
        }
    }

    # Write a profile file under <Root>\<FolderName>\<FileName>.psd1 and return its path.
    function Write-TestProfile {
        param(
            [Parameter(Mandatory)][string]$Root,
            [string]$Vendor = 'Acme',
            [string]$ModelId = 'm1',
            [string]$FolderName = $Vendor.ToLowerInvariant(),
            [string]$FileName = $ModelId,
            [string[]]$Omit = @(),
            [hashtable]$Replace = @{}
        )
        $lines = Get-TestProfileLine -Vendor $Vendor -ModelId $ModelId
        foreach ($key in $Omit) { $lines.Remove($key) }
        foreach ($key in $Replace.Keys) { $lines[$key] = $Replace[$key] }
        $folder = Join-Path $Root $FolderName
        $null = New-Item -Path $folder -ItemType Directory -Force
        $path = Join-Path $folder ($FileName + '.psd1')
        $body = @('@{') + @($lines.Keys | ForEach-Object { '    {0} = {1}' -f $_, $lines[$_] }) + '}'
        Set-Content -LiteralPath $path -Value ($body -join [Environment]::NewLine)
        $path
    }

    # The message a script block throws, or $null when it does not throw.
    function Get-ThrownMessage {
        param([Parameter(Mandatory)][scriptblock]$Action)
        try { & $Action } catch { return $_.Exception.Message }
        $null
    }

    # file:line entries for every member access (.Name) or string index (['Name']) of an unverifiable block.
    function Find-UnverifiedValueRead {
        param([Parameter(Mandatory)][string[]]$Path)
        $blocked = @('FirmwareMinimum', 'BiosDefaults')
        foreach ($file in $Path) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            $nodes = $ast.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $blocked -contains $node.Member.Value) -or
                    ($node -is [System.Management.Automation.Language.IndexExpressionAst] -and
                    $node.Index -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $blocked -contains $node.Index.Value)
                }, $true)
            foreach ($node in $nodes) { '{0}:{1}' -f $file, $node.Extent.StartLineNumber }
        }
    }
}

Describe 'Get-KitProfile' {
    It 'loads the 840-g6 profile with its platform, firmware family, excludes and minimum' {
        $p = Get-KitProfile -Vendor HP -ModelId 840-g6
        $p | Should -BeOfType [hashtable]
        $p.Vendor | Should -Be 'HP'
        $p.ModelId | Should -Be '840-g6'
        $p.Platform | Should -Be '8549'
        $p.BiosFamily | Should -Be 'R70'
        $p.DriverExclude | Should -Contain 'AMD Video'
        $p.DriverExclude | Should -Contain 'DisplayLink'
        $p.DriverExclude | Should -Contain 'Hotkey Support'
        $p.FirmwareMinimum.Version | Should -Be '01.36.00'
        $p.ProfilePath | Should -BeLike '*\profiles\hp\840-g6.psd1'
    }

    It 'loads a profile by path' {
        $path = Write-TestProfile -Root $TestDrive
        $p = Get-KitProfile -Path $path
        $p.ModelId | Should -Be 'm1'
        $p.ProfilePath | Should -Be $path
    }

    It 'names every missing key in the error' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'm2' -Omit 'PackSelection', 'BiosFamily'
        $message = Get-ThrownMessage { Get-KitProfile -Path $path }
        $message | Should -BeLike '*is missing required keys:*'
        $message | Should -BeLike '*PackSelection*'
        $message | Should -BeLike '*BiosFamily*'
    }

    It 'rejects a ModelId that differs from the file name' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'm3' -FileName 'other'
        { Get-KitProfile -Path $path } | Should -Throw '*ModelId*other*'
    }

    It 'rejects a Vendor that differs from the folder name' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'm4' -FolderName 'elsewhere'
        { Get-KitProfile -Path $path } | Should -Throw '*Vendor*elsewhere*'
    }

    It 'rejects an unsupported SchemaVersion' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'm5' -Replace @{ SchemaVersion = '2' }
        { Get-KitProfile -Path $path } | Should -Throw '*SchemaVersion*'
    }

    It 'rejects a Verified flag that is not a boolean' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'm6' -Replace @{ PlatformVerified = "'yes'" }
        { Get-KitProfile -Path $path } | Should -Throw '*PlatformVerified*'
    }

    It 'lists the available ModelIds for an unknown model' {
        $root = Join-Path $TestDrive 'catalog'
        $null = Write-TestProfile -Root $root -ModelId 'a1'
        $null = Write-TestProfile -Root $root -ModelId 'a2'
        { Get-KitProfile -Vendor Acme -ModelId 'zzz' -ProfileRoot $root } | Should -Throw '*Available ModelIds: a1, a2*'
    }

    It 'fails clearly for a vendor that has no profile folder' {
        { Get-KitProfile -Vendor Nobody -ProfileRoot $TestDrive } | Should -Throw '*No profiles*Nobody*'
    }

    It 'returns every profile of the vendor sorted by ModelId when no model is given' {
        $root = Join-Path $TestDrive 'sorted'
        $null = Write-TestProfile -Root $root -ModelId 'b2'
        $null = Write-TestProfile -Root $root -ModelId 'a1'
        @(Get-KitProfile -Vendor Acme -ProfileRoot $root).ModelId | Should -Be @('a1', 'b2')
    }

    It 'refuses a ModelId that could leave the profile folder' {
        { Get-KitProfile -Vendor HP -ModelId '..\x' } | Should -Throw
    }

    It 'does not run code in a profile file' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'm7' -Replace @{ Name = "(New-Item -Path '$TestDrive\ran.txt' -ItemType File)" }
        { Get-KitProfile -Path $path } | Should -Throw
        Join-Path $TestDrive 'ran.txt' | Should -Not -Exist
    }
}

Describe 'Kit.Core exports (profile)' {
    BeforeAll {
        $source = Join-Path $PSScriptRoot '..\kit\core\Profile.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $source).Path, [ref]$null, [ref]$null)
        $script:definedInProfile = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name)
        $script:expectedProfileExports = @('Get-KitProfile', 'Get-KitVerifiedValue')
        Import-Module $script:coreManifest -Force
        $script:exported = @((Get-Module -Name Kit.Core).ExportedFunctions.Keys)
    }

    It 'exports Get-KitProfile and Get-KitVerifiedValue' {
        $script:exported | Should -Contain 'Get-KitProfile'
        $script:exported | Should -Contain 'Get-KitVerifiedValue'
    }

    It 'exports exactly the expected names among the functions Profile.ps1 defines' {
        $definedAndExported = @($script:definedInProfile | Where-Object { $script:exported -contains $_ })
        $definedAndExported | Sort-Object | Should -Be @($script:expectedProfileExports | Sort-Object)
    }
}

Describe 'G5 profile' {
    It 'lists both models, 840-g5 first' {
        @(Get-KitProfile -Vendor HP).ModelId | Should -Be @('840-g5', '840-g6')
    }

    It 'carries the 83B2 platform, the Q78 firmware family and the sp157750 minimum' {
        $p = Get-KitProfile -Vendor HP -ModelId 840-g5
        $p.Platform | Should -Be '83B2'
        $p.PlatformVerified | Should -BeFalse
        $p.BiosFamily | Should -Be 'Q78'
        $p.FirmwareMinimum.Version | Should -Be '01.31.00'
        $p.FirmwareMinimum.SoftPaq | Should -Be 'sp157750'
    }

    It 'carries a firmware SoftPaq id on <ModelId>' -ForEach @(
        @{ ModelId = '840-g5' }
        @{ ModelId = '840-g6' }
    ) {
        (Get-KitProfile -Vendor HP -ModelId $ModelId).FirmwareMinimum.SoftPaq | Should -Match '^sp\d+$'
    }

    It 'flags the firmware minimum and BIOS defaults of <ModelId> as unverified booleans' -ForEach @(
        @{ ModelId = '840-g5' }
        @{ ModelId = '840-g6' }
    ) {
        $p = Get-KitProfile -Vendor HP -ModelId $ModelId
        $p.FirmwareMinimum.Verified | Should -BeOfType [bool]
        $p.FirmwareMinimum.Verified | Should -BeFalse
        $p.BiosDefaults.Verified | Should -BeOfType [bool]
        $p.BiosDefaults.Verified | Should -BeFalse
    }
}

Describe 'Get-KitVerifiedValue' {
    BeforeAll {
        $script:g5 = Get-KitProfile -Vendor HP -ModelId 840-g5
        $script:g6 = Get-KitProfile -Vendor HP -ModelId 840-g6
    }

    It 'throws for an unverified <Name> on the G6' -ForEach @(
        @{ Name = 'FirmwareMinimum' }
        @{ Name = 'BiosDefaults' }
    ) {
        { Get-KitVerifiedValue -ModelProfile $script:g6 -Name $Name } | Should -Throw "*$Name for 840-g6 is unverified*"
    }

    It 'throws for the unverified G5 platform' {
        { Get-KitVerifiedValue -ModelProfile $script:g5 -Name Platform } | Should -Throw '*Platform for 840-g5 is unverified*'
    }

    It 'names the source of the unverified value in the error' {
        { Get-KitVerifiedValue -ModelProfile $script:g6 -Name BiosDefaults } | Should -Throw '*Source: Best-known values*'
    }

    It 'returns the verified G6 platform with no warning' {
        $value = Get-KitVerifiedValue -ModelProfile $script:g6 -Name Platform -WarningVariable warned -WarningAction SilentlyContinue
        $value | Should -Be '8549'
        $warned | Should -BeNullOrEmpty
    }

    It 'returns the unverified firmware minimum with one warning under -AllowUnverified' {
        $value = Get-KitVerifiedValue -ModelProfile $script:g6 -Name FirmwareMinimum -AllowUnverified -WarningVariable warned -WarningAction SilentlyContinue
        $value.Version | Should -Be '01.36.00'
        $value.SoftPaq | Should -Be 'sp174025'
        $value.ContainsKey('Verified') | Should -BeFalse
        @($warned).Count | Should -Be 1
        $warned[0].Message | Should -BeLike '*unverified*'
    }

    It 'returns the unverified BIOS defaults as the Settings table under -AllowUnverified' {
        $value = Get-KitVerifiedValue -ModelProfile $script:g6 -Name BiosDefaults -AllowUnverified -WarningAction SilentlyContinue
        $value | Should -BeOfType [hashtable]
        $value['Secure Boot'] | Should -Be 'Enable'
    }

    It 'returns a verified value with no warning and no error' {
        $path = Write-TestProfile -Root $TestDrive -ModelId 'v1'
        $verified = Get-KitProfile -Path $path
        $firmware = Get-KitVerifiedValue -ModelProfile $verified -Name FirmwareMinimum -WarningVariable warnedFirmware -WarningAction SilentlyContinue
        $bios = Get-KitVerifiedValue -ModelProfile $verified -Name BiosDefaults -WarningVariable warnedBios -WarningAction SilentlyContinue
        $firmware.Version | Should -Be '01.02.03'
        $bios['Secure Boot'] | Should -Be 'Enable'
        $warnedFirmware | Should -BeNullOrEmpty
        $warnedBios | Should -BeNullOrEmpty
    }
}

Describe 'Unverified value guard' {
    BeforeAll {
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $listed = @(& git -C $script:repoRoot ls-files --cached --others --exclude-standard -- kit builder)
        $profileSource = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'kit\core\Profile.ps1'))
        $script:scanned = @($listed |
                Where-Object { $_ -match '\.(ps1|psm1)$' } |
                ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot $_)) } |
                Where-Object { $_ -ne $profileSource })
    }

    It 'finds source files to scan' {
        $script:scanned | Should -Not -BeNullOrEmpty
    }

    It 'finds no direct read of FirmwareMinimum or BiosDefaults outside Profile.ps1' {
        @(Find-UnverifiedValueRead -Path $script:scanned) | Should -BeNullOrEmpty
    }

    It 'flags a member access and a string index in a sample file' {
        $sample = Join-Path $TestDrive 'sample.ps1'
        Set-Content -LiteralPath $sample -Value ('$p.FirmwareMinimum.Version', '$p["BiosDefaults"]', 'Get-KitVerifiedValue -ModelProfile $p -Name BiosDefaults')
        $hits = @(Find-UnverifiedValueRead -Path $sample)
        $hits | Should -HaveCount 2
        $hits[0] | Should -BeLike '*sample.ps1:1'
        $hits[1] | Should -BeLike '*sample.ps1:2'
    }
}

Describe 'Firmware minimum format' {
    It 'is a two-digit dotted triple that survives the [version] cast for <ModelId>' -ForEach @(
        @{ ModelId = '840-g5' }
        @{ ModelId = '840-g6' }
    ) {
        $text = (Get-KitProfile -Vendor HP -ModelId $ModelId).FirmwareMinimum.Version
        $text | Should -Match '^\d{2}\.\d{2}\.\d{2}$'
        $parts = $text.Split('.') | ForEach-Object { [int]$_ }
        [version]$text | Should -Be ([version]::new($parts[0], $parts[1], $parts[2]))
    }

    It 'compares below, at and above the minimum of <ModelId>' -ForEach @(
        @{ ModelId = '840-g5' }
        @{ ModelId = '840-g6' }
    ) {
        $minimum = [version](Get-KitProfile -Vendor HP -ModelId $ModelId).FirmwareMinimum.Version
        $lower = [version]::new($minimum.Major, $minimum.Minor - 1, $minimum.Build)
        $higher = [version]::new($minimum.Major, $minimum.Minor + 1, $minimum.Build)
        ($lower -lt $minimum) | Should -BeTrue
        ($minimum -lt $minimum) | Should -BeFalse
        ($higher -gt $minimum) | Should -BeTrue
        ([version]'01.36.00' -eq [version]'1.36.0') | Should -BeTrue
    }
}
