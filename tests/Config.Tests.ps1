BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:kitFolder = Join-Path $script:repoRoot 'kit'
    $script:coreManifest = Join-Path $script:kitFolder 'core\Kit.Core.psd1'
    Import-Module $script:coreManifest -Force

    # Every test value is shorter than six characters: the installer-account-value secret rule flags longer literals.
    $script:localValue = 'q7zx9'
    $script:otherValue = 'k3m8w'

    # A kit folder in TestDrive holding the real example, and a local file when LocalText is given.
    function Write-TestKitFolder {
        param([Parameter(Mandatory)][string]$Name, [string[]]$LocalText)
        $folder = Join-Path $TestDrive $Name
        $null = New-Item -Path $folder -ItemType Directory -Force
        Copy-Item -LiteralPath (Join-Path $script:kitFolder 'config.example.psd1') -Destination $folder
        if ($LocalText) { Set-Content -LiteralPath (Join-Path $folder 'config.local.psd1') -Value $LocalText }
        $folder
    }

    # The message a script block throws, or $null when it does not throw.
    function Get-ThrownMessage {
        param([Parameter(Mandatory)][scriptblock]$Action)
        try { & $Action } catch { return $_.Exception.Message }
        $null
    }

    # Run git against the repo and return its exit code.
    function Get-GitExitCode {
        param([Parameter(Mandatory)][string[]]$ArgumentList)
        $null = & git -C $script:repoRoot @ArgumentList 2>$null
        $LASTEXITCODE
    }
}

Describe 'config.example.psd1' {
    It 'is tracked by git' {
        Get-GitExitCode -ArgumentList @('ls-files', '--error-unmatch', 'kit/config.example.psd1') | Should -Be 0
    }

    It 'is not ignored' {
        Get-GitExitCode -ArgumentList @('check-ignore', '-q', '--no-index', 'kit/config.example.psd1') | Should -Be 1
    }

    It 'leaves the local file ignored' {
        Get-GitExitCode -ArgumentList @('check-ignore', '-q', '--no-index', 'kit/config.local.psd1') | Should -Be 0
    }

    It 'documents exactly the four third-party keys' {
        $example = Import-PowerShellDataFile -LiteralPath (Join-Path $script:kitFolder 'config.example.psd1')
        @($example.Keys) | Should -Be @('ThirdParty')
        @($example.ThirdParty.Keys | Sort-Object) | Should -Be @('CustomerId', 'InstallToken', 'InstallerUrl', 'IntegratorLogin' | Sort-Object)
    }

    It 'holds only empty-string values' {
        $example = Import-PowerShellDataFile -LiteralPath (Join-Path $script:kitFolder 'config.example.psd1')
        foreach ($key in $example.ThirdParty.Keys) {
            $example.ThirdParty[$key] | Should -BeOfType [string]
            $example.ThirdParty[$key] | Should -BeExactly ''
        }
    }
}

