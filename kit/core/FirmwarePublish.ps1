# Stage writer for a Tools stick. Dot-sourced by Kit.Core.psm1. It takes the resolved entries of one or more models, checks
# everything that can be checked without touching the stick, copies the files into the layout's folders, writes the
# manifest from the same list and marks the stick READY only when the validator finds no Fail. Nothing here formats a
# volume or runs a staged file, and no folder or file name of any vendor appears in this file.

function Set-KitVolumeLabel {
    <#
    .SYNOPSIS
    Set the label of the volume that holds a path. This is a seam over the drive; tests mock it.

    .DESCRIPTION
    Private helper of Publish-FirmwareStage. Uses System.IO.DriveInfo. Never throws: a failure, or a refusal by
    ShouldProcess, returns $false and the caller turns that into a warning.

    .PARAMETER Path
    A path on the volume.

    .PARAMETER Label
    The new label.

    .OUTPUTS
    $true when the label was set.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if (-not $PSCmdlet.ShouldProcess($root, "Set the volume label to $Label")) { return $false }
        $drive = [System.IO.DriveInfo]::new($root)
        $drive.VolumeLabel = $Label
        return $true
    }
    catch {
        return $false
    }
}

function Clear-KitVolumeCache {
    <#
    .SYNOPSIS
    Flush the write cache of the volume that holds a path. This is a seam over the drive; tests mock it.

    .DESCRIPTION
    Private helper of Publish-FirmwareStage. Uses Write-VolumeCache when the command exists. Never throws: a failure
    returns $false and the caller turns that into a warning.

    .PARAMETER Path
    A path on the volume.

    .OUTPUTS
    $true when the cache was flushed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if (-not (Get-Command -Name Write-VolumeCache -ErrorAction SilentlyContinue)) { return $false }
        Write-VolumeCache -DriveLetter $root.Substring(0, 1) -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-KitJsonMap {
    <#
    .SYNOPSIS
    Copy a table or an object into an ordered table with text keys, so ConvertTo-Json writes it as an object.

    .DESCRIPTION
    Private helper of the manifest writer. Keys of a hashtable are sorted ordinally so the same data gives the same
    bytes; the properties of an object keep their order. A $null input gives an empty table.

    .PARAMETER InputObject
    A hashtable, an ordered table or an object with properties.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [object]$InputObject
    )
    $map = [ordered]@{}
    if ($null -eq $InputObject) { return $map }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $name = [string[]]@(foreach ($key in $InputObject.Keys) { [string]$key })
        [System.Array]::Sort($name, [System.StringComparer]::Ordinal)
        foreach ($key in $name) { $map[$key] = $InputObject[$key] }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) { $map[[string]$property.Name] = $property.Value }
    }
    $map
}

function Get-KitCachedHash {
    <#
    .SYNOPSIS
    Return the lower-case hash of a file, computing each file and algorithm once per cache.

    .DESCRIPTION
    Private helper of Get-KitStagePlan. The same source image is listed under several groups and models, and a BIOS
    image can be large, so each distinct file is hashed once per algorithm.

    .PARAMETER Path
    The file.

    .PARAMETER Algorithm
    SHA256, SHA384 or SHA512.

    .PARAMETER Cache
    A hashtable that keeps results between calls.

    .OUTPUTS
    The hash as 64 (SHA256), 96 (SHA384) or 128 (SHA512) lower-case hex characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('SHA256', 'SHA384', 'SHA512')]
        [string]$Algorithm,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )
    $key = $Algorithm + '|' + $Path.ToLowerInvariant()
    if (-not $Cache.ContainsKey($key)) {
        $Cache[$key] = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
    }
    $Cache[$key]
}

