#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Build a Windows install ISO with a baseline package's drivers pre-injected and the kit staged for first boot.

.DESCRIPTION
The package comes from Build.cmd (builder\Build-DriverBaseline.ps1); this script is vendor-neutral.
1. Mounts the source ISO read-only and resolves the edition in its install.wim/.esd.
2. Copies the media to -WorkRoot (an .esd edition is converted to WIM, since DISM cannot service ESD).
3. Mounts the edition and injects the drivers through kit\Install-DriverBaseline.ps1 -OfflineImagePath.
   Unless -NoFirstBoot, also stages the publishable kit files at C:\Kit, the package's manifest.json and
   Firmware folder at C:\Kit\package, and an answer file (Windows\Panther\unattend.xml) that runs the
   installer once as SYSTEM during Setup's specialize pass, before OOBE, logging to C:\Kit\firstboot.log.
   The kit's local settings file and any results folder are never copied into the image.
4. Exports it once into sources\install.wim: keeps only that edition and drops the commit's orphaned data.
5. Optionally adds specific driver folders (-BootDriver) to boot.wim's Setup image.
6. Builds a UEFI + legacy BIOS bootable ISO with IMAPI2 (built into Windows; no ADK needed).
A package built before the kit layout (manifest SchemaVersion other than 2) is refused.

.PARAMETER IsoPath
Source Windows ISO (install.wim or install.esd).

.PARAMETER PackagePath
Baseline package folder from Build.cmd (holds manifest.json, Drivers\ and Firmware\).

.PARAMETER Edition
Exact ImageName to keep. Optional when the install image holds one edition (e.g. a Pro-only ISO);
required for multi-edition media. A wrong or missing name fails fast and lists the available names.

.PARAMETER BootDriver
Driver folder names from the package's Drivers folder to add to boot.wim's Setup image.
Only storage and network drivers belong here.

.PARAMETER WorkRoot
Scratch folder, roughly 2x the ISO size, deleted afterwards unless -KeepWorkDir.
Must be empty or previously created by this script. Defaults to staging\_isobuild in the repo.

.PARAMETER OutputPath
Output ISO. Default: <source ISO name>_<vendor>-<model>.iso next to the package's model folder.

.PARAMETER NoFirstBoot
Don't stage C:\Kit or the specialize-pass answer file; the ISO then carries drivers only.

.PARAMETER KeepWorkDir
Keep WorkRoot (copied media) after a successful build.

.EXAMPLE
builder\iso\New-BaselineIso.ps1 -IsoPath D:\ISO\Win11.iso -PackagePath staging\hp\840-g6\win11-24H2 -WhatIf
Show the edition, build, and output path without copying anything.

.EXAMPLE
builder\iso\New-BaselineIso.ps1 -IsoPath D:\ISO\Win11.iso -PackagePath staging\hp\840-g6\win11-24H2 -BootDriver sp144910
Also give Windows Setup the named driver folder, for units running the disk in RAID mode.

.OUTPUTS
PSCustomObject with Iso, SizeGB, Edition, Build, Drivers, FirstBoot, SHA256.

.NOTES
Requires admin (DISM image servicing). Boots with the ISO's own efisys.bin (Microsoft 2011 CA);
units that have revoked that CA need 2023-signed boot media instead.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$IsoPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path (Join-Path $_ 'manifest.json') -PathType Leaf })]
    [string]$PackagePath,

    [string]$Edition,

    [string[]]$BootDriver = @(),

    [string]$WorkRoot = (Join-Path $PSScriptRoot '..\..\staging\_isobuild'),

    [string]$OutputPath,

    [switch]$NoFirstBoot,

    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\..\kit\core\Kit.Core.psd1') -Force

$kitRoot = Get-KitRoot
$installer = Join-Path $kitRoot 'Install-DriverBaseline.ps1'

function Read-PackageManifest {
    # A package built before the kit layout carries its own old installer copy and a manifest without
    # SchemaVersion 2. Imaging from it would stage a first-boot command that cannot bind, so refuse it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath
    )
    $manifest = Get-Content -LiteralPath (Join-Path $PackagePath 'manifest.json') -Raw | ConvertFrom-Json
    $version = if ($manifest.PSObject.Properties['SchemaVersion']) { $manifest.SchemaVersion } else { $null }
    if ($version -ne 2) {
        $shown = if ($null -eq $version) { 'none' } else { $version }
        throw "Package $PackagePath was built before the kit layout (manifest SchemaVersion $shown, expected 2). Rebuild it with Build.cmd."
    }
    $manifest
}

