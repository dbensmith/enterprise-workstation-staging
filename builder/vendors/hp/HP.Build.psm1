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

Export-ModuleMember -Function Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap, Get-HPKitModel, Save-HPKitVendorPack, New-HPKitCustomPack, Save-HPKitFirmware
