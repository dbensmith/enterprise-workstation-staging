BeforeDiscovery {
    $script:operationNames = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\kit\core\VendorContract.psd1')).Operations |
            ForEach-Object { $_.Name })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    $script:vendorsFolder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\vendors'))
    $script:completeFolder = Join-Path $script:vendorsFolder 'complete'
    $script:completeTarget = Join-Path $script:completeFolder 'Fixture.Target.psm1'
    $script:completeBuild = Join-Path $script:completeFolder 'Fixture.Build.psm1'
    $script:completeCommands = (Import-PowerShellDataFile -Path (Join-Path $script:completeFolder 'vendor.psd1')).Commands

    # Write a descriptor built from text into a TestDrive folder and return its path. Module paths are rooted
    # and point at the complete fixture's modules unless a test passes its own.
    function Write-TestDescriptor {
        param(
            [Parameter(Mandatory)][string]$Folder,
            [string]$Name = 'FixtureClone',
            [string]$TargetModule = $script:completeTarget,
            [string]$BuildModule = $script:completeBuild,
            [hashtable]$Commands = $script:completeCommands
        )
        $null = New-Item -Path $Folder -ItemType Directory -Force
        $lines = foreach ($key in ($Commands.Keys | Sort-Object)) { "        '{0}' = '{1}'" -f $key, $Commands[$key] }
        $text = @(
            '@{'
            "    Name = '$Name'"
            "    Manufacturer = '^Fixture Clone\b'"
            "    TargetModule = '$TargetModule'"
            "    BuildModule = '$BuildModule'"
            '    Commands = @{'
            $lines
            '    }'
            '}'
        ) -join [Environment]::NewLine
        $path = Join-Path $Folder 'vendor.psd1'
        Set-Content -LiteralPath $path -Value $text
        $path
    }
}

