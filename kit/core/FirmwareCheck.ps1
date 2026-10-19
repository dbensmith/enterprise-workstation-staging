# Validator for a Tools stick. Dot-sourced by Kit.Core.psm1. Pure: nothing here writes to a stick, and the only console output
# is Show-FirmwareStageFinding. The list of expected files comes from firmware-manifest.json on the stick and from nowhere else:
# no folder or file name of any vendor appears in this file.

function ConvertTo-KitFirmwareFinding {
    <#
    .SYNOPSIS
    Build one Kit.FirmwareFinding object.

    .DESCRIPTION
    Private factory used by every check in this file. A finding is a result line: a status, the check that produced it,
    a short reason, and the manifest path and group it is about (both empty when the finding is not about one file).

    .PARAMETER Status
    Pass, Warn or Fail.

    .PARAMETER Check
    The check that produced the finding.

    .PARAMETER Message
    Short reason, written to be read on a phone screen.

    .PARAMETER Path
    Manifest path of the file the finding is about, exactly as the manifest writes it.

    .PARAMETER Group
    Id of the group the file belongs to.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail')]
        [string]$Status,

        [Parameter(Mandatory)]
        [ValidateSet('Manifest', 'Volume', 'Names', 'Files', 'Hash', 'Duplicate', 'Folders', 'Root', 'Password', 'Ready', 'Layout', 'Notes')]
        [string]$Check,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Path = '',

        [string]$Group = ''
    )
    [pscustomobject]@{
        PSTypeName = 'Kit.FirmwareFinding'
        Status     = $Status
        Check      = $Check
        Message    = $Message
        Path       = $Path
        Group      = $Group
    }
}

function Get-KitVolumeInfo {
    <#
    .SYNOPSIS
    Describe the volume that holds a path. This is the one seam that touches the drive; tests mock it.

    .DESCRIPTION
    Private helper of Test-FirmwareTarget and Test-FirmwareStage. Uses System.IO.DriveInfo, so it needs no CIM and
    no admin rights. Returns $null when the path has no drive letter (a network share) or the drive is not ready.

    .PARAMETER Path
    A path on the volume.

    .OUTPUTS
    Root (for example E:\), FileSystem, Label and IsRemovable; or nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if (-not $root -or $root.StartsWith('\\')) { return $null }
        $drive = [System.IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) { return $null }
        [pscustomobject]@{
            Root        = $drive.Name
            FileSystem  = $drive.DriveFormat
            Label       = $drive.VolumeLabel
            IsRemovable = ($drive.DriveType -eq [System.IO.DriveType]::Removable)
        }
    }
    catch {
        return $null
    }
}

