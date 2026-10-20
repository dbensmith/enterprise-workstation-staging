#Requires -Version 5.1
# HP build-plane module. Builder PC only, never copied to a stick. Loads offline: no HPCMSL import at
# module load (build operations import it lazily).

# Kit.Core is offline-safe and supplies Get-KitProfile and Get-KitPackagePath.
Import-Module (Join-Path $PSScriptRoot '..\..\..\kit\core\Kit.Core.psd1')

function Select-OsRelease {
    <#
    .SYNOPSIS
    Pick the catalog OS release to build against from Get-HPDeviceDetails -OSList output.
    Returns $OsVer if HP indexes it, otherwise the newest release by build number.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$OsList,
        [Parameter(Mandatory)][ValidateSet('win10', 'win11')][string]$Os,
        [string]$OsVer
    )

    $osName = 'Microsoft Windows {0}' -f $Os.Substring(3)
    $releases = @($OsList | Where-Object OperatingSystem -EQ $osName)
    if (-not $releases) {
        throw "HP catalog lists no '$osName' releases for this platform."
    }

    if ($OsVer) {
        if ($OsVer -notin $releases.OperatingSystemRelease) {
            throw "HP catalog does not index $osName $OsVer for this platform. Available: $($releases.OperatingSystemRelease -join ', ')"
        }
        return $OsVer
    }

    ($releases | Sort-Object { [int]$_.BuildNumber } | Select-Object -Last 1).OperatingSystemRelease
}

function Select-BaselineSoftpaq {
    <#
    .SYNOPSIS
    Split SoftPaqs into Included and Excluded (with reason) using profile exclude entries.
    An entry matches a SoftPaq id exactly or any substring of its name (case-insensitive).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Softpaq,
        [string[]]$Exclude = @(),
        # Drop SoftPaqs HP has not flagged as driver-pack eligible (DPB).
        [switch]$RequireDriverPack
    )

    $included = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()

    foreach ($sp in $Softpaq) {
        $reason = if ($RequireDriverPack -and -not $sp.DPB) {
            'Not driver-pack eligible (DPB=false)'
        }
        else {
            $hit = $Exclude | Where-Object { $sp.id -eq $_ -or $sp.Name -like "*$_*" } | Select-Object -First 1
            if ($hit) { "Matches profile exclude '$hit'" }
        }

        if ($reason) {
            $excluded.Add([pscustomobject]@{ Id = $sp.id; Name = $sp.Name; Reason = $reason })
        }
        else {
            $included.Add($sp)
        }
    }

    [pscustomobject]@{ Included = $included.ToArray(); Excluded = $excluded.ToArray() }
}

function Split-SoftpaqCommand {
    <#
    .SYNOPSIS
    Split a CVA install command line ('"Tool.exe" -a -b' or 'Tool.exe -a') into File and Arguments.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    if ($CommandLine -match '^\s*"(?<file>[^"]+)"\s*(?<args>.*)$' -or $CommandLine -match '^\s*(?<file>\S+)\s*(?<args>.*)$') {
        return [pscustomobject]@{ File = $Matches.file; Arguments = $Matches.args.Trim() }
    }
    throw "Cannot parse SoftPaq command line: '$CommandLine'"
}

function ConvertTo-ReturnCodeMap {
    <#
    .SYNOPSIS
    Convert a CVA [ReturnCode] section ('3010:SUCCESS:REBOOT' = 'message') into an ordered
    code -> { Result, Reboot, Message } map, sorted by code.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][System.Collections.IDictionary]$ReturnCode)

    $entries = foreach ($key in @($ReturnCode.Keys)) {
        if ($key -match '^(?<code>-?\d+):(?<result>[A-Z]+):(?<reboot>[A-Z]+)$') {
            [pscustomobject]@{
                Code    = [int]$Matches.code
                Result  = $Matches.result
                Reboot  = $Matches.reboot -eq 'REBOOT'
                Message = $ReturnCode[$key]
            }
        }
    }

    $map = [ordered]@{}
    foreach ($e in ($entries | Sort-Object Code)) {
        $map["$($e.Code)"] = [pscustomobject]@{ Result = $e.Result; Reboot = $e.Reboot; Message = $e.Message }
    }
    $map
}

