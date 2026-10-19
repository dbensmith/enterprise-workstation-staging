#Requires -Version 5.1

<#
.SYNOPSIS
Build a repeatable driver + firmware baseline package for one vendor's model.

.DESCRIPTION
Vendor-neutral build entry. The vendor is a parameter: this script resolves the vendor descriptor and the
model profile, then runs the build through the vendor interface, one operation per stage:
  Drivers  - NewCustomPack: the vendor builds its custom driver pack from its catalog.
  Firmware - GetFirmware: the vendor downloads and extracts its BIOS and firmware packages.
The package lands in <OutputRoot>\<vendor>\<model>\<os>-<release> and holds Drivers\, Firmware\ and
manifest.json only. No installer or other script is copied into it: packages are data (D-04).
Re-running refreshes the package in place; a single -Stage keeps the other stage's manifest entries.

.PARAMETER Vendor
Vendor name from its descriptor (vendor.psd1), for example the folder name under kit\vendors.

.PARAMETER Model
Model id: the profile file name under kit\profiles\<vendor>, without its extension.

.PARAMETER ProfilePath
Load the model profile from this file instead of by -Model.

.PARAMETER VendorRoot
Folders searched for vendor descriptors. Defaults to the vendors folder of the kit.

.PARAMETER OutputRoot
Parent folder for packages. Defaults to the staging folder next to the repo.

.PARAMETER OsVer
Overrides the profile's OsVer. Must be a release the vendor's catalog indexes for the platform.

.PARAMETER Stage
Drivers, Firmware, or both (default). A partial run keeps the other stage's manifest entries.

.EXAMPLE
builder\Build-DriverBaseline.ps1 -Vendor HP -Model 840-g6 -WhatIf
Show what the 840 G6 build would select and download, without building anything.

.EXAMPLE
builder\Build-DriverBaseline.ps1 -Vendor HP -Model 840-g5 -Stage Firmware
Stage only the 840 G5 firmware and keep its driver entries from the previous manifest.

.OUTPUTS
None. Writes the package folder and an Included/Excluded summary to the information stream.

.NOTES
Elevation and tool requirements (catalog module, administrator rights) belong to the vendor module and are
checked there; -WhatIf previews without them where the vendor allows it.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByModel')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Vendor,

    [Parameter(Mandatory, ParameterSetName = 'ByModel')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Model,

    [Parameter(Mandatory, ParameterSetName = 'ByPath')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ProfilePath,

    [string[]]$VendorRoot,

    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\staging'),

    [string]$OsVer,

    [ValidateSet('Drivers', 'Firmware')]
    [string[]]$Stage = @('Drivers', 'Firmware')
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

$vendorArguments = @{ Name = $Vendor }
if ($VendorRoot) { $vendorArguments.VendorRoot = $VendorRoot }
$vendorInfo = Get-KitVendor @vendorArguments

$modelProfile = if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
    Get-KitProfile -Path $ProfilePath
}
else {
    Get-KitProfile -Vendor $vendorInfo.Name -ModelId $Model
}
if ($modelProfile.Vendor -ine $vendorInfo.Name) {
    throw "Profile $($modelProfile.ProfilePath) belongs to vendor '$($modelProfile.Vendor)', not '$($vendorInfo.Name)'."
}
# An unverified platform id (say, one taken from a forum post) is built against only with a warning.
$platform = Get-KitVerifiedValue -ModelProfile $modelProfile -Name Platform -AllowUnverified

# Preference variables do not reach functions in another module, so -WhatIf is passed explicitly.
$buildParameters = @{
    ModelProfile = $modelProfile
    OsVer        = $OsVer
    OutputPath   = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputRoot)
    WhatIf       = [bool]$WhatIfPreference
}

$pack = $null
$firmware = $null
if ('Drivers' -in $Stage) {
    $pack = Invoke-KitVendorCommand -Vendor $vendorInfo -Operation NewCustomPack -Parameters $buildParameters
    if (-not $pack) { throw "Vendor '$($vendorInfo.Name)' returned no result for NewCustomPack." }
    # Build the second stage against the release the first one resolved.
    $buildParameters.OsVer = $pack.OsVer
}
if ('Firmware' -in $Stage) {
    $firmware = Invoke-KitVendorCommand -Vendor $vendorInfo -Operation GetFirmware -Parameters $buildParameters
    if (-not $firmware) { throw "Vendor '$($vendorInfo.Name)' returned no result for GetFirmware." }
}

$results = @($pack, $firmware) | Where-Object { $_ }
$packageDir = $results[0].PackagePath
if (@($results.PackagePath | Select-Object -Unique).Count -ne 1) {
    throw "The vendor's stages disagree on the package folder: $(($results.PackagePath) -join ' vs ')."
}
$manifestPath = Join-Path $packageDir 'manifest.json'

# Carry forward sections for stages not run this time, so a partial rebuild keeps a complete manifest.
$previous = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
$toolVersions = [ordered]@{}
if ($previous.ToolVersions) {
    foreach ($property in $previous.ToolVersions.PSObject.Properties) { $toolVersions[$property.Name] = $property.Value }
}
foreach ($result in $results) {
    foreach ($name in $result.ToolVersions.Keys) { $toolVersions[$name] = $result.ToolVersions[$name] }
}

$manifest = [ordered]@{
    SchemaVersion = 2
    Profile       = $modelProfile.Name
    Vendor        = $vendorInfo.Name
    ModelId       = $modelProfile.ModelId
    Platform      = $platform
    Os            = $modelProfile.Os
    OsVer         = $results[0].OsVer
    BuiltUtc      = (Get-Date).ToUniversalTime().ToString('o')
    ToolVersions  = $toolVersions
    Drivers       = @($previous.Drivers | Where-Object { $_ })
    Firmware      = @($previous.Firmware | Where-Object { $_ })
    Excluded      = @($previous.Excluded | Where-Object { $_ -and $_.Stage -notin $Stage })
}
if ($pack) {
    $manifest.Drivers = @($pack.Drivers)
    $manifest.Excluded += @($pack.Excluded)
}
if ($firmware) {
    $manifest.Firmware = @($firmware.Firmware)
    $manifest.Excluded += @($firmware.Excluded)
}

if ($PSCmdlet.ShouldProcess($packageDir, 'Write manifest.json')) {
    $null = New-Item -Path $packageDir -ItemType Directory -Force
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

Write-Information "`nIncluded:"
Write-Information "$(@($manifest.Drivers) + @($manifest.Firmware) | Format-Table Id, Category, Version, Name -AutoSize | Out-String)"
Write-Information 'Excluded:'
Write-Information "$($manifest.Excluded | Format-Table Stage, Id, Name, Reason -AutoSize | Out-String)"
Write-Information "Package: $packageDir"
