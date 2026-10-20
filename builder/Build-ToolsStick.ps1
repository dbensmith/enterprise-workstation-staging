#Requires -Version 5.1

<#
.SYNOPSIS
Build a Tools stick: download the firmware, stage it onto the stick and prove the stick is ready.

.DESCRIPTION
Vendor-neutral master firmware build. The vendor is a parameter: this script resolves the vendor descriptor and the
model profiles, checks the target, then runs two vendor operations per model (GetFirmware, then GetFirmwareStickLayout)
and hands the results to Publish-FirmwareStage, which copies the files, writes firmware-manifest.json and the READY
marker, and validates the stick. The script names no vendor and writes no file itself.
The vendor, the models and the target are asked for only when their parameters are left out, and only here; a session
that cannot ask stops with a message that names the parameter to pass.
The target is checked before anything is downloaded. Output is short [PASS], [WARN] and [FAIL] lines. The exit code is 0
only when the stick is READY with no Fail; every other outcome, including every error, is exit code 1.

.PARAMETER Vendor
Vendor name from its descriptor (vendor.psd1). Asked for when left out; a single available vendor is used as is.

.PARAMETER Model
Model ids, the profile file names without extension, for example 840-g5 and 840-g6. Several ids may be given as a list
or joined by commas ('a,b'), which is how powershell.exe -File delivers them. Asked for when left out.

.PARAMETER TargetPath
The Tools stick: a FAT32 volume root such as E:\. Asked for when left out.

.PARAMETER DiagnosticsSource
Folder that holds the captured UEFI diagnostics tree, for a layout that stages one. Without it, when the layout needs a
capture, the run stops with a message that begins FW-05.

.PARAMETER CaptureName
Which of the layout's captures -DiagnosticsSource is. Needed only when the layout has more than one.

.PARAMETER NewDiagnosticsSnapshot
Record the snapshot of the capture in -DiagnosticsSource next to the layout, then stage from it. Review the new
snapshot file before it is committed.

.PARAMETER FlashModel
Stage this one model only, plus the groups a normal build leaves out (the flash-image escape hatch). It must be one of
the selected models.

.PARAMETER IncludeKit
Also copy the kit files into the kit folder of the stick. Off by default.

.PARAMETER RemoveStale
Delete files inside the closed group folders that the new manifest does not list. Without it such a file fails the run.

.PARAMETER AllowFolder
Stage into an ordinary folder instead of a FAT32 volume root. For tests and dry runs; the real command always targets
a FAT32 volume root such as E:\.

.PARAMETER ValidateOnly
Check the stick in -TargetPath against its own manifest and do nothing else: no vendor is loaded and nothing is
downloaded or written.

.PARAMETER OsVer
Overrides the profile's OsVer for the vendor download.

.PARAMETER OutputRoot
Parent folder for the downloaded packages. Defaults to the staging folder next to the repo.

.PARAMETER VendorRoot
Folders searched for vendor descriptors. Defaults to the vendors folder of the kit.

.PARAMETER ProfileRoot
Folder that holds the model profiles. Defaults to the profiles folder of the kit.

.PARAMETER LayoutPath
Use this firmware layout file instead of the vendor's own.

.EXAMPLE
builder\Build-ToolsStick.ps1 -Vendor HP -Model 840-g5,840-g6 -TargetPath E:\ -DiagnosticsSource D:\capture
Download the firmware of two models and stage it, with the recorded diagnostics capture, onto the stick in E:.

.EXAMPLE
builder\Build-ToolsStick.ps1 -Vendor HP -Model 840-g5 -TargetPath E:\ -WhatIf
Preview the download and stop; nothing is staged and the stick is not touched.

.EXAMPLE
builder\Build-ToolsStick.ps1 -ValidateOnly -TargetPath E:\
Re-check the stick in E: against its manifest without a build.

.EXAMPLE
builder\Build-ToolsStick.ps1 -Vendor HP -Model 840-g5 -TargetPath E:\ -DiagnosticsSource D:\capture -NewDiagnosticsSnapshot
Record the snapshot of a freshly captured tree next to the layout, then stage from it.

.OUTPUTS
None. Writes result lines to the host. Exit code 0 (READY) or 1.

