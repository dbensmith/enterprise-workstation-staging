BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    $script:coreManifest = Join-Path $script:corePath 'Kit.Core.psd1'
    Import-Module $script:coreManifest -Force
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1'
    $script:fixtureText = [IO.File]::ReadAllText($script:fixture)

    # Write a copy of the fixture with one text replacement into TestDrive and return its path. The replacement must
    # change the text, so a typo in a test cannot turn a rejection test into a vacuous pass.
    function Write-TestLayout {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$Old,
            [Parameter(Mandatory)][AllowEmptyString()][string]$New
        )
        $text = $script:fixtureText.Replace($Old, $New)
        if ($text -ceq $script:fixtureText) { throw "The fixture does not contain '$Old'." }
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $folder -ItemType Directory
        $path = Join-Path $folder 'layout.psd1'
        [IO.File]::WriteAllText($path, $text)
        $path
    }

    # The message a script block throws, or $null when it does not throw.
    function Get-ThrownMessage {
        [CmdletBinding()]
        param([Parameter(Mandatory)][scriptblock]$Action)
        try { & $Action } catch { return $_.Exception.Message }
        $null
    }
}

Describe 'Get-KitFirmwareLayout on the committed fixture' {
    BeforeAll {
        $script:layout = Get-KitFirmwareLayout -Path $script:fixture
    }

    It 'is a Kit.FirmwareLayout with the file, label and file system' {
        $script:layout.PSObject.TypeNames | Should -Contain 'Kit.FirmwareLayout'
        $script:layout.Path | Should -Be (Resolve-Path -LiteralPath $script:fixture).ProviderPath
        $script:layout.SchemaVersion | Should -Be 1
        $script:layout.VolumeLabel | Should -Be 'FX_TOOLS'
        $script:layout.FileSystem | Should -Be 'FAT32'
    }

    It 'keeps the five groups in file order' {
        @($script:layout.Groups.Id) | Should -Be @('G-New', 'G-Current', 'G-Diag', 'G-Win', 'G-Dev')
    }

    It 'resolves the source kinds and the capture name' {
        @($script:layout.Groups.SourceKind) | Should -Be @('BiosImage', 'BiosImage', 'Captured', 'WindowsFlashTool', 'FlashImage')
        @($script:layout.Groups | Where-Object CaptureName).Id | Should -Be 'G-Diag'
        ($script:layout.Groups | Where-Object Id -EQ 'G-Diag').CaptureName | Should -Be 'fx-diag'
        ($script:layout.Groups | Where-Object Id -EQ 'G-Diag').Source | Should -Be 'Captured:fx-diag'
    }

    It 'carries the Closed and Default flags and the folders as written' {
        @($script:layout.Groups.Closed) | Should -Be @($true, $true, $false, $true, $true)
        @($script:layout.Groups.Default) | Should -Be @($true, $true, $true, $true, $false)
        @($script:layout.Groups.Folder) | Should -Be @('Vendor\BIOS\New', 'Vendor\BIOS\Current', 'EFI\FX', 'firmware\fx\{Platform}', 'FX\DEVFW')
    }

    It 'reports every Verified block as not verified' {
        foreach ($group in $script:layout.Groups) {
            $group.Verified.Status | Should -BeFalse
            @($group.Verified.Model).Count | Should -Be 0
        }
    }

    It 'lists the capture with its snapshot path beside the layout file' {
        @($script:layout.Captures).Count | Should -Be 1
        $script:layout.Captures[0].Name | Should -Be 'fx-diag'
        $script:layout.Captures[0].PackageId | Should -Be 'fxdiag1'
        $script:layout.Captures[0].Version | Should -Be '1.0'
        $script:layout.Captures[0].Snapshot | Should -Be 'fx-diag.snapshot.psd1'
        $script:layout.Captures[0].SnapshotPath | Should -Be (Join-Path (Split-Path -Path $script:fixture -Parent) 'fx-diag.snapshot.psd1')
    }

    It 'is pure ASCII' {
        [IO.File]::ReadAllBytes($script:fixture) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty
    }
}