function Get-KitStagePlan {
    <#
    .SYNOPSIS
    Check every entry of every model without touching the stick and return the list of files to write.

    .DESCRIPTION
    Private helper of Publish-FirmwareStage. Each entry must name a group of the layout, a path that is valid on FAT32 and
    lies under its group folder (with {Platform} replaced by the model's platform id), and an existing source whose size
    and SHA-256 equal the entry's and whose vendor hash, when present, matches. Any problem throws one message that
    names the entry, so nothing has been written when it is raised. A staged captured group needs an entry in the
    capture path table.

    .PARAMETER Layout
    The Kit.FirmwareLayout.

    .PARAMETER Model
    The vendor results, one per model.

    .PARAMETER StagedGroup
    The layout groups that are staged in this run.

    .PARAMETER CapturePath
    Capture name to the folder that holds the captured tree.

    .OUTPUTS
    Pair (Owner, Entry for every entry) and Destination (one record per distinct destination path).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Layout,

        [Parameter(Mandatory)]
        [object[]]$Model,

        [Parameter(Mandatory)]
        [object[]]$StagedGroup,

        [Parameter(Mandatory)]
        [hashtable]$CapturePath
    )
    $cache = @{}
    $stagedId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($group in $StagedGroup) { $null = $stagedId.Add($group.Id) }
    $layoutGroup = @{}
    foreach ($group in $Layout.Groups) { $layoutGroup[$group.Id.ToLowerInvariant()] = $group }

    foreach ($group in $StagedGroup) {
        if ($group.SourceKind -ceq 'Captured' -and -not $CapturePath.ContainsKey($group.CaptureName)) {
            throw ("FW-05: the UEFI diagnostics capture is missing. Group '{0}' needs the captured tree; pass it as the capture path for '{1}' (builder: -DiagnosticsSource). Steps: docs\firmware-bench-checklist.md." -f $group.Id, $group.CaptureName)
        }
    }

    $pair = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Model) {
        foreach ($entry in @($item.Entries)) {
            $path = [string]$entry.RelativePath
            $label = "entry '$path' of model '$($item.ModelId)'"
            $group = $layoutGroup[([string]$entry.Group).ToLowerInvariant()]
            if (-not $group) { throw "$label names the group '$($entry.Group)', which the layout does not have" }
            if ($group.SourceKind -ceq 'Captured') { throw "$label names the captured group '$($group.Id)'; a captured group is filled from the capture only" }
            if (-not $stagedId.Contains($group.Id)) { continue }

            $problem = @(Get-KitStagePathProblem -RelativePath $path -Size ([long]$entry.Size))
            if ($problem.Count -gt 0) { throw "$label is not a valid stick path: $($problem -join '; ')" }
            $leaf = $path.Substring($path.LastIndexOf('\') + 1)
            if ($leaf -like '*Pswd*.bin' -or $leaf -eq 'password.bin') { throw "$label is a password file name; such a file must never be staged" }

            $folder = $group.Folder
            if ($folder.Contains('{Platform}')) {
                if (-not [string]$item.PlatformId) { throw "$label needs a platform id: group '$($group.Id)' folder is $folder" }
                $folder = $folder.Replace('{Platform}', [string]$item.PlatformId)
            }
            if (-not $path.StartsWith($folder + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "$label lies outside its group folder $folder (group '$($group.Id)')"
            }

            $source = [string]$entry.SourcePath
            if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "$label has no source file: $source" }
            $length = (Get-Item -LiteralPath $source -Force).Length
            if ($length -ne [long]$entry.Size) { throw "$label source size $length differs from the vendor result size $($entry.Size)" }
            $sha256 = Get-KitCachedHash -Path $source -Algorithm SHA256 -Cache $cache
            if ($sha256 -ne ([string]$entry.Sha256).ToLowerInvariant()) { throw "$label source SHA-256 differs from the vendor result" }
            $vendorHash = $null
            if ($entry.VendorHash) {
                $algorithm = [string]$entry.VendorHash.Algorithm
                if ($algorithm -notin 'SHA256', 'SHA384', 'SHA512') { throw "$label has vendor hash algorithm '$algorithm', which is not supported" }
                if ((Get-KitCachedHash -Path $source -Algorithm $algorithm -Cache $cache) -ne ([string]$entry.VendorHash.Value).ToLowerInvariant()) {
                    throw "$label source $algorithm hash differs from the vendor hash"
                }
                $vendorHash = [pscustomobject]@{ Algorithm = $algorithm; Value = [string]$entry.VendorHash.Value; Source = [string]$entry.VendorHash.Source }
            }
            $pair.Add([pscustomobject]@{
                    Owner = [string]$item.ModelId
                    Entry = [pscustomobject]@{
                        RelativePath = $path
                        SourcePath   = $source
                        Group        = $group.Id
                        Size         = [long]$length
                        Sha256       = $sha256
                        VendorHash   = $vendorHash
                    }
                })
        }
    }

    $destination = [System.Collections.Generic.List[object]]::new()
    $first = @{}
    foreach ($each in $pair) {
        $key = $each.Entry.RelativePath.ToLowerInvariant()
        if (-not $first.ContainsKey($key)) {
            $first[$key] = $each
            $destination.Add($each.Entry)
            continue
        }
        $other = $first[$key]
        $ownerA = if ($other.Owner) { $other.Owner } else { 'shared' }
        $ownerB = if ($each.Owner) { $each.Owner } else { 'shared' }
        if ($each.Entry.Sha256 -ne $other.Entry.Sha256) {
            throw "Two models map to one path with different content: $($other.Entry.RelativePath) ($ownerA, $ownerB)"
        }
        if ($each.Entry.RelativePath -cne $other.Entry.RelativePath) {
            throw "Two entries differ only in letter case: $($other.Entry.RelativePath) ($ownerA) and $($each.Entry.RelativePath) ($ownerB); FAT32 treats them as one file"
        }
    }
    [pscustomobject]@{ Pair = $pair.ToArray(); Destination = $destination.ToArray() }
}

function ConvertTo-KitManifestFile {
    <#
    .SYNOPSIS
    Build the manifest record of one staged file.

    .DESCRIPTION
    Private helper of Get-KitStageManifest. The record keys are path, group, size, sha256 and vendorHash.

    .PARAMETER Entry
    A checked entry from Get-KitStagePlan.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [object]$Entry
    )
    $vendorHash = $null
    if ($Entry.VendorHash) {
        $vendorHash = [ordered]@{
            algorithm = [string]$Entry.VendorHash.Algorithm
            value     = [string]$Entry.VendorHash.Value
            source    = [string]$Entry.VendorHash.Source
        }
    }
    $record = [ordered]@{
        path       = [string]$Entry.RelativePath
        group      = [string]$Entry.Group
        size       = [long]$Entry.Size
        sha256     = [string]$Entry.Sha256
        vendorHash = $vendorHash
    }
    $record
}

