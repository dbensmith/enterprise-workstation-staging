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
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($lines -join "`n"); Lines = $lines }
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
