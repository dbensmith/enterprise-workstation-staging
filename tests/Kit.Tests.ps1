BeforeAll {
    $script:repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:runCmd = Join-Path $script:repo 'kit\Run.cmd'
    $script:runPs1 = Join-Path $script:repo 'kit\Run.ps1'
    $script:installer = Join-Path $script:repo 'kit\Install-DriverBaseline.ps1'
    $script:minimalPackage = 'tests\fixtures\packages\minimal'

    # Run a native child from the repo root and return its exit code and merged output.
    # A local Continue lets native stderr through without becoming a terminating error under 5.1.
    function Invoke-KitChild {
        param(
            [Parameter(Mandatory)][string]$FilePath,
            [string[]]$ArgumentList = @(),
            [string]$WorkingDirectory = $script:repo
        )
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
        }
        finally {
            Pop-Location
        }
    }

    function Read-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    }

    function Get-CommandNameList {
        param([Parameter(Mandatory)]$Ast)
        @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
}

Describe 'Run.cmd launcher' {
    It 'is stored with CRLF line endings only' {
        $bytes = [IO.File]::ReadAllBytes($script:runCmd)
        $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
        $crlf = 0
        for ($i = 1; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10 -and $bytes[$i - 1] -eq 13) { $crlf++ }
        }
        $lf | Should -BeGreaterThan 0
        $crlf | Should -Be $lf
    }
    It 'clears PSModulePath and starts 5.1 with a process-scope bypass on the Run.ps1 beside it' {
        $text = Get-Content -LiteralPath $script:runCmd -Raw
        $text | Should -Match ([regex]::Escape('set "PSModulePath="'))
        $text | Should -Match ([regex]::Escape('-ExecutionPolicy Bypass'))
        $text | Should -Match ([regex]::Escape('"%~dp0Run.ps1" %*'))
        $text | Should -Match ([regex]::Escape('exit /b %ERRORLEVEL%'))
        $text | Should -Match ([regex]::Escape('%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'))
    }
    It 'is marked eol=crlf in .gitattributes' {
        $attr = & git -C $script:repo check-attr eol -- kit/Run.cmd
        "$attr" | Should -Match 'eol: crlf'
    }
}

Describe 'Install through the vendor interface' {
    Context 'a -WhatIf rehearsal from cmd.exe' {
        BeforeAll {
            $script:rehearsal = Invoke-KitChild -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'kit\Run.cmd', '-Mode', 'Install', '-PackagePath', $script:minimalPackage, '-Vendor', 'HP', '-Force', '-WhatIf')
        }
        It 'runs the whole path and exits 0' {
            $script:rehearsal.Output | Should -Match 'Baseline: Fixture package'
            $script:rehearsal.Output | Should -Match 'Done with 0 failure\(s\)'
            $script:rehearsal.ExitCode | Should -Be 0
        }
        It 'reports whether third-party settings are present' {
            $script:rehearsal.Output | Should -Match '(?m)^(WARNING: )?Third-party settings: '
        }
    }
    It 'refuses -Mode Install without a package path' {
        $run = Invoke-KitChild -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'kit\Run.cmd', '-Mode', 'Install', '-WhatIf')
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match '-PackagePath is required'
    }
    Context 'the installer script' {
        BeforeAll {
            $script:installerAst = Read-ScriptAst -Path $script:installer
        }
        It 'declares the documented parameters' {
            $names = @($script:installerAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($expected in 'PackagePath', 'OfflineImagePath', 'SkipFirmware', 'Force', 'LogPath', 'Vendor') {
                $names | Should -Contain $expected
            }
        }
        It 'names no vendor command and does not load the config' {
            $commands = Get-CommandNameList -Ast $script:installerAst
            $commands | Should -Contain 'Invoke-KitVendorCommand'
            @($commands | Where-Object { $_ -like '*-HP*' -or $_ -like '*HPCMSL*' }) | Should -BeNullOrEmpty
            $commands | Should -Not -Contain 'Get-KitConfig'
        }
    }
}

