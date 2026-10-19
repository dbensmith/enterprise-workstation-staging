# Model profiles. Dot-sourced by Kit.Core.psm1. A profile is one standalone data file per model, kept under
# kit\profiles\<vendor>\<ModelId>.psd1. It is read with Import-PowerShellDataFile only, so a profile can hold data and never code.

# Keys every profile must carry, and the keys each nested block must carry. A missing key is reported by name.
$script:KitProfileKey = @(
    'SchemaVersion', 'Vendor', 'ModelId', 'Name', 'Platform', 'PlatformVerified', 'BiosFamily', 'Os', 'OsVer'
    'DriverExclude', 'FirmwareExclude', 'PackSelection', 'FirmwareMinimum', 'BiosDefaults'
)
$script:KitProfileBlockKey = [ordered]@{
    FirmwareMinimum = @('Version', 'Verified', 'Source')
    BiosDefaults    = @('Settings', 'Verified', 'Source')
}

function Read-KitProfileFile {
    <#
    .SYNOPSIS
    Load one profile file and check it against the profile schema.

    .DESCRIPTION
    Private helper of Get-KitProfile. Throws a message that names the file and what is wrong: keys that are
    missing, an unsupported SchemaVersion, a ModelId that differs from the file name, a Vendor that differs from
    the folder name, or a Verified flag that is not a boolean.

    .PARAMETER Path
    Path of the profile file.

    .OUTPUTS
    System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Profile $fullPath not found."
    }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $fullPath
    }
    catch {
        throw "Profile $fullPath is not a plain data file: $($_.Exception.Message)"
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $script:KitProfileKey) {
        if (-not $data.ContainsKey($key)) { $missing.Add($key) }
    }
    foreach ($block in $script:KitProfileBlockKey.Keys) {
        if (-not $data.ContainsKey($block)) { continue }
        if ($data[$block] -isnot [hashtable]) { throw "Profile ${fullPath}: $block must be a hashtable." }
        foreach ($key in $script:KitProfileBlockKey[$block]) {
            if (-not $data[$block].ContainsKey($key)) { $missing.Add("$block.$key") }
        }
    }
    if ($missing.Count -gt 0) {
        throw "Profile $fullPath is missing required keys: $($missing -join ', ')"
    }

    if ($data.SchemaVersion -ne 1) {
        throw "Profile ${fullPath}: SchemaVersion must be 1 (found $($data.SchemaVersion))."
    }
    $modelFileName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
    if ($data.ModelId -ne $modelFileName) {
        throw "Profile ${fullPath}: ModelId '$($data.ModelId)' does not match its file name '$modelFileName'."
    }
    $folderName = Split-Path -Path (Split-Path -Path $fullPath -Parent) -Leaf
    if ($data.Vendor -ne $folderName) {
        throw "Profile ${fullPath}: Vendor '$($data.Vendor)' does not match its folder name '$folderName'."
    }
    $flags = [ordered]@{
        PlatformVerified          = $data.PlatformVerified
        'FirmwareMinimum.Verified' = $data.FirmwareMinimum.Verified
        'BiosDefaults.Verified'   = $data.BiosDefaults.Verified
    }
    foreach ($name in $flags.Keys) {
        if ($flags[$name] -isnot [bool]) { throw "Profile ${fullPath}: $name must be `$true or `$false." }
    }

    $data.ProfilePath = $fullPath
    $data
}

