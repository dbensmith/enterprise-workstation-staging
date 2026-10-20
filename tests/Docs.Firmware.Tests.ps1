BeforeDiscovery {
    # The layout groups and the script parameter names are read here so the checks below are generated from the real
    # files: a group added to the layout without a checklist row, or a renamed switch, fails a test.
    $script:discoveryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
    $layoutData = Import-PowerShellDataFile -LiteralPath (Join-Path $script:discoveryRoot 'kit\vendors\hp\layouts\hp-usb-flash.layout.psd1')
    $script:layoutGroups = @($layoutData.Groups | ForEach-Object { @{ Id = $_.Id; Folder = $_.Folder; Default = [bool]$_.Default } })
    $discoveryScript = Join-Path $script:discoveryRoot 'builder\Build-ToolsStick.ps1'
    $discoveryAst = [System.Management.Automation.Language.Parser]::ParseFile($discoveryScript, [ref]$null, [ref]$null)
    $script:scriptParameters = @($discoveryAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).ProviderPath
    $script:checklistPath = Join-Path $script:repoRoot 'docs\firmware-bench-checklist.md'
    $script:readmePath = Join-Path $script:repoRoot 'README.md'
    $script:buildScript = Join-Path $script:repoRoot 'builder\Build-ToolsStick.ps1'

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:buildScript, [ref]$null, [ref]$null)
    $script:scriptParameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $script:allowedSwitches = $script:scriptParameters + @('WhatIf', 'Confirm', 'Verbose')
    $script:groupCount = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'kit\vendors\hp\layouts\hp-usb-flash.layout.psd1')).Groups).Count

    function Get-DocSection {
        # The lines under one '## ' heading, up to the next '## ' heading.
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Heading
        )
        $lines = @($Text -split '\r?\n')
        $start = [array]::IndexOf($lines, $Heading)
        $section = @()
        if ($start -ge 0) {
            for ($i = $start + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^## ') { break }
                $section += $lines[$i]
            }
        }
        , $section
    }

    function Get-FencedBlock {
        # One entry per fenced code block: the trimmed, non-blank lines inside it.
        param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
        $blocks = New-Object System.Collections.Generic.List[object]
        $current = $null
        foreach ($text in $Line) {
            if ($text -match '^\s*```') {
                if ($null -eq $current) { $current = New-Object System.Collections.Generic.List[string] }
                else { $blocks.Add(@($current)); $current = $null }
                continue
            }
            if ($null -ne $current -and $text.Trim()) { $current.Add($text.Trim()) }
        }
        , @($blocks)
    }

    function Get-ProseLine {
        # The lines outside fenced code blocks.
        [CmdletBinding()]
        param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
        $inside = $false
        foreach ($text in $Line) {
            if ($text -match '^\s*```') { $inside = -not $inside; continue }
            if (-not $inside) { $text }
        }
    }

    function Get-SwitchAfterScript {
        # The -Name tokens that follow Build-ToolsStick.ps1 on one line (the powershell.exe switches before it are not
        # parameters of the script).
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Line)
        $at = $Line.IndexOf('Build-ToolsStick.ps1', [StringComparison]::Ordinal)
        if ($at -lt 0) { return }
        $tail = $Line.Substring($at + 'Build-ToolsStick.ps1'.Length)
        foreach ($match in [regex]::Matches($tail, '(?<=\s)-([A-Za-z][A-Za-z0-9]*)')) { $match.Groups[1].Value }
    }

    function Test-Ascii {
        [CmdletBinding()]
        [OutputType([bool])]
        param([Parameter(Mandatory)][string]$Path)
        $bytes = [IO.File]::ReadAllBytes($Path)
        -not (@($bytes | Where-Object { $_ -gt 127 }).Count -gt 0)
    }
}

