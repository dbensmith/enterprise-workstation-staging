BeforeDiscovery {
    # The four firmware files; one that does not exist yet is left out rather than skipped.
    $script:astFile = @('FirmwareCheck.ps1', 'FirmwareLayout.ps1', 'FirmwarePublish.ps1', 'FirmwareCapture.ps1' |
            Where-Object { Test-Path -LiteralPath (Join-Path $PSScriptRoot "..\kit\core\$_") } |
            ForEach-Object { @{ Name = $_ } })
}

BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    $script:coreManifest = Join-Path $script:corePath 'Kit.Core.psd1'
    Import-Module $script:coreManifest -Force

    # The message of the exception a script block throws, or an empty string when it does not throw.
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

    # A vendor result (the Kit.FirmwareStickLayout contract) built by hand. -Root receives the source images, each written
    # from run-time bytes. -Entry is a list of @{ Group; Path; Bytes; VendorAlgorithm }; without it the model gets one image
    # with a SHA-384 vendor hash in each of the groups G-New and G-Current.
    function New-TestModelResult {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$ModelId,
            [Parameter(Mandatory)][string]$PlatformId,
            [Parameter(Mandatory)][string]$Family,
            [byte[]]$Bytes = [byte[]](1..32),
            [hashtable[]]$Entry,
            [string[]]$Note = @(),
            [object]$WindowsFlash,
            [string]$Vendor = 'Fixture'
        )
        if (-not $PSCmdlet.ShouldProcess($Root, 'Write test images')) { return }
        if (-not $Entry) {
            $image = '{0}_000100.bin' -f $Family
            $Entry = @(
                @{ Group = 'G-New'; Path = "Vendor\BIOS\New\$image"; Bytes = $Bytes; VendorAlgorithm = 'SHA384' }
                @{ Group = 'G-Current'; Path = "Vendor\BIOS\Current\$image"; Bytes = $Bytes; VendorAlgorithm = 'SHA384' }
            )
        }
        $built = foreach ($item in $Entry) {
            $source = Join-Path -Path $Root -ChildPath (Join-Path -Path $ModelId -ChildPath $item.Path)
            $null = New-Item -Path (Split-Path -Path $source -Parent) -ItemType Directory -Force
            [IO.File]::WriteAllBytes($source, [byte[]]$item.Bytes)
            $vendorHash = $null
            if ($item.VendorAlgorithm) {
                $vendorHash = [pscustomobject]@{
                    Algorithm = $item.VendorAlgorithm
                    Value     = (Get-FileHash -LiteralPath $source -Algorithm $item.VendorAlgorithm).Hash.ToLowerInvariant()
                    Source    = 'catalog'
                }
            }
            [pscustomobject]@{
                RelativePath = $item.Path
                SourcePath   = $source
                Group        = $item.Group
                Size         = ([long]([byte[]]$item.Bytes).Length)
                Sha256       = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
                VendorHash   = $vendorHash
            }
        }
        [pscustomobject]@{
            PSTypeName       = 'Kit.FirmwareStickLayout'
            Vendor           = $Vendor
            ModelId          = $ModelId
            Name             = "Fixture $ModelId"
            PlatformId       = $PlatformId
            PlatformVerified = $false
            BiosFamily       = $Family
            LatestBios       = [pscustomobject]@{ Version = '1.00'; Date = '2026-01-01'; PackageId = "fx-$Family"; File = "${Family}_000100.bin"; DependencyMinimum = '' }
            WindowsFlash     = $WindowsFlash
            Entries          = @($built)
            Notes            = $Note
        }
    }

    # The two-group layout of the tracer tests, written as a data file.
    function Write-TestLayout {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Path)
        if (-not $PSCmdlet.ShouldProcess($Path, 'Write a test layout')) { return }
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
        [IO.File]::WriteAllText($Path, $text, [Text.Encoding]::ASCII)
        $Path
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