function Get-KitStagePathProblem {
    <#
    .SYNOPSIS
    List the reasons a stick-relative path cannot exist on a FAT32 volume.

    .DESCRIPTION
    Private helper shared by the stage validator and the layout loader. Rules: no drive letter and not rooted,
    backslash is the only separator, no empty, dot or double-dot segment, no character FAT32 forbids, no trailing
    space or dot, no reserved device name, no segment over 255 characters, no path over 259 characters once a drive
    prefix is added, and no file over 4294967295 bytes.

    .PARAMETER RelativePath
    The path, relative to the stick root.

    .PARAMETER Size
    File size in bytes. Left out (-1) when the path is not a file.

    .OUTPUTS
    One string per reason; nothing when the path is fine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RelativePath,

        [long]$Size = -1
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($RelativePath.Length -eq 0) {
        $problems.Add('the path is empty')
    }
    else {
        if ($RelativePath.StartsWith('\')) { $problems.Add('the path is rooted') }
        if ($RelativePath -match '^[A-Za-z]:') { $problems.Add('the path starts with a drive letter') }
        if ($RelativePath.Contains('/')) { $problems.Add("the path uses '/' (backslash is the separator)") }
        $emptySegment = $false
        foreach ($segment in $RelativePath.Split('\')) {
            if ($segment.Length -eq 0) {
                if (-not $emptySegment -and -not $RelativePath.StartsWith('\')) { $problems.Add('the path has an empty segment') }
                $emptySegment = $true
                continue
            }
            if ($segment -eq '.' -or $segment -eq '..') {
                $problems.Add("the path has a '$segment' segment")
                continue
            }
            if ($segment.Length -gt 255) { $problems.Add("segment '$($segment.Substring(0, 20))...' is over 255 characters") }
            if ($segment -match '[<>:"|?*\x00-\x1f]') { $problems.Add("segment '$segment' has a character FAT32 does not allow") }
            if ($segment.EndsWith(' ') -or $segment.EndsWith('.')) { $problems.Add("segment '$segment' ends with a space or a dot") }
            if ($segment.Split('.')[0].TrimEnd() -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $problems.Add("segment '$segment' is a reserved device name") }
        }
        if (($RelativePath.Length + 3) -gt 259) { $problems.Add('the path is over 259 characters with a drive prefix') }
    }
    if ($Size -gt 4294967295) { $problems.Add("the size $Size is over the FAT32 limit of 4294967295 bytes") }
    $problems.ToArray()
}

function Get-KitClosedFolder {
    <#
    .SYNOPSIS
    List the concrete stick folders of every closed group in a manifest.

    .DESCRIPTION
    A closed group is a folder that may hold only the files the manifest lists. A group folder may carry the token
    {Platform}; it is replaced by the platformId of each model that has files in that group, so the group yields one
    folder per such model. Groups that are not closed yield nothing. Only property access is used, so an object built
    in memory works as well as one read from JSON.

    .PARAMETER Manifest
    A manifest-shaped object: groups (id, folder, closed) and models (platformId, files with a group each).

    .OUTPUTS
    Folder paths relative to the stick root, without duplicates, in group order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($group in $Manifest.groups) {
        if ($group.closed -ne $true) { continue }
        $folder = [string]$group.folder
        if (-not $folder.Contains('{Platform}')) {
            if ($seen.Add($folder)) { $folder }
            continue
        }
        foreach ($model in $Manifest.models) {
            $usesGroup = $false
            foreach ($file in $model.files) {
                if ([string]$file.group -eq [string]$group.id) { $usesGroup = $true }
            }
            if ($usesGroup -and $model.platformId) {
                $concrete = $folder.Replace('{Platform}', [string]$model.platformId)
                if ($seen.Add($concrete)) { $concrete }
            }
        }
    }
}

function Read-KitFirmwareManifest {
    <#
    .SYNOPSIS
    Read firmware-manifest.json from the root of a stick.

    .DESCRIPTION
    Private helper of Test-FirmwareStage. Throws one message that names the file when it is absent, is not JSON or
    carries a schemaVersion other than 1. The text may start with a byte order mark.

    .PARAMETER Path
    The stick root.

    .OUTPUTS
    The parsed manifest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $file = Join-Path -Path $Path -ChildPath 'firmware-manifest.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "firmware-manifest.json not found under $Path"
    }
    try {
        $manifest = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "firmware-manifest.json is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $manifest) { throw 'firmware-manifest.json is not valid JSON: the file is empty' }
    if ($manifest.schemaVersion -ne 1) {
        throw "firmware-manifest.json schemaVersion '$($manifest.schemaVersion)' is not supported (expected 1)"
    }
    $manifest
}

function Get-KitStageEntry {
    <#
    .SYNOPSIS
    List every file record of a manifest with the model that owns it.

    .DESCRIPTION
    Private helper of Test-FirmwareStage. The records are every models[].files entry plus every shared entry; a shared
    record is owned by 'shared'.

    .PARAMETER Manifest
    The parsed manifest.

    .OUTPUTS
    ModelId and Record for each file record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest
    )
    foreach ($model in $Manifest.models) {
        foreach ($file in $model.files) { [pscustomobject]@{ ModelId = [string]$model.modelId; Record = $file } }
    }
    foreach ($file in $Manifest.shared) { [pscustomobject]@{ ModelId = 'shared'; Record = $file } }
}

function Get-KitStageFileProblem {
    <#
    .SYNOPSIS
    Compare one staged file with its manifest record and return the first problem found.

    .DESCRIPTION
    Private helper of Test-FirmwareStage. Checks, in order: the file exists, the size matches, the SHA-256 matches and,
    when the record carries a vendor hash, that hash matches (SHA256, SHA384 or SHA512). A file is hashed only when it
    exists and has the right size. Returns $null when the file is good, else an object with Check and Message.

    .PARAMETER Root
    The stick root.

    .PARAMETER Record
    One manifest file record: path, size, sha256 and optional vendorHash.

    .OUTPUTS
    Check and Message of the first problem, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [object]$Record
    )
    $relative = [string]$Record.path
    $full = $null
    if ($relative) { $full = Join-Path -Path $Root -ChildPath $relative }
    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{ Check = 'Files'; Message = 'missing' }
    }
    $staged = (Get-Item -LiteralPath $full -Force).Length
    if ($staged -ne [long]$Record.size) {
        return [pscustomobject]@{ Check = 'Files'; Message = ('size differs (staged {0}, manifest {1})' -f $staged, $Record.size) }
    }
    if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne [string]$Record.sha256) {
        return [pscustomobject]@{ Check = 'Hash'; Message = 'SHA-256 differs' }
    }
    $vendor = $Record.vendorHash
    if ($vendor) {
        $algorithm = [string]$vendor.algorithm
        if ($algorithm -notin 'SHA256', 'SHA384', 'SHA512') {
            return [pscustomobject]@{ Check = 'Hash'; Message = "vendor hash algorithm '$algorithm' is not supported" }
        }
        if ((Get-FileHash -LiteralPath $full -Algorithm $algorithm).Hash -ne [string]$vendor.value) {
            return [pscustomobject]@{ Check = 'Hash'; Message = "vendor hash differs ($algorithm)" }
        }
    }
}

function Get-KitStickFile {
    <#
    .SYNOPSIS
    List every file on a stick except the trees Windows keeps for itself.

    .DESCRIPTION
    Private helper of the password check. Skips System Volume Information and $RECYCLE.BIN, which a non-admin cannot
    read and which are not part of the payload.

    .PARAMETER Root
    The stick root.

    .OUTPUTS
    System.IO.FileInfo
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if (-not $item.PSIsContainer) {
            $item
        }
        elseif ($item.Name -notin 'System Volume Information', '$RECYCLE.BIN') {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force
        }
    }
}

