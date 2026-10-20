BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    $script:masterScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\builder\Build-ToolsStick.ps1'))
    $script:vendorRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\vendors'))
    $script:profileRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\profiles'))
    $script:fixtureLayout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1'))

    # A workspace under TestDrive: layout\ (a copy of the fixture layout), capture\ (run-time files of a captured tree),
    # out\ (the staging root) and stick\ (the target). No image is committed; the fixture vendor writes them at run time.
    function New-TestWorkspace {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([pscustomobject])]
        param()
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if (-not $PSCmdlet.ShouldProcess($root, 'Create the test workspace')) { return }
        $workspace = [pscustomobject]@{
            Root    = $root
            Layout  = Join-Path $root 'layout\fixture.layout.psd1'
            Capture = Join-Path $root 'capture'
            Out     = Join-Path $root 'out'
            Stick   = Join-Path $root 'stick'
        }
        foreach ($folder in 'layout', 'capture\EFI\FX\sub', 'out', 'stick') {
            $null = New-Item -Path (Join-Path $root $folder) -ItemType Directory -Force
        }
        Copy-Item -LiteralPath $script:fixtureLayout -Destination $workspace.Layout
        [IO.File]::WriteAllText((Join-Path $workspace.Capture 'EFI\FX\a.efi'), 'capture a', [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $workspace.Capture 'EFI\FX\sub\b.dll'), 'capture b', [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $workspace.Capture 'EFI\FX\c.json'), '{"c":1}', [Text.Encoding]::ASCII)
        $workspace
    }

    # The two BiosImage groups only: no captured group, so no diagnostics capture is needed.
    function Write-SimpleLayout {
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(Mandatory)][string]$Path)
        $text = @'