function Get-KitStageManifest {
    <#
    .SYNOPSIS
    Build the manifest object from the checked plan, the layout and the staged groups.

    .DESCRIPTION
    Private helper of Publish-FirmwareStage. The manifest is built field by field from an allow-list, so nothing of the
    builder (environment, user, configuration, paths) reaches the stick. Each file record is written once: under the
    model that owns it, or under shared when it belongs to no model. The keys come out in a fixed order.

    .PARAMETER Layout
    The Kit.FirmwareLayout.

    .PARAMETER Model
    The vendor results, one per model.

    .PARAMETER StagedGroup
    The layout groups that are staged in this run.

    .PARAMETER Plan
    The plan from Get-KitStagePlan.

    .PARAMETER FlashModel
    The model id of a -FlashModel run, or an empty string.

    .PARAMETER ToolVersion
    The Kit.Core module version.

    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Layout,

        [Parameter(Mandatory)]
        [object[]]$Model,

        [Parameter(Mandatory)]
        [object[]]$StagedGroup,

        [Parameter(Mandatory)]
        [pscustomobject]$Plan,

        [AllowEmptyString()]
        [string]$FlashModel = '',

        [Parameter(Mandatory)]
        [string]$ToolVersion
    )
    $group = @(foreach ($item in $StagedGroup) {
            [ordered]@{ id = $item.Id; folder = $item.Folder; closed = [bool]$item.Closed; verified = [bool]$item.Verified.Status }
        })

    $models = @(foreach ($item in $Model) {
            $bios = $null
            if ($item.LatestBios) {
                $bios = [ordered]@{
                    version           = [string]$item.LatestBios.Version
                    date              = [string]$item.LatestBios.Date
                    packageId         = [string]$item.LatestBios.PackageId
                    file              = [string]$item.LatestBios.File
                    dependencyMinimum = [string]$item.LatestBios.DependencyMinimum
                }
            }
            $flash = $null
            if ($item.WindowsFlash) {
                $flash = [ordered]@{
                    path          = [string]$item.WindowsFlash.Path
                    silentInstall = [string]$item.WindowsFlash.SilentInstall
                    returnCodes   = ConvertTo-KitJsonMap -InputObject $item.WindowsFlash.ReturnCodes
                }
            }
            $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $file = @(foreach ($each in $Plan.Pair) {
                    if ($each.Owner -eq [string]$item.ModelId -and $listed.Add($each.Entry.RelativePath)) { ConvertTo-KitManifestFile -Entry $each.Entry }
                })
            [ordered]@{
                modelId          = [string]$item.ModelId
                name             = [string]$item.Name
                platformId       = [string]$item.PlatformId
                platformVerified = [bool]$item.PlatformVerified
                biosFamily       = [string]$item.BiosFamily
                latestBios       = $bios
                windowsFlash     = $flash
                files            = $file
            }
        })

    $listedShared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $shared = @(foreach ($each in $Plan.Pair) {
            if (-not $each.Owner -and $listedShared.Add($each.Entry.RelativePath)) { ConvertTo-KitManifestFile -Entry $each.Entry }
        })

    $unverified = @($StagedGroup | Where-Object { $_.Verified.Status -ne $true })
    $manifest = [ordered]@{
        schemaVersion = 1
        toolVersion   = $ToolVersion
        builtUtc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        vendor        = [string]$Model[0].Vendor
        volumeLabel   = [string]$Layout.VolumeLabel
        fileSystem    = [string]$Layout.FileSystem
        verified      = ($unverified.Count -eq 0)
        flashModel    = $FlashModel
        groups        = $group
        models        = $models
        shared        = $shared
        diagnostics   = $null
    }
    $manifest
}