function Get-KitProfile {
    <#
    .SYNOPSIS
    Load the data profile of one model, or of every model of a vendor.

    .DESCRIPTION
    A profile is a standalone .psd1 file at <ProfileRoot>\<vendor lowercased>\<ModelId>.psd1. It is loaded with
    Import-PowerShellDataFile, so it cannot run code, and is checked against the profile schema: every required key
    must exist, SchemaVersion must be 1, ModelId must equal the file name, Vendor must equal the folder name and
    the Verified flags must be booleans. The returned hashtable also carries a ProfilePath key.

    Do not read FirmwareMinimum or BiosDefaults from the result directly: use Get-KitVerifiedValue, which refuses a
    value that was not confirmed on hardware.

    .PARAMETER Vendor
    Vendor folder name, matched case-insensitively.

    .PARAMETER ModelId
    Model id, which is the profile file name without its extension. Omit it to get every profile of the vendor,
    sorted by ModelId.

    .PARAMETER Path
    Load one profile by file path instead of by vendor and model.

    .PARAMETER ProfileRoot
    Folder that holds one sub-folder per vendor. Defaults to the profiles folder of this kit.

    .EXAMPLE
    Get-KitProfile -Vendor Contoso -ModelId m100-g2

    .EXAMPLE
    Get-KitProfile -Vendor Contoso | ForEach-Object ModelId

    .OUTPUTS
    System.Collections.Hashtable
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByModel')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByModel')]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
        [string]$Vendor,

        [Parameter(ParameterSetName = 'ByModel')]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
        [string]$ModelId,

        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [string]$Path,

        [string]$ProfileRoot = (Join-Path (Get-KitRoot) 'profiles')
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        return Read-KitProfileFile -Path $Path
    }

    $vendorFolder = Join-Path $ProfileRoot $Vendor.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $vendorFolder -PathType Container)) {
        throw "No profiles for vendor '$Vendor' under $ProfileRoot."
    }
    $files = @(Get-ChildItem -LiteralPath $vendorFolder -Filter '*.psd1' -File | Sort-Object -Property BaseName)

    if (-not $ModelId) {
        foreach ($file in $files) { Read-KitProfileFile -Path $file.FullName }
        return
    }

    $match = @($files | Where-Object { $_.BaseName -eq $ModelId })
    if ($match.Count -eq 0) {
        throw "No profile '$ModelId' for vendor '$Vendor' under $vendorFolder. Available ModelIds: $(($files.BaseName) -join ', ')"
    }
    Read-KitProfileFile -Path $match[0].FullName
}

function Get-KitVerifiedValue {
    <#
    .SYNOPSIS
    Read a profile value that may not have been confirmed on hardware, refusing it unless it is verified.

    .DESCRIPTION
    FirmwareMinimum and BiosDefaults are read through the Verified flag of their own block, Platform through
    PlatformVerified. A value whose flag is not exactly $true makes the function throw
    "<Name> for <ModelId> is unverified (Verified = $false); confirm on hardware first. Source: <Source>".
    With -AllowUnverified the same text is written as a warning and the value is returned, so a caller
    that relies on an unconfirmed value says so out loud.

    Code outside this file must not read the FirmwareMinimum or BiosDefaults keys directly:
    tests\Profiles.Tests.ps1 scans kit and builder for that.

    .PARAMETER ModelProfile
    A profile returned by Get-KitProfile.

    .PARAMETER Name
    FirmwareMinimum returns the block's own values without its Verified and Source keys.
    BiosDefaults returns the Settings hashtable. Platform returns the platform id string.

    .PARAMETER AllowUnverified
    Return an unverified value with a warning instead of throwing.

    .EXAMPLE
    Get-KitVerifiedValue -ModelProfile $modelProfile -Name Platform -AllowUnverified

    .OUTPUTS
    System.Collections.Hashtable or System.String
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [Parameter(Mandatory)][ValidateSet('FirmwareMinimum', 'BiosDefaults', 'Platform')][string]$Name,
        [switch]$AllowUnverified
    )

    $modelLabel = if ($ModelProfile.ContainsKey('ModelId')) { $ModelProfile.ModelId } else { '(unknown model)' }
    if (-not $ModelProfile.ContainsKey($Name)) {
        throw "$Name for $modelLabel is not in the profile; load it with Get-KitProfile."
    }

    switch ($Name) {
        'Platform' {
            $verified = if ($ModelProfile.ContainsKey('PlatformVerified')) { $ModelProfile.PlatformVerified } else { $false }
            $source = if ($ModelProfile.ContainsKey('PlatformSource')) { $ModelProfile.PlatformSource } else { 'not recorded' }
            $value = $ModelProfile.Platform
        }
        'FirmwareMinimum' {
            $block = $ModelProfile.FirmwareMinimum
            $verified = $block.Verified
            $source = $block.Source
            $value = @{}
            foreach ($key in $block.Keys) {
                if ($key -notin 'Verified', 'Source') { $value[$key] = $block[$key] }
            }
        }
        'BiosDefaults' {
            $block = $ModelProfile.BiosDefaults
            $verified = $block.Verified
            $source = $block.Source
            $value = $block.Settings
        }
    }

    if ($verified -ne $true) {
        $message = "$Name for $modelLabel is unverified (Verified = `$false); confirm on hardware first. Source: $source"
        if (-not $AllowUnverified) { throw $message }
        Write-Warning $message
    }
    $value
}
