BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    $script:coreManifest = Join-Path $script:corePath 'Kit.Core.psd1'
    Import-Module $script:coreManifest -Force

    # The captured tree of the fixture: three files under EFI\FX plus the two trees Windows keeps for itself.
    function New-TestCapture {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root)
        if (-not $PSCmdlet.ShouldProcess($Root, 'Write a test capture')) { return }
        $content = @{
            'EFI\FX\a.efi'              = [byte[]](1..12)
            'EFI\FX\sub\b.dll'          = [byte[]](20..60)
            'EFI\FX\c.json'             = [byte[]](65..90)
            'System Volume Information\x' = [byte[]](1, 2)
            '$RECYCLE.BIN\y'            = [byte[]](3, 4)
        }
        foreach ($relative in $content.Keys) {
            $path = Join-Path -Path $Root -ChildPath $relative
            $null = New-Item -Path (Split-Path -Path $path -Parent) -ItemType Directory -Force
            [IO.File]::WriteAllBytes($path, $content[$relative])
        }
        $Root
    }

    # A copy of the fixture layout in its own folder, so the snapshot it names is written next to it.
    function Copy-TestLayout {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([pscustomobject])]
        param()
        $folder = Join-Path -Path $TestDrive -ChildPath ('layout-' + [guid]::NewGuid().ToString('N'))
        if (-not $PSCmdlet.ShouldProcess($folder, 'Copy the fixture layout')) { return }
        $null = New-Item -Path $folder -ItemType Directory -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1') -Destination $folder
        Get-KitFirmwareLayout -Path (Join-Path $folder 'fixture.layout.psd1')
    }

    function New-TestModelResult {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$ModelId,
            [Parameter(Mandatory)][string]$PlatformId,
            [Parameter(Mandatory)][string]$Family
        )
        if (-not $PSCmdlet.ShouldProcess($Root, 'Write test images')) { return }
        $image = '{0}_000100.bin' -f $Family
        $entry = foreach ($folder in 'New', 'Current') {
            $relative = "Vendor\BIOS\$folder\$image"
            $source = Join-Path -Path $Root -ChildPath (Join-Path -Path $ModelId -ChildPath $relative)
            $null = New-Item -Path (Split-Path -Path $source -Parent) -ItemType Directory -Force
            [IO.File]::WriteAllBytes($source, [byte[]](1..32))
            [pscustomobject]@{
                RelativePath = $relative
                SourcePath   = $source
                Group        = "G-$folder"
                Size         = 32L
                Sha256       = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
                VendorHash   = $null
            }
        }
        [pscustomobject]@{
            PSTypeName       = 'Kit.FirmwareStickLayout'
            Vendor           = 'Fixture'
            ModelId          = $ModelId
            Name             = "Fixture $ModelId"
            PlatformId       = $PlatformId
            PlatformVerified = $false
            BiosFamily       = $Family
            LatestBios       = [pscustomobject]@{ Version = '1.00'; Date = '2026-01-01'; PackageId = "fx-$Family"; File = $image; DependencyMinimum = '' }
            WindowsFlash     = $null
            Entries          = @($entry)
            Notes            = @()
        }
    }

    function Get-ThrownMessage {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][scriptblock]$Script)
        try {
            $null = & $Script
            ''
        }
        catch {
            $_.Exception.Message
        }
    }

    function New-StickPath {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([string])]
        param()
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        if ($PSCmdlet.ShouldProcess($path, 'Make a stick folder')) {
            $null = New-Item -Path $path -ItemType Directory -Force
            $path
        }
    }
}

