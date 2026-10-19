# Capture and replay of a tree that cannot be fetched silently. Dot-sourced by Kit.Core.psm1. Such a tree is captured once by
# hand on a bench PC, recorded as a data file (relative path, size and SHA-256 of every file), reviewed and committed.
# At build time the captured tree is replayed from that record: a changed, missing or extra file stops the build. Nothing
# here runs a captured file, and no folder or file name of any vendor appears in this file.

function Get-KitCaptureFile {
    <#
    .SYNOPSIS
    List the files of a captured tree with their tree-relative paths, sizes and SHA-256.

    .DESCRIPTION
    Private helper of New-KitFirmwareSnapshot and Resolve-KitCaptureEntry. The tree root corresponds to the stick root.
    The two first-level folders Windows keeps for itself are left out. Files are sorted by path, ordinal and
    case-insensitive, so the order does not depend on the machine.

    .PARAMETER Root
    The folder that holds the captured tree.

    .PARAMETER Cache
    A hashtable that keeps hashes between calls.

    .OUTPUTS
    RelativePath, FullName, Size and Sha256 for each file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [hashtable]$Cache = @{}
    )
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-KitStickFile -Root $full) {
        $list.Add([pscustomobject]@{
                RelativePath = $file.FullName.Substring($full.Length + 1)
                FullName     = $file.FullName
                Size         = [long]$file.Length
                Sha256       = Get-KitCachedHash -Path $file.FullName -Algorithm SHA256 -Cache $Cache
            })
    }
    $list.Sort([System.Comparison[object]] {
            param($left, $right)
            [string]::Compare($left.RelativePath, $right.RelativePath, [System.StringComparison]::OrdinalIgnoreCase)
        })
    $list.ToArray()
}

function New-KitFirmwareSnapshot {
    <#
    .SYNOPSIS
    Record a captured tree as a data file: relative path, size and SHA-256 of every file.

    .DESCRIPTION
    Run once on the bench after the tree has been captured. The snapshot is pure ASCII with no time stamp, files sorted by
    path, so recording the same tree twice gives the same bytes and a change shows as a clean diff to review before it is
    committed. Publish-FirmwareStage replays the snapshot at build time. The files of the two first-level folders Windows
    keeps for itself are not recorded. Throws, naming the file or folder, for a missing folder, a tree without a file, a
    file name outside ASCII, a path that cannot exist on FAT32, or a Name that is not letters, digits, dot, underscore or
    hyphen.

    .PARAMETER SourcePath
    The folder that holds the captured tree; its root corresponds to the stick root.

    .PARAMETER Name
    The capture name as the layout writes it.

    .PARAMETER Path
    The snapshot file to write.

    .PARAMETER PassThru
    Return Path, Name and FileCount.

    .EXAMPLE
    New-KitFirmwareSnapshot -SourcePath D:\capture -Name fx-diag -Path .\fx-diag.snapshot.psd1
    Records the tree in D:\capture.

    .OUTPUTS
    Kit.FirmwareSnapshot with -PassThru; nothing otherwise.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$PassThru
    )
    if ($Name -cnotmatch '^[A-Za-z0-9._-]+$') { throw "Name '$Name' may hold only letters, digits, dot, underscore and hyphen" }
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw "SourcePath $SourcePath not found; give the folder that holds the captured tree" }

    $file = @(Get-KitCaptureFile -Root $SourcePath)
    if ($file.Count -eq 0) { throw "SourcePath $SourcePath holds no file" }
    foreach ($item in $file) {
        if ($item.RelativePath -cmatch '[^\x20-\x7E]') { throw "File $($item.RelativePath) has a character outside ASCII in its name" }
        $problem = @(Get-KitStagePathProblem -RelativePath $item.RelativePath -Size $item.Size)
        if ($problem.Count -gt 0) { throw "File $($item.RelativePath) is not valid on FAT32: $($problem -join '; ')" }
    }

    $line = [System.Collections.Generic.List[string]]::new()
    $line.Add("# Recorded capture ${Name}: relative path, size and SHA-256 of every file. Review the diff before committing.")
    $line.Add('@{')
    $line.Add('    SchemaVersion = 1')
    $line.Add("    Name          = '$Name'")
    $line.Add('    Files         = @(')
    foreach ($item in $file) {
        $quoted = $item.RelativePath.Replace("'", "''")
        $line.Add(("        @{{ Path = '{0}'; Size = {1}; Sha256 = '{2}' }}" -f $quoted, $item.Size, $item.Sha256))
    }
    $line.Add('    )')
    $line.Add('}')
    $text = ($line -join "`n") + "`n"

    $target = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if ($PSCmdlet.ShouldProcess($target, 'Record capture snapshot')) {
        $null = New-Item -Path (Split-Path -Path $target -Parent) -ItemType Directory -Force
        [System.IO.File]::WriteAllText($target, $text, [System.Text.Encoding]::ASCII)
    }
    if ($PassThru) {
        [pscustomobject]@{ PSTypeName = 'Kit.FirmwareSnapshot'; Path = $target; Name = $Name; FileCount = $file.Count }
    }
}