# Resolve every path now: DISM, robocopy and IMAPI2 do not take the unnormalised '..' of a default.
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
$WorkRoot = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($WorkRoot)
$manifest = Read-PackageManifest -PackagePath $PackagePath
if ($OutputPath) {
    $OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
}
else {
    $OutputPath = Join-Path (Split-Path $PackagePath) ('{0}_{1}-{2}.iso' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $manifest.Vendor.ToLowerInvariant(), $manifest.ModelId)
}
$marker = Join-Path $WorkRoot '.kit-iso-workdir'
$media = Join-Path $WorkRoot 'media'
$mountDir = Join-Path $WorkRoot 'mount'

function Invoke-WithMountedImage {
    # Mount, run $Action, commit. Any failure discards the mount so no stale mount is left behind.
    param([string]$ImagePath, [int]$Index, [scriptblock]$Action)
    $null = New-Item -Path $mountDir -ItemType Directory -Force
    $null = Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $mountDir
    $saved = $false
    try {
        & $Action $mountDir
        $null = Dismount-WindowsImage -Path $mountDir -Save
        $saved = $true
    }
    finally {
        if (-not $saved) { $null = Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction Continue }
    }
}

function Add-FirstBootRun {
    # Stage the publishable kit files at <image>\Kit and the package's manifest and firmware at <image>\Kit\package,
    # then run the installer once, as SYSTEM, in Setup's specialize pass (before OOBE). An image answer file is used
    # because SetupComplete.cmd is disabled on PCs with an OEM product key. Drivers are already injected, so they
    # are not copied. Only Get-KitPublishFile output is copied: the local settings file and results never travel.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImageRoot,
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$KitRoot
    )
    $answerFile = Join-Path $ImageRoot 'Windows\Panther\unattend.xml'
    if (Test-Path $answerFile) {
        throw "The image already has $answerFile; refusing to overwrite it. Re-run with -NoFirstBoot, or merge the command into that file."
    }
    $target = Join-Path $ImageRoot 'Kit'
    foreach ($entry in (Get-KitPublishFile -Root $KitRoot)) {
        $destination = Join-Path $target $entry.RelativePath
        $null = New-Item -Path (Split-Path -Path $destination -Parent) -ItemType Directory -Force
        Copy-Item -LiteralPath $entry.FullName -Destination $destination
    }
    $packageTarget = Join-Path $target 'package'
    $null = New-Item -Path $packageTarget -ItemType Directory -Force
    Copy-Item -LiteralPath (Join-Path $PackagePath 'manifest.json') -Destination $packageTarget
    $firmwareDir = Join-Path $PackagePath 'Firmware'
    if (Test-Path $firmwareDir) { Copy-Item -LiteralPath $firmwareDir -Destination $packageTarget -Recurse }

    $null = New-Item -Path (Split-Path $answerFile) -ItemType Directory -Force
    Set-Content -Path $answerFile -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Driver and firmware baseline</Description>
          <Path>cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File %SystemDrive%\Kit\Install-DriverBaseline.ps1 -PackagePath %SystemDrive%\Kit\package -LogPath %SystemDrive%\Kit\firstboot.log</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
'@
}

# Resolve every input before the long-running work, so bad arguments fail in seconds.
$bootDriverDirs = foreach ($id in $BootDriver) {
    $dir = Get-ChildItem -Path (Join-Path $PackagePath 'Drivers') -Directory -Recurse -Filter $id | Select-Object -First 1
    if (-not $dir) { throw "Driver folder '$id' is not in $PackagePath\Drivers." }
    $dir.FullName
}

