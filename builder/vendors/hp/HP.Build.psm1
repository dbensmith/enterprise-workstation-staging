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
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $null = $PSCmdlet.ShouldProcess($OutputPath, 'Stage the model')
    throw [System.NotImplementedException]::new("moved in by Task 2 of Plan 01-06 ($($ModelProfile.ModelId) $OsVer -> $OutputPath)")
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
    param(
        [Parameter(Mandatory)][hashtable]$ModelProfile,
        [AllowEmptyString()][string]$OsVer,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $null = $PSCmdlet.ShouldProcess($OutputPath, 'Stage the model')
    throw [System.NotImplementedException]::new("moved in by Task 2 of Plan 01-06 ($($ModelProfile.ModelId) $OsVer -> $OutputPath)")
}

Export-ModuleMember -Function Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap, Get-HPKitModel, Save-HPKitVendorPack, New-HPKitCustomPack, Save-HPKitFirmware
