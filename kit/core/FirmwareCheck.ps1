# Validator for a Tools stick. Dot-sourced by Kit.Core.psm1. Pure: nothing here writes to a stick, and the only console output
# is Show-FirmwareStageFinding. The list of expected files comes from firmware-manifest.json on the stick and from nowhere else.

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

function Test-FirmwareStage {
    <#
    .SYNOPSIS
    Prove that a Tools stick matches its own firmware-manifest.json.

    .DESCRIPTION
    Reads the manifest at the stick root and takes the list of expected files from it alone. Every file must exist
    with the manifest size, SHA-256 and, where the manifest has one, the vendor hash. Each problem becomes one Fail
    finding whose Path is the manifest path of the file. A stick with no readable manifest returns one Fail; this
    function never throws for a bad stick.

    .PARAMETER Path
    The stick root, for example E:\.

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
        [string]$Path
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    try {
        $manifest = Read-KitFirmwareManifest -Path $Path
    }
    catch {
        $findings.Add((ConvertTo-KitFirmwareFinding -Status Fail -Check Manifest -Message $_.Exception.Message))
        return $findings.ToArray()
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($model in $manifest.models) {
        foreach ($file in $model.files) { $records.Add($file) }
    }
    foreach ($file in $manifest.shared) { $records.Add($file) }

    $problemCount = 0
    foreach ($record in $records) {
        $problem = Get-KitStageFileProblem -Root $Path -Record $record
        if ($problem) {
            $problemCount++
            $findings.Add((ConvertTo-KitFirmwareFinding -Status Fail -Check $problem.Check -Message $problem.Message -Path ([string]$record.path) -Group ([string]$record.group)))
        }
    }
    if ($problemCount -eq 0) {
        $findings.Add((ConvertTo-KitFirmwareFinding -Status Pass -Check Files -Message ('{0} files present' -f $records.Count)))
        $findings.Add((ConvertTo-KitFirmwareFinding -Status Pass -Check Hash -Message ('{0} files hash OK' -f $records.Count)))
    }
    $findings.ToArray()
}

function Show-FirmwareStageFinding {
    <#
    .SYNOPSIS
    Print validator findings as coloured console lines.

    .DESCRIPTION
    The one place in the core module that writes to the host. Each finding is one line that starts with [PASS] in
    green, [WARN] in yellow or [FAIL] in red, and a finding that names a file adds a second, indented line with the
    manifest path.

    .PARAMETER Finding
    Findings from Test-FirmwareStage or Test-FirmwareTarget.

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
        [object[]]$Finding
    )
    foreach ($item in $Finding) {
        $color = switch ($item.Status) {
            'Pass' { 'Green' }
            'Warn' { 'Yellow' }
            default { 'Red' }
        }
        Write-Host -Object ('[{0}] {1}' -f $item.Status.ToUpperInvariant(), $item.Message) -ForegroundColor $color
        if ($item.Path) { Write-Host -Object ('  {0}' -f $item.Path) -ForegroundColor $color }
    }
}
