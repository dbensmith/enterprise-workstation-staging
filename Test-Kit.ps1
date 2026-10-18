#Requires -Version 5.1

<#
.SYNOPSIS
Run the repo's quality and secret gates: lint, tests and gitleaks, under Windows PowerShell 5.1.

.DESCRIPTION
One script for every gate (D-14). With no switch it lints every git-visible .ps1/.psm1/.psd1 file
with PSScriptAnalyzer (zero findings allowed) and then runs the Pester suite under tests\.
The pre-commit hook (.githooks\pre-commit) runs it with -PreCommit, which first scans the staged
changes with gitleaks and stops the commit on any finding.

Tools are pinned and live in the gitignored .tools\ folder; -InstallTools fetches them once.
Each stage prints one line: [PASS], [FAIL] or [SKIP] followed by the gate name and a detail.

.PARAMETER PreCommit
Scan the staged changes for secrets, then lint, then run the tests. This is what the hook runs.

.PARAMETER ScanHistory
Scan every commit on every ref for secrets with the repo's .gitleaks.toml.

.PARAMETER InstallTools
Install the pinned Pester, PSScriptAnalyzer and gitleaks into .tools\ (or $env:KIT_TOOLS).
Tools already present are left alone, so a second run downloads nothing.

.PARAMETER InstallHook
Point this clone at the versioned hook folder: git config core.hooksPath .githooks.

.PARAMETER TestPath
Run only these Pester test files (no lint). A single comma-separated string is also accepted,
because powershell.exe -File passes "a,b" as one value.

.PARAMETER TestResultPath
Also write the Pester result as JUnit XML to this file.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1
Lint every script and run all tests. Exit 0 only when both pass.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -TestPath tests/Repo.Tests.ps1
Run one test file.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -PreCommit
Staged secret scan, then lint, then tests (the pre-commit hook).

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -ScanHistory
Scan the full history of every ref for secrets.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -InstallTools
Install the pinned tools into .tools\.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-Kit.ps1 -InstallHook
Enable the pre-commit hook for this clone.

.OUTPUTS
None. Writes one result line per stage. Exit code 0 = no stage failed, 1 = a stage failed,
2 = not running under Windows PowerShell 5.1.

.NOTES
Pinned tools: Pester 6.2.0, PSScriptAnalyzer 1.25.0, gitleaks 8.30.1 (archive SHA-256 checked).
Environment: KIT_TOOLS overrides the tools folder. KIT_GATE_ACTIVE=1 marks a nested gate run
(the hook proof in tests\Repo.Tests.ps1); the Pester stage is skipped there so it cannot recurse.
#>
[CmdletBinding(DefaultParameterSetName = 'Gate')]
param(
    [Parameter(Mandatory, ParameterSetName = 'PreCommit')]
    [switch]$PreCommit,

    [Parameter(Mandatory, ParameterSetName = 'ScanHistory')]
    [switch]$ScanHistory,

    [Parameter(Mandatory, ParameterSetName = 'InstallTools')]
    [switch]$InstallTools,

    [Parameter(Mandatory, ParameterSetName = 'InstallHook')]
    [switch]$InstallHook,

    [Parameter(Mandatory, ParameterSetName = 'Focus')]
    [string[]]$TestPath,

    [Parameter(ParameterSetName = 'Gate')]
    [Parameter(ParameterSetName = 'Focus')]
    [string]$TestResultPath
)

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Error "Test-Kit.ps1 must run under Windows PowerShell 5.1 (powershell.exe); this is PowerShell $($PSVersionTable.PSVersion)." -ErrorAction Continue
    exit 2
}

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$root = $PSScriptRoot

$pesterVersion = '6.2.0'
$analyzerVersion = '1.25.0'
$gitleaksVersion = '8.30.1'
$gitleaksUrl = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'
$gitleaksSha256 = 'D29144DEFF3A68AA93CED33DDDF84B7FDC26070ADD4AA0F4513094C8332AFC4E'

$script:failureCount = 0