function Initialize-HPCMSL {
    # Import HPCMSL, installing it from the PowerShell Gallery first when it is missing. Build operations
    # call this lazily, so merely importing this module never needs HPCMSL.
    [CmdletBinding()]
    param()

    if (Get-Module -ListAvailable -Name HPCMSL) {
        Import-Module HPCMSL
        return
    }

    Write-Information 'Installing HPCMSL from the PowerShell Gallery...'
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # Windows PowerShell 5.1 defaults to TLS 1.0/1.1, which the Gallery rejects.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
    $install = @{ Name = 'HPCMSL'; Scope = 'AllUsers'; Force = $true }
    # -AcceptLicense only exists in PowerShellGet 2.x+; inbox 1.0.0.1 on 5.1 lacks it.
    if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) { $install.AcceptLicense = $true }
    Install-Module @install
    Import-Module HPCMSL
}

function Test-HPKitElevation {
    # True when the session runs as an administrator.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-HPKitElevation {
    # New-HPBuildDriverPack and SoftPaq self-extraction both require elevation. -WhatIf only reads the catalog.
    [CmdletBinding()]
    param()

    if (-not $WhatIfPreference -and -not (Test-HPKitElevation)) {
        throw 'Run from an elevated PowerShell session (or add -WhatIf to preview the selection).'
    }
}

function Reset-HPKitDirectory {
    # Empty a stage's output so SoftPaqs superseded since the last build don't linger.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Recreate empty directory')) { return }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    $null = New-Item -Path $Path -ItemType Directory -Force
}

function ConvertTo-HPKitSoftpaqSummary {
    # The fields the manifest records for one SoftPaq.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, ValueFromPipeline)][object]$Softpaq)

    process {
        [pscustomobject]@{ Id = $Softpaq.id; Name = $Softpaq.Name; Version = $Softpaq.Version; Category = $Softpaq.Category; ReleaseDate = $Softpaq.ReleaseDate }
    }
}

function Resolve-HPKitOsRelease {
    # The catalog release to build against: the requested one if HP indexes it, else the newest.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer
    )

    $requested = if ($OsVer) { $OsVer } else { $ModelProfile.OsVer }
    Select-OsRelease -OsList (Get-HPDeviceDetails -Platform $ModelProfile.Platform -OSList) -Os $ModelProfile.Os -OsVer $requested
}

function Get-HPKitToolVersion {
    # Versions of the tools that produced a package, recorded in the manifest.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{ HPCMSL = "$((Get-Module HPCMSL).Version)" }
}

function Get-HPKitModel {
    <#
    .SYNOPSIS
    List the HP models this kit has a profile for (ListModels operation).

    .DESCRIPTION
    Reads the HP profiles with Get-KitProfile and projects the fields a model picker needs. Offline:
    no catalog query.

    .EXAMPLE
    Get-HPKitModel | Format-Table ModelId, Platform, PlatformVerified

    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    foreach ($modelProfile in @(Get-KitProfile -Vendor HP)) {
        [pscustomobject]@{
            Vendor           = $modelProfile.Vendor
            ModelId          = $modelProfile.ModelId
            Name             = $modelProfile.Name
            Platform         = $modelProfile.Platform
            PlatformVerified = $modelProfile.PlatformVerified
            ProfilePath      = $modelProfile.ProfilePath
        }
    }
}