Describe 'Get-KitFirmwareLayout rejections' {
    It 'rejects <Name> and names the file and the problem' -ForEach @(
        @{ Name = 'SchemaVersion 2'; Old = 'SchemaVersion = 1'; New = 'SchemaVersion = 2'; Problem = '*SchemaVersion*' }
        @{ Name = 'an unknown top-level key'; Old = "VolumeLabel   = 'FX_TOOLS'"; New = "VolumeLabel   = 'FX_TOOLS'; Bogus = 1"; Problem = "*'Bogus'*" }
        @{ Name = 'a missing Groups key'; Old = 'Groups        = @('; New = 'Grouped       = @('; Problem = "*'Groups'*" }
        @{ Name = 'an unknown group key'; Old = "Id = 'G-New'; Folder"; New = "Id = 'G-New'; Bogus = 1; Folder"; Problem = "*'Bogus'*" }
        @{ Name = 'a missing group key'; Old = "Source = 'BiosImage'; Closed = `$true; Default = `$true"; New = "Source = 'BiosImage'; Closed = `$true"; Problem = "*'Default'*" }
        @{ Name = 'a duplicate Id that differs only in case'; Old = "Id = 'G-Current'"; New = "Id = 'g-new'"; Problem = '*duplicate*' }
        @{ Name = 'a rooted Folder'; Old = "Folder = 'Vendor\BIOS\New'"; New = "Folder = '\Vendor\BIOS\New'"; Problem = "*'Folder'*" }
        @{ Name = 'a Folder with a parent segment'; Old = "Folder = 'Vendor\BIOS\New'"; New = "Folder = 'Vendor\..\New'"; Problem = "*'Folder'*" }
        @{ Name = 'a Folder with a colon'; Old = "Folder = 'Vendor\BIOS\New'"; New = "Folder = 'Vendor:BIOS\New'"; Problem = "*'Folder'*" }
        @{ Name = 'a Folder with a trailing backslash'; Old = "Folder = 'Vendor\BIOS\New'"; New = "Folder = 'Vendor\BIOS\New\'"; Problem = "*'Folder'*" }
        @{ Name = 'a Folder with an empty segment'; Old = "Folder = 'Vendor\BIOS\New'"; New = "Folder = 'Vendor\\New'"; Problem = "*'Folder'*" }
        @{ Name = 'a Folder with an unknown token'; Old = "Folder = 'Vendor\BIOS\New'"; New = "Folder = 'Vendor\{Model}\New'"; Problem = "*'Folder'*" }
        @{ Name = 'the platform token in a captured group'; Old = "Folder = 'EFI\FX'"; New = "Folder = 'EFI\{Platform}'"; Problem = "*'Folder'*" }
        @{ Name = 'an unknown Source'; Old = "Source = 'WindowsFlashTool'"; New = "Source = 'Nonsense'"; Problem = "*'Source'*" }
        @{ Name = 'a captured Source with no such capture'; Old = "Source = 'Captured:fx-diag'"; New = "Source = 'Captured:zz'"; Problem = '*Captured:zz*' }
        @{ Name = 'a Closed value that is not a boolean'; Old = "Source = 'WindowsFlashTool'; Closed = `$true"; New = "Source = 'WindowsFlashTool'; Closed = 'yes'"; Problem = "*'Closed'*" }
        @{ Name = 'a Default value that is not a boolean'; Old = "Source = 'FlashImage'; Closed = `$true; Default = `$false"; New = "Source = 'FlashImage'; Closed = `$true; Default = 0"; Problem = "*'Default'*" }
        @{ Name = 'a verified block without By'; Old = "Status = `$false; Model = @(); Bios = ''; Date = ''; By = ''"; New = "Status = `$true; Model = @('m1'); Bios = '1.00'; Date = '2026-11-02'; By = ''"; Problem = "*'By'*" }
        @{ Name = 'a verified block with a date in the wrong form'; Old = "Status = `$false; Model = @(); Bios = ''; Date = ''; By = ''"; New = "Status = `$true; Model = @('m1'); Bios = '1.00'; Date = '11/02/2026'; By = 'tester'"; Problem = "*'Date'*" }
        @{ Name = 'a VolumeLabel of 12 characters'; Old = "'FX_TOOLS'"; New = "'ABCDEFGHIJKL'"; Problem = '*VolumeLabel*' }
        @{ Name = 'a file system other than FAT32'; Old = "FileSystem    = 'FAT32'"; New = "FileSystem    = 'NTFS'"; Problem = '*FileSystem*' }
    ) {
        $path = Write-TestLayout -Old $Old -New $New
        $message = Get-ThrownMessage -Action { Get-KitFirmwareLayout -Path $path }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -BeLike "*$path*"
        $message | Should -BeLike $Problem
    }

    It 'throws a message that names the file when the layout does not exist' {
        $path = Join-Path $TestDrive 'nowhere.psd1'
        { Get-KitFirmwareLayout -Path $path } | Should -Throw "*$path*not found*"
    }

    It 'refuses a command expression, says it is not a plain data file and never runs it' {
        $ran = Join-Path $TestDrive 'ran.txt'
        $path = Write-TestLayout -Old "VolumeLabel   = 'FX_TOOLS'" -New "VolumeLabel   = (New-Item -Path '$ran' -ItemType File)"
        $message = Get-ThrownMessage -Action { Get-KitFirmwareLayout -Path $path }
        $message | Should -BeLike '*not a plain data file*'
        $message | Should -BeLike "*$path*"
        $ran | Should -Not -Exist
    }
}

