# Firmware layout loader. Dot-sourced by Kit.Core.psm1. A layout is a data file that says which folders a Tools stick has,
# where each folder's files come from and whether the folder has been proven on hardware. It is read with
# Import-PowerShellDataFile only, so code inside a layout file never runs. Pure: nothing here writes.

function Get-KitLayoutKeyProblem {
    <#
    .SYNOPSIS
    Compare the keys of a layout table with the keys the schema allows.

    .DESCRIPTION
    Private helper of Get-KitLayoutProblem. A missing required key is reported before an unknown key.

    .PARAMETER Table
    The table to check.

    .PARAMETER Required
    Keys that must be present.

    .PARAMETER Optional
    Keys that may be present.

    .PARAMETER Label
    How the table is called in the message, for example "group 'G-New'".

    .OUTPUTS
    One sentence naming the first problem, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Table,

        [Parameter(Mandatory)]
        [string[]]$Required,

        [string[]]$Optional = @(),

        [Parameter(Mandatory)]
        [string]$Label
    )
    foreach ($key in $Required) {
        if (-not $Table.ContainsKey($key)) { return "$Label is missing key '$key'" }
    }
    foreach ($key in $Table.Keys) {
        if (($Required + $Optional) -notcontains [string]$key) { return "$Label has unknown key '$key'" }
    }
}