Describe 'Test-KitVendorContract negatives' {
    It 'reports exactly one MissingOperation when <_> is absent from Commands' -ForEach $script:operationNames {
        $operation = $_
        $commands = $script:completeCommands.Clone()
        $commands.Remove($operation)
        $path = Write-TestDescriptor -Folder (Join-Path $TestDrive "drop-$operation") -Commands $commands
        $found = @(Test-KitVendorContract -DescriptorPath $path)
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'MissingOperation'
        $found[0].Operation | Should -Be $operation
    }

    It 'reports exactly one CommandNotFound when <_> maps to a command the module does not export' -ForEach $script:operationNames {
        $operation = $_
        $commands = $script:completeCommands.Clone()
        $commands[$operation] = 'Get-NoSuchFixtureCommand'
        $path = Write-TestDescriptor -Folder (Join-Path $TestDrive "bad-$operation") -Commands $commands
        $found = @(Test-KitVendorContract -DescriptorPath $path)
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'CommandNotFound'
        $found[0].Operation | Should -Be $operation
    }

    It 'reports MissingParameter naming the parameter a command lacks' {
        $folder = Join-Path $TestDrive 'short-param'
        $null = New-Item -Path $folder -ItemType Directory -Force
        $module = Join-Path $folder 'Short.Build.psm1'
        Set-Content -LiteralPath $module -Value @'
function Get-FixtureKitModel { [CmdletBinding()] param() }
function Save-FixtureKitVendorPack { [CmdletBinding()] param($ModelProfile, $OsVer, $OutputPath) }
function New-FixtureKitCustomPack { [CmdletBinding()] param($ModelProfile, $OsVer) }
function Save-FixtureKitFirmware { [CmdletBinding()] param($ModelProfile, $OsVer, $OutputPath) }
Export-ModuleMember -Function *
'@
        $path = Write-TestDescriptor -Folder $folder -BuildModule $module
        $found = @(Test-KitVendorContract -DescriptorPath $path)
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'MissingParameter'
        $found[0].Operation | Should -Be 'NewCustomPack'
        $found[0].Detail | Should -Be 'OutputPath'
    }

    It 'reports a Commands key outside the contract as UnknownOperation' {
        $commands = $script:completeCommands.Clone()
        $commands['BogusOperation'] = 'Get-FixtureKitModel'
        $path = Write-TestDescriptor -Folder (Join-Path $TestDrive 'unknown-op') -Commands $commands
        $found = @(Test-KitVendorContract -DescriptorPath $path)
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'UnknownOperation'
        $found[0].Operation | Should -Be 'BogusOperation'
    }

    It 'reports a descriptor that holds code as InvalidDescriptor and never runs the code' {
        $folder = Join-Path $TestDrive 'code-descriptor'
        $null = New-Item -Path $folder -ItemType Directory -Force
        $marker = Join-Path $TestDrive 'ran.txt'
        $text = @(
            '@{'
            "    Name = (Set-Content -LiteralPath '$marker' -Value 'ran')"
            "    Manufacturer = '^Fixture Clone\b'"
            "    TargetModule = '$script:completeTarget'"
            '    Commands = @{}'
            '}'
        ) -join [Environment]::NewLine
        $path = Join-Path $folder 'vendor.psd1'
        Set-Content -LiteralPath $path -Value $text
        $found = @(Test-KitVendorContract -DescriptorPath $path)
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'InvalidDescriptor'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'reports a missing BuildModule file as ModuleNotFound, and -Plane Target checks nothing there' {
        $folder = Join-Path $TestDrive 'no-build'
        $path = Write-TestDescriptor -Folder $folder -BuildModule (Join-Path $folder 'Absent.Build.psm1')
        $found = @(Test-KitVendorContract -DescriptorPath $path)
        $found | Should -HaveCount 1
        $found[0].Kind | Should -Be 'ModuleNotFound'
        $found[0].Detail | Should -BeLike '*Absent.Build.psm1*'
        @(Test-KitVendorContract -DescriptorPath $path -Plane Target) | Should -BeNullOrEmpty
    }

    It 'reports every contract entry as MissingOperation, in contract order and identically on a second run, for empty Commands' {
        $path = Write-TestDescriptor -Folder (Join-Path $TestDrive 'empty-commands') -Commands @{}
        $first = @(Test-KitVendorContract -DescriptorPath $path)
        $second = @(Test-KitVendorContract -DescriptorPath $path)
        $first | Should -HaveCount 8
        @($first | ForEach-Object { $_.Kind } | Select-Object -Unique) | Should -Be @('MissingOperation')
        @($first | ForEach-Object { $_.Operation }) | Should -Be $script:operationNames
        @($second | ForEach-Object { '{0}|{1}|{2}' -f $_.Operation, $_.Kind, $_.Detail }) |
            Should -Be @($first | ForEach-Object { '{0}|{1}|{2}' -f $_.Operation, $_.Kind, $_.Detail })
    }

    It 'leaves the fixture folder byte for byte unchanged' {
        $snapshot = {
            @(Get-ChildItem -LiteralPath $script:completeFolder -Recurse -File | Sort-Object -Property FullName |
                    ForEach-Object { '{0} {1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        }
        $before = & $snapshot
        $null = @(Test-KitVendorContract -DescriptorPath (Join-Path $script:completeFolder 'vendor.psd1'))
        $after = & $snapshot
        $before | Should -Not -BeNullOrEmpty
        $after | Should -Be $before
    }
}

Describe 'Contract test as a gate' {
    BeforeAll {
        $script:contractTest = Join-Path $PSScriptRoot 'Contract.Tests.ps1'
        $script:pesterManifest = Join-Path (Get-Module -Name Pester).ModuleBase 'Pester.psd1'
        $script:runner = Join-Path $TestDrive 'Invoke-ContractRun.ps1'
        Set-Content -LiteralPath $script:runner -Value @'
param([string]$PesterManifest, [string]$TestFile, [string]$VendorRoot)
Import-Module -Name $PesterManifest -Force
$config = New-PesterConfiguration
$config.Run.Container = New-PesterContainer -Path $TestFile -Data @{ VendorRoot = @($VendorRoot) }
$config.Run.Exit = $true
$config.Output.Verbosity = 'None'
Invoke-Pester -Configuration $config
'@
        # Run the contract test file in its own powershell.exe against one vendor root; return the exit code.
        function Get-ContractRunExitCode {
            param([Parameter(Mandatory)][string]$VendorRoot)
            $ErrorActionPreference = 'Continue'
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:runner `
                -PesterManifest $script:pesterManifest -TestFile $script:contractTest -VendorRoot $VendorRoot 2>&1
            $LASTEXITCODE
        }
    }

    It 'exits 1 for a vendor missing an operation' {
        Get-ContractRunExitCode -VendorRoot (Join-Path $script:vendorsFolder 'missing-op') | Should -Be 1
    }

    It 'exits 0 for a complete vendor' {
        Get-ContractRunExitCode -VendorRoot $script:completeFolder | Should -Be 0
    }

    It 'does not pass vacuously when no descriptor is found' {
        $empty = Join-Path $TestDrive 'no-vendors'
        $null = New-Item -Path $empty -ItemType Directory -Force
        Get-ContractRunExitCode -VendorRoot $empty | Should -Not -Be 0
    }
}