Describe 'Firmware bench checklist' {
    BeforeAll {
        $script:checklistExists = Test-Path -LiteralPath $script:checklistPath -PathType Leaf
        $script:checklistText = if ($script:checklistExists) { [IO.File]::ReadAllText($script:checklistPath) } else { '' }
        $script:checklistLines = @($script:checklistText -split '\r?\n')
        $script:headings = @(
            '# Firmware bench checklist (FW-06)'
            '## 1. What this proves and what you need'
            '## 2. Build the stick'
            "## 3. Capture HP's UEFI diagnostics (once per HP release)"
            '## 4. Bench: HP EliteBook 840 G6'
            '## 5. Bench: HP EliteBook 840 G5'
            '## 6. Other things to confirm'
            '## 7. Record the result'
            '## 8. Prune and close'
            '## Appendix A. Layout groups'
        )
    }

    It 'reads the layout groups and the script parameters' {
        $script:groupCount | Should -BeGreaterThan 0
        $script:scriptParameters.Count | Should -BeGreaterThan 0
    }

    It 'exists and is pure ASCII' {
        $script:checklistExists | Should -BeTrue
        Test-Ascii -Path $script:checklistPath | Should -BeTrue
    }

    It 'begins with the title heading' {
        $script:checklistLines[0] | Should -BeExactly '# Firmware bench checklist (FW-06)'
    }

    It 'holds the ten headings exactly once each, in order' {
        $positions = foreach ($heading in $script:headings) {
            $found = @(for ($i = 0; $i -lt $script:checklistLines.Count; $i++) { if ($script:checklistLines[$i] -ceq $heading) { $i } })
            $found.Count | Should -Be 1 -Because "'$heading' must appear exactly once"
            $found[0]
        }
        $sorted = @($positions | Sort-Object)
        @($positions) | Should -Be $sorted
    }

    It 'has an Appendix A row for group <Id> that names its folder' -ForEach $script:layoutGroups {
        $appendix = Get-DocSection -Text $script:checklistText -Heading '## Appendix A. Layout groups'
        $rows = @($appendix | Where-Object { $_ -like "| $Id |*" })
        $rows.Count | Should -Be 1
        $rows[0].Contains($Folder) | Should -BeTrue -Because "the row of $Id must carry the layout folder '$Folder'"
        $staged = if ($Default) { 'yes' } else { 'no' }
        @($rows[0].Split('|') | ForEach-Object { $_.Trim() })[3] | Should -Be $staged
    }

    It 'has exactly one Appendix A row per layout group' {
        $appendix = Get-DocSection -Text $script:checklistText -Heading '## Appendix A. Layout groups'
        $header = @($appendix | Where-Object { $_ -like '| Group |*' })
        $header.Count | Should -Be 1
        $header[0] | Should -Be '| Group | Folder | Staged by default | Menu to try | Result |'
        $rows = @($appendix | Where-Object { $_ -like '|*' -and $_ -notlike '| Group |*' -and $_ -notmatch '^\|[-\s|]+\|$' })
        $rows.Count | Should -Be $script:groupCount
    }

    It 'carries the token <Token>' -ForEach (@(
        'FW-06', 'FW-06 stays open', '01.35.02', '840-g5', '840-g6', 'F10', 'F2', 'Esc', 'HP_TOOLS', 'FAT32', '-FlashModel',
        '-DiagnosticsSource', '-NewDiagnosticsSnapshot', '-ValidateOnly', 'Build-ToolsStick.ps1', 'sp171653',
        'Win32_BaseBoard', 'Status', 'Model', 'Bios', 'Date', 'By', 'format E: /FS:FAT32'
    ) | ForEach-Object { @{ Token = $_ } }) {
        $script:checklistText.IndexOf($Token, [StringComparison]::Ordinal) | Should -BeGreaterOrEqual 0
    }

    It 'prints only real parameters after Build-ToolsStick.ps1' {
        $lines = @($script:checklistLines | Where-Object { $_.Contains('Build-ToolsStick.ps1') })
        $lines.Count | Should -BeGreaterThan 0
        $names = @($lines | ForEach-Object { Get-SwitchAfterScript -Line $_ })
        $names.Count | Should -BeGreaterThan 0
        foreach ($name in $names) {
            $script:allowedSwitches | Should -Contain $name -Because "-$name is printed on a Build-ToolsStick.ps1 line of the checklist"
        }
    }

    It 'names only real parameters for the switch <Switch>' -ForEach @(
        @{ Switch = 'FlashModel' }
        @{ Switch = 'DiagnosticsSource' }
        @{ Switch = 'NewDiagnosticsSnapshot' }
        @{ Switch = 'ValidateOnly' }
        @{ Switch = 'IncludeKit' }
    ) {
        $script:scriptParameters | Should -Contain $Switch
        $script:checklistText.IndexOf("-$Switch", [StringComparison]::Ordinal) | Should -BeGreaterOrEqual 0
    }

    It 'states the ordering rule in section 2' {
        $section = (Get-DocSection -Text $script:checklistText -Heading '## 2. Build the stick') -join "`n"
        $section.IndexOf('format, then capture, then stage', [StringComparison]::Ordinal) | Should -BeGreaterOrEqual 0
    }

    It 'shows a Verified example that parses with a boolean Status, an array Model and a yyyy-MM-dd Date' {
        $section = Get-DocSection -Text $script:checklistText -Heading '## 7. Record the result'
        $example = @($section | Where-Object { $_ -match '^\s*Verified = @\{.*\}\s*$' })
        $example.Count | Should -Be 1
        $value = $example[0].Trim().Substring('Verified = '.Length)
        $file = Join-Path $TestDrive 'verified.psd1'
        [IO.File]::WriteAllText($file, "@{ V = $value }")
        $data = Import-PowerShellDataFile -LiteralPath $file
        $data.V.Status | Should -BeOfType [bool]
        , $data.V.Model | Should -BeOfType [object[]]
        $data.V.Date | Should -Match '^\d{4}-\d{2}-\d{2}$'
        $data.V.Bios | Should -Not -BeNullOrEmpty
        $data.V.By | Should -Not -BeNullOrEmpty
    }

    It 'does not claim that anything is bench-verified or that a bench is scheduled' {
        $script:checklistText | Should -Not -Match '(?i)scheduled'
        $script:checklistText | Should -Match '(?i)deferred'
        $script:checklistText | Should -Match '(?i)optional'
    }
}