Describe 'Installer transcript and exit codes' {
    BeforeAll {
        # The first-boot shape: powershell.exe -File <installer> -PackagePath <p> -LogPath <file>
        function Invoke-InstallerChild {
            param(
                [Parameter(Mandatory)][string]$Package,
                [Parameter(Mandatory)][string]$Log,
                [string[]]$Extra = @()
            )
            Invoke-KitChild -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'kit\Install-DriverBaseline.ps1',
                    '-PackagePath', $Package, '-Vendor', 'HP', '-Force', '-WhatIf', '-LogPath', $Log) + $Extra)
        }
    }
    It 'binds -LogPath, exits 0 and keeps the run in the transcript' {
        $log = Join-Path $TestDrive 'first.log'
        $run = Invoke-InstallerChild -Package 'tests\fixtures\packages\minimal' -Log $log
        $run.ExitCode | Should -Be 0
        $log | Should -Exist
        $text = Get-Content -LiteralPath $log -Raw
        $text | Should -Match 'Done with 0 failure\(s\)'
        $text | Should -Match 'End time'
    }
    It 'exits 1 for a missing firmware executable and still closes the transcript' {
        $log = Join-Path $TestDrive 'broken.log'
        $run = Invoke-InstallerChild -Package 'tests\fixtures\packages\broken-fw' -Log $log
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'executable not found'
        $text = Get-Content -LiteralPath $log -Raw
        $text | Should -Match 'executable not found'
        $text | Should -Match 'End time'
    }
    It 'rehearses an offline image injection and shows the dism.exe command' {
        $package = Join-Path $TestDrive 'offline-pkg'
        $null = New-Item -ItemType Directory -Path (Join-Path $package 'Drivers') -Force
        Copy-Item -LiteralPath (Join-Path $script:repo 'tests\fixtures\packages\minimal\manifest.json') -Destination $package
        $image = Join-Path $TestDrive 'mounted-image'
        $null = New-Item -ItemType Directory -Path $image -Force
        $run = Invoke-KitChild -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'kit\Install-DriverBaseline.ps1',
            '-PackagePath', $package, '-Vendor', 'HP', '-OfflineImagePath', $image, '-WhatIf')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'dism\.exe'
    }
    It 'writes the transcript start and stop inside try/finally with WhatIf off' {
        $text = Get-Content -LiteralPath $script:installer -Raw
        $text | Should -Match ([regex]::Escape('Start-Transcript -Path $LogPath -Append -WhatIf:$false'))
        $ast = Read-ScriptAst -Path $script:installer
        $try = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $false))
        $try.Count | Should -Be 1
        $try[0].Finally.Extent.Text | Should -Match ([regex]::Escape('Stop-Transcript -WhatIf:$false'))
    }
}

Describe 'Run.ps1 config presence and elevation' {
    BeforeAll {
        $script:runAst = Read-ScriptAst -Path $script:runPs1
        $script:auditIf = @($script:runAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match "\`$Mode\s+-eq\s+'Audit'"
                }, $false))
    }
    It 'starts exactly one elevated process, in the Install branch only' {
        $starts = @($script:runAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process'
                }, $true))
        $starts.Count | Should -Be 1
        $starts[0].Extent.Text | Should -Match '-Verb\s+RunAs'
        $script:auditIf.Count | Should -Be 1
        $script:auditIf[0].ElseClause | Should -Not -BeNullOrEmpty
        $install = $script:auditIf[0].ElseClause.Extent
        $starts[0].Extent.StartOffset | Should -BeGreaterThan $install.StartOffset
        $starts[0].Extent.EndOffset | Should -BeLessThan $install.EndOffset
    }
    It 'quotes the relaunch line with ConvertTo-KitCommandLine and reads the config' {
        $text = Get-Content -LiteralPath $script:runPs1 -Raw
        $text | Should -Match 'ConvertTo-KitCommandLine'
        $text | Should -Match 'Get-KitConfig'
        $text | Should -Not -Match 'Set-ExecutionPolicy'
    }
    It 'shows that settings are present without printing a value' {
        $copy = Join-Path $TestDrive 'kitcopy'
        Copy-Item -LiteralPath (Join-Path $script:repo 'kit') -Destination $copy -Recurse
        $secret = 'zz-sentinel-' + [guid]::NewGuid().ToString('N')
        Set-Content -LiteralPath (Join-Path $copy 'config.local.psd1') -Value "@{ ThirdParty = @{ InstallToken = '$secret' } }"
        $log = Join-Path $TestDrive 'secret.log'
        $package = Join-Path $script:repo 'tests\fixtures\packages\minimal'
        $run = Invoke-KitChild -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', (Join-Path $copy 'Run.cmd'), '-Mode', 'Install', '-PackagePath', $package, '-Vendor', 'HP', '-Force', '-WhatIf', '-LogPath', $log)
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'Third-party settings: found in config\.local\.psd1'
        $run.Output | Should -Not -Match $secret
        (Get-Content -LiteralPath $log -Raw) | Should -Not -Match $secret
    }
}