function Get-KitLayoutProblem {
    <#
    .SYNOPSIS
    Check loaded layout data against the schema and return the first problem.

    .DESCRIPTION
    Private helper of Get-KitFirmwareLayout. Order: top-level keys, SchemaVersion, VolumeLabel, FileSystem, Groups (each
    group in file order: keys, Id, Folder, Source, Closed, Default, Verified), then Captures. The Folder rule is the same
    FAT32 path rule the stage validator applies to staged files.

    .PARAMETER Data
    The hashtable Import-PowerShellDataFile returned.

    .OUTPUTS
    One sentence naming the first problem, or nothing when the data is a valid layout.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Data
    )
    $problem = Get-KitLayoutKeyProblem -Table $Data -Required 'SchemaVersion', 'VolumeLabel', 'FileSystem', 'Groups' -Optional 'Captures' -Label 'the layout'
    if ($problem) { return $problem }
    if ($Data.SchemaVersion -isnot [int] -or $Data.SchemaVersion -ne 1) { return "key 'SchemaVersion' must be 1" }
    if ($Data.VolumeLabel -isnot [string] -or $Data.VolumeLabel -cnotmatch '^[A-Za-z0-9_-]{1,11}$') {
        return "key 'VolumeLabel' must be 1 to 11 letters, digits, underscores or hyphens"
    }
    if ($Data.FileSystem -isnot [string] -or $Data.FileSystem -cne 'FAT32') { return "key 'FileSystem' must be FAT32" }
    if ($Data.Groups -isnot [array] -or $Data.Groups.Count -eq 0) { return "key 'Groups' must be a non-empty list of groups" }
    if ($Data.ContainsKey('Captures') -and $Data.Captures -isnot [array]) { return "key 'Captures' must be a list" }

    $captureName = @()
    foreach ($capture in $Data.Captures) {
        if ($capture -is [hashtable] -and $capture.Name -is [string]) { $captureName += $capture.Name }
    }

    $seenId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($group in $Data.Groups) {
        if ($group -isnot [hashtable]) { return "every entry of 'Groups' must be a table" }
        $label = "group '$($group.Id)'"
        $problem = Get-KitLayoutKeyProblem -Table $group -Required 'Id', 'Folder', 'Source', 'Closed', 'Default', 'Verified' -Label $label
        if ($problem) { return $problem }
        if ($group.Id -isnot [string] -or $group.Id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return "$label has a bad key 'Id' (letters, digits, dot, underscore, hyphen)" }
        if (-not $seenId.Add($group.Id)) { return "$label is a duplicate Id (Ids are compared without case)" }

        $source = $group.Source
        $isCaptured = ($source -is [string]) -and ($source -cmatch '^Captured:')
        if ($group.Folder -isnot [string]) { return "$label key 'Folder' must be text" }
        $folder = $group.Folder
        if ($folder.Contains('{Platform}')) {
            if ($isCaptured) { return "$label key 'Folder' must not use {Platform}: a captured tree is not per model" }
            $folder = $folder.Replace('{Platform}', '0000')
        }
        if ($folder.Contains('{') -or $folder.Contains('}')) { return "$label key 'Folder' has a token other than {Platform}" }
        if ($folder.EndsWith('\')) { return "$label key 'Folder' must not end with a backslash" }
        $folderProblem = @(Get-KitStagePathProblem -RelativePath $folder)
        if ($folderProblem.Count -gt 0) { return "$label key 'Folder' is not a stick-relative FAT32 path: $($folderProblem -join '; ')" }

        if ($source -isnot [string]) { return "$label key 'Source' must be text" }
        if ($isCaptured) {
            if ($captureName -notcontains $source.Substring('Captured:'.Length)) {
                return "$label key 'Source' is '$source' but Captures has no capture with that name"
            }
        }
        elseif ($source -cnotin 'BiosImage', 'FlashImage', 'WindowsFlashTool') {
            return "$label key 'Source' is '$source' (use BiosImage, FlashImage, WindowsFlashTool or Captured:<name>)"
        }
        if ($group.Closed -isnot [bool]) { return "$label key 'Closed' must be `$true or `$false" }
        if ($group.Default -isnot [bool]) { return "$label key 'Default' must be `$true or `$false" }

        if ($group.Verified -isnot [hashtable]) { return "$label key 'Verified' must be a table" }
        $problem = Get-KitLayoutKeyProblem -Table $group.Verified -Required 'Status', 'Model', 'Bios', 'Date', 'By' -Label "$label Verified block"
        if ($problem) { return $problem }
        $verified = $group.Verified
        if ($verified.Status -isnot [bool]) { return "$label Verified key 'Status' must be `$true or `$false" }
        if ($verified.Model -isnot [array]) { return "$label Verified key 'Model' must be a list of model ids" }
        foreach ($model in $verified.Model) {
            if ($model -isnot [string]) { return "$label Verified key 'Model' must hold text only" }
        }
        foreach ($name in 'Bios', 'Date', 'By') {
            if ($verified[$name] -isnot [string]) { return "$label Verified key '$name' must be text" }
        }
        if ($verified.Status) {
            if ($verified.Model.Count -eq 0) { return "$label is verified but Verified key 'Model' is empty" }
            if (-not $verified.Bios) { return "$label is verified but Verified key 'Bios' is empty" }
            if (-not $verified.By) { return "$label is verified but Verified key 'By' is empty" }
            if ($verified.Date -cnotmatch '^\d{4}-\d{2}-\d{2}$') { return "$label is verified but Verified key 'Date' is not yyyy-MM-dd" }
        }
    }

    $seenCapture = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($capture in $Data.Captures) {
        if ($capture -isnot [hashtable]) { return "every entry of 'Captures' must be a table" }
        $label = "capture '$($capture.Name)'"
        $problem = Get-KitLayoutKeyProblem -Table $capture -Required 'Name', 'PackageId', 'Version', 'Snapshot' -Label $label
        if ($problem) { return $problem }
        foreach ($name in 'Name', 'PackageId', 'Version', 'Snapshot') {
            if ($capture[$name] -isnot [string] -or -not $capture[$name]) { return "$label key '$name' must be non-empty text" }
        }
        if ($capture.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return "$label has a bad key 'Name' (letters, digits, dot, underscore, hyphen)" }
        if (-not $seenCapture.Add($capture.Name)) { return "$label is a duplicate Name" }
        $snapshotProblem = @(Get-KitStagePathProblem -RelativePath $capture.Snapshot)
        if ($snapshotProblem.Count -gt 0) { return "$label key 'Snapshot' is not a relative path: $($snapshotProblem -join '; ')" }
    }
}

function Get-KitFirmwareLayout {
    <#
    .SYNOPSIS
    Load and validate a firmware layout file.

    .DESCRIPTION
    A layout is a data file (.psd1) with SchemaVersion, VolumeLabel, FileSystem, an optional Captures list and a Groups
    list. Each group has Id, Folder, Source (BiosImage, FlashImage, WindowsFlashTool or Captured:<capture name>), Closed,
    Default and a Verified block (Status, Model, Bios, Date, By) that records whether the folder was proven on hardware.
    The file is read with Import-PowerShellDataFile, so a file that contains code is refused and the code never runs.
    Every schema violation throws one message that names the file and the problem. Groups keep the order of the file.

    .PARAMETER Path
    The layout file.

    .EXAMPLE
    (Get-KitFirmwareLayout -Path .\fixture.layout.psd1).Groups | Where-Object Default
    Lists the groups a normal build stages.

    .OUTPUTS
    Kit.FirmwareLayout: Path, SchemaVersion, VolumeLabel, FileSystem, Groups (Id, Folder, Source, SourceKind, CaptureName,
    Closed, Default, Verified) and Captures (Name, PackageId, Version, Snapshot, SnapshotPath).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Layout $Path not found." }
    $file = (Resolve-Path -LiteralPath $Path).ProviderPath
    try {
        $data = Import-PowerShellDataFile -LiteralPath $file
    }
    catch {
        throw "Layout $file is not a plain data file: $($_.Exception.Message)"
    }
    if ($data -isnot [hashtable]) { throw "Layout ${file}: the file must hold one table" }
    $problem = Get-KitLayoutProblem -Data $data
    if ($problem) { throw "Layout ${file}: $problem" }

    $groups = foreach ($group in $data.Groups) {
        $capture = ''
        if ($group.Source -cmatch '^Captured:(.+)$') {
            $kind = 'Captured'
            $wanted = $Matches[1]
            $capture = ($data.Captures | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1).Name
        }
        else {
            $kind = $group.Source
        }
        [pscustomobject]@{
            Id          = $group.Id
            Folder      = $group.Folder
            Source      = $group.Source
            SourceKind  = $kind
            CaptureName = $capture
            Closed      = $group.Closed
            Default     = $group.Default
            Verified    = [pscustomobject]@{
                Status = $group.Verified.Status
                Model  = [string[]]@($group.Verified.Model)
                Bios   = $group.Verified.Bios
                Date   = $group.Verified.Date
                By     = $group.Verified.By
            }
        }
    }
    $folder = Split-Path -Path $file -Parent
    $captures = foreach ($capture in $data.Captures) {
        [pscustomobject]@{
            Name         = $capture.Name
            PackageId    = $capture.PackageId
            Version      = $capture.Version
            Snapshot     = $capture.Snapshot
            SnapshotPath = Join-Path -Path $folder -ChildPath $capture.Snapshot
        }
    }
    [pscustomobject]@{
        PSTypeName    = 'Kit.FirmwareLayout'
        Path          = $file
        SchemaVersion = $data.SchemaVersion
        VolumeLabel   = $data.VolumeLabel
        FileSystem    = $data.FileSystem
        Groups        = @($groups)
        Captures      = @($captures)
    }
}
