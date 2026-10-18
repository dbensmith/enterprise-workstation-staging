BeforeDiscovery {
    # Same file set Test-Kit.ps1 lints: tracked plus untracked-but-not-ignored.
    $script:discoveryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
    $script:visibleFiles = @(& git -C $script:discoveryRoot ls-files --cached --others --exclude-standard)
    $script:scriptFiles = @($script:visibleFiles | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' } | ForEach-Object { @{ File = $_ } })
    $script:asciiFiles = @($script:visibleFiles | Where-Object { $_ -match '\.(ps1|psm1|psd1|cmd)$' -or $_ -eq '.githooks/pre-commit' } |
            ForEach-Object { @{ File = $_ } })
    $script:hasPwsh = [bool](Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue)
}

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

    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
}

Describe 'Pre-commit secret gate' -Tag Hook {
    BeforeAll {
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

Describe 'Lint and repo hygiene' {
    BeforeAll {
        $list = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $script:repoRoot, 'ls-files', '--cached', '--others', '--exclude-standard')
        $script:visible = @($list.Output)
        # Built at run time so this file does not itself carry the marker it looks for.
        $script:marker = 'gitleaks' + ':allow'
    }

    It 'PSScriptAnalyzerSettings.psd1 holds only Rules, and every rule sets Enable = $true' {
        $settings = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1')
        @($settings.Keys) | Should -Be @('Rules') -Because 'ExcludeRules, IncludeRules and Severity would filter findings'
        $settings.Rules.Count | Should -BeGreaterThan 0
        foreach ($rule in $settings.Rules.GetEnumerator()) {
            $rule.Value | Should -BeOfType [hashtable] -Because "$($rule.Key) must be a rule configuration"
            ($rule.Value.Enable -is [bool] -and $rule.Value.Enable) | Should -BeTrue -Because "$($rule.Key) must set Enable = `$true"
        }
    }

    It '<File> carries no SuppressMessage attribute' -ForEach $scriptFiles {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $script:repoRoot -ChildPath $File), [ref]$null, [ref]$null)
        $suppressions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AttributeAst] -and $node.TypeName.FullName -like '*SuppressMessage*'
            }, $true)
        @($suppressions).Count | Should -Be 0
    }

    It 'has no .gitleaksignore and no allowlist in .gitleaks.toml' {
        Join-Path -Path $script:repoRoot -ChildPath '.gitleaksignore' | Should -Not -Exist
        Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.gitleaks.toml') -Raw | Should -Not -Match 'allowlist'
    }

    It 'no git-visible file outside .planning/ and .claude/ carries the inline allow marker' {
        $offenders = foreach ($file in $script:visible) {
            if ($file -match '^\.(planning|claude)/') { continue }
            $full = Join-Path -Path $script:repoRoot -ChildPath $file
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            if ([IO.File]::ReadAllText($full).IndexOf($script:marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $file }
        }
        @($offenders) | Should -BeNullOrEmpty
    }

    It '<File> is pure ASCII' -ForEach $asciiFiles {
        # Windows PowerShell 5.1 reads a BOM-less non-ASCII script as ANSI. Latin-1 maps each byte to one char.
        $text = [Text.Encoding]::GetEncoding('iso-8859-1').GetString([IO.File]::ReadAllBytes((Join-Path -Path $script:repoRoot -ChildPath $File)))
        $hit = [regex]::Match($text, '[^\x00-\x7F]')
        $hit.Success | Should -BeFalse -Because "byte offset $($hit.Index) is 0x80 or above"
    }

    It '.githooks/pre-commit has LF line endings, kept LF by .gitattributes' {
        [IO.File]::ReadAllBytes((Join-Path -Path $script:repoRoot -ChildPath '.githooks\pre-commit')) -contains [byte]13 | Should -BeFalse
        $attr = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $script:repoRoot, 'check-attr', 'eol', '--', '.githooks/pre-commit')
        ($attr.Output -join '') | Should -BeLike '*: eol: lf'
    }

    It '.cmd launchers check out with CRLF' {
        $attr = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $script:repoRoot, 'check-attr', 'eol', '--', 'kit/Run.cmd')
        ($attr.Output -join '') | Should -BeLike '*: eol: crlf'
    }

    It 'Test-Kit.ps1 refuses to run under PowerShell 7 (exit 2)' -Skip:(-not $hasPwsh) {
        $run = Invoke-RepoNative -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', (Join-Path -Path $script:repoRoot -ChildPath 'Test-Kit.ps1'))
        $run.ExitCode | Should -Be 2
        ($run.Output -join ' ') | Should -BeLike '*Windows PowerShell 5.1*'
    }

    It 'git ignores <IgnoredPath>' -ForEach @(
        @{ IgnoredPath = 'staging/hp/840-g6/win11-24H2/manifest.json' }
        @{ IgnoredPath = '.tools/Modules/x' }
        @{ IgnoredPath = 'kit/config.local.psd1' }
        @{ IgnoredPath = 'HP_Staging/x' }
        @{ IgnoredPath = 'results/x.txt' }
    ) {
        $check = Invoke-RepoNative -FilePath 'git' -ArgumentList @('-C', $script:repoRoot, 'check-ignore', '-q', '--no-index', $IgnoredPath)
        $check.ExitCode | Should -Be 0
    }
}
