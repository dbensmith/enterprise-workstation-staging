# The shipped HP data path end to end: the real layout file (copied, never rewritten), the output of the HP resolver for the
# 840 G5 and the 840 G6 and a fake diagnostics capture go through the core writer and the core validator. Everything a
# test needs is made at run time; HPCMSL is a stand-in module and nothing here touches the network.
# This file fails whenever the shipped layout and the validator disagree, which is the point of it.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\builder\vendors\hp\HP.Build.psm1') -Force

    $script:hpLayout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\kit\vendors\hp\layouts\hp-usb-flash.layout.psd1'))
    $script:captureName = 'diagnostics-sp171653'

    # HPCMSL is not installed on the builder PC and Pester can only mock a command that exists, so the resolver runs
    # against a stand-in module with HP's command and parameter names, generated from this table.
    function Import-HPCMSLStandIn {
        $spec = [ordered]@{
            'Get-HPBIOSUpdates'     = 'param($Platform, [switch]$Latest, [switch]$All)'
            'Get-HPSoftpaqMetadata' = 'param($Number)'
        }
        $source = foreach ($name in $spec.Keys) {
            "function $name { $($spec[$name]); process { [pscustomobject]`$PSBoundParameters } }"
        }
        $null = New-Module -Name HPCMSL -ScriptBlock ([scriptblock]::Create($source -join "`n")) | Import-Module -Global -Force
    }

    # A SoftPaq package as the firmware stage leaves it: the BIOS image, the flash tool files, the CVA data and the
    # SoftPaq executable, all made of run-time bytes.
    function Write-FakePackage {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$ModelId,
            [Parameter(Mandatory)][string]$OsFolder,
            [Parameter(Mandatory)][string]$SoftPaq,
            [Parameter(Mandatory)][string]$Bin
        )
        $package = Join-Path $Root "hp\$ModelId\$OsFolder"
        $folder = Join-Path $package "Firmware\$SoftPaq"
        $null = New-Item -Path (Join-Path $folder 'data') -ItemType Directory -Force
        $image = Join-Path $folder $Bin
        [IO.File]::WriteAllBytes($image, [Text.Encoding]::ASCII.GetBytes("fake bios image $ModelId $Bin"))
        $exe = Join-Path $folder "$SoftPaq.exe"
        [IO.File]::WriteAllBytes($exe, [Text.Encoding]::ASCII.GetBytes("fake softpaq executable $SoftPaq"))
        foreach ($name in 'HpFirmwareUpdRec64.exe', 'contents.txt', 'data\HpFirmwareUpdRec.cva') {
            [IO.File]::WriteAllBytes((Join-Path $folder $name), [Text.Encoding]::ASCII.GetBytes("fake $name of $ModelId"))
        }
        [pscustomobject]@{
            PackagePath = $package
            Sha256      = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
            Sha384      = (Get-FileHash -LiteralPath $image -Algorithm SHA384).Hash
            ExeSha256   = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        }
    }

    # One Get-HPBIOSUpdates row as HPCMSL 1.9.0 returns it.
    function Get-FakeCatalogEntry {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$Ver,
            [Parameter(Mandatory)][string]$Bin,
            [Parameter(Mandatory)][string]$Sha384
        )
        [pscustomobject]@{ Ver = $Ver; Date = '2026-06-13'; Bin = $Bin; Sha384 = $Sha384; RollbackAllowed = $true; Importance = 'Recommended'; Dependency = '' }
    }

    # The CVA of a SoftPaq as Get-HPSoftpaqMetadata returns it, with the executable hash in upper case as HP writes it.
    function Get-FakeCva {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][string]$ExeSha256,
            [hashtable]$Dependency
        )
        $cva = [ordered]@{
            Softpaq             = @{ SoftPaqSHA256 = $ExeSha256 }
            'Install Execution' = @{ SilentInstall = '"HpFirmwareUpdRec.exe" -r -b -s' }
            ReturnCode          = @{ '3010:SUCCESS:REBOOT' = 'A restart is required.'; '1602:CANCEL:NOREBOOT' = 'Flash failed due to dependency not satisfied.' }
        }
        if ($Dependency) { $cva['Dependency'] = $Dependency }
        [pscustomobject]$cva
    }

    # Stage the given models into a new folder target with the shipped layout copy and the recorded capture.
    function Invoke-StagePublish {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][pscustomobject]$Layout,
            [Parameter(Mandatory)][object[]]$Model,
            [Parameter(Mandatory)][hashtable]$CapturePath,
            [string]$FlashModel
        )
        $stick = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $splat = @{
            Layout      = $Layout
            Model       = $Model
            TargetPath  = $stick
            CapturePath = $CapturePath
            AllowFolder = $true
            PassThru    = $true
        }
        if ($FlashModel) { $splat.FlashModel = $FlashModel }
        Publish-FirmwareStage @splat
    }

    # Put one stray file on a stick, making its folders.
    function Write-StrayFile {
        [CmdletBinding()]
        [OutputType([void])]
        param(
            [Parameter(Mandatory)][string]$Stick,
            [Parameter(Mandatory)][string]$Relative
        )
        $full = Join-Path -Path $Stick -ChildPath $Relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
        [IO.File]::WriteAllText($full, 'stray', [Text.Encoding]::ASCII)
    }

    # The findings of a check, with a given status.
    function Select-Finding {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Finding,
            [Parameter(Mandatory)][string]$Status,
            [string]$Check
        )
        $Finding | Where-Object { $_.Status -eq $Status -and (-not $Check -or $_.Check -eq $Check) }
    }
}