function Publish-FirmwareStage {
    <#
    .SYNOPSIS
    Write the firmware files of one or more models onto a Tools stick and mark the stick READY when it checks out.

    .DESCRIPTION
    Vendor-neutral. The vendor results in -Model say which files exist and where in the layout they belong; this
    function copies them into the layout's group folders and writes firmware-manifest.json from the same list. Everything
    that can fail without touching the stick is checked first and throws before any file is written: a bad entry path, an
    entry outside its group folder, a missing source, a hash that differs from the vendor result, a missing diagnostics
    capture, a target that is not a FAT32 volume root. After the copy the stick is checked with Test-FirmwareStage;
    READY is deleted at the start of every run and written last, only when that check returns no Fail. Nothing is
    formatted and no staged file is run.

    .PARAMETER Layout
    The Kit.FirmwareLayout from Get-KitFirmwareLayout.

    .PARAMETER Model
    Vendor results (Kit.FirmwareStickLayout), one per model.

    .PARAMETER TargetPath
    The stick root, for example E:\ (or any folder with -AllowFolder).

    .PARAMETER CapturePath
    Table of capture name to the folder that holds the captured tree.

    .PARAMETER FlashModel
    A model id. Stages only that model and also the groups that are not staged by default (the escape hatch for flashing
    one model from a folder the normal build leaves out). An id that is not among the models throws and lists them.

    .PARAMETER IncludeKit
    Also copy the kit files Get-KitPublishFile lists into <target>\kit. Off by default.

    .PARAMETER KitRoot
    The kit folder to copy with -IncludeKit. Defaults to the kit this module belongs to.

    .PARAMETER RemoveStale
    Delete files inside closed group folders that the new manifest does not list. Without it such a file is a Fail.

    .PARAMETER AllowFolder
    Stage into a plain folder: the FAT32 and label checks are skipped (one Warn) and the folder is created.

    .PARAMETER PassThru
    Return the Kit.FirmwareStageResult: Ready, Written, TargetPath, ManifestPath, FileCount, Findings, UnverifiedGroup,
    Verified.

    .EXAMPLE
    Publish-FirmwareStage -Layout $layout -Model $results -TargetPath E:\ -PassThru
    Stages the models onto the stick in E: and returns the result.

    .OUTPUTS
    Kit.FirmwareStageResult with -PassThru; nothing otherwise.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Layout,

        [Parameter(Mandatory)]
        [object[]]$Model,

        [Parameter(Mandatory)]
        [string]$TargetPath,

        [hashtable]$CapturePath = @{},

        [string]$FlashModel,

        [switch]$IncludeKit,

        [string]$KitRoot = (Get-KitRoot),

        [switch]$RemoveStale,

        [switch]$AllowFolder,

        [switch]$PassThru
    )
    if ($Layout.PSObject.TypeNames -notcontains 'Kit.FirmwareLayout') { throw 'Layout must come from Get-KitFirmwareLayout' }
    $models = @($Model)
    if ($models.Count -eq 0) { throw 'Model must hold at least one vendor result' }
    $seenModel = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $models) {
        if (-not [string]$item.ModelId) { throw 'Every vendor result needs a ModelId' }
        if (-not $seenModel.Add([string]$item.ModelId)) { throw "ModelId '$($item.ModelId)' appears twice in Model" }
        if ([string]$item.Vendor -ne [string]$models[0].Vendor) { throw "Model '$($item.ModelId)' is from vendor '$($item.Vendor)' but the first model is from '$($models[0].Vendor)'; one stick holds one vendor" }
    }
    $target = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($TargetPath)

    $staged = @($Layout.Groups | Where-Object { $_.Default })
    $flashId = ''
    if ($FlashModel) {
        $match = @($models | Where-Object { $_.ModelId -eq $FlashModel })
        if ($match.Count -eq 0) { throw "FlashModel '$FlashModel' is not one of: $(($models | ForEach-Object { $_.ModelId }) -join ', ')" }
        $models = $match
        $flashId = [string]$match[0].ModelId
        $staged = @($Layout.Groups)
    }
    if ($staged.Count -eq 0) { throw 'The layout has no default group to stage' }
    if ($IncludeKit -and -not (Test-Path -LiteralPath $KitRoot -PathType Container)) { throw "KitRoot $KitRoot not found" }
    $plan = Get-KitStagePlan -Layout $Layout -Model $models -StagedGroup $staged -CapturePath $CapturePath

    $targetFinding = @(Test-FirmwareTarget -Path $target -AllowFolder:$AllowFolder | Where-Object { $_.Status -eq 'Fail' })
    if ($targetFinding.Count -gt 0) { throw ($targetFinding.Message -join '; ') }
    $labelDiffers = $false
    if (-not $AllowFolder) {
        $info = Get-KitVolumeInfo -Path $target
        $labelDiffers = [bool]($info -and [string]$info.Label -ne [string]$Layout.VolumeLabel)
    }

    $manifestPath = Join-Path -Path $target -ChildPath 'firmware-manifest.json'
    $readyPath = Join-Path -Path $target -ChildPath 'READY'
    $own = [System.Collections.Generic.List[object]]::new()
    $validator = @()
    $ready = $false
    $written = $false
    $unverified = [string[]]@($staged | Where-Object { $_.Verified.Status -ne $true } | ForEach-Object { $_.Id })

    if ($PSCmdlet.ShouldProcess($target, 'Stage firmware')) {
        $ConfirmPreference = 'None'
        if ($AllowFolder) { $null = New-Item -Path $target -ItemType Directory -Force }
        if (Test-Path -LiteralPath $readyPath) { Remove-Item -LiteralPath $readyPath -Force }

        foreach ($file in $plan.Destination) {
            $destination = Join-Path -Path $target -ChildPath $file.RelativePath
            $current = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            if ($current -and $current.Length -eq $file.Size -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.Sha256) { continue }
            $null = New-Item -Path (Split-Path -Path $destination -Parent) -ItemType Directory -Force
            Copy-Item -LiteralPath $file.SourcePath -Destination $destination -Force -ErrorAction Stop
        }

        if ($labelDiffers -and -not (Set-KitVolumeLabel -Path $target -Label $Layout.VolumeLabel -Confirm:$false)) {
            $own.Add((ConvertTo-KitFirmwareFinding -Status Warn -Check Volume -Message "could not set the volume label to $($Layout.VolumeLabel)"))
        }

        if ($IncludeKit) {
            foreach ($file in Get-KitPublishFile -Root $KitRoot) {
                $destination = Join-Path -Path $target -ChildPath (Join-Path -Path 'kit' -ChildPath $file.RelativePath)
                $null = New-Item -Path (Split-Path -Path $destination -Parent) -ItemType Directory -Force
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
            }
        }

        $manifest = Get-KitStageManifest -Layout $Layout -Model $models -StagedGroup $staged -Plan $plan -FlashModel $flashId -ToolVersion $MyInvocation.MyCommand.Module.Version.ToString()
        if ($RemoveStale) {
            $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($file in $plan.Destination) { $null = $listed.Add($file.RelativePath) }
            $prefix = $target.TrimEnd('\') + '\'
            foreach ($folder in Get-KitClosedFolder -Manifest $manifest) {
                $full = Join-Path -Path $target -ChildPath $folder
                if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
                foreach ($stale in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force)) {
                    $relative = $stale.FullName.Substring($prefix.Length)
                    if ($listed.Contains($relative)) { continue }
                    Remove-Item -LiteralPath $stale.FullName -Force
                    $own.Add((ConvertTo-KitFirmwareFinding -Status Warn -Check Folders -Message 'removed a file the manifest does not list' -Path $relative))
                }
            }
        }
        $json = ConvertTo-Json -InputObject $manifest -Depth 6
        [System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))
        $written = $true

        $validator = @(Test-FirmwareStage -Path $target -AllowFolder:$AllowFolder -IgnoreReadyMarker)
        foreach ($item in $models) {
            foreach ($note in @($item.Notes)) {
                if ($note) { $own.Add((ConvertTo-KitFirmwareFinding -Status Warn -Check Notes -Message "model $($item.ModelId): $note")) }
            }
        }
        $failed = @($validator + $own.ToArray() | Where-Object { $_.Status -eq 'Fail' })
        if ($failed.Count -eq 0) {
            $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            [System.IO.File]::WriteAllText($readyPath, "$hash`r`n", [System.Text.Encoding]::ASCII)
            $ready = $true
            if (-not $AllowFolder -and -not (Clear-KitVolumeCache -Path $target)) {
                $own.Add((ConvertTo-KitFirmwareFinding -Status Warn -Check Volume -Message 'could not flush the volume cache; wait before removing the stick'))
            }
        }
    }

    if ($PassThru) {
        [pscustomobject]@{
            PSTypeName      = 'Kit.FirmwareStageResult'
            Ready           = $ready
            Written         = $written
            TargetPath      = $target
            ManifestPath    = $manifestPath
            FileCount       = @($plan.Destination).Count
            Findings        = @($validator + $own.ToArray())
            UnverifiedGroup = $unverified
            Verified        = ($unverified.Count -eq 0)
        }
    }
}