function Test-KitStageName {
    <#
    .SYNOPSIS
    Check every manifest path against the FAT32 name rules.

    .DESCRIPTION
    Private check of Test-FirmwareStage. A path that cannot exist on FAT32 is a Fail naming the path. Two paths that
    differ only in case are a Fail too, because FAT32 treats them as one file. The same path written twice is not
    reported here; Test-KitStageDuplicate compares the content.

    .PARAMETER Entry
    File records with their owning model, from Get-KitStageEntry.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry
    )
    $firstSpelling = @{}
    $problemCount = 0
    foreach ($item in $Entry) {
        $path = [string]$item.Record.path
        $group = [string]$item.Record.group
        $size = -1
        if ($null -ne $item.Record.size) { $size = [long]$item.Record.size }
        $reason = @(Get-KitStagePathProblem -RelativePath $path -Size $size)
        if ($reason.Count -gt 0) {
            $problemCount++
            ConvertTo-KitFirmwareFinding -Status Fail -Check Names -Message ('not valid on FAT32: ' + ($reason -join '; ')) -Path $path -Group $group
            continue
        }
        $key = $path.ToLowerInvariant()
        if (-not $firstSpelling.ContainsKey($key)) {
            $firstSpelling[$key] = $path
        }
        elseif ($firstSpelling[$key] -cne $path) {
            $problemCount++
            ConvertTo-KitFirmwareFinding -Status Fail -Check Names -Message ("same file as '{0}' on FAT32 (case-insensitive)" -f $firstSpelling[$key]) -Path $path -Group $group
        }
    }
    if ($problemCount -eq 0) {
        ConvertTo-KitFirmwareFinding -Status Pass -Check Names -Message ('{0} paths valid on FAT32' -f @($Entry).Count)
    }
}

