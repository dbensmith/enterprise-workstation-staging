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
            [switch]$Preview
        )
        & $script:buildScript -Vendor Fixture -VendorRoot $script:vendorRoot -ProfilePath $script:profilePath `
            -OutputRoot $OutputRoot -Stage $Stage -WhatIf:$Preview 6>$null
    }

    function Read-BuildScriptAst {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:buildScript, [ref]$tokens, [ref]$errors)
    }

    $script:buildCmd = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Build.cmd'))

    # Run a native child and return its exit code and merged output. A local Continue lets native stderr through
    # without becoming a terminating error under 5.1.
    function Invoke-BuilderChild {
        param(
            [Parameter(Mandatory)][string]$FilePath,
            [string[]]$ArgumentList = @()
        )
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
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
        Invoke-FixtureBuild -OutputRoot $script:root -Preview
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
        # The value after -Operation is the next element of the command, not the parameter's own Argument.
        $operations = foreach ($command in $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $elements = @($command.CommandElements)
            for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'Operation') {
                    $elements[$i + 1].Value
                }
            }
        }
        $operations | Should -Contain 'NewCustomPack'
        $operations | Should -Contain 'GetFirmware'
    }
}

Describe 'Build.cmd launcher' {
    It 'is stored with CRLF line endings only' {
        $bytes = [IO.File]::ReadAllBytes($script:buildCmd)
        $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
        $crlf = 0
        for ($i = 1; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
        $lf | Should -BeGreaterThan 0
        $crlf | Should -Be $lf
    }
    It 'clears PSModulePath and starts 5.1 with a process-scope bypass on the build script beside it' {
        $text = Get-Content -LiteralPath $script:buildCmd -Raw
        $text | Should -Match ([regex]::Escape('set "PSModulePath="'))
        $text | Should -Match ([regex]::Escape('-ExecutionPolicy Bypass'))
        $text | Should -Match ([regex]::Escape('"%~dp0builder\Build-DriverBaseline.ps1" %*'))
        $text | Should -Match ([regex]::Escape('exit /b %ERRORLEVEL%'))
        $text | Should -Match ([regex]::Escape('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'))
    }
    It 'builds the fixture package from cmd.exe and writes its manifest' {
        $output = Join-Path $TestDrive 'cmd-build'
        $run = Invoke-BuilderChild -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', $script:buildCmd,
            '-Vendor', 'Fixture', '-VendorRoot', $script:vendorRoot, '-ProfilePath', $script:profilePath, '-OutputRoot', $output)
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $manifestPath = Join-Path $output 'fixture\m1\win11-24H2\manifest.json'
        $manifestPath | Should -Exist
        (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).Vendor | Should -Be 'Fixture'
    }
    It 'returns the build script exit code for a profile that does not exist' {
        $run = Invoke-BuilderChild -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', $script:buildCmd,
            '-Vendor', 'Fixture', '-VendorRoot', $script:vendorRoot, '-ProfilePath', (Join-Path $TestDrive 'missing.psd1'), '-OutputRoot', (Join-Path $TestDrive 'cmd-missing'))
        $run.ExitCode | Should -Not -Be 0
    }
}