Describe 'Get-KitConfig' {
    It 'returns the empty defaults when there is no local file' {
        $kit = Write-TestKitFolder -Name 'defaults'
        $config = Get-KitConfig -Root $kit
        $config.Source | Should -Be 'Defaults'
        $config.LocalPath | Should -BeNullOrEmpty
        $config.ThirdParty | Should -BeOfType [hashtable]
        foreach ($key in 'InstallerUrl', 'IntegratorLogin', 'CustomerId', 'InstallToken') {
            $config.ThirdParty[$key] | Should -BeExactly ''
        }
    }

    It 'uses the local values and keeps the other keys empty' {
        $kit = Write-TestKitFolder -Name 'local' -LocalText "@{ ThirdParty = @{ CustomerId = '$script:localValue' } }"
        $config = Get-KitConfig -Root $kit
        $config.Source | Should -Be 'Local'
        $config.LocalPath | Should -Be (Join-Path $kit 'config.local.psd1')
        $config.ThirdParty.CustomerId | Should -Be $script:localValue
        $config.ThirdParty.InstallerUrl | Should -BeExactly ''
        $config.ThirdParty.IntegratorLogin | Should -BeExactly ''
        $config.ThirdParty.InstallToken | Should -BeExactly ''
    }

    It 'lets a non-empty override win over the local value' {
        $kit = Write-TestKitFolder -Name 'override' -LocalText "@{ ThirdParty = @{ CustomerId = '$script:localValue' } }"
        $config = Get-KitConfig -Root $kit -Override @{ ThirdParty = @{ CustomerId = $script:otherValue } }
        $config.ThirdParty.CustomerId | Should -Be $script:otherValue
    }

    It 'lets a non-empty override win over the defaults' {
        $kit = Write-TestKitFolder -Name 'override-defaults'
        $config = Get-KitConfig -Root $kit -Override @{ ThirdParty = @{ CustomerId = $script:otherValue } }
        $config.Source | Should -Be 'Defaults'
        $config.ThirdParty.CustomerId | Should -Be $script:otherValue
    }

    It 'does not let an empty override clear the local value' {
        $kit = Write-TestKitFolder -Name 'empty-override' -LocalText "@{ ThirdParty = @{ CustomerId = '$script:localValue' } }"
        $config = Get-KitConfig -Root $kit -Override @{ ThirdParty = @{ CustomerId = '' } }
        $config.ThirdParty.CustomerId | Should -Be $script:localValue
    }

    It 'rejects a local key that is not in the example' {
        $kit = Write-TestKitFolder -Name 'bogus-key' -LocalText "@{ ThirdParty = @{ Bogus = 'x' } }"
        { Get-KitConfig -Root $kit } | Should -Throw '*Unknown config key*ThirdParty.Bogus*'
    }

    It 'rejects a local section that is not in the example' {
        $kit = Write-TestKitFolder -Name 'bogus-section' -LocalText "@{ Other = @{ CustomerId = 'x' } }"
        { Get-KitConfig -Root $kit } | Should -Throw '*Unknown config key*Other*'
    }

    It 'rejects an override key that is not in the example' {
        $kit = Write-TestKitFolder -Name 'bogus-override'
        { Get-KitConfig -Root $kit -Override @{ ThirdParty = @{ Bogus = 'x' } } } | Should -Throw '*Unknown config key*ThirdParty.Bogus*'
    }

    It 'rejects a value that is not text' {
        $kit = Write-TestKitFolder -Name 'not-text' -LocalText '@{ ThirdParty = @{ CustomerId = 7 } }'
        { Get-KitConfig -Root $kit } | Should -Throw '*ThirdParty.CustomerId*text*'
    }

    It 'rejects a local file that contains code and never runs it' {
        $marker = Join-Path $TestDrive 'ran.txt'
        $kit = Write-TestKitFolder -Name 'code' -LocalText "@{ ThirdParty = @{ CustomerId = (New-Item -Path '$marker' -ItemType File) } }"
        { Get-KitConfig -Root $kit } | Should -Throw '*config.local.psd1 is not a plain data file*'
        $marker | Should -Not -Exist
    }

    It 'fails when the example is missing' {
        $kit = Join-Path $TestDrive 'no-example'
        $null = New-Item -Path $kit -ItemType Directory -Force
        { Get-KitConfig -Root $kit } | Should -Throw '*config.example.psd1*'
    }

    It 'writes no config value to any output stream' {
        $kit = Write-TestKitFolder -Name 'streams' -LocalText "@{ ThirdParty = @{ CustomerId = '$script:localValue' } }"
        $captured = @(Get-KitConfig -Root $kit -Verbose -InformationAction Continue *>&1)
        $records = @($captured | Where-Object {
                $_ -is [System.Management.Automation.WarningRecord] -or
                $_ -is [System.Management.Automation.InformationRecord] -or
                $_ -is [System.Management.Automation.ErrorRecord]
            })
        $records | Should -BeNullOrEmpty
        $messages = @($captured | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -or $_ -is [System.Management.Automation.DebugRecord] })
        ($messages | Out-String) | Should -Not -BeLike "*$script:localValue*"
        @($captured | Where-Object { $_.PSObject.TypeNames[0] -eq 'System.Management.Automation.PSCustomObject' }) | Should -HaveCount 1
    }
}

Describe 'Kit.Core exports (config)' {
    BeforeAll {
        $source = Join-Path $script:kitFolder 'core\Config.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $source).Path, [ref]$null, [ref]$null)
        $script:definedInConfig = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name)
        Import-Module $script:coreManifest -Force
        $script:exported = @((Get-Module -Name Kit.Core).ExportedFunctions.Keys)
    }

    It 'exports Get-KitConfig' {
        $script:exported | Should -Contain 'Get-KitConfig'
    }

    It 'exports no other function that Config.ps1 defines' {
        $definedAndExported = @($script:definedInConfig | Where-Object { $script:exported -contains $_ })
        $definedAndExported | Should -Be @('Get-KitConfig')
    }
}