function Read-KitFirmwareSnapshot {
    <#
    .SYNOPSIS
    Read and validate a recorded capture snapshot.

    .DESCRIPTION
    Private helper of Resolve-KitCaptureEntry. The file is read with Import-PowerShellDataFile only, so code in it never
    runs. Keys are exactly SchemaVersion, Name and Files; SchemaVersion is 1; Name equals the capture name; Files is not
    empty and each file has exactly Path, Size and Sha256 (64 lower-case hex characters); every path is valid on FAT32 and
    appears once (compared without case). Every message starts with FW-05.

    .PARAMETER Path
    The snapshot file.

    .PARAMETER Name
    The capture name the snapshot must be for.

    .OUTPUTS
    Path, Size and Sha256 for each recorded file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path
    }
    catch {
        throw "FW-05: snapshot $Path is not a plain data file: $($_.Exception.Message)"
    }
    if ($data -isnot [hashtable]) { throw "FW-05: snapshot ${Path}: the file must hold one table" }
    $problem = Get-KitLayoutKeyProblem -Table $data -Required 'SchemaVersion', 'Name', 'Files' -Label 'the snapshot'
    if ($problem) { throw "FW-05: snapshot ${Path}: $problem" }
    if ($data.SchemaVersion -isnot [int] -or $data.SchemaVersion -ne 1) { throw "FW-05: snapshot ${Path}: key 'SchemaVersion' must be 1" }
    if ($data.Name -isnot [string] -or $data.Name -cne $Name) { throw "FW-05: snapshot $Path is for the capture '$($data.Name)', not '$Name'" }
    if ($data.Files -isnot [array] -or $data.Files.Count -eq 0) { throw "FW-05: snapshot ${Path}: key 'Files' must be a non-empty list" }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $data.Files) {
        if ($file -isnot [hashtable]) { throw "FW-05: snapshot ${Path}: every entry of 'Files' must be a table" }
        $problem = Get-KitLayoutKeyProblem -Table $file -Required 'Path', 'Size', 'Sha256' -Label "snapshot file '$($file.Path)'"
        if ($problem) { throw "FW-05: snapshot ${Path}: $problem" }
        if ($file.Path -isnot [string]) { throw "FW-05: snapshot ${Path}: a file Path must be text" }
        $pathProblem = @(Get-KitStagePathProblem -RelativePath $file.Path)
        if ($pathProblem.Count -gt 0) { throw "FW-05: snapshot ${Path}: path '$($file.Path)' is not valid: $($pathProblem -join '; ')" }
        if ($file.Size -isnot [int] -and $file.Size -isnot [long]) { throw "FW-05: snapshot ${Path}: file '$($file.Path)' has a Size that is not a whole number" }
        if ($file.Size -lt 0) { throw "FW-05: snapshot ${Path}: file '$($file.Path)' has a negative Size" }
        if ($file.Sha256 -isnot [string] -or $file.Sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "FW-05: snapshot ${Path}: file '$($file.Path)' has a Sha256 that is not 64 lower-case hex characters"
        }
        if (-not $seen.Add($file.Path)) { throw "FW-05: snapshot ${Path}: the path '$($file.Path)' appears twice (compared without case)" }
        [pscustomobject]@{ Path = $file.Path; Size = [long]$file.Size; Sha256 = $file.Sha256 }
    }
}