Describe 'Publish-FirmwareStage tracer' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images'
        $script:layout = Get-KitFirmwareLayout -Path (Write-TestLayout -Path (Join-Path $TestDrive 'tracer.layout.psd1'))
        $script:flash = [pscustomobject]@{
            Path         = 'firmware\flash.exe'
            SilentInstall = '/s'
            ReturnCodes  = @{ '0' = 'success'; '3010' = 'reboot needed' }
        }
        $script:m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00' -Note @('check the dock firmware') -WindowsFlash $script:flash
    }

    It 'stages one model into both group folders and reports a ready stick' {
        $stick = New-StickPath
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru
        $result.PSObject.TypeNames | Should -Contain 'Kit.FirmwareStageResult'
        $result.Ready | Should -BeTrue
        $result.Written | Should -BeTrue
        $result.FileCount | Should -Be 2
        $result.TargetPath | Should -Be $stick
        $result.ManifestPath | Should -Be (Join-Path $stick 'firmware-manifest.json')
        $source = (Get-FileHash -LiteralPath $script:m1.Entries[0].SourcePath -Algorithm SHA256).Hash
        foreach ($relative in 'Vendor\BIOS\New\F00_000100.bin', 'Vendor\BIOS\Current\F00_000100.bin') {
            $staged = Join-Path $stick $relative
            $staged | Should -Exist
            (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash | Should -Be $source
        }
    }

    It 'returns nothing without -PassThru' {
        $stick = New-StickPath
        Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder | Should -BeNullOrEmpty
        (Join-Path $stick 'READY') | Should -Exist
    }

    It 'writes a manifest with the fixed key order, no byte order mark and no builder data' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        $path = Join-Path $stick 'firmware-manifest.json'
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        @($manifest.PSObject.Properties.Name) | Should -Be @(
            'schemaVersion', 'toolVersion', 'builtUtc', 'vendor', 'volumeLabel', 'fileSystem', 'verified', 'flashModel', 'groups', 'models', 'shared', 'diagnostics')
        $manifest.schemaVersion | Should -Be 1
        $manifest.toolVersion | Should -Be (Get-Module -Name Kit.Core).Version.ToString()
        $manifest.builtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $built = [datetime]::ParseExact($manifest.builtUtc, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        ([datetime]::UtcNow - $built).TotalSeconds | Should -BeLessThan 60
        $manifest.vendor | Should -Be 'Fixture'
        $manifest.volumeLabel | Should -Be 'FX_TOOLS'
        $manifest.fileSystem | Should -Be 'FAT32'
        $manifest.verified | Should -BeFalse
        $manifest.flashModel | Should -Be ''
        @($manifest.shared).Count | Should -Be 0
        $manifest.diagnostics | Should -BeNullOrEmpty
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Not -Match 'OrderedDictionary'
        $text | Should -Not -Match ([regex]::Escape($TestDrive))
    }

    It 'describes the staged groups, the model and every file in the manifest' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        @($manifest.groups).Count | Should -Be 2
        $manifest.groups[0].id | Should -Be 'G-New'
        $manifest.groups[0].folder | Should -Be 'Vendor\BIOS\New'
        $manifest.groups[0].closed | Should -BeTrue
        $manifest.groups[0].verified | Should -BeFalse
        @($manifest.models).Count | Should -Be 1
        $model = $manifest.models[0]
        $model.modelId | Should -Be 'm1'
        $model.name | Should -Be 'Fixture m1'
        $model.platformId | Should -Be '0000'
        $model.platformVerified | Should -BeFalse
        $model.biosFamily | Should -Be 'F00'
        $model.latestBios.version | Should -Be '1.00'
        $model.latestBios.date | Should -Be '2026-01-01'
        $model.latestBios.packageId | Should -Be 'fx-F00'
        $model.latestBios.file | Should -Be 'F00_000100.bin'
        $model.windowsFlash.path | Should -Be 'firmware\flash.exe'
        $model.windowsFlash.silentInstall | Should -Be '/s'
        $model.windowsFlash.returnCodes.'0' | Should -Be 'success'
        $model.windowsFlash.returnCodes.'3010' | Should -Be 'reboot needed'
        @($model.files).Count | Should -Be 2
        $file = $model.files[0]
        $file.path | Should -Be 'Vendor\BIOS\New\F00_000100.bin'
        $file.group | Should -Be 'G-New'
        $file.size | Should -Be 32
        $file.sha256 | Should -Match '^[0-9a-f]{64}$'
        $file.vendorHash.algorithm | Should -Be 'SHA384'
        $file.vendorHash.value | Should -Be $script:m1.Entries[0].VendorHash.Value
        $file.vendorHash.source | Should -Be 'catalog'
    }

    It 'writes a JSON null for a model without a Windows flash tool' {
        $stick = New-StickPath
        $plain = New-TestModelResult -Root $script:images -ModelId 'm9' -PlatformId '0009' -Family 'F09'
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($plain) -TargetPath $stick -AllowFolder
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        $manifest.models[0].windowsFlash | Should -BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | Should -Match '"windowsFlash":\s+null'
    }

    It 'writes READY last with the SHA-256 of the manifest and the validator finds no Fail' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        $ready = Join-Path $stick 'READY'
        $ready | Should -Exist
        $expected = (Get-FileHash -LiteralPath (Join-Path $stick 'firmware-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        [string](Get-Content -LiteralPath $ready -TotalCount 1) | Should -BeExactly $expected
        @(Test-FirmwareStage -Path $stick -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'warns once that the layout is not bench-verified and once per model note, and lists the unverified groups' {
        $stick = New-StickPath
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru
        @($result.Findings | Where-Object { $_.Status -eq 'Warn' -and $_.Message -like '*not bench-verified*' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.Status -eq 'Warn' -and $_.Check -eq 'Notes' -and $_.Message -like '*check the dock firmware*' }).Count | Should -Be 1
        @($result.UnverifiedGroup) | Should -Be @('G-New', 'G-Current')
        $result.Verified | Should -BeFalse
    }

    It 'stops with FW-05 when a captured group has no capture path and leaves the target empty' {
        $fixture = Get-KitFirmwareLayout -Path (Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1')
        $stick = New-StickPath
        $one = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00'
        { Publish-FirmwareStage -Layout $fixture -Model @($one) -TargetPath $stick -AllowFolder } | Should -Throw 'FW-05*'
        @(Get-ChildItem -LiteralPath $stick -Force) | Should -BeNullOrEmpty
    }

    It 'returns no READY and keeps the Fail when the validator fails, and removes a READY from an earlier run' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        (Join-Path $stick 'READY') | Should -Exist
        Mock Test-FirmwareStage -ModuleName Kit.Core {
            [pscustomobject]@{ PSTypeName = 'Kit.FirmwareFinding'; Status = 'Fail'; Check = 'Files'; Message = 'forced failure'; Path = 'x'; Group = '' }
        }
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeFalse
        (Join-Path $stick 'READY') | Should -Not -Exist
        @($result.Findings | Where-Object { $_.Status -eq 'Fail' -and $_.Message -eq 'forced failure' }).Count | Should -Be 1
    }

    It 'writes nothing under -WhatIf' {
        $stick = Join-Path $TestDrive ('whatif-' + [guid]::NewGuid().ToString('N'))
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru -WhatIf
        $result.Written | Should -BeFalse
        $result.Ready | Should -BeFalse
        $stick | Should -Not -Exist
        $existing = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $existing -AllowFolder -WhatIf
        @(Get-ChildItem -LiteralPath $existing -Force) | Should -BeNullOrEmpty
    }
}

Describe 'Publish-FirmwareStage merge rule and entry checks' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images-merge'
        $script:layout = Get-KitFirmwareLayout -Path (Write-TestLayout -Path (Join-Path $TestDrive 'merge.layout.psd1'))
        $script:fullFixture = Get-KitFirmwareLayout -Path (Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1')
    }

    It 'stages two models side by side without one overwriting the other' {
        $stick = New-StickPath
        $m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00' -Bytes ([byte[]](1..32))
        $m2 = New-TestModelResult -Root $script:images -ModelId 'm2' -PlatformId '0001' -Family 'F01' -Bytes ([byte[]](33..64))
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($m1, $m2) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        $result.FileCount | Should -Be 4
        foreach ($folder in 'New', 'Current') {
            (Get-FileHash -LiteralPath (Join-Path $stick "Vendor\BIOS\$folder\F00_000100.bin") -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $m1.Entries[0].SourcePath -Algorithm SHA256).Hash
            (Get-FileHash -LiteralPath (Join-Path $stick "Vendor\BIOS\$folder\F01_000100.bin") -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $m2.Entries[0].SourcePath -Algorithm SHA256).Hash
        }
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        @($manifest.models).Count | Should -Be 2
        @($manifest.models[0].files | Where-Object { $_.path -like '*F00_*' }).Count | Should -Be 2
        @($manifest.models[0].files | Where-Object { $_.path -like '*F01_*' }).Count | Should -Be 0
        @($manifest.models[1].files | Where-Object { $_.path -like '*F01_*' }).Count | Should -Be 2
        @($manifest.models[1].files | Where-Object { $_.path -like '*F00_*' }).Count | Should -Be 0
    }

    It 'refuses two models that map one path to different content, names the path and both models, and writes nothing' {
        $stick = New-StickPath
        $a = New-TestModelResult -Root $script:images -ModelId 'c1' -PlatformId '0001' -Family 'F00' -Entry @(@{ Group = 'G-New'; Path = 'Vendor\BIOS\New\SAME.bin'; Bytes = [byte[]](1..8) })
        $b = New-TestModelResult -Root $script:images -ModelId 'c2' -PlatformId '0002' -Family 'F01' -Entry @(@{ Group = 'G-New'; Path = 'Vendor\BIOS\New\same.bin'; Bytes = [byte[]](9..16) })
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($a, $b) -TargetPath $stick -AllowFolder }
        $message | Should -BeLike '*Vendor\BIOS\New\SAME.bin*'
        $message | Should -BeLike '*c1*'
        $message | Should -BeLike '*c2*'
        @(Get-ChildItem -LiteralPath $stick -Force) | Should -BeNullOrEmpty
    }

    It 'copies a path with identical content once and lists it under both models' {
        $stick = New-StickPath
        $entry = @(@{ Group = 'G-New'; Path = 'Vendor\BIOS\New\SHARED.bin'; Bytes = [byte[]](1..8) })
        $a = New-TestModelResult -Root $script:images -ModelId 's1' -PlatformId '0001' -Family 'F00' -Entry $entry
        $b = New-TestModelResult -Root $script:images -ModelId 's2' -PlatformId '0002' -Family 'F01' -Entry $entry
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($a, $b) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        $result.FileCount | Should -Be 1
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        @($manifest.models[0].files).Count | Should -Be 1
        @($manifest.models[1].files).Count | Should -Be 1
    }

    It 'refuses a repeated or mixed-vendor model list before writing' {
        $stick = New-StickPath
        $a = New-TestModelResult -Root $script:images -ModelId 'r1' -PlatformId '0001' -Family 'F00'
        $b = New-TestModelResult -Root $script:images -ModelId 'R1' -PlatformId '0002' -Family 'F01'
        $c = New-TestModelResult -Root $script:images -ModelId 'r3' -PlatformId '0003' -Family 'F02' -Vendor 'Other'
        { Publish-FirmwareStage -Layout $script:layout -Model @($a, $b) -TargetPath $stick -AllowFolder } | Should -Throw '*appears twice*'
        { Publish-FirmwareStage -Layout $script:layout -Model @($a, $c) -TargetPath $stick -AllowFolder } | Should -Throw '*one vendor*'
        @(Get-ChildItem -LiteralPath $stick -Force) | Should -BeNullOrEmpty
    }

    It 'refuses <Name> before writing and names the entry' -ForEach @(
        @{ Name = 'a parent segment'; Needle = '..\x.bin'; Mutate = { param($e) $e.RelativePath = '..\x.bin' } }
        @{ Name = 'a rooted path'; Needle = '\Vendor\BIOS\New\F00_000100.bin'; Mutate = { param($e) $e.RelativePath = '\Vendor\BIOS\New\F00_000100.bin' } }
        @{ Name = 'a path with a colon'; Needle = 'F00:000100.bin'; Mutate = { param($e) $e.RelativePath = 'Vendor\BIOS\New\F00:000100.bin' } }
        @{ Name = 'a path outside its group folder'; Needle = 'Vendor\BIOS\Other\F00_000100.bin'; Mutate = { param($e) $e.RelativePath = 'Vendor\BIOS\Other\F00_000100.bin' } }
        @{ Name = 'an unknown group'; Needle = 'G-Nope'; Mutate = { param($e) $e.Group = 'G-Nope' } }
        @{ Name = 'a missing source file'; Needle = 'nowhere.bin'; Mutate = { param($e) $e.SourcePath = 'C:\nowhere\nowhere.bin' } }
        @{ Name = 'a source whose SHA-256 differs from the vendor result'; Needle = 'SHA-256'; Mutate = { param($e) $e.Sha256 = ('0' * 64) } }
        @{ Name = 'a source whose vendor hash differs'; Needle = 'SHA384'; Mutate = { param($e) $e.VendorHash.Value = ('0' * 96) } }
        @{ Name = 'a password file name'; Needle = 'HPQPswd1.bin'; Mutate = { param($e) $e.RelativePath = 'Vendor\BIOS\New\HPQPswd1.bin' } }
        @{ Name = 'password.bin'; Needle = 'PASSWORD.BIN'; Mutate = { param($e) $e.RelativePath = 'Vendor\BIOS\New\PASSWORD.BIN' } }
    ) {
        $stick = New-StickPath
        $model = New-TestModelResult -Root $script:images -ModelId 'bad' -PlatformId '0001' -Family 'F00'
        & $Mutate $model.Entries[0]
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($model) -TargetPath $stick -AllowFolder }
        $message | Should -BeLike "*$Needle*"
        @(Get-ChildItem -LiteralPath $stick -Force) | Should -BeNullOrEmpty
    }

    It 'refuses an entry that names a captured group' {
        $stick = New-StickPath
        $model = New-TestModelResult -Root $script:images -ModelId 'cap' -PlatformId '0001' -Family 'F00' -Entry @(@{ Group = 'G-Diag'; Path = 'EFI\FX\a.efi'; Bytes = [byte[]](1..8) })
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:fullFixture -Model @($model) -TargetPath $stick -AllowFolder -CapturePath @{ 'fx-diag' = $TestDrive } }
        $message | Should -BeLike '*EFI\FX\a.efi*'
        $message | Should -BeLike '*captured*'
        @(Get-ChildItem -LiteralPath $stick -Force) | Should -BeNullOrEmpty
    }
}