Describe 'New-KitFirmwareSnapshot' {
    BeforeEach {
        $script:capture = New-TestCapture -Root (Join-Path $TestDrive ('cap-' + [guid]::NewGuid().ToString('N')))
        $script:snapshot = Join-Path $TestDrive ('snap-' + [guid]::NewGuid().ToString('N') + '\fx-diag.snapshot.psd1')
    }

    It 'records exactly the three files, sorted, with size and lower-case SHA-256, and skips the Windows trees' {
        $result = New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot -PassThru
        $result.Path | Should -Be $script:snapshot
        $result.Name | Should -Be 'fx-diag'
        $result.FileCount | Should -Be 3
        $data = Import-PowerShellDataFile -LiteralPath $script:snapshot
        $data.SchemaVersion | Should -Be 1
        $data.Name | Should -Be 'fx-diag'
        @($data.Files).Count | Should -Be 3
        @($data.Files | ForEach-Object { $_.Path }) | Should -Be @('EFI\FX\a.efi', 'EFI\FX\c.json', 'EFI\FX\sub\b.dll')
        $first = $data.Files[0]
        $first.Size | Should -Be 12
        $first.Sha256 | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $script:capture 'EFI\FX\a.efi') -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($file in $data.Files) { $file.Sha256 | Should -Match '^[0-9a-f]{64}$' }
    }

    It 'writes pure ASCII and the same bytes for the same tree' {
        $null = New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot
        $one = [IO.File]::ReadAllBytes($script:snapshot)
        @($one | Where-Object { $_ -gt 127 }) | Should -BeNullOrEmpty
        $again = Join-Path $TestDrive ('again-' + [guid]::NewGuid().ToString('N') + '.psd1')
        $null = New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $again
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($again)) | Should -Be ([Convert]::ToBase64String($one))
    }

    It 'doubles a single quote in a path' {
        $odd = Join-Path $script:capture "EFI\FX\it's.efi"
        [IO.File]::WriteAllBytes($odd, [byte[]](1, 2, 3))
        $null = New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot
        @((Import-PowerShellDataFile -LiteralPath $script:snapshot).Files | ForEach-Object { $_.Path }) | Should -Contain "EFI\FX\it's.efi"
    }

    It 'writes nothing under -WhatIf' {
        $null = New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot -WhatIf
        $script:snapshot | Should -Not -Exist
    }

    It 'throws for <Name>' -ForEach @(
        @{ Name = 'a missing source folder'; Needle = 'nowhere'; Arguments = @{ SourcePath = 'C:\nowhere\nowhere'; Name = 'fx-diag' } }
        @{ Name = 'a tree with no file'; Needle = 'holds no file'; Arguments = @{ SourcePath = 'EMPTY'; Name = 'fx-diag' } }
        @{ Name = 'a capture name with a space'; Needle = 'bad name'; Arguments = @{ SourcePath = 'CAPTURE'; Name = 'bad name' } }
        @{ Name = 'a capture name with a slash'; Needle = 'a/b'; Arguments = @{ SourcePath = 'CAPTURE'; Name = 'a/b' } }
    ) {
        $arguments = $Arguments.Clone()
        if ($arguments.SourcePath -eq 'EMPTY') {
            $arguments.SourcePath = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -Path (Join-Path $arguments.SourcePath 'System Volume Information') -ItemType Directory -Force
        }
        if ($arguments.SourcePath -eq 'CAPTURE') { $arguments.SourcePath = $script:capture }
        $message = Get-ThrownMessage -Script { New-KitFirmwareSnapshot @arguments -Path $script:snapshot }
        $message | Should -BeLike "*$Needle*"
        $script:snapshot | Should -Not -Exist
    }

    It 'throws and names a file whose name has a character outside ASCII' {
        $odd = 'caf' + [char]0x00E9 + '.efi'
        [IO.File]::WriteAllBytes((Join-Path $script:capture "EFI\FX\$odd"), [byte[]](1, 2, 3))
        $message = Get-ThrownMessage -Script { New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot }
        $message | Should -BeLike "*$odd*"
        $message | Should -BeLike '*ASCII*'
        $script:snapshot | Should -Not -Exist
    }

    It 'throws and names a file whose path is not valid on FAT32' {
        Mock Get-KitStagePathProblem -ModuleName Kit.Core { 'forced problem' }
        $message = Get-ThrownMessage -Script { New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot }
        $message | Should -BeLike '*EFI\FX\a.efi*'
        $message | Should -BeLike '*forced problem*'
        $script:snapshot | Should -Not -Exist
    }
}

