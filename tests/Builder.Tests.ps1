BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    $script:buildScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\builder\Build-DriverBaseline.ps1'))
    $script:vendorRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\vendors'))
    $script:profilePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\profiles\fixture\m1.psd1'))

    # Run the build script in-process against the fixture vendor and profile; the information stream is discarded.
    function Invoke-FixtureBuild {
        param(
            [Parameter(Mandatory)][string]$OutputRoot,
            [string[]]$Stage = @('Drivers', 'Firmware'),
            [switch]$WhatIf
        )
        & $script:buildScript -Vendor Fixture -VendorRoot $script:vendorRoot -ProfilePath $script:profilePath `
            -OutputRoot $OutputRoot -Stage $Stage -WhatIf:$WhatIf 6>$null
    }

    function Read-BuildScriptAst {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:buildScript, [ref]$tokens, [ref]$errors)
    }
}

Describe 'Build-DriverBaseline through the vendor interface' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:packageDir = Join-Path $script:root 'fixture\m1\win11-24H2'
        $script:manifestPath = Join-Path $script:packageDir 'manifest.json'
    }

    Context 'a full build' {
        BeforeEach {
            Invoke-FixtureBuild -OutputRoot $script:root
            $script:manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        }
        It 'writes the manifest into the per-vendor/model package folder' {
            $script:manifestPath | Should -Exist
            $script:manifest.Vendor | Should -Be 'Fixture'
            $script:manifest.ModelId | Should -Be 'm1'
            $script:manifest.Platform | Should -Be '0000'
            $script:manifest.OsVer | Should -Be '24H2'
            $script:manifest.SchemaVersion | Should -Be 2
        }
        It 'records the driver and firmware entries and the tool versions' {
            $script:manifest.Drivers[0].Id | Should -Be 'fx001'
            $script:manifest.Firmware[0].Id | Should -Be 'fx100'
            $script:manifest.ToolVersions.FixtureTool | Should -Be '1.0'
        }
        It 'holds the vendor driver output' {
            Join-Path $script:packageDir 'Drivers\fixture.inf' | Should -Exist
        }
        It 'copies no script into the package (packages are data only)' {
            $scripts = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'fixture') -Recurse -File |
                    Where-Object { $_.Extension -in '.ps1', '.psm1' })
            $scripts | Should -BeNullOrEmpty
        }
    }

    It 'keeps the Drivers entries of the previous manifest on a -Stage Firmware rerun' {
        Invoke-FixtureBuild -OutputRoot $script:root
        Invoke-FixtureBuild -OutputRoot $script:root -Stage Firmware
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $manifest.Drivers[0].Id | Should -Be 'fx001'
        $manifest.Firmware[0].Id | Should -Be 'fx100'
    }

    It 'writes no manifest under -WhatIf' {
        Invoke-FixtureBuild -OutputRoot $script:root -WhatIf
        $script:manifestPath | Should -Not -Exist
    }
}

Describe 'Build-DriverBaseline script shape' {
    BeforeAll {
        # A missing script must fail every It below, not let the scans find nothing.
        $script:buildScript | Should -Exist
        $script:ast = Read-BuildScriptAst
        $script:ast | Should -Not -BeNullOrEmpty
    }
    It 'names no HP command and no HP string' {
        $commands = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-HP|HPCMSL' }
        $strings = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            Where-Object { $_.Value -in 'HP', 'HPCMSL' }
        @($commands) + @($strings | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
    }
    It 'copies nothing into the package' {
        $copies = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Copy-Item' }, $true)
        $copies | Should -BeNullOrEmpty
    }
    It 'defaults -OutputRoot to the staging folder next to the repo' {
        $parameter = $script:ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'OutputRoot' }
        $parameter.DefaultValue.Extent.Text | Should -Be "(Join-Path `$PSScriptRoot '..\staging')"
    }
    It 'runs the build through the vendor operations' {
        $operations = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandParameterAst] -and $node.ParameterName -eq 'Operation' }, $true) |
            ForEach-Object { $_.Argument.Value }
        $operations | Should -Contain 'NewCustomPack'
        $operations | Should -Contain 'GetFirmware'
    }
}
