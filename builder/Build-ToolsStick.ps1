#Requires -Version 5.1

<#
.SYNOPSIS
Build a Tools stick: download the firmware, stage it onto the stick and prove the stick is ready.

.DESCRIPTION
Vendor-neutral master firmware build. The vendor is a parameter: this script resolves the vendor descriptor and the
model profiles, checks the target, then runs two vendor operations per model (GetFirmware, then GetFirmwareStickLayout)
and hands the results to Publish-FirmwareStage, which copies the files, writes firmware-manifest.json and the READY
marker, and validates the stick. The script names no vendor and writes no file itself.
The target is checked before anything is downloaded. Output is short [PASS], [WARN] and [FAIL] lines. The exit code is 0
only when the stick is READY with no Fail; every other outcome, including every error, is exit code 1.

.PARAMETER Vendor
Vendor name from its descriptor (vendor.psd1).

.PARAMETER Model
Model ids, the profile file names without extension, for example 840-g5.

.PARAMETER TargetPath
The Tools stick: a FAT32 volume root such as E:\.

.PARAMETER AllowFolder
Stage into an ordinary folder instead of a FAT32 volume root. For tests and dry runs.

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
builder\Build-ToolsStick.ps1 -Vendor Fixture -Model m1 -TargetPath E:\
Download the firmware of model m1 and stage it onto the stick in E:.

.EXAMPLE
builder\Build-ToolsStick.ps1 -Vendor Fixture -Model m1 -TargetPath E:\ -WhatIf
Preview the download and stop; nothing is staged.

.EXAMPLE
builder\Build-ToolsStick.ps1 -Vendor Fixture -Model m1 -TargetPath C:\Temp\stick -AllowFolder
Stage into an ordinary folder for a dry run.

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

    [switch]$AllowFolder,

    [string]$OsVer,

    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\staging'),

    [string[]]$VendorRoot,

    [string]$ProfileRoot,

    [string]$LayoutPath
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

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

try {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    if (-not $Vendor) { throw 'Cannot ask for Vendor here. Pass -Vendor on the command line.' }
    if (-not $Model) { throw 'Cannot ask for Model here. Pass -Model on the command line.' }
    if (-not $TargetPath) { throw 'Cannot ask for TargetPath here. Pass -TargetPath on the command line.' }

    $vendorArguments = @{ Name = $Vendor }
    if ($VendorRoot) { $vendorArguments.VendorRoot = $VendorRoot }
    $vendorInfo = Get-KitVendor @vendorArguments

    $profiles = foreach ($id in $Model) {
        $profileArguments = @{ Vendor = $vendorInfo.Name; ModelId = $id }
        if ($ProfileRoot) { $profileArguments.ProfileRoot = $ProfileRoot }
        Get-KitProfile @profileArguments
    }

    # The target is checked before any vendor operation, so a wrong volume costs no download.
    $resolvedTarget = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($TargetPath)
    $targetFinding = @(Test-FirmwareTarget -Path $resolvedTarget -AllowFolder:$AllowFolder)
    Show-FirmwareStageFinding -Finding $targetFinding
    if (@($targetFinding | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) {
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Fail -Message 'Stopped before any download. Fix the target and run again.')
        exit 1
    }

    $outputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputRoot)
    $packages = foreach ($modelProfile in $profiles) {
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
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedTarget, 'Stage firmware onto the Tools stick')) {
        if ($WhatIfPreference) {
            Write-Information 'WhatIf: nothing was staged'
            exit 0
        }
        throw 'Staging was not confirmed. Nothing was staged.'
    }

    $results = @(for ($index = 0; $index -lt @($profiles).Count; $index++) {
            $layoutParameters = @{
                ModelProfile = @($profiles)[$index]
                PackagePath  = @($packages)[$index].PackagePath
                LayoutPath   = if ($LayoutPath) { $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LayoutPath) } else { '' }
            }
            $layoutResult = Invoke-KitVendorCommand -Vendor $vendorInfo -Operation GetFirmwareStickLayout -Parameters $layoutParameters
            if (-not $layoutResult) {
                throw "Vendor '$($vendorInfo.Name)' returned no result for GetFirmwareStickLayout (model $(@($profiles)[$index].ModelId))."
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

    $publishParameters = @{
        Layout      = $layout
        Model       = $results
        TargetPath  = $resolvedTarget
        CapturePath = @{}
        AllowFolder = [bool]$AllowFolder
        PassThru    = $true
    }
    $stage = @(Publish-FirmwareStage @publishParameters) | Select-Object -Last 1

    foreach ($result in $results) {
        $bios = $result.LatestBios
        $text = if ($bios) { "$($result.ModelId): BIOS $($bios.Version) $($bios.File)" } else { "$($result.ModelId): no BIOS information" }
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Pass -Message $text)
    }
    Show-FirmwareStageFinding -Finding @($stage.Findings)

    $failCount = @($stage.Findings | Where-Object { $_.Status -eq 'Fail' }).Count
    if ($stage.Ready -and $failCount -eq 0) {
        Show-FirmwareStageFinding -Finding (ConvertTo-BuildFinding -Status Pass -Message "READY - $($stage.FileCount) files for $(@($results).Count) models")
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
