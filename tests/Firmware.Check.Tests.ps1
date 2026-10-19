BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    Import-Module (Join-Path $script:corePath 'Kit.Core.psd1') -Force

    # Hand-built Tools stick, independent of any writer. Each -Record is @{ Path; Bytes; Model; Group; VendorAlgorithm }:
    # Path is relative to the stick, Bytes the file content, Model the owning model id ('shared' for a shared file),
    # Group the group id, VendorAlgorithm an optional SHA256/SHA384/SHA512 name for a vendor hash. Returns the manifest path.
    function New-TestStick {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][hashtable[]]$Record,
            [hashtable[]]$Group,
            [hashtable[]]$Model,
            [string]$VolumeLabel = 'FX_TOOLS',
            [switch]$Verified,
            [switch]$NoReady
        )
        if (-not $PSCmdlet.ShouldProcess($Root, 'Write a test stick')) { return }
        $null = New-Item -Path $Root -ItemType Directory -Force

        if (-not $Group) {
            $Group = @(foreach ($id in ($Record | ForEach-Object { $_.Group } | Select-Object -Unique)) {
                    $first = $Record | Where-Object { $_.Group -eq $id } | Select-Object -First 1
                    @{ Id = $id; Folder = (Split-Path -Path $first.Path -Parent); Closed = $true; Verified = [bool]$Verified }
                })
        }
        if (-not $Model) {
            $number = 0
            $Model = @(foreach ($id in ($Record | Where-Object { $_.Model -ne 'shared' } | ForEach-Object { $_.Model } | Select-Object -Unique)) {
                    $number++
                    @{ ModelId = $id; PlatformId = ('{0:D4}' -f $number); PlatformVerified = $true; DependencyMinimum = '' }
                })
        }

        $built = @{}
        foreach ($item in $Record) {
            $target = Join-Path -Path $Root -ChildPath $item.Path
            $null = New-Item -Path (Split-Path -Path $target -Parent) -ItemType Directory -Force
            [IO.File]::WriteAllBytes($target, [byte[]]$item.Bytes)
            $vendorHash = $null
            if ($item.VendorAlgorithm) {
                $vendorHash = [ordered]@{
                    algorithm = $item.VendorAlgorithm
                    value     = (Get-FileHash -LiteralPath $target -Algorithm $item.VendorAlgorithm).Hash.ToLowerInvariant()
                    source    = 'catalog'
                }
            }
            $built[$item.Path] = [ordered]@{
                path       = $item.Path
                group      = $item.Group
                size       = ([long]([byte[]]$item.Bytes).Length)
                sha256     = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                vendorHash = $vendorHash
            }
        }

        $models = @(foreach ($entry in $Model) {
                $files = @($Record | Where-Object { $_.Model -eq $entry.ModelId } | ForEach-Object { $built[$_.Path] })
                [ordered]@{
                    modelId          = $entry.ModelId
                    name             = "Fixture $($entry.ModelId)"
                    platformId       = $entry.PlatformId
                    platformVerified = [bool]$entry.PlatformVerified
                    biosFamily       = 'FX1'
                    latestBios       = [ordered]@{ version = '1.00'; date = '2026-01-01'; packageId = 'fx1'; file = 'a.bin'; dependencyMinimum = [string]$entry.DependencyMinimum }
                    windowsFlash     = $null
                    files            = $files
                }
            })
        $shared = @($Record | Where-Object { $_.Model -eq 'shared' } | ForEach-Object { $built[$_.Path] })
        $groups = @(foreach ($entry in $Group) {
                [ordered]@{ id = $entry.Id; folder = $entry.Folder; closed = [bool]$entry.Closed; verified = [bool]$entry.Verified }
            })

        $manifest = [ordered]@{
            schemaVersion = 1
            toolVersion   = '0.1.0'
            builtUtc      = '2026-10-20T09:00:00Z'
            vendor        = 'Fixture'
            volumeLabel   = $VolumeLabel
            fileSystem    = 'FAT32'
            verified      = [bool]$Verified
            flashModel    = ''
            groups        = $groups
            models        = $models
            shared        = $shared
            diagnostics   = $null
        }
        $manifestPath = Join-Path -Path $Root -ChildPath 'firmware-manifest.json'
        $json = ConvertTo-Json -InputObject $manifest -Depth 6
        [IO.File]::WriteAllText($manifestPath, $json, [Text.UTF8Encoding]::new($false))
        if (-not $NoReady) {
            $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath 'READY'), "$hash`r`n", [Text.Encoding]::ASCII)
        }
        $manifestPath
    }

    # Two files in the closed group G-New for model m1; the image carries a SHA-384 vendor hash.
    function New-TracerStick {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root)
        if (-not $PSCmdlet.ShouldProcess($Root, 'Write the tracer stick')) { return }
        $null = New-TestStick -Root $Root -Record @(
            @{ Path = 'Vendor\BIOS\New\R70_013600.bin'; Bytes = [byte[]](1..64); Model = 'm1'; Group = 'G-New'; VendorAlgorithm = 'SHA384' }
            @{ Path = 'Vendor\BIOS\New\info.txt'; Bytes = [byte[]](70..90); Model = 'm1'; Group = 'G-New' }
        )
        $Root
    }
}