function Show-GateResult {
    # The only place this script writes to the host: one coloured line per stage.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL', 'SKIP')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Gate,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Detail
    )
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        default { 'Yellow' }
    }
    if ($Status -eq 'FAIL') { $script:failureCount++ }
    Write-Host ('[{0}] {1}: {2}' -f $Status, $Gate, $Detail) -ForegroundColor $color
}

function Invoke-GateNative {
    # Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop', so relax it here.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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

function Get-GateToolRoot {
    # KIT_TOOLS wins; then this checkout's .tools; then the main checkout's (so linked worktrees share one install).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:KIT_TOOLS) { return $env:KIT_TOOLS }
    $local = Join-Path -Path $root -ChildPath '.tools'
    if (Test-Path -LiteralPath (Join-Path -Path $local -ChildPath 'Modules')) { return $local }
    $common = Invoke-GateNative -FilePath 'git' -ArgumentList @('-C', $root, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($common.ExitCode -eq 0 -and $common.Output.Count -gt 0) {
        $mainRoot = Split-Path -Path ([string]$common.Output[-1]).Trim() -Parent
        $shared = Join-Path -Path $mainRoot -ChildPath '.tools'
        if (Test-Path -LiteralPath (Join-Path -Path $shared -ChildPath 'Modules')) { return $shared }
    }
    return $local
}

function Resolve-GateModuleManifest {
    # Returns the manifest to import for a pinned module, or $null when it is not installed.
    # .NET Framework refuses to load assemblies from a path it maps outside the MyComputer zone
    # (an untrusted Dev Drive maps to Internet), so such an install is mirrored, version folder
    # and all, into a per-user cache on the system drive and imported from there.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version
    )
    $source = Join-Path -Path (Get-GateToolRoot) -ChildPath ('Modules\{0}\{1}' -f $Name, $Version)
    $manifest = Join-Path -Path $source -ChildPath "$Name.psd1"
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    $zone = [Security.Policy.Zone]::CreateFromUrl(([uri]$manifest).AbsoluteUri).SecurityZone
    if ($zone -eq [Security.SecurityZone]::MyComputer) { return $manifest }

    $cache = Join-Path -Path $env:LOCALAPPDATA -ChildPath ('Test-Kit\Modules\{0}\{1}' -f $Name, $Version)
    $cached = Join-Path -Path $cache -ChildPath "$Name.psd1"
    $current = (Test-Path -LiteralPath $cached) -and
        ((Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash)
    if (-not $current) {
        Write-Verbose "$source is in the $zone zone; mirroring it to $cache"
        $partial = "$cache.partial"
        foreach ($stale in $partial, $cache) {
            if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
        }
        $null = New-Item -Path (Split-Path -Path $cache -Parent) -ItemType Directory -Force
        Copy-Item -LiteralPath $source -Destination $partial -Recurse
        Rename-Item -LiteralPath $partial -NewName (Split-Path -Path $cache -Leaf)
    }
    return $cached
}

function Install-GateModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$ModuleRoot
    )
    $manifest = Join-Path -Path $ModuleRoot -ChildPath ('{0}\{1}\{0}.psd1' -f $Name, $Version)
    if (Test-Path -LiteralPath $manifest) {
        Show-GateResult -Status PASS -Gate 'InstallTools' -Detail "$Name $Version already present"
        return
    }
    try {
        Save-Module -Name $Name -RequiredVersion $Version -Path $ModuleRoot -Repository PSGallery -Force
        if (-not (Test-Path -LiteralPath $manifest)) { throw "Save-Module finished but $manifest is missing." }
        Show-GateResult -Status PASS -Gate 'InstallTools' -Detail "$Name $Version saved to $ModuleRoot"
    }
    catch {
        $inbox = (Get-Module -ListAvailable -Name PowerShellGet | Sort-Object -Property Version -Descending | Select-Object -First 1).Version
        Show-GateResult -Status FAIL -Gate 'InstallTools' -Detail ("$Name $Version could not be saved with PowerShellGet $inbox ($($_.Exception.Message)). " +
            "Fallback: from pwsh run Save-PSResource -Name $Name -Version $Version -Path '$ModuleRoot' -Repository PSGallery -TrustRepository")
    }
}