@{
    SchemaVersion = 1
    VolumeLabel   = 'FX_TOOLS'
    FileSystem    = 'FAT32'
    Groups        = @(
        @{ Id = 'G-New'; Folder = 'Vendor\BIOS\New'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'G-Current'; Folder = 'Vendor\BIOS\Current'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
    )
}
'@
        if ($PSCmdlet.ShouldProcess($Path, 'Write the simple layout')) {
            [IO.File]::WriteAllText($Path, $text, [Text.Encoding]::ASCII)
        }
    }

    # Run the master script in-process against the fixture vendor. $Parameter is splatted; the information stream
    # (which carries Write-Host text) is merged into the output.
    function Invoke-Master {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory)][hashtable]$Parameter)
        $lines = @(& $script:masterScript @Parameter 6>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($lines -join "`n"); Lines = $lines; Flat = (($lines -join ' ') -replace '\s+', ' ') }
    }

    # Run the master script in a real Windows PowerShell 5.1 process, the way Build.cmd starts one: PSModulePath cleared,
    # a process-scope bypass, -File. Standard input comes from a file (empty by default) so a prompt can never wait on a
    # person, and the child is killed after the timeout so the gate cannot hang. Output is the wrapped console text;
    # Flat is the same text with line breaks and indents folded to single spaces, for matching phrases.
    function Invoke-ScriptChild {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string[]]$ArgumentList,
            [string]$InputText = '',
            [int]$TimeoutSeconds = 240,
            [switch]$NonInteractive
        )
        $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $stem = Join-Path $TestDrive ('child-' + [guid]::NewGuid().ToString('N'))
        $inputFile = "$stem.in"
        $outputFile = "$stem.out"
        $errorFile = "$stem.err"
        [IO.File]::WriteAllText($inputFile, $InputText, [Text.Encoding]::ASCII)
        $lead = @('-NoProfile')
        if ($NonInteractive) { $lead += '-NonInteractive' }
        $lead += @('-ExecutionPolicy', 'Bypass', '-File', $script:masterScript)
        $quoted = foreach ($item in @($lead) + @($ArgumentList)) {
            if ($item -match '[\s"]') { '"' + $item.Replace('"', '\"') + '"' } else { $item }
        }
        $commandLine = $quoted -join ' '
        $savedModulePath = $env:PSModulePath
        $env:PSModulePath = ''
        try {
            $process = Start-Process -FilePath $executable -ArgumentList $commandLine -NoNewWindow -PassThru `
                -RedirectStandardInput $inputFile -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile
        }
        finally {
            $env:PSModulePath = $savedModulePath
        }
        $null = $process.Handle
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "The child process did not finish within $TimeoutSeconds seconds: $commandLine"
        }
        $process.WaitForExit()
        $text = @($outputFile, $errorFile | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $text; Flat = ($text -replace '\s+', ' ') }
    }

    # The command line every fixture child run shares, as a list of strings.
    function Get-ChildBase {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory)][pscustomobject]$Workspace, [switch]$NoPrompt)
        $list = @('-ProfileRoot', $script:profileRoot, '-LayoutPath', $Workspace.Layout, '-OutputRoot', $Workspace.Out, '-AllowFolder', '-VendorRoot', $script:vendorRoot)
        if (-not $NoPrompt) { $list += @('-Vendor', 'Fixture', '-TargetPath', $Workspace.Stick) }
        $list
    }

    # The parameters every fixture run shares.
    function Get-MasterBase {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][pscustomobject]$Workspace)
        @{
            Vendor      = 'Fixture'
            VendorRoot  = $script:vendorRoot
            ProfileRoot = $script:profileRoot
            LayoutPath  = $Workspace.Layout
            OutputRoot  = $Workspace.Out
            TargetPath  = $Workspace.Stick
            AllowFolder = $true
        }
    }

    function Read-StickManifest {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory)][string]$Stick)
        Get-Content -LiteralPath (Join-Path $Stick 'firmware-manifest.json') -Raw | ConvertFrom-Json
    }

    function Read-ScriptAst {
        [CmdletBinding()]
        [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
        param()
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:masterScript, [ref]$tokens, [ref]$errors)
    }
}

Describe 'Build-ToolsStick one model end to end' {
    BeforeAll {
        $script:ws = New-TestWorkspace
        Write-SimpleLayout -Path $script:ws.Layout
        $parameter = Get-MasterBase -Workspace $script:ws
        $parameter.Model = 'm1'
        $script:run = Invoke-Master -Parameter $parameter
    }

    It 'finishes with exit code 0 and a READY stick whose validator finds no Fail' {
        $script:run.ExitCode | Should -Be 0 -Because $script:run.Output
        (Join-Path $script:ws.Stick 'READY') | Should -Exist
        $fail = @(Test-FirmwareStage -Path $script:ws.Stick -AllowFolder | Where-Object { $_.Status -eq 'Fail' })
        $fail | Should -BeNullOrEmpty
    }
    It 'lists the model and both image copies in the manifest' {
        $manifest = Read-StickManifest -Stick $script:ws.Stick
        @($manifest.models).Count | Should -Be 1
        $manifest.models[0].modelId | Should -Be 'm1'
        $path = @($manifest.models[0].files | ForEach-Object { $_.path })
        $path | Should -Contain 'Vendor\BIOS\New\F00_000100.bin'
        $path | Should -Contain 'Vendor\BIOS\Current\F00_000100.bin'
    }
    It 'prints short PASS lines, the BIOS line, the unverified warning and a READY verdict last' {
        $script:run.Output | Should -Match '\[PASS\]'
        $script:run.Output | Should -Match 'm1: BIOS 01\.00\.00 F00_000100\.bin'
        $script:run.Output | Should -Match '\[WARN\][^\n]*not bench-verified'
        $last = @($script:run.Lines | Where-Object { $_ -match '\[(PASS|WARN|FAIL)\]' })[-1]
        $last | Should -Match '^\[PASS\].*READY'
    }
    It 'ran the vendor operation with a full backslash output path' {
        (Join-Path $script:ws.Out 'fixture\m1\win11-24H2') | Should -Exist
    }
}

Describe 'Build-ToolsStick script shape' {
    BeforeAll {
        # A missing script must fail every It below, not let the scans find nothing.
        $script:masterScript | Should -Exist
        $script:ast = Read-ScriptAst
        $script:ast | Should -Not -BeNullOrEmpty
    }
    It 'names no vendor command and no vendor string' {
        $commands = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-HP|HPCMSL' }
        $strings = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            Where-Object { $_.Value -in 'HP', 'HPCMSL' }
        @($commands) + @($strings | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
    }
    It 'runs the firmware build and the stick layout through the vendor operations' {
        $operations = foreach ($command in $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $elements = @($command.CommandElements)
            for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'Operation') {
                    $elements[$i + 1].Value
                }
            }
        }
        $operations | Should -Contain 'GetFirmware'
        $operations | Should -Contain 'GetFirmwareStickLayout'
    }
}

Describe 'Build-ToolsStick two models with the diagnostics capture' {
    BeforeAll {
        $script:ws = New-TestWorkspace
        $parameter = Get-MasterBase -Workspace $script:ws
        $parameter.Model = @('m1', 'm2')
        $parameter.DiagnosticsSource = $script:ws.Capture
        $parameter.NewDiagnosticsSnapshot = $true
        $script:first = Invoke-Master -Parameter $parameter
        $script:manifest = Read-StickManifest -Stick $script:ws.Stick
    }

    It 'records the snapshot next to the layout and stages a READY stick' {
        $script:first.ExitCode | Should -Be 0 -Because $script:first.Output
        (Join-Path (Split-Path $script:ws.Layout -Parent) 'fx-diag.snapshot.psd1') | Should -Exist
        (Join-Path $script:ws.Stick 'READY') | Should -Exist
    }
    It 'keeps both BIOS images in both folders without one overwriting the other (FW-01)' {
        foreach ($folder in 'New', 'Current') {
            $one = Join-Path $script:ws.Stick "Vendor\BIOS\$folder\F00_000100.bin"
            $two = Join-Path $script:ws.Stick "Vendor\BIOS\$folder\F01_000100.bin"
            $one | Should -Exist
            $two | Should -Exist
            (Get-FileHash -LiteralPath $one).Hash | Should -Not -Be (Get-FileHash -LiteralPath $two).Hash
        }
    }
    It 'stages the Windows fallback folders of both platforms and leaves the flash-image folder out' {
        @(Get-ChildItem -LiteralPath (Join-Path $script:ws.Stick 'firmware\fx\0000') -File).Count | Should -BeGreaterThan 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:ws.Stick 'firmware\fx\0001') -File).Count | Should -BeGreaterThan 0
        (Join-Path $script:ws.Stick 'FX\DEVFW') | Should -Not -Exist
    }
    It 'stages the three captured files (FW-05) and lists both models and three shared records (FW-02)' {
        (Join-Path $script:ws.Stick 'EFI\FX\a.efi') | Should -Exist
        (Join-Path $script:ws.Stick 'EFI\FX\sub\b.dll') | Should -Exist
        (Join-Path $script:ws.Stick 'EFI\FX\c.json') | Should -Exist
        @($script:manifest.models | ForEach-Object { $_.modelId }) | Should -Be @('m1', 'm2')
        @($script:manifest.shared).Count | Should -Be 3
    }
    It 'is READY again on a second run from the recorded snapshot and changes no staged file' {
        $before = @{}
        foreach ($file in Get-ChildItem -LiteralPath $script:ws.Stick -Recurse -File) {
            $before[$file.FullName] = $file.LastWriteTimeUtc.Ticks
        }
        $parameter = Get-MasterBase -Workspace $script:ws
        $parameter.Model = @('m1', 'm2')
        $parameter.DiagnosticsSource = $script:ws.Capture
        $second = Invoke-Master -Parameter $parameter
        $second.ExitCode | Should -Be 0 -Because $second.Output
        foreach ($file in Get-ChildItem -LiteralPath $script:ws.Stick -Recurse -File | Where-Object { $_.Name -notin 'firmware-manifest.json', 'READY' }) {
            $file.LastWriteTimeUtc.Ticks | Should -Be $before[$file.FullName] -Because $file.FullName
        }
    }
}

Describe 'Build-ToolsStick model list' {
    It 'selects the same two models from <Name>' -ForEach @(
        @{ Name = 'one comma-joined string'; Value = @('m1,m2') }
        @{ Name = 'an array'; Value = @('m1', 'm2') }
        @{ Name = 'an array with a padded id'; Value = @('m1', ' m2') }
        @{ Name = 'a list with a repeated id'; Value = @('m1', 'm2', 'm1') }
    ) {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = $Value
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 0 -Because $run.Output
        @((Read-StickManifest -Stick $ws.Stick).models | ForEach-Object { $_.modelId }) | Should -Be @('m1', 'm2')
    }
    It 'stops with the available ids for an unknown model' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm9'
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match '\[FAIL\]'
        $run.Output | Should -Match 'm1'
        $run.Output | Should -Match 'm2'
        (Join-Path $ws.Out 'fixture') | Should -Not -Exist
    }
}

Describe 'Build-ToolsStick -FlashModel, -IncludeKit and -RemoveStale' {
    It 'stages one model and the flash-image group with -FlashModel' {
        $ws = New-TestWorkspace
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = @('m1', 'm2')
        $parameter.FlashModel = 'm1'
        $parameter.DiagnosticsSource = $ws.Capture
        $parameter.NewDiagnosticsSnapshot = $true
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 0 -Because $run.Output
        @((Read-StickManifest -Stick $ws.Stick).models | ForEach-Object { $_.modelId }) | Should -Be @('m1')
        [IO.File]::ReadAllText((Join-Path $ws.Stick 'FX\DEVFW\firmware.bin')) | Should -Be 'fixture bios m1'
        (Join-Path $ws.Stick 'Vendor\BIOS\New\F01_000100.bin') | Should -Not -Exist
    }
    It 'stops and lists the selected models when -FlashModel is not one of them' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        $parameter.FlashModel = 'm2'
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match '\[FAIL\]'
        $run.Output | Should -Match 'm1'
        (Join-Path $ws.Out 'fixture') | Should -Not -Exist
    }
    It 'copies the kit only with -IncludeKit and never its local config' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        $plain = Invoke-Master -Parameter $parameter
        $plain.ExitCode | Should -Be 0 -Because $plain.Output
        (Join-Path $ws.Stick 'kit') | Should -Not -Exist
        $parameter.IncludeKit = $true
        $with = Invoke-Master -Parameter $parameter
        $with.ExitCode | Should -Be 0 -Because $with.Output
        (Join-Path $ws.Stick 'kit\Run.cmd') | Should -Exist
        (Join-Path $ws.Stick 'kit\config.local.psd1') | Should -Not -Exist
    }
    It 'fails on a stale file in a closed folder and removes it with -RemoveStale' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        (Invoke-Master -Parameter $parameter).ExitCode | Should -Be 0
        $stale = Join-Path $ws.Stick 'Vendor\BIOS\New\old.bin'
        [IO.File]::WriteAllText($stale, 'old', [Text.Encoding]::ASCII)
        $blocked = Invoke-Master -Parameter $parameter
        $blocked.ExitCode | Should -Be 1
        $blocked.Output | Should -Match 'old\.bin'
        $parameter.RemoveStale = $true
        $cleaned = Invoke-Master -Parameter $parameter
        $cleaned.ExitCode | Should -Be 0 -Because $cleaned.Output
        $stale | Should -Not -Exist
    }
}

Describe 'Build-ToolsStick -WhatIf and -ValidateOnly' {
    It 'previews the download and stages nothing under -WhatIf' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        $parameter.WhatIf = $true
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'nothing was staged'
        @(Get-ChildItem -LiteralPath $ws.Stick -Force) | Should -BeNullOrEmpty
    }
    It 're-checks a stick with -ValidateOnly without calling a vendor' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        (Invoke-Master -Parameter $parameter).ExitCode | Should -Be 0
        $before = @(Get-ChildItem -LiteralPath $ws.Out -Recurse -Force | ForEach-Object { $_.FullName })
        $check = Invoke-Master -Parameter @{ ValidateOnly = $true; TargetPath = $ws.Stick; AllowFolder = $true }
        $check.ExitCode | Should -Be 0 -Because $check.Output
        $check.Output | Should -Not -Match '\[FAIL\]'
        $check.Output | Should -Match 'READY'
        @(Get-ChildItem -LiteralPath $ws.Out -Recurse -Force | ForEach-Object { $_.FullName }).Count | Should -Be $before.Count
    }
}

Describe 'Build-ToolsStick diagnostics source selection' {
    It 'names the layout when it has no capture to supply' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        $parameter.DiagnosticsSource = $ws.Capture
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match '\[FAIL\]'
        $run.Output | Should -Match 'fixture\.layout\.psd1'
    }
    It 'lists the captures when there are two and no -CaptureName' {
        $ws = New-TestWorkspace
        $text = [IO.File]::ReadAllText($ws.Layout)
        $text = $text.Replace("Snapshot = 'fx-diag.snapshot.psd1' }", "Snapshot = 'fx-diag.snapshot.psd1' }`n        @{ Name = 'fx-two'; PackageId = 'fxdiag2'; Version = '1.0'; Snapshot = 'fx-two.snapshot.psd1' }")
        $text = $text.Replace('        @{ Id = ''G-Win'';', "        @{ Id = 'G-Two'; Folder = 'EFI\FT'; Source = 'Captured:fx-two'; Closed = `$false; Default = `$true`n            Verified = @{ Status = `$false; Model = @(); Bios = ''; Date = ''; By = '' } }`n        @{ Id = 'G-Win';")
        [IO.File]::WriteAllText($ws.Layout, $text, [Text.Encoding]::ASCII)
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        $parameter.DiagnosticsSource = $ws.Capture
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'fx-diag'
        $run.Output | Should -Match 'fx-two'
        $run.Output | Should -Match 'CaptureName'
    }
    It 'asks for -DiagnosticsSource with the FW-05 message when the layout needs a capture' {
        $ws = New-TestWorkspace
        $parameter = Get-MasterBase -Workspace $ws
        $parameter.Model = 'm1'
        $run = Invoke-Master -Parameter $parameter
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match '\[FAIL\] FW-05'
        (Join-Path $ws.Stick 'firmware-manifest.json') | Should -Not -Exist
        (Join-Path $ws.Stick 'READY') | Should -Not -Exist
    }
}

