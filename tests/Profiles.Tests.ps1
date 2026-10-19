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
        $script:expectedProfileExports = @('Get-KitProfile')
        Import-Module $script:coreManifest -Force
        $script:exported = @((Get-Module -Name Kit.Core).ExportedFunctions.Keys)
    }

    It 'exports Get-KitProfile' {
        $script:exported | Should -Contain 'Get-KitProfile'
    }

    It 'exports exactly the expected names among the functions Profile.ps1 defines' {
        $definedAndExported = @($script:definedInProfile | Where-Object { $script:exported -contains $_ })
        $definedAndExported | Sort-Object | Should -Be @($script:expectedProfileExports | Sort-Object)
    }
}