AfterAll {
    Remove-Module -Name HPCMSL -Force -ErrorAction SilentlyContinue
}

Describe 'Shipped HP layout through Publish-FirmwareStage and Test-FirmwareStage' {
    BeforeAll {
        Import-HPCMSLStandIn
        $work = Join-Path $TestDrive 'work'
        $layoutFolder = Join-Path $work 'layout'
        $null = New-Item -Path $layoutFolder -ItemType Directory -Force
        $copy = Join-Path $layoutFolder 'hp-usb-flash.layout.psd1'
        Copy-Item -LiteralPath $script:hpLayout -Destination $copy
        $script:layout = Get-KitFirmwareLayout -Path $copy

        # The recorded diagnostics capture, taken from a fake tree and written beside the copied layout.
        $script:capture = Join-Path $work 'capture'
        foreach ($relative in 'EFI\HP\SystemDiags\SystemDiags.efi', 'EFI\HP\SystemDiags\SystemDiags.efi.s12', 'EFI\HP\SystemDiags\lib\HpSysDiags.dll', 'EFI\HP\BIOSUpdate\HpBiosUpdate.efi', 'EFI\HP\DI.efi') {
            $file = Join-Path $script:capture $relative
            $null = New-Item -Path (Split-Path -Path $file -Parent) -ItemType Directory -Force
            [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes("fake captured $relative"))
        }
        New-KitFirmwareSnapshot -SourcePath $script:capture -Name $script:captureName -Path $script:layout.Captures[0].SnapshotPath
        $script:capturePath = @{ $script:captureName = $script:capture }

        $script:g5Package = Write-FakePackage -Root (Join-Path $work 'staging') -ModelId 840-g5 -OsFolder win11-22H2 -SoftPaq sp157750 -Bin Q78_013100.bin
        $script:g6Package = Write-FakePackage -Root (Join-Path $work 'staging') -ModelId 840-g6 -OsFolder win11-24H2 -SoftPaq sp174025 -Bin R70_013600.bin
        $script:catalog = @{
            '83B2' = @(Get-FakeCatalogEntry -Ver '1.31.00' -Bin 'Q78_013100.bin' -Sha384 $script:g5Package.Sha384)
            '8549' = @(Get-FakeCatalogEntry -Ver '1.36.00' -Bin 'R70_013600.bin' -Sha384 $script:g6Package.Sha384)
        }
        $script:metadata = @{
            '157750' = Get-FakeCva -ExeSha256 $script:g5Package.ExeSha256
            '174025' = Get-FakeCva -ExeSha256 $script:g6Package.ExeSha256 -Dependency @{ MinimumBIOSVersion_R70 = '01.35.02' }
        }
        Mock Initialize-HPCMSL -ModuleName HP.Build {}
        Mock Get-HPBIOSUpdates -ModuleName HP.Build { $script:catalog["$Platform"] }
        Mock Get-HPSoftpaqMetadata -ModuleName HP.Build { $script:metadata["$Number"] }

        $script:g5Result = Get-HPKitFirmwareStickLayout -ModelProfile (Get-KitProfile -Vendor HP -ModelId 840-g5) -PackagePath $script:g5Package.PackagePath -LayoutPath $copy -WarningAction SilentlyContinue
        $script:g6Result = Get-HPKitFirmwareStickLayout -ModelProfile (Get-KitProfile -Vendor HP -ModelId 840-g6) -PackagePath $script:g6Package.PackagePath -LayoutPath $copy
        $script:model = @($script:g5Result, $script:g6Result)
    }

    Context 'a clean run' {
        BeforeAll {
            $script:stage = Invoke-StagePublish -Layout $script:layout -CapturePath $script:capturePath -Model $script:model
            $script:stick = $script:stage.TargetPath
            $script:finding = @(Test-FirmwareStage -Path $script:stick -AllowFolder)
            $script:manifest = Get-Content -LiteralPath (Join-Path $script:stick 'firmware-manifest.json') -Raw | ConvertFrom-Json
        }

        It 'uses the shipped layout file as it is' {
            $script:layout.Path | Should -Not -Be $script:hpLayout
            (Get-FileHash -LiteralPath $script:layout.Path -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $script:hpLayout -Algorithm SHA256).Hash
            @($script:layout.Groups) | Should -HaveCount 8
        }

        It 'marks the stick ready' {
            $script:stage.Ready | Should -BeTrue
            Join-Path $script:stick 'READY' | Should -Exist
        }

        It 'finds no Fail when the stick is validated again' {
            Select-Finding -Finding $script:finding -Status Fail | Should -HaveCount 0
        }

        It 'lists exactly the six staged groups in layout order, the flash-only groups left out' {
            @($script:manifest.groups.id) | Should -Be @('F10-New', 'F10-New-ESP', 'Diag-Current', 'Diag-Current-ESP', 'Diag-Tree', 'Win-Fallback')
        }

        It 'keeps the folder text of the Win-Fallback group with its token and marks it closed' {
            $group = $script:manifest.groups | Where-Object id -EQ 'Win-Fallback'
            $group.folder | Should -Be 'firmware\hp\{Platform}'
            $group.closed | Should -BeTrue
        }

        It 'lists each model with its own image in all four BIOS folders' {
            $g5 = $script:manifest.models | Where-Object modelId -EQ '840-g5'
            $g6 = $script:manifest.models | Where-Object modelId -EQ '840-g6'
            foreach ($folder in 'Hewlett-Packard\BIOS\New', 'EFI\HP\BIOS\New', 'Hewlett-Packard\BIOS\Current', 'EFI\HP\BIOS\Current') {
                @($g5.files.path) | Should -Contain "$folder\Q78_013100.bin"
                @($g6.files.path) | Should -Contain "$folder\R70_013600.bin"
            }
            @($g5.files.path) | Should -Not -Contain 'EFI\HP\BIOS\New\R70_013600.bin'
            @($g6.files.path) | Should -Not -Contain 'EFI\HP\BIOS\New\Q78_013100.bin'
        }

        It 'lists the fallback files of each model in its own platform folder' {
            $g5 = $script:manifest.models | Where-Object modelId -EQ '840-g5'
            $g6 = $script:manifest.models | Where-Object modelId -EQ '840-g6'
            @($g5.files.path | Where-Object { $_ -like 'firmware\hp\83B2\*' }) | Should -HaveCount 4
            @($g6.files.path | Where-Object { $_ -like 'firmware\hp\8549\*' }) | Should -HaveCount 4
            Join-Path $script:stick 'firmware\hp\8549\data\HpFirmwareUpdRec.cva' | Should -Exist
            Join-Path $script:stick 'firmware\hp\83B2\HpFirmwareUpdRec64.exe' | Should -Exist
            Join-Path $script:stick 'firmware\hp\8549\sp174025.exe' | Should -Not -Exist
        }

        It 'records how to run the flash tool and the BIOS the G6 image needs first' {
            $g6 = $script:manifest.models | Where-Object modelId -EQ '840-g6'
            $g6.windowsFlash.path | Should -Be 'firmware\hp\8549'
            $g6.windowsFlash.silentInstall | Should -Be '"HpFirmwareUpdRec.exe" -r -b -s'
            $g6.windowsFlash.returnCodes.'1602' | Should -Be 'CANCEL'
            $g6.windowsFlash.returnCodes.'3010' | Should -Be 'SUCCESS:REBOOT'
            $g6.latestBios.dependencyMinimum | Should -Be '01.35.02'
        }

        It 'holds the five captured files under shared' {
            @($script:manifest.shared) | Should -HaveCount 5
            @($script:manifest.shared.path) | Should -Contain 'EFI\HP\SystemDiags\lib\HpSysDiags.dll'
            @($script:manifest.shared.path) | Should -Contain 'EFI\HP\DI.efi'
        }

        It 'warns only about the folder target, the unverified layout, the G5 platform and the G6 dependency' {
            $warn = @(Select-Finding -Finding $script:finding -Status Warn)
            $warn | Should -HaveCount 4
            @($warn | Where-Object Check -EQ 'Volume') | Should -HaveCount 1
            @($warn | Where-Object Check -EQ 'Layout') | Should -HaveCount 1
            @($warn | Where-Object { $_.Check -eq 'Notes' -and $_.Message -like '*840-g5*83B2*' }) | Should -HaveCount 1
            @($warn | Where-Object { $_.Check -eq 'Notes' -and $_.Message -like '*840-g6*01.35.02*' }) | Should -HaveCount 1
        }

        It 'raises no Warn with the Root check and no unexpected-file Fail on the captured tree or the ESP BIOS folders' {
            Select-Finding -Finding $script:finding -Status Warn -Check Root | Should -HaveCount 0
            Select-Finding -Finding $script:finding -Status Fail -Check Folders | Should -HaveCount 0
        }
    }

    Context 'closed groups inside the open EFI\HP folder' {
        BeforeEach {
            $script:stick = (Invoke-StagePublish -Layout $script:layout -CapturePath $script:capturePath -Model $script:model).TargetPath
        }

        It 'fails for a stray file in <Relative>, naming it' -ForEach @(
            @{ Relative = 'EFI\HP\BIOS\New\stray.bin' }
            @{ Relative = 'EFI\HP\BIOS\Current\sub\x.txt' }
            @{ Relative = 'Hewlett-Packard\BIOS\New\stray.bin' }
        ) {
            Write-StrayFile -Stick $script:stick -Relative $Relative
            $fail = @(Select-Finding -Finding @(Test-FirmwareStage -Path $script:stick -AllowFolder) -Status Fail)
            $fail | Should -HaveCount 1
            $fail[0].Check | Should -Be 'Folders'
            $fail[0].Path | Should -Be $Relative
        }

        It 'gives no Fail for a stray file in the open SystemDiags folder' {
            Write-StrayFile -Stick $script:stick -Relative 'EFI\HP\SystemDiags\stray.txt'
            Select-Finding -Finding @(Test-FirmwareStage -Path $script:stick -AllowFolder) -Status Fail | Should -HaveCount 0
        }
    }

    Context 'the {Platform} token of Win-Fallback' {
        BeforeEach {
            $script:stick = (Invoke-StagePublish -Layout $script:layout -CapturePath $script:capturePath -Model $script:model).TargetPath
        }

        It 'checks the folder of <Platform> as a closed folder' -ForEach @(
            @{ Platform = '8549' }
            @{ Platform = '83B2' }
        ) {
            $relative = "firmware\hp\$Platform\stray.txt"
            Write-StrayFile -Stick $script:stick -Relative $relative
            $fail = @(Select-Finding -Finding @(Test-FirmwareStage -Path $script:stick -AllowFolder) -Status Fail)
            $fail | Should -HaveCount 1
            $fail[0].Check | Should -Be 'Folders'
            $fail[0].Path | Should -Be $relative
        }

        It 'does not check the folder of a platform that no model has, and does not warn about the root' {
            Write-StrayFile -Stick $script:stick -Relative 'firmware\hp\9999\x.txt'
            $finding = @(Test-FirmwareStage -Path $script:stick -AllowFolder)
            Select-Finding -Finding $finding -Status Fail | Should -HaveCount 0
            Select-Finding -Finding $finding -Status Warn -Check Root | Should -HaveCount 0
        }
    }

    Context 'the stick root allow-list' {
        BeforeEach {
            $script:stick = (Invoke-StagePublish -Layout $script:layout -CapturePath $script:capturePath -Model $script:model).TargetPath
        }

        It 'warns about no root entry on the clean stick' {
            Select-Finding -Finding @(Test-FirmwareStage -Path $script:stick -AllowFolder) -Status Warn -Check Root | Should -HaveCount 0
        }

        It 'accepts kit, results, System Volume Information and $RECYCLE.BIN' {
            foreach ($relative in 'kit\x.txt', 'results\x.txt', 'System Volume Information\x', '$RECYCLE.BIN\x') {
                Write-StrayFile -Stick $script:stick -Relative $relative
            }
            $finding = @(Test-FirmwareStage -Path $script:stick -AllowFolder)
            Select-Finding -Finding $finding -Status Warn -Check Root | Should -HaveCount 0
            Select-Finding -Finding $finding -Status Fail | Should -HaveCount 0
        }

        It 'warns once about any other entry at the root' {
            Write-StrayFile -Stick $script:stick -Relative 'junk.txt'
            $warn = @(Select-Finding -Finding @(Test-FirmwareStage -Path $script:stick -AllowFolder) -Status Warn -Check Root)
            $warn | Should -HaveCount 1
            $warn[0].Path | Should -Be 'junk.txt'
        }

        It 'warns once about the HP folder, because HP\DEVFW is not staged by default' {
            Write-StrayFile -Stick $script:stick -Relative 'HP\x.txt'
            $warn = @(Select-Finding -Finding @(Test-FirmwareStage -Path $script:stick -AllowFolder) -Status Warn -Check Root)
            $warn | Should -HaveCount 1
            $warn[0].Path | Should -Be 'HP'
        }
    }

    Context 'with -FlashModel 840-g6' {
        BeforeAll {
            $script:flashStage = Invoke-StagePublish -Layout $script:layout -CapturePath $script:capturePath -Model $script:model -FlashModel 840-g6
            $script:flashStick = $script:flashStage.TargetPath
            $script:flashFinding = @(Test-FirmwareStage -Path $script:flashStick -AllowFolder)
            $script:flashManifest = Get-Content -LiteralPath (Join-Path $script:flashStick 'firmware-manifest.json') -Raw | ConvertFrom-Json
        }

        It 'stages only the 840-g6 and every group of the layout' {
            $script:flashStage.Ready | Should -BeTrue
            $script:flashManifest.flashModel | Should -Be '840-g6'
            @($script:flashManifest.models.modelId) | Should -Be @('840-g6')
            @($script:flashManifest.groups.id) | Should -Be @('F10-New', 'F10-New-ESP', 'Diag-Current', 'Diag-Current-ESP', 'Diag-Tree', 'Esc-DEVFW', 'Esc-DEVFW-ESP', 'Win-Fallback')
        }

        It 'adds firmware.bin to the two DEVFW folders with the hash of the G6 image' {
            foreach ($relative in 'HP\DEVFW\firmware.bin', 'EFI\HP\DEVFW\firmware.bin') {
                $staged = Join-Path $script:flashStick $relative
                $staged | Should -Exist
                (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash | Should -Be $script:g6Package.Sha256
            }
        }

        It 'validates without a Fail' {
            Select-Finding -Finding $script:flashFinding -Status Fail | Should -HaveCount 0
        }

        It 'treats EFI\HP\DEVFW as a closed folder inside the open EFI\HP folder' {
            Write-StrayFile -Stick $script:flashStick -Relative 'EFI\HP\DEVFW\stray.bin'
            $fail = @(Select-Finding -Finding @(Test-FirmwareStage -Path $script:flashStick -AllowFolder) -Status Fail)
            $fail | Should -HaveCount 1
            $fail[0].Path | Should -Be 'EFI\HP\DEVFW\stray.bin'
        }
    }
}