function Test-KitStageFile {
    <#
    .SYNOPSIS
    Check that every listed file is on the stick with the manifest size and hashes.

    .DESCRIPTION
    Private check of Test-FirmwareStage. One Fail per file with a problem, carrying the manifest path. A record whose
    path already failed the name rules is skipped, so one bad file gives one line.

    .PARAMETER Root
    The stick root.

    .PARAMETER Entry
    File records with their owning model, from Get-KitStageEntry.

    .PARAMETER SkipPath
    Manifest paths to leave out because they are not valid names.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$SkipPath
    )
    $problemCount = $SkipPath.Count
    foreach ($item in $Entry) {
        $record = $item.Record
        if ($SkipPath.Contains([string]$record.path)) { continue }
        $problem = Get-KitStageFileProblem -Root $Root -Record $record
        if ($problem) {
            $problemCount++
            ConvertTo-KitFirmwareFinding -Status Fail -Check $problem.Check -Message $problem.Message -Path ([string]$record.path) -Group ([string]$record.group)
        }
    }
    if ($problemCount -eq 0) {
        ConvertTo-KitFirmwareFinding -Status Pass -Check Files -Message ('{0} files present' -f @($Entry).Count)
        ConvertTo-KitFirmwareFinding -Status Pass -Check Hash -Message ('{0} files hash OK' -f @($Entry).Count)
    }
}

function Test-KitStageDuplicate {
    <#
    .SYNOPSIS
    Check that no two records send different content to one destination.

    .DESCRIPTION
    Private check of Test-FirmwareStage. Destinations are compared case-insensitively. Records with the same
    destination and the same SHA-256 are fine (two models may share a file); different content is one Fail that names
    the path and both model ids.

    .PARAMETER Entry
    File records with their owning model, from Get-KitStageEntry.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry
    )
    $byPath = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Entry) {
        $key = ([string]$item.Record.path).ToLowerInvariant()
        if (-not $byPath.ContainsKey($key)) {
            $byPath[$key] = [System.Collections.Generic.List[object]]::new()
            $order.Add($key)
        }
        $byPath[$key].Add($item)
    }
    $problemCount = 0
    foreach ($key in $order) {
        $same = $byPath[$key]
        $first = $same[0]
        foreach ($other in $same) {
            if ([string]$other.Record.sha256 -ne [string]$first.Record.sha256) {
                $problemCount++
                ConvertTo-KitFirmwareFinding -Status Fail -Check Duplicate -Message ('different content for one path: {0} and {1}' -f $first.ModelId, $other.ModelId) -Path ([string]$first.Record.path) -Group ([string]$first.Record.group)
                break
            }
        }
    }
    if ($problemCount -eq 0) {
        ConvertTo-KitFirmwareFinding -Status Pass -Check Duplicate -Message 'no path has two different contents'
    }
}

function Test-KitStageFolder {
    <#
    .SYNOPSIS
    Check that closed group folders hold only the files the manifest lists.

    .DESCRIPTION
    Private check of Test-FirmwareStage. Every file at any depth inside a closed group folder must be a manifest path
    (compared case-insensitively); any other file is a Fail named by its root-relative path. Open groups, and anything
    outside the closed folders, are not looked at here.

    .PARAMETER Root
    The stick root.

    .PARAMETER Manifest
    The parsed manifest.

    .PARAMETER Entry
    File records with their owning model, from Get-KitStageEntry.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [object]$Manifest,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry
    )
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Entry) { $null = $listed.Add([string]$item.Record.path) }
    $prefix = $Root.TrimEnd('\') + '\'
    $problemCount = 0
    foreach ($folder in Get-KitClosedFolder -Manifest $Manifest) {
        $full = Join-Path -Path $Root -ChildPath $folder
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $full -Recurse -File -Force) {
            $relative = $file.FullName.Substring($prefix.Length)
            if (-not $listed.Contains($relative)) {
                $problemCount++
                ConvertTo-KitFirmwareFinding -Status Fail -Check Folders -Message 'unexpected file' -Path $relative
            }
        }
    }
    if ($problemCount -eq 0) {
        ConvertTo-KitFirmwareFinding -Status Pass -Check Folders -Message 'closed folders hold only listed files'
    }
}