Describe 'Publish-FirmwareStage group selection and -FlashModel' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images-select'
        $script:fx = Get-KitFirmwareLayout -Path (Join-Path $PSScriptRoot 'fixtures\firmware\fixture.layout.psd1')
        $script:fx.Groups = @($script:fx.Groups | Where-Object { $_.Id -ne 'G-Diag' })
        $script:bytes1 = [byte[]](1..32)
        $script:bytes2 = [byte[]](33..64)
        $script:m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00' -Entry @(
            @{ Group = 'G-New'; Path = 'Vendor\BIOS\New\F00_000100.bin'; Bytes = $script:bytes1 }
            @{ Group = 'G-Current'; Path = 'Vendor\BIOS\Current\F00_000100.bin'; Bytes = $script:bytes1 }
            @{ Group = 'G-Dev'; Path = 'FX\DEVFW\firmware.bin'; Bytes = $script:bytes1 })
        $script:m2 = New-TestModelResult -Root $script:images -ModelId 'm2' -PlatformId '0001' -Family 'F01' -Entry @(
            @{ Group = 'G-New'; Path = 'Vendor\BIOS\New\F01_000100.bin'; Bytes = $script:bytes2 }
            @{ Group = 'G-Current'; Path = 'Vendor\BIOS\Current\F01_000100.bin'; Bytes = $script:bytes2 }
            @{ Group = 'G-Dev'; Path = 'FX\DEVFW\firmware.bin'; Bytes = $script:bytes2 })
    }

    It 'stages default groups only when -FlashModel is absent' {
        $stick = New-StickPath
        $result = Publish-FirmwareStage -Layout $script:fx -Model @($script:m1, $script:m2) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        $result.FileCount | Should -Be 4
        (Join-Path $stick 'FX\DEVFW') | Should -Not -Exist
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        @($manifest.groups | ForEach-Object { $_.id }) | Should -Not -Contain 'G-Dev'
        $manifest.flashModel | Should -Be ''
    }

    It 'stages the non-default group of exactly one model with -FlashModel' {
        $stick = New-StickPath
        $result = Publish-FirmwareStage -Layout $script:fx -Model @($script:m1, $script:m2) -TargetPath $stick -AllowFolder -FlashModel 'm1' -PassThru
        $result.Ready | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $stick 'FX\DEVFW\firmware.bin') -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $script:m1.Entries[0].SourcePath -Algorithm SHA256).Hash
        (Join-Path $stick 'Vendor\BIOS\New\F01_000100.bin') | Should -Not -Exist
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        $manifest.flashModel | Should -Be 'm1'
        @($manifest.models).Count | Should -Be 1
        $manifest.models[0].modelId | Should -Be 'm1'
        @($manifest.groups | ForEach-Object { $_.id }) | Should -Contain 'G-Dev'
    }

    It 'throws for an unknown -FlashModel and lists the available ids' {
        $stick = New-StickPath
        { Publish-FirmwareStage -Layout $script:fx -Model @($script:m1, $script:m2) -TargetPath $stick -AllowFolder -FlashModel 'nope' } | Should -Throw '*nope*m1, m2*'
        @(Get-ChildItem -LiteralPath $stick -Force) | Should -BeNullOrEmpty
    }

    It 'accepts a {Platform} folder with the model platform id, keeps the token in the manifest and refuses another platform' {
        $stick = New-StickPath
        $good = New-TestModelResult -Root $script:images -ModelId 'w1' -PlatformId '0000' -Family 'F00' -Entry @(@{ Group = 'G-Win'; Path = 'firmware\fx\0000\flash.exe'; Bytes = [byte[]](1..16) })
        $result = Publish-FirmwareStage -Layout $script:fx -Model @($good) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        (Join-Path $stick 'firmware\fx\0000\flash.exe') | Should -Exist
        $manifest = [IO.File]::ReadAllText((Join-Path $stick 'firmware-manifest.json')) | ConvertFrom-Json
        ($manifest.groups | Where-Object { $_.id -eq 'G-Win' }).folder | Should -Be 'firmware\fx\{Platform}'

        $other = New-StickPath
        $bad = New-TestModelResult -Root $script:images -ModelId 'w2' -PlatformId '0000' -Family 'F00' -Entry @(@{ Group = 'G-Win'; Path = 'firmware\fx\9999\flash.exe'; Bytes = [byte[]](1..16) })
        { Publish-FirmwareStage -Layout $script:fx -Model @($bad) -TargetPath $other -AllowFolder } | Should -Throw '*outside its group folder*'
        @(Get-ChildItem -LiteralPath $other -Force) | Should -BeNullOrEmpty
    }
}