Describe 'Test-FirmwareStage tracer' {
    BeforeEach {
        $script:stick = New-TracerStick -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:image = Join-Path $script:stick 'Vendor\BIOS\New\R70_013600.bin'
    }

    It 'returns typed findings and no Fail for a good stick' {
        $findings = @(Test-FirmwareStage -Path $script:stick)
        @($findings | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
        @($findings | Where-Object Status -EQ 'Pass').Count | Should -BeGreaterThan 0
        foreach ($finding in $findings) {
            $finding.PSObject.TypeNames | Should -Contain 'Kit.FirmwareFinding'
            $finding.Status | Should -BeIn 'Pass', 'Warn', 'Fail'
        }
    }

    It 'fails once with the manifest path when a byte is appended' {
        $stream = [IO.File]::Open($script:image, [IO.FileMode]::Append)
        try { $stream.WriteByte(7) } finally { $stream.Dispose() }
        $fails = @(Test-FirmwareStage -Path $script:stick | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
        $fails[0].Message | Should -BeLike '*size differs*'
    }

    It 'fails once on a same-length content change' {
        [IO.File]::WriteAllBytes($script:image, [byte[]](101..164))
        $fails = @(Test-FirmwareStage -Path $script:stick | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
        $fails[0].Message | Should -BeLike '*SHA-256 differs*'
    }

    It 'fails with missing and the manifest path when a file is deleted' {
        Remove-Item -LiteralPath $script:image
        $fails = @(Test-FirmwareStage -Path $script:stick | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -Be 'missing'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
    }

    It 'fails when the vendor hash no longer matches and names the algorithm' {
        $manifestPath = Join-Path $script:stick 'firmware-manifest.json'
        $text = [IO.File]::ReadAllText($manifestPath)
        $manifest = $text | ConvertFrom-Json
        $value = $manifest.models[0].files[0].vendorHash.value
        $edited = $text.Replace($value, ('0' * $value.Length))
        [IO.File]::WriteAllText($manifestPath, $edited, [Text.UTF8Encoding]::new($false))
        $fails = @(Test-FirmwareStage -Path $script:stick | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Hash' })
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*vendor hash differs*SHA384*'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
    }

    It 'returns one Fail and does not throw when there is no manifest' {
        $empty = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $empty -ItemType Directory
        $findings = @(Test-FirmwareStage -Path $empty)
        $findings.Count | Should -Be 1
        $findings[0].Status | Should -Be 'Fail'
        $findings[0].Check | Should -Be 'Manifest'
        $findings[0].Message | Should -BeLike '*firmware-manifest.json not found*'
    }

    It 'returns one Fail for a manifest that is not JSON' {
        Set-Content -LiteralPath (Join-Path $script:stick 'firmware-manifest.json') -Value 'not json {'
        $findings = @(Test-FirmwareStage -Path $script:stick)
        $findings.Count | Should -Be 1
        $findings[0].Status | Should -Be 'Fail'
        $findings[0].Message | Should -BeLike '*not valid JSON*'
    }

    It 'returns one Fail for schemaVersion 2' {
        $manifestPath = Join-Path $script:stick 'firmware-manifest.json'
        $text = [IO.File]::ReadAllText($manifestPath) -replace '"schemaVersion":\s*1', '"schemaVersion": 2'
        [IO.File]::WriteAllText($manifestPath, $text, [Text.UTF8Encoding]::new($false))
        $findings = @(Test-FirmwareStage -Path $script:stick)
        $findings.Count | Should -Be 1
        $findings[0].Status | Should -Be 'Fail'
        $findings[0].Message | Should -BeLike '*schemaVersion*'
    }
}

Describe 'Show-FirmwareStageFinding' {
    BeforeEach {
        Mock Write-Host -ModuleName Kit.Core {}
    }

    It 'writes a <Status> finding once in <Color> with the <Prefix> prefix' -ForEach @(
        @{ Status = 'Fail'; Color = 'Red'; Prefix = '[FAIL]' }
        @{ Status = 'Warn'; Color = 'Yellow'; Prefix = '[WARN]' }
        @{ Status = 'Pass'; Color = 'Green'; Prefix = '[PASS]' }
    ) {
        $finding = [pscustomobject]@{ PSTypeName = 'Kit.FirmwareFinding'; Status = $Status; Check = 'Files'; Message = 'something'; Path = ''; Group = '' }
        Show-FirmwareStageFinding -Finding @($finding)
        Should -Invoke Write-Host -ModuleName Kit.Core -Times 1 -Exactly
        Should -Invoke Write-Host -ModuleName Kit.Core -Times 1 -Exactly -ParameterFilter {
            $ForegroundColor -eq $Color -and $Object.StartsWith($Prefix)
        }
    }
}

Describe 'Kit.Core exports' {
    It 'exports <Name>' -ForEach @(
        @{ Name = 'Test-FirmwareStage' }
        @{ Name = 'Show-FirmwareStageFinding' }
    ) {
        (Get-Module -Name Kit.Core).ExportedFunctions.Keys | Should -Contain $Name
    }
}