Describe 'Build-ToolsStick exit codes through a real child process' {
    It 'builds two models from one comma-joined -Model value and exits 0' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $run = Invoke-ScriptChild -ArgumentList ((Get-ChildBase -Workspace $ws) + @('-Model', 'm1,m2'))
        $run.ExitCode | Should -Be 0 -Because $run.Output
        @((Read-StickManifest -Stick $ws.Stick).models | ForEach-Object { $_.modelId }) | Should -Be @('m1', 'm2')
        (Join-Path $ws.Stick 'READY') | Should -Exist
    }
    It 'refuses a target that is not a FAT32 volume root before any download' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $arguments = @('-Vendor', 'Fixture', '-VendorRoot', $script:vendorRoot, '-ProfileRoot', $script:profileRoot, '-LayoutPath', $ws.Layout,
            '-OutputRoot', $ws.Out, '-TargetPath', $ws.Stick, '-Model', 'm1')
        $run = Invoke-ScriptChild -ArgumentList $arguments
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '\[FAIL\]'
        $run.Flat | Should -Match 'FAT32|root'
        $run.Flat | Should -Match ([regex]::Escape([IO.Path]::GetPathRoot($ws.Stick)))
        (Join-Path $ws.Out 'fixture') | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $ws.Root -Recurse -Force -Filter 'firmware-manifest.json') | Should -BeNullOrEmpty
    }
    It 'stops red with FW-05 when the diagnostics capture is missing' {
        $ws = New-TestWorkspace
        $run = Invoke-ScriptChild -ArgumentList ((Get-ChildBase -Workspace $ws) + @('-Model', 'm1'))
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '\[FAIL\]'
        $run.Output | Should -Match 'FW-05'
        (Join-Path $ws.Stick 'firmware-manifest.json') | Should -Not -Exist
        (Join-Path $ws.Stick 'READY') | Should -Not -Exist
    }
    It 'names the file of an altered capture and withdraws READY' {
        $ws = New-TestWorkspace
        $arguments = (Get-ChildBase -Workspace $ws) + @('-Model', 'm1', '-DiagnosticsSource', $ws.Capture)
        $good = Invoke-ScriptChild -ArgumentList ($arguments + '-NewDiagnosticsSnapshot')
        $good.ExitCode | Should -Be 0 -Because $good.Output
        (Join-Path $ws.Stick 'READY') | Should -Exist
        $file = Join-Path $ws.Capture 'EFI\FX\a.efi'
        $bytes = [IO.File]::ReadAllBytes($file)
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($file, $bytes)
        $run = Invoke-ScriptChild -ArgumentList $arguments
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '\[FAIL\]'
        $run.Flat | Should -Match ([regex]::Escape('EFI\FX\a.efi'))
        $run.Flat | Should -Match 'differs from the recorded snapshot'
        (Join-Path $ws.Stick 'READY') | Should -Not -Exist
    }
    It 'fails loudly for the wrong-folder incident and passes again when the file is back' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $build = Invoke-ScriptChild -ArgumentList ((Get-ChildBase -Workspace $ws) + @('-Model', 'm1'))
        $build.ExitCode | Should -Be 0 -Because $build.Output
        $right = Join-Path $ws.Stick 'Vendor\BIOS\New\F00_000100.bin'
        $wrong = Join-Path $ws.Stick 'Vendor\BIOS\Other\F00_000100.bin'
        $null = New-Item -Path (Split-Path $wrong -Parent) -ItemType Directory -Force
        Move-Item -LiteralPath $right -Destination $wrong
        $check = @('-ValidateOnly', '-TargetPath', $ws.Stick, '-AllowFolder')
        $bad = Invoke-ScriptChild -ArgumentList $check
        $bad.ExitCode | Should -Be 1 -Because $bad.Output
        $bad.Output | Should -Match '\[FAIL\]'
        $bad.Output | Should -Match 'F00_000100\.bin'
        Move-Item -LiteralPath $wrong -Destination $right
        $good = Invoke-ScriptChild -ArgumentList $check
        $good.ExitCode | Should -Be 0 -Because $good.Output
    }
    It 'works without -OutputRoot: the default resolves under a real 5.1 child (preview only, nothing written)' {
        $ws = New-TestWorkspace
        $arguments = @('-Vendor', 'Fixture', '-VendorRoot', $script:vendorRoot, '-ProfileRoot', $script:profileRoot, '-LayoutPath', $ws.Layout,
            '-TargetPath', $ws.Stick, '-AllowFolder', '-Model', 'm1', '-WhatIf')
        $run = Invoke-ScriptChild -ArgumentList $arguments
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'nothing was staged'
        @(Get-ChildItem -LiteralPath $ws.Stick -Force) | Should -BeNullOrEmpty
    }
    It 'fails -ValidateOnly on a folder with no manifest and names firmware-manifest.json' {
        $ws = New-TestWorkspace
        $run = Invoke-ScriptChild -ArgumentList @('-ValidateOnly', '-TargetPath', $ws.Stick, '-AllowFolder')
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match 'firmware-manifest\.json'
    }
    It 'lists the available ids for an unknown model' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $run = Invoke-ScriptChild -ArgumentList ((Get-ChildBase -Workspace $ws) + @('-Model', 'm9'))
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Flat | Should -Match 'm1'
        $run.Flat | Should -Match 'm2'
    }
    It 'fails and names -Model when it cannot ask for it' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $run = Invoke-ScriptChild -ArgumentList (Get-ChildBase -Workspace $ws) -NonInteractive -TimeoutSeconds 120
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Flat | Should -Match '-Model'
    }
    It 'takes vendor, models and target from standard input when they are omitted' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $answer = "1`r`n1,2`r`n$($ws.Stick)`r`n"
        $run = Invoke-ScriptChild -ArgumentList (Get-ChildBase -Workspace $ws -NoPrompt) -InputText $answer -TimeoutSeconds 120
        $run.ExitCode | Should -Be 0 -Because $run.Output
        @((Read-StickManifest -Stick $ws.Stick).models | ForEach-Object { $_.modelId }) | Should -Be @('m1', 'm2')
    }
    It 'exits non-zero instead of hanging when the answers run out' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $run = Invoke-ScriptChild -ArgumentList (Get-ChildBase -Workspace $ws -NoPrompt) -InputText "1`r`n1,2`r`n" -TimeoutSeconds 120
        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match '\[FAIL\]'
        (Join-Path $ws.Stick 'READY') | Should -Not -Exist
    }
    It 'fails on a stale file, naming it, and succeeds with -RemoveStale' {
        $ws = New-TestWorkspace
        Write-SimpleLayout -Path $ws.Layout
        $arguments = (Get-ChildBase -Workspace $ws) + @('-Model', 'm1')
        (Invoke-ScriptChild -ArgumentList $arguments).ExitCode | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $ws.Stick 'Vendor\BIOS\New\old.bin'), 'old', [Text.Encoding]::ASCII)
        $blocked = Invoke-ScriptChild -ArgumentList $arguments
        $blocked.ExitCode | Should -Be 1 -Because $blocked.Output
        $blocked.Output | Should -Match 'old\.bin'
        $cleaned = Invoke-ScriptChild -ArgumentList ($arguments + '-RemoveStale')
        $cleaned.ExitCode | Should -Be 0 -Because $cleaned.Output
    }
}