Describe 'Publish-FirmwareStage re-runs and stale files' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images-rerun'
        $script:layout = Get-KitFirmwareLayout -Path (Write-TestLayout -Path (Join-Path $TestDrive 'rerun.layout.psd1'))
        $script:m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00'
    }

    It 'leaves an already correct staged file alone on a second run' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        $old = [datetime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
        $files = @('Vendor\BIOS\New\F00_000100.bin', 'Vendor\BIOS\Current\F00_000100.bin' | ForEach-Object { Join-Path $stick $_ })
        foreach ($file in $files) { (Get-Item -LiteralPath $file).LastWriteTimeUtc = $old }
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        foreach ($file in $files) { (Get-Item -LiteralPath $file).LastWriteTimeUtc | Should -Be $old }
        @(Test-FirmwareStage -Path $stick -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'repairs a staged file whose content changed' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        $file = Join-Path $stick 'Vendor\BIOS\New\F00_000100.bin'
        [IO.File]::WriteAllBytes($file, [byte[]](9, 9, 9))
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $script:m1.Entries[0].SourcePath -Algorithm SHA256).Hash
    }

    It 'fails on a stale file in a closed folder and removes it only with -RemoveStale' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        $stale = Join-Path $stick 'Vendor\BIOS\New\old.bin'
        $outside = Join-Path $stick 'Other\keep.txt'
        [IO.File]::WriteAllBytes($stale, [byte[]](1, 2, 3))
        $null = New-Item -Path (Split-Path -Path $outside -Parent) -ItemType Directory
        [IO.File]::WriteAllBytes($outside, [byte[]](4, 5, 6))

        $blocked = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -PassThru
        $blocked.Ready | Should -BeFalse
        (Join-Path $stick 'READY') | Should -Not -Exist
        @($blocked.Findings | Where-Object { $_.Status -eq 'Fail' -and $_.Path -eq 'Vendor\BIOS\New\old.bin' }).Count | Should -Be 1
        $stale | Should -Exist

        $cleaned = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -RemoveStale -PassThru
        $cleaned.Ready | Should -BeTrue
        $stale | Should -Not -Exist
        $outside | Should -Exist
        @($cleaned.Findings | Where-Object { $_.Status -eq 'Warn' -and $_.Check -eq 'Folders' -and $_.Path -eq 'Vendor\BIOS\New\old.bin' }).Count | Should -Be 1
    }
}

