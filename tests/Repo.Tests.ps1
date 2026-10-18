Describe 'Pre-commit secret gate' -Tag Hook {
    BeforeAll {
        function Invoke-RepoNative {
            # Native stderr must not become a terminating error; return the exit code and merged output.
            param(
                [Parameter(Mandatory)]
                [string]$FilePath,

                [string[]]$ArgumentList = @()
            )
            $ErrorActionPreference = 'Continue'
            $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = @($output)
            }
        }

        function New-HookRepo {
            # A throwaway repo in TestDrive holding copies of the gate files, wired to the versioned hook.
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([string])]
            param(
                [Parameter(Mandatory)]
                [string]$Name
            )
            $path = Join-Path -Path $TestDrive -ChildPath $Name
            if (-not $PSCmdlet.ShouldProcess($path, 'Create a throwaway git repo wired to the pre-commit hook')) { return }
            $null = New-Item -Path (Join-Path -Path $path -ChildPath '.githooks') -ItemType Directory -Force
            $setup = @(
                , @('init', '-q')
                , @('config', 'user.name', 'Hook Proof')
                , @('config', 'user.email', 'hook-proof@example.invalid')
                , @('config', 'core.autocrlf', 'false')
                , @('config', 'commit.gpgsign', 'false')
            )
            foreach ($gitArgs in $setup) {
                $r = Invoke-RepoNative -FilePath 'git' -ArgumentList (@('-C', $path) + $gitArgs)
                if ($r.ExitCode -ne 0) { throw "git $($gitArgs -join ' ') failed in ${path}: $($r.Output -join ' ')" }
            }
            foreach ($file in 'Test-Kit.ps1', 'PSScriptAnalyzerSettings.psd1', '.gitleaks.toml', '.githooks\pre-commit') {
                Copy-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath $file) -Destination (Join-Path -Path $path -ChildPath $file)
            }
            $r = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $path, 'config', 'core.hooksPath', '.githooks')
            if ($r.ExitCode -ne 0) { throw "git config core.hooksPath failed in ${path}: $($r.Output -join ' ')" }
            $path
        }

        function Get-TestToken {
            # Built at run time so no literal token ever sits in this file (the repo's own scan would catch it).
            $alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
            $body = -join (1..36 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
            ('gh' + 'p_') + $body
        }

        function Invoke-HookCommit {
            # Stage one file holding $Content and try to commit it through the hook.
            param(
                [Parameter(Mandatory)]
                [string]$Repo,

                [Parameter(Mandatory)]
                [string]$Content
            )
            Set-Content -LiteralPath (Join-Path -Path $Repo -ChildPath 'settings.txt') -Value $Content -Encoding Ascii
            $add = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $Repo, 'add', 'settings.txt')
            if ($add.ExitCode -ne 0) { throw "git add failed in ${Repo}: $($add.Output -join ' ')" }
            $commit = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $Repo, 'commit', '-q', '-m', 'add settings')
            $head = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $Repo, 'rev-parse', '--verify', '-q', 'HEAD')
            [pscustomobject]@{
                CommitExitCode = $commit.ExitCode
                CommitOutput   = $commit.Output -join [Environment]::NewLine
                HeadExitCode   = $head.ExitCode
            }
        }

        $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
        # Same resolution as Test-Kit.ps1: KIT_TOOLS, this checkout's .tools, then the main checkout's .tools.
        $script:toolRoot = if ($env:KIT_TOOLS) {
            $env:KIT_TOOLS
        }
        elseif (Test-Path -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.tools\Modules')) {
            Join-Path -Path $script:repoRoot -ChildPath '.tools'
        }
        else {
            $common = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $script:repoRoot, 'rev-parse', '--path-format=absolute', '--git-common-dir')
            Join-Path -Path (Split-Path -Path ([string]$common.Output[-1]).Trim() -Parent) -ChildPath '.tools'
        }

        # The inner gate (run by the hook) finds the tools here and skips Pester, even when this file runs directly.
        $script:savedTools = $env:KIT_TOOLS
        $script:savedGate = $env:KIT_GATE_ACTIVE
        $env:KIT_TOOLS = $script:toolRoot
        $env:KIT_GATE_ACTIVE = '1'
    }

    AfterAll {
        if ($null -eq $script:savedTools) { Remove-Item -Path Env:\KIT_TOOLS -ErrorAction SilentlyContinue } else { $env:KIT_TOOLS = $script:savedTools }
        if ($null -eq $script:savedGate) { Remove-Item -Path Env:\KIT_GATE_ACTIVE -ErrorAction SilentlyContinue } else { $env:KIT_GATE_ACTIVE = $script:savedGate }
    }

    It 'refuses a commit holding a GitHub-style token' {
        $repo = New-HookRepo -Name 'leak'
        $result = Invoke-HookCommit -Repo $repo -Content "github_token = $(Get-TestToken)"
        $result.CommitExitCode | Should -Not -Be 0 -Because $result.CommitOutput
        $result.HeadExitCode | Should -Not -Be 0 -Because 'a refused commit must not create HEAD'
    }

    It 'refuses the same token when its line carries an inline allow marker' {
        $repo = New-HookRepo -Name 'allow'
        $marker = 'gitleaks' + ':allow'
        $result = Invoke-HookCommit -Repo $repo -Content "github_token = $(Get-TestToken)  # $marker"
        $result.CommitExitCode | Should -Not -Be 0 -Because $result.CommitOutput
        $result.HeadExitCode | Should -Not -Be 0 -Because 'a refused commit must not create HEAD'
    }

    It 'lets a clean commit through and creates HEAD' {
        $repo = New-HookRepo -Name 'clean'
        $result = Invoke-HookCommit -Repo $repo -Content 'log_level = verbose'
        $result.CommitExitCode | Should -Be 0 -Because $result.CommitOutput
        $result.HeadExitCode | Should -Be 0
    }
}