function Save-HPKitVendorPack {
    <#
    .SYNOPSIS
    Download HP's published driver pack for a model (GetVendorPack operation). Not implemented yet.

    .DESCRIPTION
    Delivered in Phase 4 (BUILD-03). The function exists now so the vendor contract sees the real
    signature; it throws NotImplementedException naming what was asked for.

    .PARAMETER ModelProfile
    Model profile from Get-KitProfile.

    .PARAMETER OsVer
    OS release, or empty for the newest the catalog indexes.

    .PARAMETER OutputPath
    Staging root folder.

    .EXAMPLE
    Save-HPKitVendorPack -ModelProfile $modelProfile -OsVer 24H2 -OutputPath .\staging

    .OUTPUTS
    None. Always throws until Phase 4.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )

    # Always throws: the pack download is Phase 4, so -WhatIf gets the same answer as a real run.
    $null = $PSCmdlet.ShouldProcess($OutputPath, 'Download the vendor driver pack')
    throw [System.NotImplementedException]::new("GetVendorPack (HP's published driver pack) is BUILD-03, delivered in Phase 4; requested for $($ModelProfile.ModelId) $OsVer -> $OutputPath.")
}

function New-HPKitCustomPack {
    <#
    .SYNOPSIS
    Build the custom driver pack from the HP catalog (NewCustomPack operation).

    .PARAMETER ModelProfile
    Model profile from Get-KitProfile.

    .PARAMETER OsVer
    OS release, or empty for the newest the catalog indexes.

    .PARAMETER OutputPath
    Staging root folder.

    .EXAMPLE
    New-HPKitCustomPack -ModelProfile $modelProfile -OsVer '' -OutputPath .\staging

    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )

    Assert-HPKitElevation
    Initialize-HPCMSL
    $osRelease = Resolve-HPKitOsRelease -ModelProfile $ModelProfile -OsVer $OsVer
    Write-Information "$($ModelProfile.Name) [$($ModelProfile.Platform)]: building against HP catalog $($ModelProfile.Os) $osRelease"
    $packageDir = Get-KitPackagePath -OutputRoot $OutputPath -Vendor HP -ModelId $ModelProfile.ModelId -Os $ModelProfile.Os -OsVer $osRelease
    $query = @{ Platform = $ModelProfile.Platform; Os = $ModelProfile.Os; OsVer = $osRelease; Quiet = $true }

    $selection = Select-BaselineSoftpaq -Softpaq @(Get-HPSoftpaqList @query -Category Driver) -Exclude $ModelProfile.DriverExclude -RequireDriverPack
    if (-not $selection.Included) { throw 'Driver selection is empty; check the profile excludes and catalog.' }

    $driverDir = Join-Path $packageDir 'Drivers'
    Reset-HPKitDirectory -Path $driverDir
    if ($PSCmdlet.ShouldProcess($driverDir, "Build driver pack from $($selection.Included.Count) SoftPaqs")) {
        # The pack lands in <Path>\<Name>, so build into the package root to get <package>\Drivers.
        # HPCMSL's own "JSON is truncated" warning here is harmless: it's its internal Drivers\manifest.json.
        $null = $selection.Included | New-HPBuildDriverPack -Path $packageDir -Name 'Drivers' -Format NoCompressedFile -Os $ModelProfile.Os -OSVer $osRelease -Overwrite
    }

    [pscustomobject]@{
        Operation    = 'NewCustomPack'
        PackagePath  = $packageDir
        OsVer        = $osRelease
        PackKind     = 'custom'
        Drivers      = @($selection.Included | ConvertTo-HPKitSoftpaqSummary)
        Excluded     = @($selection.Excluded | Select-Object -Property *, @{ Name = 'Stage'; Expression = { 'Drivers' } })
        ToolVersions = Get-HPKitToolVersion
    }
}