Describe 'Publish-FirmwareStage target volume and label' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images-volume'
        $script:layout = Get-KitFirmwareLayout -Path (Write-TestLayout -Path (Join-Path $TestDrive 'volume.layout.psd1'))
        $script:m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00'
    }

    BeforeEach {
        $script:stick = New-StickPath
        $script:volRoot = $script:stick + '\'
        $script:volFs = 'FAT32'
        $script:volLabel = 'FX_TOOLS'
        Mock Get-KitVolumeInfo -ModuleName Kit.Core { [pscustomobject]@{ Root = $script:volRoot; FileSystem = $script:volFs; Label = $script:volLabel; IsRemovable = $true } }
        Mock Set-KitVolumeLabel -ModuleName Kit.Core { $script:volLabel = $Label; $true }
        Mock Clear-KitVolumeCache -ModuleName Kit.Core { $true }
    }

    It 'refuses an NTFS volume by name and writes nothing' {
        $script:volFs = 'NTFS'
        $message = Get-ThrownMessage -Script { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick }
        $message | Should -BeLike "*$($script:stick)*"
        $message | Should -BeLike '*FAT32*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'refuses a path that is not a volume root' {
        $script:volRoot = 'E:\'
        { Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick } | Should -Throw '*root*'
        @(Get-ChildItem -LiteralPath $script:stick -Force) | Should -BeNullOrEmpty
    }

    It 'sets the volume label once when it differs and reports a ready stick' {
        $script:volLabel = 'OTHER'
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -PassThru
        $result.Ready | Should -BeTrue
        Should -Invoke Set-KitVolumeLabel -ModuleName Kit.Core -Times 1 -Exactly -ParameterFilter { $Label -eq 'FX_TOOLS' }
        Should -Invoke Clear-KitVolumeCache -ModuleName Kit.Core -Times 1 -Exactly
    }

    It 'leaves the volume label alone when it already matches' {
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -PassThru
        $result.Ready | Should -BeTrue
        Should -Invoke Set-KitVolumeLabel -ModuleName Kit.Core -Times 0 -Exactly
    }

    It 'warns and withholds READY when the label cannot be set' {
        $script:volLabel = 'OTHER'
        Mock Set-KitVolumeLabel -ModuleName Kit.Core { $false }
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -PassThru
        $result.Ready | Should -BeFalse
        (Join-Path $script:stick 'READY') | Should -Not -Exist
        @($result.Findings | Where-Object { $_.Status -eq 'Warn' -and $_.Check -eq 'Volume' -and $_.Message -like '*label*' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.Status -eq 'Fail' -and $_.Message -like '*OTHER*' }).Count | Should -Be 1
    }

    It 'warns but stays ready when the volume cache cannot be flushed' {
        Mock Clear-KitVolumeCache -ModuleName Kit.Core { $false }
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $script:stick -PassThru
        $result.Ready | Should -BeTrue
        @($result.Findings | Where-Object { $_.Status -eq 'Warn' -and $_.Message -like '*flush*' }).Count | Should -Be 1
    }

    It 'never asks the drive about a plain folder' {
        $folder = Join-Path $TestDrive ('plain-' + [guid]::NewGuid().ToString('N'))
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $folder -AllowFolder -PassThru
        $result.Ready | Should -BeTrue
        Should -Invoke Get-KitVolumeInfo -ModuleName Kit.Core -Times 0 -Exactly
        Should -Invoke Set-KitVolumeLabel -ModuleName Kit.Core -Times 0 -Exactly
        Should -Invoke Clear-KitVolumeCache -ModuleName Kit.Core -Times 0 -Exactly
    }
}