Describe 'Build-ToolsStick public surface' {
    BeforeAll {
        $script:masterScript | Should -Exist
        $script:ast = Read-ScriptAst
        $script:ast | Should -Not -BeNullOrEmpty
    }
    It 'copies, deletes, writes and runs nothing itself' {
        $forbidden = 'Copy-Item', 'Remove-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Start-Process', 'Invoke-Expression', 'Format-Volume', 'Write-Host'
        $used = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -in $forbidden }
        $used | Should -BeNullOrEmpty
    }
    It 'asks questions only inside its two prompt helpers, and no core or vendor file asks any' {
        $reads = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-Host' }, $true)
        @($reads).Count | Should -BeGreaterThan 0
        foreach ($read in $reads) {
            $parent = $read.Parent
            while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
            $parent.Name | Should -BeIn 'Select-BuildChoice', 'Read-BuildTarget'
        }
        $folders = (Join-Path $PSScriptRoot '..\kit\core'), (Join-Path $PSScriptRoot '..\kit\vendors'), (Join-Path $PSScriptRoot '..\builder\vendors')
        $others = Get-ChildItem -LiteralPath $folders -Recurse -File -Include '*.ps1', '*.psm1' |
            Select-String -Pattern 'Read-Host' -SimpleMatch
        @($others) | Should -BeNullOrEmpty
    }
    It 'declares exactly the documented parameters' {
        $declared = @($script:ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $expected = 'Vendor', 'Model', 'TargetPath', 'DiagnosticsSource', 'CaptureName', 'NewDiagnosticsSnapshot', 'FlashModel', 'IncludeKit',
        'RemoveStale', 'AllowFolder', 'ValidateOnly', 'OsVer', 'OutputRoot', 'VendorRoot', 'ProfileRoot', 'LayoutPath'
        $declared | Should -Be $expected
    }
    It 'defaults -OutputRoot to the staging folder next to the repo, set in the body because 5.1 cannot do it in the param block' {
        # With [CmdletBinding()] and -File, $PSScriptRoot is empty in a param default under Windows PowerShell 5.1.
        $parameter = $script:ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'OutputRoot' }
        $parameter.DefaultValue | Should -BeNullOrEmpty
        $assignment = $script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$OutputRoot'
            }, $true) | Where-Object { $_.Right.Extent.Text -eq "Join-Path `$PSScriptRoot '..\staging'" }
        @($assignment).Count | Should -Be 1
    }
    It 'ends every run with exit code 0 or 1 only' {
        $exits = $script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
        @($exits).Count | Should -BeGreaterThan 0
        foreach ($exit in $exits) { $exit.Pipeline.Extent.Text | Should -BeIn '0', '1' }
    }
    It 'documents every parameter and gives at least three examples' {
        $help = Get-Help -Name $script:masterScript -Full
        foreach ($name in 'Vendor', 'Model', 'TargetPath', 'DiagnosticsSource', 'CaptureName', 'NewDiagnosticsSnapshot', 'FlashModel', 'IncludeKit',
            'RemoveStale', 'AllowFolder', 'ValidateOnly', 'OsVer', 'OutputRoot', 'VendorRoot', 'ProfileRoot', 'LayoutPath') {
            $entry = $help.parameters.parameter | Where-Object { $_.name -eq $name }
            $entry | Should -Not -BeNullOrEmpty -Because $name
            (($entry.description | ForEach-Object { $_.Text }) -join '') | Should -Not -BeNullOrEmpty -Because $name
        }
        @($help.examples.example).Count | Should -BeGreaterOrEqual 3
    }
    It 'leaves the Build.cmd launcher on Build-DriverBaseline.ps1' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Build.cmd') -Raw
        $text | Should -Match ([regex]::Escape('builder\Build-DriverBaseline.ps1'))
        $text | Should -Not -Match 'Build-ToolsStick'
    }
}