Describe 'Get-KitFirmwareLayout accepted variants' {
    It 'loads a layout with no Captures key and reports an empty Captures array' {
        $lines = [IO.File]::ReadAllLines($script:fixture)
        $start = [array]::FindIndex($lines, [Predicate[string]] { param($line) $line -match '^\s*Captures\s*=' })
        $kept = @($lines[0..($start - 1)]) + @($lines[($start + 3)..($lines.Count - 1)])
        $text = ($kept -join [Environment]::NewLine).Replace("'Captured:fx-diag'", "'BiosImage'")
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        [IO.File]::WriteAllText($path, $text)
        $layout = Get-KitFirmwareLayout -Path $path
        @($layout.Captures).Count | Should -Be 0
        @($layout.Groups).Count | Should -Be 5
    }

    It 'loads a verified block and reports its Status as true' {
        $path = Write-TestLayout -Old "Status = `$false; Model = @(); Bios = ''; Date = ''; By = ''" -New "Status = `$true; Model = @('m1'); Bios = '1.00'; Date = '2026-11-02'; By = 'tester'"
        $layout = Get-KitFirmwareLayout -Path $path
        foreach ($group in $layout.Groups) {
            $group.Verified.Status | Should -BeTrue
            @($group.Verified.Model) | Should -Be @('m1')
            $group.Verified.Bios | Should -Be '1.00'
            $group.Verified.Date | Should -Be '2026-11-02'
            $group.Verified.By | Should -Be 'tester'
        }
    }
}

Describe 'Kit.Core exports (layout)' {
    It 'exports Get-KitFirmwareLayout first in the firmware block, before Test-FirmwareTarget' {
        $names = @((Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport)
        $names.IndexOf('Get-KitFirmwareLayout') | Should -BeGreaterThan $names.IndexOf('Get-KitPublishFile')
        $names.IndexOf('Get-KitFirmwareLayout') | Should -Be ($names.IndexOf('Get-KitPublishFile') + 1)
        $names.IndexOf('Get-KitFirmwareLayout') | Should -BeLessThan $names.IndexOf('Test-FirmwareTarget')
    }

    It 'keeps every other function FirmwareLayout.ps1 defines private' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:corePath 'FirmwareLayout.ps1'), [ref]$tokens, [ref]$errors)
        $defined = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $defined | Should -Contain 'Get-KitFirmwareLayout'
        $exported = @((Get-Module -Name Kit.Core).ExportedFunctions.Keys)
        @($defined | Where-Object { $exported -contains $_ }) | Should -Be @('Get-KitFirmwareLayout')
    }
}