function Resolve-KitCaptureEntry {
    <#
    .SYNOPSIS
    Replay a recorded capture: check the captured tree against its snapshot and return one entry per file.

    .DESCRIPTION
    Private helper of Get-KitStagePlan. Stops with a message that starts with FW-05 when the capture path is missing,
    is not a folder, the snapshot is absent or invalid, a snapshot path lies outside the group folder, a recorded file is
    missing or has another size or SHA-256, or the capture holds a file the snapshot does not list. The two first-level
    folders Windows keeps for itself are ignored.

    .PARAMETER Layout
    The Kit.FirmwareLayout.

    .PARAMETER Group
    A captured group of the layout.

    .PARAMETER CapturePath
    Capture name to the folder that holds the captured tree.

    .PARAMETER Cache
    A hashtable that keeps hashes between calls.

    .OUTPUTS
    RelativePath, SourcePath, Group, Size, Sha256 and VendorHash (always $null) for each file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Layout,

        [Parameter(Mandatory)]
        [pscustomobject]$Group,

        [Parameter(Mandatory)]
        [hashtable]$CapturePath,

        [hashtable]$Cache = @{}
    )
    $capture = $Layout.Captures | Where-Object { $_.Name -eq $Group.CaptureName } | Select-Object -First 1
    $name = [string]$capture.Name
    if (-not $CapturePath.ContainsKey($name) -or -not [string]$CapturePath[$name]) {
        throw ("FW-05: the UEFI diagnostics capture is missing. Group '{0}' needs the captured tree; pass it as the capture path for '{1}' (builder: -DiagnosticsSource). Steps: docs\firmware-bench-checklist.md." -f $Group.Id, $name)
    }
    $folder = [string]$CapturePath[$name]
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "FW-05: the capture folder for '$name' does not exist: $folder. Steps: docs\firmware-bench-checklist.md."
    }
    if (-not (Test-Path -LiteralPath $capture.SnapshotPath -PathType Leaf)) {
        throw "FW-05: no recorded snapshot at $($capture.SnapshotPath). Record one from the capture with -NewDiagnosticsSnapshot, review the diff and commit it."
    }
    $recorded = @(Read-KitFirmwareSnapshot -Path $capture.SnapshotPath -Name $name)

    $prefix = $Group.Folder + '\'
    foreach ($item in $recorded) {
        if (-not $item.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "FW-05: snapshot path '$($item.Path)' lies outside the folder $($Group.Folder) of group '$($Group.Id)'"
        }
    }

    $actual = @{}
    foreach ($item in Get-KitCaptureFile -Root $folder -Cache $Cache) { $actual[$item.RelativePath.ToLowerInvariant()] = $item }
    $entry = foreach ($item in $recorded) {
        $found = $actual[$item.Path.ToLowerInvariant()]
        if (-not $found) { throw "FW-05: captured file $($item.Path) is listed in the snapshot but is missing from the capture; re-capture it or re-record the snapshot after review." }
        if ($found.Size -ne $item.Size) {
            throw "FW-05: captured file $($item.Path) differs from the recorded snapshot (size $($found.Size), recorded $($item.Size)); re-record with -NewDiagnosticsSnapshot after review."
        }
        if ($found.Sha256 -ne $item.Sha256) {
            throw "FW-05: captured file $($item.Path) differs from the recorded snapshot (SHA-256); re-record with -NewDiagnosticsSnapshot after review."
        }
        [pscustomobject]@{
            RelativePath = $item.Path
            SourcePath   = $found.FullName
            Group        = $Group.Id
            Size         = $item.Size
            Sha256       = $item.Sha256
            VendorHash   = $null
        }
    }

    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $recorded) { $null = $listed.Add($item.Path) }
    $extra = @($actual.Values | Where-Object { -not $listed.Contains($_.RelativePath) } | ForEach-Object { $_.RelativePath } | Sort-Object)
    if ($extra.Count -gt 0) {
        $shown = ($extra | Select-Object -First 5) -join ', '
        throw "FW-05: the capture holds $($extra.Count) file(s) the snapshot does not list: $shown; remove them or re-record the snapshot after review."
    }
    $entry
}
