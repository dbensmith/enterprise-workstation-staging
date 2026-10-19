BeforeAll {
    $script:corePath = (Join-Path $PSScriptRoot '..\kit\core')
    Import-Module (Join-Path $script:corePath 'Kit.Core.psd1') -Force

    # Hand-built Tools stick, independent of any writer. Each -Record is @{ Path; Bytes; Model; Group; VendorAlgorithm }:
    # Path is relative to the stick, Bytes the file content, Model the owning model id ('shared' for a shared file),
    # Group the group id, VendorAlgorithm an optional SHA256/SHA384/SHA512 name for a vendor hash. -Group is a list of
    # @{ Id; Folder; Closed; Verified } and -Model a list of @{ ModelId; PlatformId; PlatformVerified; DependencyMinimum }.
    # Returns the manifest path. READY is written last unless -NoReady is given.
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

        $built = foreach ($item in $Record) {
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
            [pscustomobject]@{
                Model  = $item.Model
                Object = [ordered]@{
                    path       = $item.Path
                    group      = $item.Group
                    size       = ([long]([byte[]]$item.Bytes).Length)
                    sha256     = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                    vendorHash = $vendorHash
                }
            }
        }

        $models = @(foreach ($entry in $Model) {
                $files = @($built | Where-Object { $_.Model -eq $entry.ModelId } | ForEach-Object { $_.Object })
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
        $shared = @($built | Where-Object { $_.Model -eq 'shared' } | ForEach-Object { $_.Object })
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

    # Parse the stick's manifest, let the script block change it, write it back and re-seal READY so that only the change shows.
    function Edit-TestManifest {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][scriptblock]$Edit
        )
        $manifestPath = Join-Path -Path $Root -ChildPath 'firmware-manifest.json'
        $parsed = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        & $Edit $parsed
        [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $parsed -Depth 6), [Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path -Path $Root -ChildPath 'READY'), "$hash`r`n", [Text.Encoding]::ASCII)
    }

    # Script block for a Get-KitVolumeInfo mock: the volume that holds the stick. Mocks run in module scope, so the values are baked in.
    function Get-VolumeScript {
        [CmdletBinding()]
        [OutputType([scriptblock])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [string]$FileSystem = 'FAT32',
            [string]$Label = 'FX_TOOLS',
            [bool]$Removable = $true
        )
        [scriptblock]::Create("[pscustomobject]@{ Root = '$Root\'; FileSystem = '$FileSystem'; Label = '$Label'; IsRemovable = `$$Removable }")
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

    # The two closed sibling folders of the 2026-10-05 incident, each holding one image.
    function New-IncidentStick {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root)
        if (-not $PSCmdlet.ShouldProcess($Root, 'Write the incident stick')) { return }
        $null = New-TestStick -Root $Root -Record @(
            @{ Path = 'Vendor\BIOS\New\R70_013600.bin'; Bytes = [byte[]](1..64); Model = 'm1'; Group = 'G-New' }
            @{ Path = 'Vendor\BIOS\Current\R70_013500.bin'; Bytes = [byte[]](2..65); Model = 'm1'; Group = 'G-Current' }
        ) -Group @(
            @{ Id = 'G-New'; Folder = 'Vendor\BIOS\New'; Closed = $true; Verified = $false }
            @{ Id = 'G-Current'; Folder = 'Vendor\BIOS\Current'; Closed = $true; Verified = $false }
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
        $findings = @(Test-FirmwareStage -Path $script:stick -AllowFolder)
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
        $fails = @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
        $fails[0].Message | Should -BeLike '*size differs*'
    }

    It 'fails once on a same-length content change' {
        [IO.File]::WriteAllBytes($script:image, [byte[]](101..164))
        $fails = @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
        $fails[0].Message | Should -BeLike '*SHA-256 differs*'
    }

    It 'fails with missing and the manifest path when a file is deleted' {
        Remove-Item -LiteralPath $script:image
        $fails = @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -Be 'missing'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
    }

    It 'fails when the vendor hash no longer matches and names the algorithm' {
        Edit-TestManifest -Root $script:stick -Edit { param($m) $m.models[0].files[0].vendorHash.value = ('0' * 96) }
        $fails = @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Hash' })
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*vendor hash differs*SHA384*'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
    }

    It 'returns one Fail and does not throw when there is no manifest' {
        $empty = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $empty -ItemType Directory
        $fails = @(Test-FirmwareStage -Path $empty -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Check | Should -Be 'Manifest'
        $fails[0].Message | Should -BeLike '*firmware-manifest.json not found*'
    }

    It 'returns one Fail for a manifest that is not JSON' {
        Set-Content -LiteralPath (Join-Path $script:stick 'firmware-manifest.json') -Value 'not json {'
        $fails = @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*not valid JSON*'
    }

    It 'returns one Fail for schemaVersion 2' {
        Edit-TestManifest -Root $script:stick -Edit { param($m) $m.schemaVersion = 2 }
        $fails = @(Test-FirmwareStage -Path $script:stick -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*schemaVersion*'
    }
}

Describe 'Get-KitStagePathProblem' {
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a drive path'; Relative = 'C:\x.bin' }
        @{ Name = 'a rooted path'; Relative = '\x.bin' }
        @{ Name = 'a parent segment'; Relative = 'a\..\b.bin' }
        @{ Name = 'a current-folder segment'; Relative = 'a\.\b.bin' }
        @{ Name = 'an empty segment'; Relative = 'a\\b.bin' }
        @{ Name = 'a forward slash'; Relative = 'a/b.bin' }
        @{ Name = 'a question mark'; Relative = 'a\b?.bin' }
        @{ Name = 'a colon'; Relative = 'a\b:c.bin' }
        @{ Name = 'a trailing space'; Relative = 'a\b .bin ' }
        @{ Name = 'a trailing dot'; Relative = 'a\b.' }
        @{ Name = 'a reserved device name with extension'; Relative = 'a\CON.bin' }
        @{ Name = 'a reserved device name in lower case'; Relative = 'a\com1' }
        @{ Name = 'a bare reserved device name'; Relative = 'NUL' }
        @{ Name = 'a 256-character segment'; Relative = ('a\' + ('b' * 256)) }
        @{ Name = 'a path over 259 characters with a drive prefix'; Relative = (('seg\' * 70) + 'f.bin') }
    ) {
        InModuleScope Kit.Core -Parameters @{ Relative = $Relative } {
            @(Get-KitStagePathProblem -RelativePath $Relative).Count | Should -BeGreaterThan 0
        }
    }

    It 'accepts an ordinary firmware path' {
        InModuleScope Kit.Core {
            @(Get-KitStagePathProblem -RelativePath 'Vendor\BIOS\New\R70_013600.bin').Count | Should -Be 0
        }
    }

    It 'rejects a size over 4294967295 and accepts 4294967295' {
        InModuleScope Kit.Core {
            @(Get-KitStagePathProblem -RelativePath 'a\b.bin' -Size 4294967296).Count | Should -BeGreaterThan 0
            @(Get-KitStagePathProblem -RelativePath 'a\b.bin' -Size 4294967295).Count | Should -Be 0
        }
    }
}

Describe 'Get-KitClosedFolder' {
    It 'expands the platform token once per model that has files in the group and skips open groups' {
        InModuleScope Kit.Core {
            $manifest = [pscustomobject]@{
                groups = @(
                    [pscustomobject]@{ id = 'G-Plain'; folder = 'Vendor\BIOS\New'; closed = $true }
                    [pscustomobject]@{ id = 'G-Win'; folder = 'firmware\fx\{Platform}'; closed = $true }
                    [pscustomobject]@{ id = 'G-Open'; folder = 'EFI\FX'; closed = $false }
                )
                models = @(
                    [pscustomobject]@{ modelId = 'm1'; platformId = '8549'; files = @(
                            [pscustomobject]@{ path = 'Vendor\BIOS\New\a.bin'; group = 'G-Plain' }
                            [pscustomobject]@{ path = 'firmware\fx\8549\a.txt'; group = 'G-Win' }) }
                    [pscustomobject]@{ modelId = 'm2'; platformId = '83B2'; files = @(
                            [pscustomobject]@{ path = 'firmware\fx\83B2\b.txt'; group = 'G-Win' }) }
                    [pscustomobject]@{ modelId = 'm3'; platformId = '9999'; files = @(
                            [pscustomobject]@{ path = 'EFI\FX\c.efi'; group = 'G-Open' }) }
                )
            }
            @(Get-KitClosedFolder -Manifest $manifest) | Should -Be @('Vendor\BIOS\New', 'firmware\fx\8549', 'firmware\fx\83B2')
        }
    }
}

Describe 'Test-FirmwareStage name rules and duplicates' {
    BeforeEach {
        $script:root = New-IncidentStick -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }

    It 'fails a record whose path cannot exist on FAT32 and names it' {
        Edit-TestManifest -Root $script:root -Edit { param($m) $m.models[0].files[0].path = 'Vendor\BIOS\New\a?b.bin' }
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Names' })
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*not valid on FAT32*'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\a?b.bin'
    }

    It 'fails two records whose paths differ only in case and names both' {
        Edit-TestManifest -Root $script:root -Edit {
            param($m)
            $copy = $m.models[0].files[0].PSObject.Copy()
            $copy.path = $copy.path.ToUpperInvariant()
            $m.models[0].files = @($m.models[0].files) + $copy
        }
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Names' })
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'VENDOR\BIOS\NEW\R70_013600.BIN'
        $fails[0].Message | Should -BeLike '*Vendor\BIOS\New\R70_013600.bin*'
    }

    It 'fails a size over the FAT32 limit' {
        Edit-TestManifest -Root $script:root -Edit { param($m) $m.models[0].files[0].size = 4294967296 }
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Names' })
        $fails.Count | Should -Be 1
    }

    It 'fails two models that write different content to one destination and names both' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Root $folder -Record @(
            @{ Path = 'Vendor\BIOS\New\x.bin'; Bytes = [byte[]](1..16); Model = 'm1'; Group = 'G-New' }
            @{ Path = 'Vendor\BIOS\New\x.bin'; Bytes = [byte[]](21..36); Model = 'm2'; Group = 'G-New' }
        )
        $fails = @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Duplicate' })
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\x.bin'
        $fails[0].Message | Should -BeLike '*m1*'
        $fails[0].Message | Should -BeLike '*m2*'
    }

    It 'accepts two models that write identical content to one destination' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Root $folder -Record @(
            @{ Path = 'Vendor\BIOS\New\x.bin'; Bytes = [byte[]](1..16); Model = 'm1'; Group = 'G-New' }
            @{ Path = 'Vendor\BIOS\New\x.bin'; Bytes = [byte[]](1..16); Model = 'm2'; Group = 'G-New' }
        )
        @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'fails a manifest that lacks a required key and names the key' {
        Edit-TestManifest -Root $script:root -Edit { param($m) $m.PSObject.Properties.Remove('groups') }
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike "*'groups'*"
    }
}

Describe 'Test-FirmwareStage folders and root (the 2026-10-05 incident)' {
    BeforeEach {
        $script:root = New-IncidentStick -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:newImage = Join-Path $script:root 'Vendor\BIOS\New\R70_013600.bin'
    }

    It 'passes the correctly staged stick' {
        @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'fails once with the manifest path when the image sits in a folder no group covers' {
        $null = New-Item -Path (Join-Path $script:root 'Vendor\BIOS\Other') -ItemType Directory
        Move-Item -LiteralPath $script:newImage -Destination (Join-Path $script:root 'Vendor\BIOS\Other\R70_013600.bin')
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -Be 'missing'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\R70_013600.bin'
        (Split-Path -Path $fails[0].Path -Leaf) | Should -Be 'R70_013600.bin'
    }

    It 'fails twice when the image sits in the other closed folder: missing there, unexpected here' {
        Move-Item -LiteralPath $script:newImage -Destination (Join-Path $script:root 'Vendor\BIOS\Current\R70_013600.bin')
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 2
        @($fails | Where-Object { $_.Message -eq 'missing' -and $_.Path -ceq 'Vendor\BIOS\New\R70_013600.bin' }).Count | Should -Be 1
        @($fails | Where-Object { $_.Message -like '*unexpected file*' -and $_.Path -ceq 'Vendor\BIOS\Current\R70_013600.bin' }).Count | Should -Be 1
    }

    It 'fails a stray file at any depth inside a closed folder' {
        $null = New-Item -Path (Join-Path $script:root 'Vendor\BIOS\New\deep\er') -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $script:root 'Vendor\BIOS\New\deep\er\x.txt') -Value 'x'
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Check | Should -Be 'Folders'
        $fails[0].Message | Should -BeLike '*unexpected file*'
        $fails[0].Path | Should -BeExactly 'Vendor\BIOS\New\deep\er\x.txt'
    }

    It 'ignores a stray file inside an open folder' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Root $folder -Record @(
            @{ Path = 'EFI\FX\a.efi'; Bytes = [byte[]](1..8); Model = 'shared'; Group = 'G-Diag' }
        ) -Group @(@{ Id = 'G-Diag'; Folder = 'EFI\FX'; Closed = $false; Verified = $false })
        Set-Content -LiteralPath (Join-Path $folder 'EFI\FX\extra.txt') -Value 'x'
        @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'gives no finding for the entries Windows and the kit add at the root' {
        foreach ($name in 'System Volume Information', '$RECYCLE.BIN', 'kit', 'results') {
            $null = New-Item -Path (Join-Path $script:root $name) -ItemType Directory
        }
        @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Check -eq 'Root' -and $_.Status -ne 'Pass' }) | Should -BeNullOrEmpty
    }

    It 'warns once for any other root entry and names it' {
        $null = New-Item -Path (Join-Path $script:root 'Stray') -ItemType Directory
        $warns = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Check -eq 'Root' -and $_.Status -eq 'Warn' })
        $warns.Count | Should -Be 1
        $warns[0].Path | Should -Be 'Stray'
    }

    It 'checks a platform-token folder once per model, with the token replaced' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Root $folder -Record @(
            @{ Path = 'firmware\fx\8549\a.txt'; Bytes = [byte[]](1..8); Model = 'm1'; Group = 'G-Win' }
            @{ Path = 'firmware\fx\83B2\b.txt'; Bytes = [byte[]](9..16); Model = 'm2'; Group = 'G-Win' }
        ) -Group @(@{ Id = 'G-Win'; Folder = 'firmware\fx\{Platform}'; Closed = $true; Verified = $false }) -Model @(
            @{ ModelId = 'm1'; PlatformId = '8549'; PlatformVerified = $true; DependencyMinimum = '' }
            @{ ModelId = 'm2'; PlatformId = '83B2'; PlatformVerified = $true; DependencyMinimum = '' }
        )
        @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $folder 'firmware\fx\83B2\stray.txt') -Value 'x'
        $fails = @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Path | Should -BeExactly 'firmware\fx\83B2\stray.txt'
    }

    It 'fails a password file named <Name> anywhere under the stick' -ForEach @(
        @{ Name = 'HPQPswd1.bin' }
        @{ Name = 'password.bin' }
        @{ Name = 'x-Pswd-y.bin' }
    ) {
        $folder = Join-Path $script:root 'Vendor\BIOS\Other'
        $null = New-Item -Path $folder -ItemType Directory -Force
        [IO.File]::WriteAllBytes((Join-Path $folder $Name), [byte[]](1..4))
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Password' })
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*password file*'
        $fails[0].Path | Should -BeExactly "Vendor\BIOS\Other\$Name"
    }
}

