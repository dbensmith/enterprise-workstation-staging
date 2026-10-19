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
    It 'runs the whole path from cmd.exe as a -WhatIf rehearsal and exits 0' {
        $run = Invoke-KitChild -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'kit\Run.cmd', '-Mode', 'Install', '-PackagePath', $script:minimalPackage, '-Vendor', 'HP', '-Force', '-WhatIf')
        $run.Output | Should -Match 'Baseline: Fixture package'
        $run.Output | Should -Match 'Done with 0 failure\(s\)'
        $run.ExitCode | Should -Be 0
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