Describe 'Publish-FirmwareStage replays a recorded capture' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images-capture'
        $script:m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00'
        $script:m2 = New-TestModelResult -Root $script:images -ModelId 'm2' -PlatformId '0001' -Family 'F01'
    }

    BeforeEach {
        $script:capture = New-TestCapture -Root (Join-Path $TestDrive ('cap-' + [guid]::NewGuid().ToString('N')))
        $script:layout = Copy-TestLayout
        $script:snapshot = $script:layout.Captures[0].SnapshotPath
        $null = New-KitFirmwareSnapshot -SourcePath $script:capture -Name 'fx-diag' -Path $script:snapshot
        $script:stick = New-StickPath
    }

    It 'stages the captured files at the same relative paths and describes them in the manifest' {
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } -PassThru
        $result.Ready | Should -BeTrue
        $result.FileCount | Should -Be 5
        foreach ($relative in 'EFI\FX\a.efi', 'EFI\FX\c.json', 'EFI\FX\sub\b.dll') {
            (Get-FileHash -LiteralPath (Join-Path $script:stick $relative) -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:capture $relative) -Algorithm SHA256).Hash
        }
        (Join-Path $script:stick 'System Volume Information') | Should -Not -Exist
        $manifest = [IO.File]::ReadAllText((Join-Path $script:stick 'firmware-manifest.json')) | ConvertFrom-Json
        @($manifest.shared).Count | Should -Be 3
        foreach ($record in $manifest.shared) {
            $record.group | Should -Be 'G-Diag'
            $record.vendorHash | Should -BeNullOrEmpty
            $record.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
        @($manifest.models[0].files | Where-Object { $_.group -eq 'G-Diag' }) | Should -BeNullOrEmpty
        $manifest.diagnostics.name | Should -Be 'fx-diag'
        $manifest.diagnostics.packageId | Should -Be 'fxdiag1'
        $manifest.diagnostics.version | Should -Be '1.0'
        $manifest.diagnostics.fileCount | Should -Be 3
        @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'stages the captured files once with a second model and with -FlashModel' {
        $both = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1, $script:m2) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } -PassThru
        $both.Ready | Should -BeTrue
        $both.FileCount | Should -Be 7
        $manifest = [IO.File]::ReadAllText((Join-Path $script:stick 'firmware-manifest.json')) | ConvertFrom-Json
        @($manifest.shared).Count | Should -Be 3

        $single = New-StickPath
        $flash = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1, $script:m2) -TargetPath $single -AllowFolder -FlashModel 'm1' -CapturePath @{ 'fx-diag' = $script:capture } -PassThru
        $flash.Ready | Should -BeTrue
        $flash.FileCount | Should -Be 5
        ([IO.File]::ReadAllText((Join-Path $single 'firmware-manifest.json')) | ConvertFrom-Json).shared.Count | Should -Be 3
    }

    It 'stops with the FW-05 missing-capture text when no capture path is given' {
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder }
        $message | Should -BeLike 'FW-05: the UEFI diagnostics capture is missing.*'
        $message | Should -BeLike "*Group 'G-Diag'*"
        $message | Should -BeLike "*'fx-diag'*"
        $message | Should -BeLike '*-DiagnosticsSource*'
        $message | Should -BeLike '*docs\firmware-bench-checklist.md*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'stops when the capture path is not an existing folder' {
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = (Join-Path $TestDrive 'no-such-folder') } }
        $message | Should -BeLike 'FW-05*no-such-folder*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'stops with the FW-05 snapshot text and the snapshot path when the snapshot is absent' {
        Remove-Item -LiteralPath $script:snapshot
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } }
        $message | Should -BeLike 'FW-05: no recorded snapshot at *'
        $message | Should -BeLike "*$($script:snapshot)*"
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'stops and names the file when one byte of a captured file was flipped' {
        $file = Join-Path $script:capture 'EFI\FX\a.efi'
        $bytes = [IO.File]::ReadAllBytes($file)
        $bytes[0] = $bytes[0] -bxor 0xFF
        [IO.File]::WriteAllBytes($file, $bytes)
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } }
        $message | Should -BeLike '*EFI\FX\a.efi*'
        $message | Should -BeLike '*differs from the recorded snapshot*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'stops and names the file when a recorded file is absent from the capture' {
        Remove-Item -LiteralPath (Join-Path $script:capture 'EFI\FX\c.json')
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } }
        $message | Should -BeLike '*EFI\FX\c.json*'
        $message | Should -BeLike 'FW-05*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'stops, counts and names a capture file the snapshot does not list' {
        [IO.File]::WriteAllBytes((Join-Path $script:capture 'EFI\FX\extra.efi'), [byte[]](1, 2, 3))
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } }
        $message | Should -BeLike 'FW-05*'
        $message | Should -BeLike '*1 file(s)*'
        $message | Should -BeLike '*EFI\FX\extra.efi*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'refuses a snapshot that is wrong in <Name>' -ForEach @(
        @{ Name = 'a path outside the group folder'; Needle = 'Other\x.efi'; Old = "Path = 'EFI\FX\a.efi'"; New = "Path = 'Other\x.efi'" }
        @{ Name = 'a duplicate path'; Needle = 'twice'; Old = "Path = 'EFI\FX\c.json'"; New = "Path = 'EFI\FX\A.EFI'" }
        @{ Name = 'a capture name that differs'; Needle = "'other'"; Old = "Name          = 'fx-diag'"; New = "Name          = 'other'" }
        @{ Name = 'a hash that is not 64 hex'; Needle = 'Sha256'; Old = "Path = 'EFI\FX\a.efi'; Size = 12; Sha256 = '"; New = "Path = 'EFI\FX\a.efi'; Size = 12; Sha256 = 'zz" }
        @{ Name = 'a key it does not know'; Needle = 'unknown key'; Old = '    SchemaVersion = 1'; New = "    SchemaVersion = 1`n    Extra = 1" }
    ) {
        $text = [IO.File]::ReadAllText($script:snapshot)
        $text.Contains($Old) | Should -BeTrue
        [IO.File]::WriteAllText($script:snapshot, $text.Replace($Old, $New), [Text.Encoding]::ASCII)
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } }
        $message | Should -BeLike 'FW-05*'
        $message | Should -BeLike "*$Needle*"
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'refuses a snapshot that holds code and never runs it' {
        [IO.File]::WriteAllText($script:snapshot, "@{ SchemaVersion = 1; Name = (New-Item -Path '$($script:stick)\ran.txt' -ItemType File) }", [Text.Encoding]::ASCII)
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -AllowFolder -CapturePath @{ 'fx-diag' = $script:capture } }
        $message | Should -BeLike 'FW-05*not a plain data file*'
        (Join-Path $script:stick 'ran.txt') | Should -Not -Exist
    }
}

Describe 'Kit.Core exports (capture)' {
    It 'exports New-KitFirmwareSnapshot right after Publish-FirmwareStage and keeps the other capture helpers private' {
        $names = @((Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport)
        $names.IndexOf('New-KitFirmwareSnapshot') | Should -Be ($names.IndexOf('Publish-FirmwareStage') + 1)
        $exported = @((Get-Module -Name Kit.Core).ExportedFunctions.Keys)
        $exported | Should -Contain 'New-KitFirmwareSnapshot'
        $exported | Should -Not -Contain 'Resolve-KitCaptureEntry'
        $exported | Should -Not -Contain 'Read-KitFirmwareSnapshot'
    }
}