function Save-HPKitFirmware {
    <#
    .SYNOPSIS
    Download and extract the model's BIOS and firmware SoftPaqs (GetFirmware operation).

    .PARAMETER ModelProfile
    Model profile from Get-KitProfile.

    .PARAMETER OsVer
    OS release, or empty for the newest the catalog indexes.

    .PARAMETER OutputPath
    Staging root folder.

    .EXAMPLE
    Save-HPKitFirmware -ModelProfile $modelProfile -OsVer '' -OutputPath .\staging

    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )

    Assert-HPKitElevation
    Initialize-HPCMSL
    $osRelease = Resolve-HPKitOsRelease -ModelProfile $ModelProfile -OsVer $OsVer
    Write-Information "$($ModelProfile.Name) [$($ModelProfile.Platform)]: staging firmware from HP catalog $($ModelProfile.Os) $osRelease"
    $packageDir = Get-KitPackagePath -OutputRoot $OutputPath -Vendor HP -ModelId $ModelProfile.ModelId -Os $ModelProfile.Os -OsVer $osRelease
    $query = @{ Platform = $ModelProfile.Platform; Os = $ModelProfile.Os; OsVer = $osRelease; Quiet = $true }

    $selection = Select-BaselineSoftpaq -Softpaq @(Get-HPSoftpaqList @query -Category BIOS, Firmware) -Exclude $ModelProfile.FirmwareExclude
    $firmwareDir = Join-Path $packageDir 'Firmware'
    Reset-HPKitDirectory -Path $firmwareDir

    $firmware = @(foreach ($sp in $selection.Included) {
            $number = $sp.id -replace '^sp', ''
            $extractDir = Join-Path $firmwareDir $sp.id
            if ($PSCmdlet.ShouldProcess($sp.id, "Download + extract '$($sp.Name)' $($sp.Version)")) {
                # With -DestinationPath, HPCMSL also saves the .exe there (it joins -SaveAs onto it), so no -SaveAs.
                $null = Get-HPSoftpaq -Number $number -Overwrite yes -Quiet -Extract -DestinationPath $extractDir
            }

            $meta = Get-HPSoftpaqMetadata -Number $number
            $silent = $meta.'Install Execution'.SilentInstall
            $entry = $sp | ConvertTo-HPKitSoftpaqSummary
            $entry | Add-Member -NotePropertyMembers ([ordered]@{
                    Path           = "Firmware/$($sp.id)"
                    # Only HP's SSM-flagged (silent-supported) SoftPaqs are auto-applied; others are staged for a technician.
                    AutoInstall    = [bool]($sp.SSM -and $silent)
                    SilentInstall  = $(if ($silent) { Split-SoftpaqCommand $silent })  # $() so Windows PowerShell 5.1 parses it
                    RebootRequired = $meta.General.SystemMustBeRebooted -eq '1'
                    # CVA [Devices] hardware IDs (e.g. a specific SSD model); the installer skips the item when none is present.
                    Devices        = @($meta.Devices.Keys | Where-Object { $_ -ne '_body' })
                    ReturnCodes    = ConvertTo-ReturnCodeMap $meta.ReturnCode
                })
            $entry
        })

    [pscustomobject]@{
        Operation    = 'GetFirmware'
        PackagePath  = $packageDir
        OsVer        = $osRelease
        Firmware     = $firmware
        Excluded     = @($selection.Excluded | Select-Object -Property *, @{ Name = 'Stage'; Expression = { 'Firmware' } })
        ToolVersions = Get-HPKitToolVersion
    }
}

function Get-HPKitWindowsFlashFile {
    <#
    .SYNOPSIS
    List the files of an extracted SoftPaq folder that may be staged as the Windows flash fallback.

    .DESCRIPTION
    Private helper of Get-HPKitFirmwareStickLayout. Every file below the folder is listed with its path inside the
    folder, sub-folders kept. The SoftPaq self-extractor <PackageId>.exe at the folder root is left out without a note
    (it is not part of the tool). A BIOS password file (HPQPswd*.bin, password.bin) is left out with a note, because
    such a file is generated from a password and must never travel on a stick. Files are sorted by path, ordinal and
    case-insensitive.

    .PARAMETER Directory
    The extracted SoftPaq folder, the one that holds the BIOS image.

    .PARAMETER PackageId
    The SoftPaq id, for example sp174025.

    .OUTPUTS
    File (Relative, FullName, Length for each file) and Note (one sentence for each file left out).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$PackageId
    )

    $root = (Resolve-Path -LiteralPath $Directory).ProviderPath.TrimEnd('\')
    $file = [System.Collections.Generic.List[object]]::new()
    $note = [System.Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $item.FullName.Substring($root.Length + 1)
        if ($relative -eq "$PackageId.exe") { continue }
        if ($item.Name -like '*Pswd*.bin' -or $item.Name -eq 'password.bin') {
            $note.Add("Left out $($item.Name): BIOS password files are never staged.")
            continue
        }
        $file.Add([pscustomobject]@{ Relative = $relative; FullName = $item.FullName; Length = [long]$item.Length })
    }
    $file.Sort([System.Comparison[object]] {
            param($left, $right)
            [string]::Compare($left.Relative, $right.Relative, [System.StringComparison]::OrdinalIgnoreCase)
        })
    [pscustomobject]@{ File = $file.ToArray(); Note = $note.ToArray() }
}