function Install-GateGitleaksBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolRoot
    )
    $folder = Join-Path -Path $ToolRoot -ChildPath 'gitleaks'
    $exe = Join-Path -Path $folder -ChildPath 'gitleaks.exe'
    if (Test-Path -LiteralPath $exe) {
        Show-GateResult -Status PASS -Gate 'InstallTools' -Detail "gitleaks $gitleaksVersion already present"
        return
    }
    $zip = Join-Path -Path $ToolRoot -ChildPath ('gitleaks_{0}_windows_x64.zip' -f $gitleaksVersion)
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $gitleaksUrl -OutFile $zip -UseBasicParsing
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ne $gitleaksSha256) {
            Remove-Item -LiteralPath $zip -Force
            throw "gitleaks archive hash mismatch: expected $gitleaksSha256, got $actual"
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $folder -Force
        Remove-Item -LiteralPath $zip -Force
        Show-GateResult -Status PASS -Gate 'InstallTools' -Detail "gitleaks $gitleaksVersion installed (SHA-256 verified)"
    }
    catch {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Show-GateResult -Status FAIL -Gate 'InstallTools' -Detail "gitleaks ${gitleaksVersion}: $($_.Exception.Message)"
    }
}

function Install-GateTool {
    [CmdletBinding()]
    param()
    $toolRoot = if ($env:KIT_TOOLS) { $env:KIT_TOOLS } else { Join-Path -Path $root -ChildPath '.tools' }
    $moduleRoot = Join-Path -Path $toolRoot -ChildPath 'Modules'
    $null = New-Item -Path $moduleRoot -ItemType Directory -Force

    # Windows PowerShell 5.1 defaults to TLS 1.0/1.1, which the Gallery and GitHub reject.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $nuget = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' }
    if (-not $nuget) {
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
    }

    Install-GateModule -Name 'Pester' -Version $pesterVersion -ModuleRoot $moduleRoot
    Install-GateModule -Name 'PSScriptAnalyzer' -Version $analyzerVersion -ModuleRoot $moduleRoot
    Install-GateGitleaksBinary -ToolRoot $toolRoot
}

function Install-GateHook {
    [CmdletBinding()]
    param()
    $null = Invoke-GateNative -FilePath 'git' -ArgumentList @('-C', $root, 'config', 'core.hooksPath', '.githooks')
    $read = Invoke-GateNative -FilePath 'git' -ArgumentList @('-C', $root, 'config', '--get', 'core.hooksPath')
    $value = ($read.Output -join '').Trim()
    if ($read.ExitCode -eq 0 -and $value -eq '.githooks') {
        Show-GateResult -Status PASS -Gate 'InstallHook' -Detail 'core.hooksPath = .githooks'
    }
    else {
        Show-GateResult -Status FAIL -Gate 'InstallHook' -Detail "core.hooksPath reads back as '$value'"
    }
}