$iso = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -PassThru -WhatIf:$false
try {
    $volume = $iso | Get-Volume
    $source = '{0}:\' -f $volume.DriveLetter
    $sourceImage = Get-ChildItem -Path (Join-Path $source 'sources') -File | Where-Object Name -In 'install.wim', 'install.esd' | Select-Object -First 1
    if (-not $sourceImage) { throw "No sources\install.wim or install.esd in $IsoPath." }

    $images = @(Get-WindowsImage -ImagePath $sourceImage.FullName)
    $image = Select-InstallImage -Image $images -Edition $Edition
    $build = (Get-WindowsImage -ImagePath $sourceImage.FullName -Index $image.ImageIndex).Version

    Write-Information "Source:  $($image.ImageName) (index $($image.ImageIndex) of $($images.Count), build $build) from $($sourceImage.Name)"
    Write-Information "Drivers: $($manifest.Profile) [$($manifest.Platform)], $($manifest.Vendor) catalog $($manifest.Os) $($manifest.OsVer), $(@($manifest.Drivers).Count) packages"
    Write-Information "Output:  $OutputPath"
    if (-not $PSCmdlet.ShouldProcess($OutputPath, "Build ISO: $($image.ImageName) $build + $($manifest.Profile) drivers")) { return }

    if (Get-WindowsImage -Mounted | Where-Object { $_.Path -like "$WorkRoot*" }) {
        throw "A stale image mount exists under $WorkRoot. Run: Dismount-WindowsImage -Path '$mountDir' -Discard"
    }
    if ((Test-Path $WorkRoot) -and -not (Test-Path $marker) -and (Get-ChildItem $WorkRoot -Force | Select-Object -First 1)) {
        throw "$WorkRoot exists and was not created by this script; choose an empty -WorkRoot."
    }
    if (Test-Path $WorkRoot) { Remove-Item -Path $WorkRoot -Recurse -Force }
    $null = New-Item -Path $media -ItemType Directory -Force
    $null = New-Item -Path $marker -ItemType File

    Write-Information 'Copying media...'
    robocopy $source $media /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Write-Verbose
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit $LASTEXITCODE." }
}
finally {
    $null = Dismount-DiskImage -ImagePath $IsoPath -WhatIf:$false
}
Get-ChildItem -Path $media -Recurse -File | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }

# A .wim is serviced in place. DISM cannot service an .esd, so convert the chosen edition to a WIM first.
$workWim = Join-Path $media "sources\$($sourceImage.Name)"
$workIndex = $image.ImageIndex
if ($sourceImage.Extension -eq '.esd') {
    Write-Information 'Converting install.esd to WIM...'
    $esd = $workWim
    $workWim = Join-Path $WorkRoot 'install.wim'
    $null = Export-WindowsImage -SourceImagePath $esd -SourceIndex $workIndex -DestinationImagePath $workWim -CompressionType max
    Remove-Item -Path $esd
    $workIndex = 1
}

Write-Information 'Injecting drivers into install.wim...'
Invoke-WithMountedImage -ImagePath $workWim -Index $workIndex -Action {
    param($dir)
    & $installer -PackagePath $PackagePath -OfflineImagePath $dir
    if ($LASTEXITCODE) { throw "Driver injection failed (Install-DriverBaseline.ps1 exit $LASTEXITCODE)." }
    if (-not $NoFirstBoot) {
        Write-Information 'Adding first-boot firmware/verification run (C:\Kit)...'
        Add-FirstBootRun -ImageRoot $dir -PackagePath $PackagePath -KitRoot $kitRoot
    }
}

# One export keeps only the chosen edition and drops the orphaned resources a commit leaves behind.
Write-Information 'Exporting final install.wim...'
$exportWim = Join-Path $WorkRoot 'export.wim'
$null = Export-WindowsImage -SourceImagePath $workWim -SourceIndex $workIndex -DestinationImagePath $exportWim -CompressionType max
Remove-Item -Path $workWim
Move-Item -Path $exportWim -Destination (Join-Path $media 'sources\install.wim')

if ($bootDriverDirs) {
    Write-Information "Adding $($BootDriver -join ', ') to boot.wim (Windows Setup)..."
    # Index 2 is the Windows Setup image; index 1 is plain WinPE.
    Invoke-WithMountedImage -ImagePath (Join-Path $media 'sources\boot.wim') -Index 2 -Action {
        param($dir)
        foreach ($d in $bootDriverDirs) { $null = Add-WindowsDriver -Path $dir -Driver $d -Recurse }
    }
}

Write-Information 'Building ISO...'
$result = New-WindowsInstallIso -MediaPath $media -Path $OutputPath -VolumeName $volume.FileSystemLabel

if (-not $KeepWorkDir) { Remove-Item -Path $WorkRoot -Recurse -Force }

[pscustomobject]@{
    Iso       = $result.FullName
    SizeGB    = [math]::Round($result.Length / 1GB, 2)
    Edition   = $image.ImageName
    Build     = $build
    Drivers   = "$($manifest.Profile) ($($manifest.Os) $($manifest.OsVer) catalog)"
    FirstBoot = -not $NoFirstBoot
    SHA256    = (Get-FileHash -Path $result.FullName -Algorithm SHA256).Hash
}