Describe 'Test-FirmwareTarget' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:folder -ItemType Directory
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith (Get-VolumeScript -Root $script:folder)
    }

    It 'passes FAT32 on a removable disk at the volume root' {
        $findings = @(Test-FirmwareTarget -Path $script:folder)
        @($findings | Where-Object Status -NE 'Pass') | Should -BeNullOrEmpty
        $findings.Count | Should -BeGreaterThan 0
    }

    It 'refuses NTFS and names the volume root and both file systems' {
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith (Get-VolumeScript -Root $script:folder -FileSystem 'NTFS')
        $fails = @(Test-FirmwareTarget -Path $script:folder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike "*$($script:folder)*"
        $fails[0].Message | Should -BeLike '*NTFS*'
        $fails[0].Message | Should -BeLike '*FAT32*'
    }

    It 'warns for FAT32 on a disk reported as fixed' {
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith (Get-VolumeScript -Root $script:folder -Removable $false)
        $findings = @(Test-FirmwareTarget -Path $script:folder)
        @($findings | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
        @($findings | Where-Object Status -EQ 'Warn').Count | Should -Be 1
    }

    It 'fails when there is no volume information' {
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith ([scriptblock]::Create('$null'))
        @(Test-FirmwareTarget -Path $script:folder | Where-Object Status -EQ 'Fail').Count | Should -Be 1
    }

    It 'fails a path that is not a volume root' {
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith ([scriptblock]::Create("[pscustomobject]@{ Root = 'E:\'; FileSystem = 'FAT32'; Label = 'FX_TOOLS'; IsRemovable = `$true }"))
        $fails = @(Test-FirmwareTarget -Path $script:folder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*root*'
    }

    It 'fails a path that does not exist' {
        $fails = @(Test-FirmwareTarget -Path (Join-Path $script:folder 'missing') | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
    }

    It 'skips every volume check under -AllowFolder with one Warn' {
        $findings = @(Test-FirmwareTarget -Path $script:folder -AllowFolder)
        $findings.Count | Should -Be 1
        $findings[0].Status | Should -Be 'Warn'
        Should -Invoke Get-KitVolumeInfo -ModuleName Kit.Core -Times 0 -Exactly
    }
}

Describe 'Test-FirmwareStage volume, READY and warnings' {
    BeforeEach {
        $script:root = New-IncidentStick -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith (Get-VolumeScript -Root $script:root)
    }

    It 'passes a complete stick on a matching FAT32 volume' {
        @(Test-FirmwareStage -Path $script:root | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'fails when the volume label differs from the manifest and names both labels' {
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith (Get-VolumeScript -Root $script:root -Label 'OTHER')
        $fails = @(Test-FirmwareStage -Path $script:root | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*OTHER*'
        $fails[0].Message | Should -BeLike '*FX_TOOLS*'
    }

    It 'refuses a non-FAT32 volume through the same target checks' {
        Mock Get-KitVolumeInfo -ModuleName Kit.Core -MockWith (Get-VolumeScript -Root $script:root -FileSystem 'exFAT')
        @(Test-FirmwareStage -Path $script:root | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Volume' }).Count | Should -BeGreaterThan 0
    }

    It 'does not ask for volume information under -AllowFolder' {
        $null = Test-FirmwareStage -Path $script:root -AllowFolder
        Should -Invoke Get-KitVolumeInfo -ModuleName Kit.Core -Times 0 -Exactly
    }

    It 'fails when the READY marker is missing' {
        Remove-Item -LiteralPath (Join-Path $script:root 'READY')
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Check | Should -Be 'Ready'
        $fails[0].Message | Should -BeLike '*READY marker missing*'
    }

    It 'fails when the READY marker does not hold the manifest hash' {
        [IO.File]::WriteAllText((Join-Path $script:root 'READY'), "abc`r`n", [Text.Encoding]::ASCII)
        $fails = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object Status -EQ 'Fail')
        $fails.Count | Should -Be 1
        $fails[0].Message | Should -BeLike '*does not match the manifest*'
    }

    It 'skips the READY check under -IgnoreReadyMarker' {
        Remove-Item -LiteralPath (Join-Path $script:root 'READY')
        @(Test-FirmwareStage -Path $script:root -AllowFolder -IgnoreReadyMarker | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
    }

    It 'warns once that the layout is not bench-verified and counts the folders' {
        $warns = @(Test-FirmwareStage -Path $script:root -AllowFolder | Where-Object { $_.Check -eq 'Layout' -and $_.Status -eq 'Warn' })
        $warns.Count | Should -Be 1
        $warns[0].Message | Should -BeLike '*not bench-verified*'
        $warns[0].Message | Should -BeLike '*FW-06*'
        $warns[0].Message | Should -BeLike '*2*'
    }

    It 'warns for a model whose platform is not verified and names it' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Root $folder -Record @(
            @{ Path = 'Vendor\BIOS\New\a.bin'; Bytes = [byte[]](1..8); Model = 'm1'; Group = 'G-New' }
        ) -Model @(@{ ModelId = 'm1'; PlatformId = '8549'; PlatformVerified = $false; DependencyMinimum = '' })
        $warns = @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object { $_.Check -eq 'Notes' -and $_.Status -eq 'Warn' })
        $warns.Count | Should -Be 1
        $warns[0].Message | Should -BeLike '*m1*'
        $warns[0].Message | Should -BeLike '*8549*'
    }

    It 'warns for a model with a minimum BIOS and names the model, the version and the minimum' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Root $folder -Record @(
            @{ Path = 'Vendor\BIOS\New\a.bin'; Bytes = [byte[]](1..8); Model = 'm1'; Group = 'G-New' }
        ) -Model @(@{ ModelId = 'm1'; PlatformId = '8549'; PlatformVerified = $true; DependencyMinimum = '01.35.02' })
        $warns = @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object { $_.Check -eq 'Notes' -and $_.Status -eq 'Warn' })
        $warns.Count | Should -Be 1
        $warns[0].Message | Should -BeLike '*m1*'
        $warns[0].Message | Should -BeLike '*1.00*'
        $warns[0].Message | Should -BeLike '*01.35.02*'
    }

    It 'returns at most 10 detail findings per check and one and-N-more Fail' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $records = @(foreach ($number in 1..15) {
                @{ Path = ('Vendor\BIOS\New\f{0:D2}.bin' -f $number); Bytes = [byte[]](1..16); Model = 'm1'; Group = 'G-New' }
            })
        $null = New-TestStick -Root $folder -Record $records
        foreach ($number in 1..15) {
            [IO.File]::WriteAllBytes((Join-Path $folder ('Vendor\BIOS\New\f{0:D2}.bin' -f $number)), [byte[]](101..116))
        }
        $fails = @(Test-FirmwareStage -Path $folder -AllowFolder | Where-Object { $_.Status -eq 'Fail' -and $_.Check -eq 'Hash' })
        $fails.Count | Should -Be 11
        @($fails | Where-Object { $_.Message -like '*and 5 more*' }).Count | Should -Be 1
    }
}

Describe 'ConvertTo-KitFirmwareLine' {
    It 'keeps every line within 44 characters, puts the path on its own indented line and keeps the file name' {
        InModuleScope Kit.Core {
            $finding = [pscustomobject]@{ Status = 'Fail'; Check = 'Folders'; Message = 'unexpected file'; Path = 'Hewlett-Packard\BIOS\Current\R70_013600.bin'; Group = '' }
            $lines = @(ConvertTo-KitFirmwareLine -Finding $finding -Width 44)
            foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 44 }
            $lines[0] | Should -Be '[FAIL] unexpected file'
            $lines[1] | Should -BeLike '  *'
            $lines[1] | Should -BeLike '*R70_013600.bin'
        }
    }

    It 'shortens a long path from the left with leading dots' {
        InModuleScope Kit.Core {
            $path = ('dir\' * 19) + 'file.bin'
            $finding = [pscustomobject]@{ Status = 'Warn'; Check = 'Root'; Message = 'x'; Path = $path; Group = '' }
            $lines = @(ConvertTo-KitFirmwareLine -Finding $finding -Width 44)
            $lines[1] | Should -BeLike '  ...*'
            $lines[1] | Should -BeLike '*file.bin'
            $lines[1].Length | Should -BeLessOrEqual 44
        }
    }

    It 'wraps a long message at word boundaries with a 7-character continuation indent' {
        InModuleScope Kit.Core {
            $finding = [pscustomobject]@{ Status = 'Pass'; Check = 'Files'; Message = 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda'; Path = ''; Group = '' }
            $lines = @(ConvertTo-KitFirmwareLine -Finding $finding -Width 44)
            $lines.Count | Should -BeGreaterThan 1
            foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 44 }
            $lines[0] | Should -BeLike '[[]PASS] alpha*'
            foreach ($line in $lines[1..($lines.Count - 1)]) { $line | Should -BeLike '       [a-z]*' }
            (($lines | ForEach-Object { $_.Substring(7) }) -join ' ') | Should -Be $finding.Message
        }
    }

    It 'splits a single word that is longer than the line' {
        InModuleScope Kit.Core {
            $finding = [pscustomobject]@{ Status = 'Fail'; Check = 'Files'; Message = ('x' * 100); Path = ''; Group = '' }
            $lines = @(ConvertTo-KitFirmwareLine -Finding $finding -Width 44)
            foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual 44 }
            (($lines | ForEach-Object { $_.Substring(7) }) -join '').Length | Should -Be 100
        }
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

    It 'writes the path of a finding on a second line in the same colour' {
        $finding = [pscustomobject]@{ PSTypeName = 'Kit.FirmwareFinding'; Status = 'Fail'; Check = 'Files'; Message = 'missing'; Path = 'a\b.bin'; Group = '' }
        Show-FirmwareStageFinding -Finding @($finding)
        Should -Invoke Write-Host -ModuleName Kit.Core -Times 2 -Exactly -ParameterFilter { $ForegroundColor -eq 'Red' }
        Should -Invoke Write-Host -ModuleName Kit.Core -Times 1 -Exactly -ParameterFilter { $Object -eq '  a\b.bin' }
    }

    It 'keeps every written line within the given width' {
        $finding = [pscustomobject]@{ PSTypeName = 'Kit.FirmwareFinding'; Status = 'Fail'; Check = 'Files'; Message = 'alpha beta gamma delta epsilon zeta eta theta'; Path = ('dir\' * 19) + 'file.bin'; Group = '' }
        Show-FirmwareStageFinding -Finding @($finding) -Width 30
        Should -Invoke Write-Host -ModuleName Kit.Core -Times 0 -Exactly -ParameterFilter { $Object.Length -gt 30 }
    }

    It 'writes nothing for an empty list' {
        Show-FirmwareStageFinding -Finding @()
        Should -Invoke Write-Host -ModuleName Kit.Core -Times 0 -Exactly
    }
}

Describe 'Kit.Core exports' {
    It 'exports <Name>' -ForEach @(
        @{ Name = 'Test-FirmwareTarget' }
        @{ Name = 'Test-FirmwareStage' }
        @{ Name = 'Show-FirmwareStageFinding' }
    ) {
        (Get-Module -Name Kit.Core).ExportedFunctions.Keys | Should -Contain $Name
    }
}
