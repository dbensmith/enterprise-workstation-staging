BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    $script:coreManifest = Join-Path $script:corePath 'Kit.Core.psd1'
    Import-Module $script:coreManifest -Force

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

Describe 'Kit.Core exports (publish)' {
    It 'exports Publish-FirmwareStage right after Show-FirmwareStageFinding' {
        $names = @((Import-PowerShellDataFile -Path $script:coreManifest).FunctionsToExport)
        $names.IndexOf('Publish-FirmwareStage') | Should -Be ($names.IndexOf('Show-FirmwareStageFinding') + 1)
        (Get-Module -Name Kit.Core).ExportedFunctions.Keys | Should -Contain 'Publish-FirmwareStage'
    }
}