.NOTES
Elevation and tool requirements belong to the vendor module and are checked there.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Vendor,

    [string[]]$Model,

    [string]$TargetPath,

    [string]$DiagnosticsSource,

    [string]$CaptureName,

    [switch]$NewDiagnosticsSnapshot,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$FlashModel,

    [switch]$IncludeKit,

    [switch]$RemoveStale,

    [switch]$AllowFolder,

    [switch]$ValidateOnly,

    [string]$OsVer,

    [string]$OutputRoot,

    [string[]]$VendorRoot,

    [string]$ProfileRoot,

    [string]$LayoutPath
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# The default is set here, not in the param block: Windows PowerShell 5.1 leaves $PSScriptRoot empty in the parameter
# defaults of a script that has [CmdletBinding()] when it is started with -File, which would fail every run that does
# not pass -OutputRoot.
if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot '..\staging' }

function ConvertTo-BuildFinding {
    # One finding in the shape Show-FirmwareStageFinding prints.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Warn', 'Fail')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Message
    )
    [pscustomobject]@{ Status = $Status; Check = 'Build'; Message = $Message; Path = ''; Group = '' }
}

function ConvertTo-BuildTargetRoot {
    # A bare drive letter ('E' or 'E:') means the root of that drive, not the current folder on it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $text = $Path.Trim()
    if ($text -match '^[A-Za-z]:?$') { return $text.Substring(0, 1) + ':\' }
    $text
}

function Select-BuildChoice {
    # Ask for one or several of a short list, answered with numbers or exact names. This and Read-BuildTarget are the
    # only places in the builder that ask a question.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string[]]$Choice,

        [Parameter(Mandatory)]
        [string[]]$Label,

        [switch]$Multiple
    )
    for ($index = 0; $index -lt $Choice.Count; $index++) {
        Write-Information ('  {0}. {1}' -f ($index + 1), $Label[$index])
    }
    $question = if ($Multiple) { "Choose $Name (numbers or names, comma-separated)" } else { "Choose $Name (a number or a name)" }
    try {
        $answer = Read-Host -Prompt $question
    }
    catch {
        throw "Cannot ask for $Name here. Pass -$Name on the command line."
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { throw "No answer was given for $Name. Pass -$Name on the command line." }

    $picked = [System.Collections.Generic.List[string]]::new()
    foreach ($token in ($answer -split ',')) {
        $text = $token.Trim()
        if (-not $text) { continue }
        $number = 0
        $chosen = $null
        if ([int]::TryParse($text, [ref]$number) -and $number -ge 1 -and $number -le $Choice.Count) {
            $chosen = $Choice[$number - 1]
        }
        else {
            $chosen = $Choice | Where-Object { $_ -ieq $text } | Select-Object -First 1
        }
        if (-not $chosen) { throw "'$text' is not one of the choices for ${Name}: $($Choice -join ', ')" }
        if (-not $picked.Contains($chosen)) { $picked.Add($chosen) }
    }
    if ($picked.Count -eq 0) { throw "No answer was given for $Name. Pass -$Name on the command line." }
    if ($picked.Count -gt 1 -and -not $Multiple) { throw "Choose one $Name only." }
    $picked.ToArray()
}

function Read-BuildTarget {
    # Ask for the Tools stick drive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $answer = Read-Host -Prompt 'Tools stick drive, for example E:\'
    }
    catch {
        throw 'Cannot ask for TargetPath here. Pass -TargetPath on the command line.'
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { throw 'No drive was given. Pass -TargetPath on the command line.' }
    $answer.Trim()
}

try {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    if ($ValidateOnly) {
        # A re-check of a stick needs no vendor, no model and no download.
        if (-not $TargetPath) { $TargetPath = Read-BuildTarget }
        $stickPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath((ConvertTo-BuildTargetRoot -Path $TargetPath))
        $checkFinding = @(Test-FirmwareStage -Path $stickPath -AllowFolder:$AllowFolder)
        Show-FirmwareStageFinding -Finding $checkFinding
        $checkFail = @($checkFinding | Where-Object { $_.Status -eq 'Fail' }).Count
        if ($checkFail -eq 0) {
            Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Pass -Message 'READY - the stick checks out')
            exit 0
        }
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Fail -Message "NOT READY - $checkFail problem(s); do not leave with this stick")
        exit 1
    }

    $vendorArguments = @{}
    if ($VendorRoot) { $vendorArguments.VendorRoot = $VendorRoot }
    if (-not $Vendor) {
        $available = @(Get-KitVendor @vendorArguments)
        if ($available.Count -eq 1) {
            $Vendor = $available[0].Name
            Write-Information "Vendor: $Vendor (the only one available)"
        }
        else {
            $names = @($available | ForEach-Object { $_.Name })
            $Vendor = Select-BuildChoice -Name Vendor -Choice $names -Label $names
        }
    }
    $vendorInfo = Get-KitVendor -Name $Vendor @vendorArguments

    $profileArguments = @{ Vendor = $vendorInfo.Name }
    if ($ProfileRoot) { $profileArguments.ProfileRoot = $ProfileRoot }

    # Ids may arrive as a list or joined by commas; blanks are dropped and repeats collapse.
    $selectedId = [System.Collections.Generic.List[string]]::new()
    $seenId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Model)) {
        foreach ($piece in ([string]$item -split ',')) {
            $id = $piece.Trim()
            if ($id -and $seenId.Add($id)) { $selectedId.Add($id) }
        }
    }
    if ($selectedId.Count -eq 0) {
        $known = @(Get-KitProfile @profileArguments)
        if ($known.Count -eq 0) { throw "Vendor '$($vendorInfo.Name)' has no model profiles." }
        $knownId = @($known | ForEach-Object { $_.ModelId })
        $knownLabel = @($known | ForEach-Object { "$($_.ModelId) - $($_.Name)" })
        foreach ($id in (Select-BuildChoice -Name Model -Choice $knownId -Label $knownLabel -Multiple)) { $selectedId.Add($id) }
    }
    # An unknown id stops here with the message that lists the available ids.
    $profiles = @(foreach ($id in $selectedId) { Get-KitProfile @profileArguments -ModelId $id })
    $profileId = @($profiles | ForEach-Object { $_.ModelId })
    if ($FlashModel -and $FlashModel -notin $profileId) {
        throw "FlashModel '$FlashModel' is not one of the selected models: $($profileId -join ', ')"
    }

    if (-not $TargetPath) { $TargetPath = Read-BuildTarget }
    $resolvedTarget = $PSCmdlet.GetUnresolvedProviderPathFromPSPath((ConvertTo-BuildTargetRoot -Path $TargetPath))

    # The target is checked before any vendor operation, so a wrong volume costs no download.
    $targetFinding = @(Test-FirmwareTarget -Path $resolvedTarget -AllowFolder:$AllowFolder)
    Show-FirmwareStageFinding -Finding $targetFinding
    if (@($targetFinding | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) {
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Fail -Message 'Stopped before any download. Fix the target and run again.')
        exit 1
    }

    $outputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputRoot)
    $packages = @(foreach ($modelProfile in $profiles) {
            # Preference variables do not reach functions in another module, so -WhatIf is passed explicitly.
            $firmwareParameters = @{
                ModelProfile = $modelProfile
                OsVer        = $OsVer
                OutputPath   = $outputPath
                WhatIf       = [bool]$WhatIfPreference
            }
            $package = Invoke-KitVendorCommand -Vendor $vendorInfo -Operation GetFirmware -Parameters $firmwareParameters
            if (-not $package -and -not $WhatIfPreference) {
                throw "Vendor '$($vendorInfo.Name)' returned no result for GetFirmware (model $($modelProfile.ModelId))."
            }
            $package
        })

    if (-not $PSCmdlet.ShouldProcess($resolvedTarget, 'Stage firmware onto the Tools stick')) {
        if ($WhatIfPreference) {
            # The layout comes from the downloaded package, which a preview does not create.
            Write-Information 'WhatIf: nothing was staged'
            exit 0
        }
        throw 'Staging was not confirmed. Nothing was staged.'
    }

    $layoutArgument = ''
    if ($LayoutPath) { $layoutArgument = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LayoutPath) }
    $results = @(for ($index = 0; $index -lt $profiles.Count; $index++) {
            $layoutParameters = @{
                ModelProfile = $profiles[$index]
                PackagePath  = $packages[$index].PackagePath
                LayoutPath   = $layoutArgument
            }
            $layoutResult = Invoke-KitVendorCommand -Vendor $vendorInfo -Operation GetFirmwareStickLayout -Parameters $layoutParameters
            if (-not $layoutResult) {
                throw "Vendor '$($vendorInfo.Name)' returned no result for GetFirmwareStickLayout (model $($profiles[$index].ModelId))."
            }
            $layoutResult
        })

    $layoutFile = $results[0].LayoutPath
    foreach ($result in $results) {
        if ($result.LayoutPath -ine $layoutFile) {
            throw "The models disagree on the layout file: $layoutFile vs $($result.LayoutPath)."
        }
    }
    $layout = Get-KitFirmwareLayout -Path $layoutFile
    $layoutName = Split-Path -Path $layoutFile -Leaf

    # The captured diagnostics tree: replayed from its recorded snapshot, optionally recording that snapshot first.
    $capturePath = @{}
    if ($DiagnosticsSource) {
        $captures = @($layout.Captures)
        if ($captures.Count -eq 0) {
            throw "Layout $layoutName has no diagnostics capture, so -DiagnosticsSource does not apply."
        }
        if ($CaptureName) {
            $capture = $captures | Where-Object { $_.Name -ieq $CaptureName } | Select-Object -First 1
            if (-not $capture) {
                throw "Layout $layoutName has no capture named '$CaptureName'. Captures: $(($captures | ForEach-Object { $_.Name }) -join ', ')"
            }
        }
        elseif ($captures.Count -eq 1) {
            $capture = $captures[0]
        }
        else {
            throw "Layout $layoutName has several captures: $(($captures | ForEach-Object { $_.Name }) -join ', '). Pass -CaptureName with one of them."
        }
        $diagnosticsPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DiagnosticsSource)
        if ($NewDiagnosticsSnapshot) {
            New-KitFirmwareSnapshot -SourcePath $diagnosticsPath -Name $capture.Name -Path $capture.SnapshotPath -Confirm:$false
            Write-Information "Recorded snapshot $($capture.Snapshot). Review it before it is committed."
        }
        $capturePath[$capture.Name] = $diagnosticsPath
    }
    elseif ($NewDiagnosticsSnapshot) {
        throw '-NewDiagnosticsSnapshot needs -DiagnosticsSource.'
    }

    $publishParameters = @{
        Layout      = $layout
        Model       = $results
        TargetPath  = $resolvedTarget
        CapturePath = $capturePath
        IncludeKit  = [bool]$IncludeKit
        RemoveStale = [bool]$RemoveStale
        AllowFolder = [bool]$AllowFolder
        PassThru    = $true
    }
    if ($FlashModel) { $publishParameters.FlashModel = $FlashModel }
    $stage = @(Publish-FirmwareStage @publishParameters) | Select-Object -Last 1

    foreach ($result in $results) {
        $bios = $result.LatestBios
        $text = if ($bios) { "$($result.ModelId): BIOS $($bios.Version) $($bios.File)" } else { "$($result.ModelId): no BIOS information" }
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Pass -Message $text)
    }
    Show-FirmwareStageFinding -Finding @($stage.Findings)

    $failCount = @($stage.Findings | Where-Object { $_.Status -eq 'Fail' }).Count
    if ($stage.Ready -and $failCount -eq 0) {
        $modelCount = if ($FlashModel) { 1 } else { @($results).Count }
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Pass -Message "READY - $($stage.FileCount) files for $modelCount models")
        exit 0
    }
    $problems = [Math]::Max($failCount, 1)
    Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Fail -Message "NOT READY - $problems problem(s); do not leave with this stick")
    exit 1
}
catch {
    $failure = ConvertTo-BuildFinding -Status Fail -Message $_.Exception.Message
    if (Get-Command -Name Show-FirmwareStageFinding -ErrorAction Ignore) {
        Show-FirmwareStageFinding -Finding $failure
    }
    else {
        Write-Information "[FAIL] $($failure.Message)"
    }
    exit 1
}