function Test-KitStageRoot {
    <#
    .SYNOPSIS
    Warn about root entries that neither the manifest nor Windows account for.

    .DESCRIPTION
    Private check of Test-FirmwareStage. Allowed at the stick root: the first folder of every group, the first folder of
    every listed path, firmware-manifest.json, READY, kit, results, System Volume Information and $RECYCLE.BIN. Every
    other entry is a Warn naming it. Never a Fail: Windows adds entries of its own to a FAT32 stick.

    .PARAMETER Root
    The stick root.

    .PARAMETER Manifest
    The parsed manifest.

    .PARAMETER Entry
    File records with their owning model, from Get-KitStageEntry.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [object]$Manifest,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry
    )
    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in 'firmware-manifest.json', 'READY', 'kit', 'results', 'System Volume Information', '$RECYCLE.BIN') { $null = $allowed.Add($name) }
    foreach ($group in $Manifest.groups) { $null = $allowed.Add(([string]$group.folder).Split('\')[0]) }
    foreach ($item in $Entry) { $null = $allowed.Add(([string]$item.Record.path).Split('\')[0]) }
    $problemCount = 0
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force | Sort-Object -Property Name) {
        if (-not $allowed.Contains($item.Name)) {
            $problemCount++
            ConvertTo-KitFirmwareFinding -Status Warn -Check Root -Message 'unexpected entry at the stick root' -Path $item.Name
        }
    }
    if ($problemCount -eq 0) {
        ConvertTo-KitFirmwareFinding -Status Pass -Check Root -Message 'stick root holds only expected entries'
    }
}

function Test-KitStagePassword {
    <#
    .SYNOPSIS
    Fail when a firmware password file is anywhere on the stick.

    .DESCRIPTION
    Private check of Test-FirmwareStage. A file named *Pswd*.bin or password.bin (any case, any folder) is a Fail named by
    its root-relative path: such a file is generated from a password and must never travel on a stick.

    .PARAMETER Root
    The stick root.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    $prefix = $Root.TrimEnd('\') + '\'
    $problemCount = 0
    foreach ($file in Get-KitStickFile -Root $Root) {
        if ($file.Name -like '*Pswd*.bin' -or $file.Name -eq 'password.bin') {
            $problemCount++
            ConvertTo-KitFirmwareFinding -Status Fail -Check Password -Message 'password file must not be on the stick' -Path $file.FullName.Substring($prefix.Length)
        }
    }
    if ($problemCount -eq 0) {
        ConvertTo-KitFirmwareFinding -Status Pass -Check Password -Message 'no password file on the stick'
    }
}

function Test-KitStageReady {
    <#
    .SYNOPSIS
    Check the READY marker against the manifest.

    .DESCRIPTION
    Private check of Test-FirmwareStage. READY must exist at the stick root and its first line must be the lower-case
    SHA-256 of firmware-manifest.json. A missing or stale marker means the stick was not finished or was changed after.

    .PARAMETER Root
    The stick root.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    $marker = Join-Path -Path $Root -ChildPath 'READY'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        return ConvertTo-KitFirmwareFinding -Status Fail -Check Ready -Message 'READY marker missing: the build did not finish'
    }
    $expected = (Get-FileHash -LiteralPath (Join-Path -Path $Root -ChildPath 'firmware-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $first = [string](Get-Content -LiteralPath $marker -TotalCount 1)
    if ($first.Trim() -cne $expected) {
        return ConvertTo-KitFirmwareFinding -Status Fail -Check Ready -Message 'READY marker does not match the manifest'
    }
    ConvertTo-KitFirmwareFinding -Status Pass -Check Ready -Message 'READY marker matches the manifest'
}

function Get-KitStageNote {
    <#
    .SYNOPSIS
    Warn about what the manifest itself says is unproven or conditional.

    .DESCRIPTION
    Private check of Test-FirmwareStage. One Warn when the layout is not bench-verified (with the number of unverified
    folders), one Warn per model whose platform id is not verified, and one Warn per model whose latest BIOS needs a
    minimum BIOS first.

    .PARAMETER Manifest
    The parsed manifest.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest
    )
    if ($Manifest.verified -eq $false) {
        $total = 0
        $unverified = 0
        foreach ($group in $Manifest.groups) {
            $total++
            if ($group.verified -ne $true) { $unverified++ }
        }
        ConvertTo-KitFirmwareFinding -Status Warn -Check Layout -Message ("not bench-verified: $unverified of $total folders unverified (FW-06 open)")
    }
    foreach ($model in $Manifest.models) {
        if ($model.platformVerified -eq $false) {
            ConvertTo-KitFirmwareFinding -Status Warn -Check Notes -Message ("model $($model.modelId): platform $($model.platformId) not verified on hardware")
        }
        $bios = $model.latestBios
        if ($bios -and $bios.dependencyMinimum) {
            ConvertTo-KitFirmwareFinding -Status Warn -Check Notes -Message ("model $($model.modelId): BIOS $($bios.version) needs BIOS $($bios.dependencyMinimum) or newer first")
        }
    }
}

function Limit-KitFirmwareFinding {
    <#
    .SYNOPSIS
    Cap the detail findings per check so a wiped stick does not flood a phone screen.

    .DESCRIPTION
    Private helper of Test-FirmwareStage. Pass findings are kept. For every check, the first Maximum Warn or Fail
    findings are kept and the rest collapse into one finding 'and N more' (a Fail when any collapsed finding was a Fail).

    .PARAMETER Finding
    The findings, in output order.

    .PARAMETER Maximum
    Detail findings kept per check.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [ValidateRange(1, 100)]
        [int]$Maximum = 10
    )
    $count = @{}
    $overflow = [ordered]@{}
    foreach ($item in $Finding) {
        if ($item.Status -eq 'Pass') {
            $item
            continue
        }
        $count[$item.Check] = 1 + [int]$count[$item.Check]
        if ($count[$item.Check] -le $Maximum) {
            $item
        }
        else {
            if (-not $overflow.Contains($item.Check)) { $overflow[$item.Check] = [System.Collections.Generic.List[object]]::new() }
            $overflow[$item.Check].Add($item)
        }
    }
    foreach ($check in $overflow.Keys) {
        $status = if (@($overflow[$check] | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { 'Fail' } else { 'Warn' }
        ConvertTo-KitFirmwareFinding -Status $status -Check $check -Message ('and {0} more' -f $overflow[$check].Count)
    }
}

function Test-FirmwareTarget {
    <#
    .SYNOPSIS
    Check that a path is the root of a FAT32 volume, the only kind of target a Tools stick may use.

    .DESCRIPTION
    Refuses a volume whose file system is not FAT32 with a Fail that names the volume root and the file system found;
    this tool never formats a volume. A path that is not a volume root, does not exist or has no volume is a Fail. FAT32
    on a disk that Windows reports as fixed is a Warn, because some USB sticks report that way. -AllowFolder skips every
    volume check with one Warn, for staging into a plain folder.

    .PARAMETER Path
    The target, for example E:\.

    .PARAMETER AllowFolder
    Accept any folder. Nothing is asked of the drive.

    .EXAMPLE
    Test-FirmwareTarget -Path E:\
    Returns a Pass for a FAT32 stick in E: and a Fail naming the file system otherwise.

    .OUTPUTS
    Kit.FirmwareFinding
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowFolder
    )
    if ($AllowFolder) {
        return ConvertTo-KitFirmwareFinding -Status Warn -Check Volume -Message 'folder target: FAT32 and label checks skipped'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return ConvertTo-KitFirmwareFinding -Status Fail -Check Volume -Message "target $Path not found"
    }
    $info = Get-KitVolumeInfo -Path $Path
    if (-not $info) {
        return ConvertTo-KitFirmwareFinding -Status Fail -Check Volume -Message "no volume found for $Path (not a drive letter, or the drive is not ready)"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    if ($resolved -ne ([string]$info.Root).TrimEnd('\')) {
        return ConvertTo-KitFirmwareFinding -Status Fail -Check Volume -Message "$Path is not a volume root; give the drive root, for example $($info.Root)"
    }
    if ([string]$info.FileSystem -ne 'FAT32') {
        return ConvertTo-KitFirmwareFinding -Status Fail -Check Volume -Message "volume $($info.Root) is $($info.FileSystem); the Tools stick must be FAT32 (this tool never formats it)"
    }
    if (-not $info.IsRemovable) {
        return ConvertTo-KitFirmwareFinding -Status Warn -Check Volume -Message "volume $($info.Root) is FAT32 but reported as a fixed disk; check it is the Tools stick"
    }
    ConvertTo-KitFirmwareFinding -Status Pass -Check Volume -Message "FAT32 volume at $($info.Root)"
}

function Test-FirmwareStage {
    <#
    .SYNOPSIS
    Prove that a Tools stick matches its own firmware-manifest.json.

    .DESCRIPTION
    Reads the manifest at the stick root and takes the list of expected files from it alone. Checks the target volume
    and its label, the manifest keys, the FAT32 name rules, that every file exists with the manifest size, SHA-256 and
    vendor hash, that no destination has two contents, that closed group folders hold nothing else, the stick root, any
    password file, and the READY marker. Each problem is one finding whose Path is the manifest path of the file. At
    most 10 detail findings are returned per check. A stick with no readable manifest gives a Fail; this function
    never throws for a bad stick.

    .PARAMETER Path
    The stick root, for example E:\.

    .PARAMETER AllowFolder
    Validate a plain folder: the FAT32 and label checks are skipped (one Warn).

    .PARAMETER IgnoreReadyMarker
    Skip the READY check, for a stick that is still being written.

    .EXAMPLE
    Test-FirmwareStage -Path E:\ | Where-Object Status -EQ 'Fail'
    Lists what is wrong with the stick in E:.

    .OUTPUTS
    Kit.FirmwareFinding: Status (Pass, Warn or Fail), Check, Message, Path, Group.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowFolder,

        [switch]$IgnoreReadyMarker
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    $requiredKey = 'schemaVersion', 'toolVersion', 'builtUtc', 'vendor', 'volumeLabel', 'fileSystem', 'verified', 'groups', 'models', 'shared'
    try {
        foreach ($item in Test-FirmwareTarget -Path $Path -AllowFolder:$AllowFolder) { $findings.Add($item) }

        $manifest = $null
        try {
            $manifest = Read-KitFirmwareManifest -Path $Path
        }
        catch {
            $findings.Add((ConvertTo-KitFirmwareFinding -Status Fail -Check Manifest -Message $_.Exception.Message))
        }

        if ($manifest) {
            $missingKey = @($requiredKey | Where-Object { $manifest.PSObject.Properties.Name -notcontains $_ })
            foreach ($key in $missingKey) {
                $findings.Add((ConvertTo-KitFirmwareFinding -Status Fail -Check Manifest -Message "firmware-manifest.json is missing the key '$key'"))
            }
            if ($missingKey.Count -eq 0) {
                $root = (Resolve-Path -LiteralPath $Path).ProviderPath
                $entry = @(Get-KitStageEntry -Manifest $manifest)

                if (-not $AllowFolder) {
                    $info = Get-KitVolumeInfo -Path $Path
                    if ($info -and [string]$info.Label -ne [string]$manifest.volumeLabel) {
                        $findings.Add((ConvertTo-KitFirmwareFinding -Status Fail -Check Volume -Message "volume label '$($info.Label)' differs from the manifest label '$($manifest.volumeLabel)'"))
                    }
                    elseif ($info) {
                        $findings.Add((ConvertTo-KitFirmwareFinding -Status Pass -Check Volume -Message "volume label $($info.Label) matches"))
                    }
                }

                $nameFinding = @(Test-KitStageName -Entry $entry)
                $skip = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($item in $nameFinding) {
                    $findings.Add($item)
                    if ($item.Status -eq 'Fail' -and $item.Message -like 'not valid on FAT32*') { $null = $skip.Add($item.Path) }
                }
                foreach ($item in Test-KitStageFile -Root $root -Entry $entry -SkipPath $skip) { $findings.Add($item) }
                foreach ($item in Test-KitStageDuplicate -Entry $entry) { $findings.Add($item) }
                foreach ($item in Test-KitStageFolder -Root $root -Manifest $manifest -Entry $entry) { $findings.Add($item) }
                foreach ($item in Test-KitStageRoot -Root $root -Manifest $manifest -Entry $entry) { $findings.Add($item) }
                foreach ($item in Test-KitStagePassword -Root $root) { $findings.Add($item) }
                if (-not $IgnoreReadyMarker) {
                    foreach ($item in Test-KitStageReady -Root $root) { $findings.Add($item) }
                }
                foreach ($item in Get-KitStageNote -Manifest $manifest) { $findings.Add($item) }
            }
        }
    }
    catch {
        $findings.Add((ConvertTo-KitFirmwareFinding -Status Fail -Check Manifest -Message "validation stopped: $($_.Exception.Message)"))
    }
    Limit-KitFirmwareFinding -Finding $findings.ToArray()
}

function ConvertTo-KitFirmwareLine {
    <#
    .SYNOPSIS
    Turn one finding into console lines no longer than a given width.

    .DESCRIPTION
    Private pure function behind Show-FirmwareStageFinding. The first line starts with [PASS], [WARN] or [FAIL]; the message
    wraps at word boundaries with a continuation indent as wide as that prefix, and a single word longer than the line is
    split. A finding path goes on its own line, indented two spaces; a path that is too long loses characters from the left
    behind '...', which keeps the file name whenever it fits.

    .PARAMETER Finding
    A Kit.FirmwareFinding.

    .PARAMETER Width
    The longest line allowed, from 20 to 120 characters.

    .OUTPUTS
    The lines, in order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Finding,

        [ValidateRange(20, 120)]
        [int]$Width = 44
    )
    $prefix = '[{0}] ' -f ([string]$Finding.Status).ToUpperInvariant()
    $available = $Width - $prefix.Length
    $content = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in (([string]$Finding.Message) -split ' ' | Where-Object { $_ -ne '' })) {
        $rest = $word
        while ($rest.Length -gt $available) {
            if ($current.Length -gt 0) {
                $content.Add($current)
                $current = ''
            }
            $content.Add($rest.Substring(0, $available))
            $rest = $rest.Substring($available)
        }
        if ($current.Length -eq 0) {
            $current = $rest
        }
        elseif (($current.Length + 1 + $rest.Length) -le $available) {
            $current = "$current $rest"
        }
        else {
            $content.Add($current)
            $current = $rest
        }
    }
    if ($current.Length -gt 0 -or $content.Count -eq 0) { $content.Add($current) }

    $indent = ' ' * $prefix.Length
    for ($index = 0; $index -lt $content.Count; $index++) {
        if ($index -eq 0) { ($prefix + $content[$index]).TrimEnd() } else { $indent + $content[$index] }
    }
    $path = [string]$Finding.Path
    if ($path) {
        $line = '  ' + $path
        if ($line.Length -gt $Width) { $line = '  ...' + $path.Substring($path.Length - ($Width - 5)) }
        $line
    }
}

function Show-FirmwareStageFinding {
    <#
    .SYNOPSIS
    Print validator findings as coloured console lines.

    .DESCRIPTION
    The one place in the core module that writes to the host. Each finding starts with [PASS] in green, [WARN] in yellow
    or [FAIL] in red; a finding that names a file adds a second, indented line with the manifest path. No line is longer
    than -Width, so the output fits a phone photo of the screen.

    .PARAMETER Finding
    Findings from Test-FirmwareStage or Test-FirmwareTarget.

    .PARAMETER Width
    The longest line to write, from 20 to 120 characters. The default is 44.

    .EXAMPLE
    Show-FirmwareStageFinding -Finding (Test-FirmwareStage -Path E:\)
    Prints the verdict for the stick in E:.

    .OUTPUTS
    None. Writes to the host.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Finding,

        [ValidateRange(20, 120)]
        [int]$Width = 44
    )
    foreach ($item in $Finding) {
        $color = switch ($item.Status) {
            'Pass' { 'Green' }
            'Warn' { 'Yellow' }
            default { 'Red' }
        }
        foreach ($line in ConvertTo-KitFirmwareLine -Finding $item -Width $Width) {
            Write-Host -Object $line -ForegroundColor $color
        }
    }
}