function Get-HPKitDependencyMinimum {
    <#
    .SYNOPSIS
    Read the BIOS a SoftPaq needs first from its CVA [Dependency] section.

    .DESCRIPTION
    Private helper of Get-HPKitFirmwareStickLayout. The key is MinimumBIOSVersion_<BiosFamily>. The version is written
    two digits per part (1.35.2 becomes 01.35.02; a missing third part counts as 0). A value that is not a version is
    kept as written and explained in Note. A SoftPaq with no Dependency section, or none for this family, gives an
    empty Value.

    .PARAMETER Dependency
    The CVA Dependency section, or $null.

    .PARAMETER BiosFamily
    The BIOS family of the model, for example R70.

    .OUTPUTS
    Value (the minimum BIOS as text, or empty) and Note (a sentence, or empty).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object]$Dependency,
        [Parameter(Mandatory)][string]$BiosFamily
    )

    $key = "MinimumBIOSVersion_$BiosFamily"
    $raw = $null
    if ($Dependency -is [System.Collections.IDictionary]) {
        if ($Dependency.Contains($key)) { $raw = $Dependency[$key] }
    }
    elseif ($null -ne $Dependency) {
        $property = $Dependency.PSObject.Properties[$key]
        if ($property) { $raw = $property.Value }
    }
    $text = ([string]$raw).Trim()
    if (-not $text) { return [pscustomobject]@{ Value = ''; Note = '' } }

    $parsed = $null
    if ([version]::TryParse($text, [ref]$parsed)) {
        $value = '{0:D2}.{1:D2}.{2:D2}' -f $parsed.Major, $parsed.Minor, [Math]::Max(0, $parsed.Build)
        return [pscustomobject]@{ Value = $value; Note = '' }
    }
    [pscustomobject]@{ Value = $text; Note = "The BIOS dependency '$text' is not a version number; it is recorded as written." }
}

