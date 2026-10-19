BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    $script:vendorsFolder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\vendors'))
    $script:completeTarget = Join-Path $script:vendorsFolder 'complete\Fixture.Target.psm1'

    # Write a minimal descriptor into a folder and return its path. The Commands table is empty: these tests
    # resolve vendors and dispatch, they do not check the contract.
    function Write-VendorDescriptor {
        param(
            [Parameter(Mandatory)][string]$Folder,
            [Parameter(Mandatory)][string]$Name,
            [string]$BuildModule
        )
        $null = New-Item -Path $Folder -ItemType Directory -Force
        $lines = @(
            '@{'
            "    Name = '$Name'"
            "    Manufacturer = '^$Name\b'"
            "    TargetModule = '$script:completeTarget'"
        )
        if ($BuildModule) { $lines += "    BuildModule = '$BuildModule'" }
        $lines += '    Commands = @{}'
        $lines += '}'
        $path = Join-Path $Folder 'vendor.psd1'
        Set-Content -LiteralPath $path -Value ($lines -join [Environment]::NewLine)
        $path
    }

    # The message a script block throws, or $null when it does not throw.
    function Get-ThrownMessage {
        param([Parameter(Mandatory)][scriptblock]$Action)
        try { & $Action } catch { return $_.Exception.Message }
        $null
    }
}

AfterAll {
    foreach ($module in 'Fixture.Target', 'Fixture.Build') { Remove-Module -Name $module -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-KitVendor' {
    It 'resolves a vendor by Name with its module paths' {
        $vendor = Get-KitVendor -Name Fixture -VendorRoot $script:vendorsFolder
        @($vendor) | Should -HaveCount 1
        $vendor.Name | Should -Be 'Fixture'
        $vendor.TargetModulePath | Should -BeLike '*Fixture.Target.psm1'
        $vendor.BuildModulePath | Should -BeLike '*Fixture.Build.psm1'
        $vendor.Commands.InstallDrivers | Should -Be 'Install-FixtureKitDriver'
    }

    It 'matches Name case-insensitively and by equality, not prefix' {
        (Get-KitVendor -Name fixture -VendorRoot $script:vendorsFolder).Name | Should -Be 'Fixture'
    }

    It 'resolves a vendor by Manufacturer regex' {
        (Get-KitVendor -Manufacturer 'Fixture Inc' -VendorRoot $script:vendorsFolder).Name | Should -Be 'Fixture'
    }

    It 'lists the available vendor names when nothing matches' {
        $message = Get-ThrownMessage { Get-KitVendor -Manufacturer 'Nobody Corp' -VendorRoot $script:vendorsFolder }
        $message | Should -BeLike "*No vendor matches 'Nobody Corp'*"
        $message | Should -BeLike '*Available:*Fixture*FixtureMissingOp*'
    }

    It 'rejects a Name nothing matches' {
        { Get-KitVendor -Name Absent -VendorRoot $script:vendorsFolder } | Should -Throw "*No vendor matches 'Absent'*"
    }

    It 'reads one descriptor by path' {
        (Get-KitVendor -DescriptorPath (Join-Path $script:vendorsFolder 'missing-op\vendor.psd1')).Name | Should -Be 'FixtureMissingOp'
    }

    It 'returns every vendor under the roots when no selector is given' {
        @(Get-KitVendor -VendorRoot $script:vendorsFolder | ForEach-Object { $_.Name }) | Should -Be @('Fixture', 'FixtureMissingOp')
    }

    It 'throws, naming both descriptor paths, when two descriptors declare one Name' {
        $first = Write-VendorDescriptor -Folder (Join-Path $TestDrive 'dup\a') -Name 'Dup'
        $second = Write-VendorDescriptor -Folder (Join-Path $TestDrive 'dup\b') -Name 'Dup'
        $message = Get-ThrownMessage { Get-KitVendor -Name Dup -VendorRoot (Join-Path $TestDrive 'dup') }
        $message | Should -BeLike "*Vendor 'Dup' is declared by more than one descriptor*"
        $message.Contains($first) | Should -BeTrue
        $message.Contains($second) | Should -BeTrue
        { Get-KitVendor -Name Other -VendorRoot (Join-Path $TestDrive 'dup') } | Should -Throw '*declared by more than one descriptor*'
    }

    It 'throws, naming the root, when a vendor root holds no descriptor' {
        $root = Join-Path $TestDrive 'empty-root'
        $null = New-Item -Path $root -ItemType Directory -Force
        $message = Get-ThrownMessage { Get-KitVendor -VendorRoot $root }
        $message | Should -BeLike '*No vendor descriptors (vendor.psd1) under*'
        $message.Contains($root) | Should -BeTrue
    }

    It 'reports a build module file that is absent as a null BuildModulePath' {
        $path = Write-VendorDescriptor -Folder (Join-Path $TestDrive 'tools-stick') -Name 'ToolsOnly' -BuildModule (Join-Path $TestDrive 'tools-stick\Absent.Build.psm1')
        (Get-KitVendor -DescriptorPath $path).BuildModulePath | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-KitVendorCommand' {
    BeforeAll {
        $script:fixtureVendor = Get-KitVendor -Name Fixture -VendorRoot $script:vendorsFolder
    }

    It 'runs a target operation with the given parameters' {
        $result = Invoke-KitVendorCommand -Vendor $script:fixtureVendor -Operation InstallDrivers -Parameters @{ PackagePath = 'p' }
        $result.Operation | Should -Be 'InstallDrivers'
        $result.PackagePath | Should -Be 'p'
    }

    It 'runs a target helper' {
        (Invoke-KitVendorCommand -Vendor $script:fixtureVendor -Operation GetDeviceIdentity).PlatformId | Should -Be '0000'
    }

    It 'runs a build operation through the build module' {
        $result = Invoke-KitVendorCommand -Vendor $script:fixtureVendor -Operation GetFirmware -Parameters @{ ModelProfile = 'm'; OsVer = '24H2'; OutputPath = 'o' }
        $result.Operation | Should -Be 'GetFirmware'
        $result.OutputPath | Should -Be 'o'
    }

    It 'refuses a build operation when the vendor has no build module' {
        $path = Write-VendorDescriptor -Folder (Join-Path $TestDrive 'no-build') -Name 'NoBuild'
        $vendor = Get-KitVendor -DescriptorPath $path
        $message = Get-ThrownMessage { Invoke-KitVendorCommand -Vendor $vendor -Operation ListModels }
        $message | Should -BeLike "*Vendor 'NoBuild' has no Build module*"
    }

    It 'rejects an operation outside the contract' {
        { Invoke-KitVendorCommand -Vendor $script:fixtureVendor -Operation NoSuchOperation } | Should -Throw
    }
}

Describe 'Kit.Core exports (vendor)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
        $script:exported = @((Get-Module -Name Kit.Core).ExportedFunctions.Keys)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\kit\core\Vendor.ps1'), [ref]$null, [ref]$null)
        $script:defined = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
    }

    It 'exports the three vendor functions' {
        $script:exported | Should -Contain 'Get-KitVendor'
        $script:exported | Should -Contain 'Test-KitVendorContract'
        $script:exported | Should -Contain 'Invoke-KitVendorCommand'
    }

    It 'keeps every other function Vendor.ps1 defines private' {
        $private = @($script:defined | Where-Object { $_ -notin 'Get-KitVendor', 'Test-KitVendorContract', 'Invoke-KitVendorCommand' })
        $private | Should -Not -BeNullOrEmpty
        @($private | Where-Object { $script:exported -contains $_ }) | Should -BeNullOrEmpty
    }
}