function Get-GateGitleaksPath {
    # The pinned binary in the tools folder, else a gitleaks on PATH, else $null.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $exe = Join-Path -Path (Get-GateToolRoot) -ChildPath 'gitleaks\gitleaks.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    $onPath = Get-Command -Name 'gitleaks' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

function Invoke-GateSecretScan {
    # Every gitleaks call goes through here, so each one uses the repo's .gitleaks.toml (gitleaks would
    # otherwise read config from the scan target) and ignores inline allow markers.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Staged', 'History')]
        [string]$Scope
    )
    $gitleaks = Get-GateGitleaksPath
    if (-not $gitleaks) {
        Show-GateResult -Status FAIL -Gate 'Secrets' -Detail 'gitleaks not found; run Test-Kit.ps1 -InstallTools'
        return
    }
    $scopeArgs = if ($Scope -eq 'Staged') { @('--pre-commit', '--staged') } else { @('--log-opts=--all') }
    $arguments = @('git') + $scopeArgs + @('--verbose', '--redact', '--no-banner', '--ignore-gitleaks-allow', '-c', (Join-Path -Path $root -ChildPath '.gitleaks.toml'), $root)
    $scan = Invoke-GateNative -FilePath $gitleaks -ArgumentList $arguments
    foreach ($line in $scan.Output) { Write-Information $line }

    if ($scan.ExitCode -ne 0) {
        $detail = if ($Scope -eq 'Staged') {
            'gitleaks found a secret in the staged changes (details above); remove it, rotate it if it is real, then commit again.'
        }
        else {
            "gitleaks reported a leak in the history of some ref (exit $($scan.ExitCode), details above); rotate the secret, then rewrite or scrub that history."
        }
        Show-GateResult -Status FAIL -Gate 'Secrets' -Detail $detail
        return
    }
    $scanned = @($scan.Output | ForEach-Object { if ($_ -match '(\d+ commits? scanned)') { $Matches[1] } }) | Select-Object -Last 1
    $what = if ($Scope -eq 'Staged') { 'staged changes clean' } else { 'full history of every ref clean' }
    Show-GateResult -Status PASS -Gate 'Secrets' -Detail ($what + $(if ($scanned) { " ($scanned)" }))
}