function Get-HPKitFirmwareStickLayout {
    <#
    .SYNOPSIS
    Resolve the model's downloaded BIOS image into Tools stick entries (GetFirmwareStickLayout operation).

    .DESCRIPTION
    Reads the firmware package the GetFirmware operation already filled and the HP stick layout, asks the HP
    catalog for the platform's BIOS list (Get-HPBIOSUpdates -All), takes the highest version and finds that
    version's image in the package by the catalog's file name. There is no second download. The image keeps
    the name HP ships, so the G5 and G6 images never share a path. The function only reads: it writes nothing.

    The result is the vendor contract Kit.FirmwareStickLayout: PlatformId, PlatformVerified, BiosFamily,
    LatestBios, Entries and Notes. One entry is produced per layout group that this module resolves: a
    BiosImage group gives the image under its folder, a FlashImage group gives a copy named firmware.bin,
    a WindowsFlashTool group gives every file of the extracted SoftPaq folder except the self-extractor and any BIOS
    password file, a Captured group gives nothing (the core replays it from a recorded snapshot).

    The SoftPaq metadata (Get-HPSoftpaqMetadata, the CVA) fills WindowsFlash (how to run the flash tool and what its
    return codes mean) and LatestBios.DependencyMinimum (the BIOS the image needs first; it is recorded, never staged).
    A SoftPaq executable whose SHA-256 differs from the CVA value stops the call, naming the file.

    .PARAMETER ModelProfile
    Model profile from Get-KitProfile.

    .PARAMETER PackagePath
    The package folder the GetFirmware operation returned.

    .PARAMETER LayoutPath
    Layout file to use. Empty means the HP layout shipped under kit\vendors\hp\layouts.

    .EXAMPLE
    Get-HPKitFirmwareStickLayout -ModelProfile $modelProfile -PackagePath $firmware.PackagePath -LayoutPath ''

    .OUTPUTS
    System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [Parameter(Mandatory)][string]$PackagePath,
        [AllowEmptyString()][string]$LayoutPath
    )

    Initialize-HPCMSL
    if (-not $LayoutPath) {
        $LayoutPath = Join-Path -Path (Get-KitRoot) -ChildPath 'vendors\hp\layouts\hp-usb-flash.layout.psd1'
    }
    $layout = Get-KitFirmwareLayout -Path $LayoutPath
    $platformId = Get-KitVerifiedValue -ModelProfile $ModelProfile -Name Platform -AllowUnverified

    # The build stops on the first problem and names the file: nothing is staged from a download that cannot be trusted.
    $catalog = @(Get-HPBIOSUpdates -Platform $platformId -All)
    if ($catalog.Count -eq 0) {
        throw "The HP catalog lists no BIOS update for platform $platformId ($($ModelProfile.ModelId)); there is no image to resolve."
    }
    $latest = $catalog | Sort-Object -Property @{ Expression = { [version]$_.Ver }; Descending = $true } | Select-Object -First 1
    $version = [version]$latest.Ver
    $bin = [string]$latest.Bin
    $vendorSha384 = ([string]$latest.Sha384).ToLowerInvariant()
    if (-not $vendorSha384) {
        throw "The HP catalog entry for $bin (BIOS $($latest.Ver)) has no SHA-384, so the image cannot be verified."
    }
    if ([string]::IsNullOrWhiteSpace($bin) -or $bin.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "The HP catalog file name '$bin' for BIOS $($latest.Ver) is not a plain file name (it is empty, or holds a path separator or another character a file name cannot hold)."
    }

    $firmwareDir = Join-Path -Path $PackagePath -ChildPath 'Firmware'
    $found = @()
    if (Test-Path -LiteralPath $firmwareDir -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $firmwareDir -Recurse -File -Filter $bin)
    }
    if ($found.Count -eq 0) {
        throw "BIOS image $bin ($($latest.Ver)) was not found under $firmwareDir; run the firmware stage first."
    }
    if ($found.Count -gt 1) {
        throw "BIOS image $bin ($($latest.Ver)) was found in more than one folder: $(($found | ForEach-Object { $_.DirectoryName }) -join '; '). Remove the extra copy and run the firmware stage again."
    }
    $image = $found[0]
    if (-not $bin.StartsWith([string]$ModelProfile.BiosFamily, [StringComparison]::OrdinalIgnoreCase)) {
        throw "BIOS image $bin does not belong to $($ModelProfile.ModelId): a $($ModelProfile.BiosFamily) image name starts with $($ModelProfile.BiosFamily)."
    }
    $sha384 = (Get-FileHash -LiteralPath $image.FullName -Algorithm SHA384).Hash.ToLowerInvariant()
    if ($sha384 -ne $vendorSha384) {
        throw "BIOS image $bin does not match the HP catalog hash for $($latest.Ver) (catalog $vendorSha384, file $sha384); download it again."
    }
    $sha256 = (Get-FileHash -LiteralPath $image.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $entries = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    # The CVA of the SoftPaq says how to run the flash tool, which BIOS the image needs first and what the executable
    # must hash to. A metadata call that fails stops the build.
    $packageId = $image.Directory.Name
    $meta = Get-HPSoftpaqMetadata -Number ($packageId -replace '^sp', '')
    $executable = Join-Path -Path $image.Directory.FullName -ChildPath "$packageId.exe"
    $cvaSha256 = [string]$meta.Softpaq.SoftPaqSHA256
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        $notes.Add("$packageId.exe is not cached; its hash was not rechecked.")
    }
    elseif (-not $cvaSha256) {
        $notes.Add("HP published no SHA-256 for $packageId.exe.")
    }
    elseif ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne $cvaSha256.Trim()) {
        throw "SoftPaq executable $packageId.exe does not match the HP CVA hash; delete $($image.Directory.FullName) and rebuild."
    }
    $dependency = Get-HPKitDependencyMinimum -Dependency $meta.Dependency -BiosFamily ([string]$ModelProfile.BiosFamily)
    if ($dependency.Note) { $notes.Add($dependency.Note) }

    foreach ($group in $layout.Groups) {
        $folder = $group.Folder.Replace('{Platform}', $platformId)
        switch ($group.SourceKind) {
            { $_ -in 'BiosImage', 'FlashImage' } {
                $leaf = if ($_ -eq 'BiosImage') { $bin } else { 'firmware.bin' }
                $entries.Add([pscustomobject]@{
                        RelativePath = "$folder\$leaf"
                        SourcePath   = $image.FullName
                        Group        = $group.Id
                        Size         = $image.Length
                        Sha256       = $sha256
                        VendorHash   = [pscustomobject]@{ Algorithm = 'SHA384'; Value = $vendorSha384; Source = 'Get-HPBIOSUpdates -All' }
                    })
            }
            'WindowsFlashTool' {
                $tool = Get-HPKitWindowsFlashFile -Directory $image.Directory.FullName -PackageId $image.Directory.Name
                foreach ($each in $tool.File) {
                    $entries.Add([pscustomobject]@{
                            RelativePath = "$folder\$($each.Relative)"
                            SourcePath   = $each.FullName
                            Group        = $group.Id
                            Size         = $each.Length
                            Sha256       = (Get-FileHash -LiteralPath $each.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                            VendorHash   = $null
                        })
                }
                foreach ($note in $tool.Note) { $notes.Add($note) }
            }
            'Captured' { }
            default { throw "Layout group $($group.Id) uses source kind $($group.SourceKind), which this vendor module cannot resolve." }
        }
    }

    # How to run the Windows flash tool: only when the layout stages it. The return codes keep the CVA order (by code).
    $windowsFlash = $null
    $toolGroup = $layout.Groups | Where-Object SourceKind -EQ 'WindowsFlashTool' | Select-Object -First 1
    if ($toolGroup) {
        $returnCodes = [ordered]@{}
        $codeMap = ConvertTo-ReturnCodeMap $meta.ReturnCode
        foreach ($code in $codeMap.Keys) {
            $returnCodes[[string]$code] = if ($codeMap[$code].Reboot) { "$($codeMap[$code].Result):REBOOT" } else { [string]$codeMap[$code].Result }
        }
        $windowsFlash = [pscustomobject]@{
            Path          = $toolGroup.Folder.Replace('{Platform}', $platformId)
            SilentInstall = [string]$meta.'Install Execution'.SilentInstall
            ReturnCodes   = $returnCodes
        }
    }

    $date = if ($latest.Date -is [datetime]) { $latest.Date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } else { [string]$latest.Date }
    [pscustomobject]@{
        PSTypeName       = 'Kit.FirmwareStickLayout'
        Operation        = 'GetFirmwareStickLayout'
        Vendor           = $ModelProfile.Vendor
        LayoutPath       = $layout.Path
        ModelId          = $ModelProfile.ModelId
        Name             = $ModelProfile.Name
        PlatformId       = $platformId
        PlatformVerified = [bool]$ModelProfile.PlatformVerified
        BiosFamily       = $ModelProfile.BiosFamily
        LatestBios       = [pscustomobject]@{
            Version           = '{0:D2}.{1:D2}.{2:D2}' -f $version.Major, $version.Minor, [Math]::Max(0, $version.Build)
            Date              = $date
            PackageId         = $image.Directory.Name
            File              = $bin
            DependencyMinimum = $dependency.Value
        }
        WindowsFlash     = $windowsFlash
        Entries          = $entries.ToArray()
        Notes            = $notes.ToArray()
    }
}

Export-ModuleMember -Function Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap, Get-HPKitModel, Save-HPKitVendorPack, New-HPKitCustomPack, Save-HPKitFirmware, Get-HPKitFirmwareStickLayout