Describe 'Publish-FirmwareStage -IncludeKit' {
    BeforeAll {
        $script:images = Join-Path $TestDrive 'images-kit'
        $script:layout = Get-KitFirmwareLayout -Path (Write-TestLayout -Path (Join-Path $TestDrive 'kit.layout.psd1'))
        $script:m1 = New-TestModelResult -Root $script:images -ModelId 'm1' -PlatformId '0000' -Family 'F00'
        $script:kit = Join-Path $TestDrive 'fakekit'
        foreach ($relative in 'Run.cmd', 'core\a.ps1', 'config.example.psd1', 'config.local.psd1', 'results\x.txt') {
            $path = Join-Path $script:kit $relative
            $null = New-Item -Path (Split-Path -Path $path -Parent) -ItemType Directory -Force
            [IO.File]::WriteAllText($path, 'x', [Text.Encoding]::ASCII)
        }
    }

    It 'copies the publishable kit files next to the vendor trees and nothing private' {
        $stick = New-StickPath
        $result = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder -IncludeKit -KitRoot $script:kit -PassThru
        $result.Ready | Should -BeTrue
        (Join-Path $stick 'kit\Run.cmd') | Should -Exist
        (Join-Path $stick 'kit\core\a.ps1') | Should -Exist
        (Join-Path $stick 'kit\config.example.psd1') | Should -Exist
        (Join-Path $stick 'kit\config.local.psd1') | Should -Not -Exist
        (Join-Path $stick 'kit\results\x.txt') | Should -Not -Exist
    }

    It 'copies no kit without the switch' {
        $stick = New-StickPath
        $null = Publish-FirmwareStage -Layout $script:layout -Model @($script:m1) -TargetPath $stick -AllowFolder
        (Join-Path $stick 'kit') | Should -Not -Exist
    }
}

Describe 'Firmware stage code never runs a file or formats a volume' {
    It 'calls none of the forbidden commands in <Name>' -ForEach $script:astFile {
        $path = Join-Path $script:corePath $Name
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $called = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        $forbidden = 'Start-Process', 'Invoke-Expression', 'Invoke-Item', 'Invoke-Command', 'Invoke-KitTool', 'Format-Volume'
        @($called | Where-Object { $forbidden -contains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'Kit.Core exports (publish)' {
    It 'exports Publish-FirmwareStage right after Show-FirmwareStageFinding' {
        $names = @((Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport)
        $names.IndexOf('Publish-FirmwareStage') | Should -Be ($names.IndexOf('Show-FirmwareStageFinding') + 1)
        (Get-Module -Name Kit.Core).ExportedFunctions.Keys | Should -Contain 'Publish-FirmwareStage'
    }
}