function Invoke-GateLint {
    [CmdletBinding()]
    param()
    $manifest = Resolve-GateModuleManifest -Name 'PSScriptAnalyzer' -Version $analyzerVersion
    if (-not $manifest) {
        Show-GateResult -Status FAIL -Gate 'Lint' -Detail "PSScriptAnalyzer $analyzerVersion not found; run Test-Kit.ps1 -InstallTools"
        return
    }
    Import-Module -Name $manifest -Force
    $loaded = (Get-Module -Name PSScriptAnalyzer).Version
    if ($loaded -ne [version]$analyzerVersion) {
        Show-GateResult -Status FAIL -Gate 'Lint' -Detail "PSScriptAnalyzer $loaded loaded; $analyzerVersion required"
        return
    }

    # Tracked plus untracked-but-not-ignored: .tools\, HP_Staging\ and staging\ are never linted,
    # and a new file is linted before it is staged. icase so that X.PS1 cannot slip past.
    $list = Invoke-GateNative -FilePath 'git' -ArgumentList @('-C', $root, 'ls-files', '--cached', '--others', '--exclude-standard', '--',
        ':(icase)*.ps1', ':(icase)*.psm1', ':(icase)*.psd1')
    if ($list.ExitCode -ne 0) {
        Show-GateResult -Status FAIL -Gate 'Lint' -Detail "git ls-files failed: $($list.Output -join ' ')"
        return
    }
    $files = @($list.Output | Sort-Object -Unique | ForEach-Object { Join-Path -Path $root -ChildPath $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $settings = Join-Path -Path $root -ChildPath 'PSScriptAnalyzerSettings.psd1'

    $findings = @(foreach ($file in $files) {
            Invoke-ScriptAnalyzer -Path $file -Settings $settings
        })
    foreach ($finding in $findings) {
        $relative = $finding.ScriptPath.Substring($root.Length).TrimStart('\', '/')
        Write-Information ('{0}  {1}:{2}  {3}' -f $finding.RuleName, $relative, $finding.Line, $finding.Message)
    }
    if ($findings.Count -gt 0) {
        Show-GateResult -Status FAIL -Gate 'Lint' -Detail "$($files.Count) files, $($findings.Count) findings"
    }
    else {
        Show-GateResult -Status PASS -Gate 'Lint' -Detail "$($files.Count) files, 0 findings"
    }
}

function Resolve-GatePath {
    # Relative paths are taken from the current folder first, then from the repo root.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    $fromCwd = Join-Path -Path (Get-Location).ProviderPath -ChildPath $Path
    if (Test-Path -LiteralPath $fromCwd) { return $fromCwd }
    return (Join-Path -Path $root -ChildPath $Path)
}

function Invoke-GateTest {
    [CmdletBinding()]
    param(
        [string[]]$Path,

        [string]$ResultPath
    )
    if ($env:KIT_GATE_ACTIVE -eq '1') {
        Show-GateResult -Status SKIP -Gate 'Tests' -Detail 'nested gate run (hook proof); Pester runs once, in the outer gate'
        return
    }
    $manifest = Resolve-GateModuleManifest -Name 'Pester' -Version $pesterVersion
    if (-not $manifest) {
        Show-GateResult -Status FAIL -Gate 'Tests' -Detail "Pester $pesterVersion not found; run Test-Kit.ps1 -InstallTools"
        return
    }
    # Inbox Pester 3.4.0 would win autoload, so load the pinned copy by path and check it.
    Import-Module -Name $manifest -Force
    $loaded = @(Get-Module -Name Pester)
    if ($loaded.Count -ne 1 -or $loaded[0].Version -ne [version]$pesterVersion) {
        Show-GateResult -Status FAIL -Gate 'Tests' -Detail "Pester $($loaded.Version -join ', ') loaded; $pesterVersion required"
        return
    }

    $runPath = if ($Path) {
        @($Path | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
                ForEach-Object { Resolve-GatePath -Path $_ })
    }
    else {
        @(Join-Path -Path $root -ChildPath 'tests')
    }
    $missing = @($runPath | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) {
        Show-GateResult -Status FAIL -Gate 'Tests' -Detail "not found: $($missing -join ', ')"
        return
    }

    $config = New-PesterConfiguration
    $config.Run.Path = [string[]]$runPath
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    if ($ResultPath) {
        $resultFile = Resolve-GatePath -Path $ResultPath
        $null = New-Item -Path (Split-Path -Path $resultFile -Parent) -ItemType Directory -Force
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputFormat = 'JUnitXml'
        $config.TestResult.OutputPath = $resultFile
    }

    $env:KIT_GATE_ACTIVE = '1'
    try {
        $result = Invoke-Pester -Configuration $config
    }
    finally {
        Remove-Item -Path Env:\KIT_GATE_ACTIVE -ErrorAction SilentlyContinue
    }

    if ($null -eq $result) {
        Show-GateResult -Status FAIL -Gate 'Tests' -Detail 'Pester returned no result (see the errors above)'
    }
    elseif ($result.Result -ne 'Passed') {
        Show-GateResult -Status FAIL -Gate 'Tests' -Detail "$($result.FailedCount) failed, $($result.PassedCount) passed"
    }
    elseif ($result.PassedCount -eq 0) {
        Show-GateResult -Status FAIL -Gate 'Tests' -Detail 'no tests ran'
    }
    else {
        Show-GateResult -Status PASS -Gate 'Tests' -Detail "$($result.PassedCount) passed"
    }
}

$mode = if ($PreCommit) { 'PreCommit' }
elseif ($ScanHistory) { 'ScanHistory' }
elseif ($InstallTools) { 'InstallTools' }
elseif ($InstallHook) { 'InstallHook' }
elseif ($TestPath) { 'Focus' }
else { 'Gate' }

switch ($mode) {
    'InstallTools' { Install-GateTool }
    'InstallHook' { Install-GateHook }
    'ScanHistory' { Invoke-GateSecretScan -Scope History }
    'PreCommit' {
        # Secrets first and fail fast: a leaking commit stops here, before PSScriptAnalyzer or Pester
        # load (this is also what keeps the hook proof in tests\Repo.Tests.ps1 from recursing).
        Invoke-GateSecretScan -Scope Staged
        if ($script:failureCount -gt 0) { exit 1 }
        Invoke-GateLint
        Invoke-GateTest
    }
    'Focus' {
        Show-GateResult -Status SKIP -Gate 'Lint' -Detail 'focused run; run Test-Kit.ps1 without -TestPath for the full gate'
        Invoke-GateTest -Path $TestPath -ResultPath $TestResultPath
    }
    default {
        Invoke-GateLint
        Invoke-GateTest -ResultPath $TestResultPath
    }
}

exit [int]($script:failureCount -gt 0)
