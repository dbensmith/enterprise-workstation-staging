#Requires -Version 5.1
# HP target-plane commands. Runs on a stock laptop from the Tools stick or the image: CIM, registry, pnputil.exe, dism.exe and package firmware executables only. Never import HPCMSL here.

Import-Module (Join-Path $PSScriptRoot '..\..\core\Kit.Core.psd1')

function ConvertTo-HPBiosVersion {
    <#
    .SYNOPSIS
    Parse an HP BIOS string into its family and version.

    .DESCRIPTION
    Reads both the SMBIOS form ('R70 Ver. 01.36.00') and the SoftPaq name form
    ('HP BIOS and System Firmware (R70) 1.36.00'). Both give Family 'R70' and Version 1.36.0.
    Text that holds no family and version returns nothing.

    .PARAMETER Text
    The BIOS string to parse. May be empty.

    .EXAMPLE
    ConvertTo-HPBiosVersion 'R70 Ver. 01.36.00'
    Returns Family R70 and Version 1.36.0.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Family (string) and Version (version), or nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text
    )

    if ($Text -cmatch '\b(?<family>[A-Z]\d{2})\b.*?(?<ver>\d{1,2}\.\d{2}\.\d{2})') {
        [pscustomobject]@{
            Family  = $Matches['family']
            Version = [version]$Matches['ver']
        }
    }
}

function Get-HPKitInstalledFirmware {
    <#
    .SYNOPSIS
    Read the installed BIOS family and version of this PC.

    .DESCRIPTION
    Parses Win32_BIOS.SMBIOSBIOSVersion with ConvertTo-HPBiosVersion. Returns nothing when the
    string cannot be parsed.

    .EXAMPLE
    Get-HPKitInstalledFirmware
    Returns Family R70 and Version 1.36.0 on an EliteBook 840 G6 with BIOS R70 Ver. 01.36.00.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Family and Version, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $bios = Get-CimInstance -ClassName Win32_BIOS
    ConvertTo-HPBiosVersion -Text "$($bios.SMBIOSBIOSVersion)"
}

function Get-FirmwareSkipReason {
    <#
    .SYNOPSIS
    Say why a firmware item does not need to run on this PC, or return nothing when it does.

    .DESCRIPTION
    A BIOS item (Category starting with 'BIOS') is skipped when the installed BIOS has the same
    family and a version greater than or equal to the package's. An unparseable or other-family
    installed BIOS never skips: HP's updater decides. An item with a device list is skipped with
    exactly 'no matching device in this PC' when none of its hardware IDs is present. Any other
    item returns nothing without reading CIM.

    .PARAMETER Firmware
    One Firmware entry of the package manifest (Id, Name, Version, Category, Devices).

    .EXAMPLE
    Get-FirmwareSkipReason $manifest.Firmware[0]
    Returns 'BIOS 1.36.0 already current (package 1.36.0)' when the BIOS is up to date.

    .OUTPUTS
    System.String, or nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][object]$Firmware
    )

    if ($Firmware.Category -like 'BIOS*') {
        $installed = Get-HPKitInstalledFirmware
        $package = ConvertTo-HPBiosVersion -Text "$($Firmware.Name) $($Firmware.Version)"
        if ($installed -and $package -and $installed.Family -ceq $package.Family -and $installed.Version -ge $package.Version) {
            return 'BIOS {0} already current (package {1})' -f $installed.Version, $package.Version
        }
        return
    }

    $devices = @($Firmware.Devices | Where-Object { $_ })
    if ($devices.Count -gt 0) {
        $present = @(Get-CimInstance -ClassName Win32_PnPEntity | ForEach-Object { $_.HardwareID } | Where-Object { $_ })
        $found = $devices | Where-Object { $present -contains $_ }
        if (-not $found) {
            return 'no matching device in this PC'
        }
    }
}

function Get-HPKitDeviceIdentity {
    <#
    .SYNOPSIS
    Describe this laptop: vendor, model, serial, BIOS string and board platform ID.

    .DESCRIPTION
    Reads Win32_ComputerSystem, Win32_BIOS and Win32_BaseBoard. PlatformId is the board product
    (for example 8549), falling back to the registry BaseBoardProduct value when CIM has none.
    Every string is trimmed.

    .EXAMPLE
    Get-HPKitDeviceIdentity
    Returns Vendor HP, Model 'HP EliteBook 840 G6', PlatformId 8549 and the serial number.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Vendor, Manufacturer, Model, PlatformId, Serial, BiosVersion.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue

    $platformId = "$($board.Product)".Trim()
    if (-not $platformId) {
        $platformId = "$(Get-ItemPropertyValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BaseBoardProduct' -ErrorAction SilentlyContinue)".Trim()
    }

    [pscustomobject]@{
        Vendor       = 'HP'
        Manufacturer = "$($system.Manufacturer)".Trim()
        Model        = "$($system.Model)".Trim()
        PlatformId   = $platformId
        Serial       = "$($bios.SerialNumber)".Trim()
        BiosVersion  = "$($bios.SMBIOSBIOSVersion)".Trim()
    }
}

function ConvertTo-HPKitResult {
    # Private: the one result shape both install commands emit.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [string]$Id,
        [string]$Name,
        [string]$Version,
        [Parameter(Mandatory)][ValidateSet('SUCCESS', 'CANCEL', 'FAILURE', 'SKIPPED', 'MANUAL')][string]$Result,
        [object]$ExitCode,
        [string]$Detail
    )

    [pscustomobject]@{
        Operation = $Operation
        Id        = $Id
        Name      = $Name
        Version   = $Version
        Result    = $Result
        ExitCode  = $ExitCode
        Detail    = $Detail
    }
}

function Install-HPKitDriver {
    <#
    .SYNOPSIS
    Install the drivers of a baseline package: online with pnputil.exe, or into an offline image with dism.exe.

    .DESCRIPTION
    Online (default) stages and installs every .inf under the package's Drivers folder with
    pnputil.exe /add-driver /subdirs /install. Exit codes 0, 3010, 259 (staged, no present device
    needed them) and -536870365 (driver does not apply to this hardware variant) are accepted.
    With -OfflineImagePath, injects the drivers into the mounted Windows image with
    dism.exe /Add-Driver /Recurse. A package with no Drivers folder is skipped cleanly.
    A failing tool throws; the caller counts it. -WhatIf runs nothing.

    .PARAMETER PackagePath
    The package root (the folder holding manifest.json and Drivers).

    .PARAMETER OfflineImagePath
    A mounted Windows image folder. When given, drivers are injected instead of installed.

    .EXAMPLE
    Install-HPKitDriver -PackagePath D:\Packages\8549
    Stages and installs the drivers on this PC.

    .EXAMPLE
    Install-HPKitDriver -PackagePath D:\Packages\8549 -OfflineImagePath C:\Mount\install
    Injects the drivers into the mounted image.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Operation, Mode, Id, Name, Version, Result, ExitCode, Detail.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [string]$OfflineImagePath
    )

    $mode = if ($OfflineImagePath) { 'Offline' } else { 'Online' }
    $driverDir = Join-Path -Path $PackagePath -ChildPath 'Drivers'
    $result = @{ Operation = 'InstallDrivers'; Name = 'Drivers' }

    if (-not (Test-Path -LiteralPath $driverDir -PathType Container)) {
        $row = ConvertTo-HPKitResult @result -Result SKIPPED -Detail 'package has no Drivers folder'
        $row | Add-Member -NotePropertyName Mode -NotePropertyValue $mode
        return $row
    }

    # -Confirm answered No stops here. Under -WhatIf the call still goes to Invoke-KitTool with -WhatIf, which prints the exact command and starts nothing.
    # Preference variables do not cross into Kit.Core's module scope, so -WhatIf is passed explicitly.
    if ($PSCmdlet.ShouldProcess($driverDir, "Install drivers ($mode)") -or $WhatIfPreference) {
        if ($OfflineImagePath) {
            Invoke-KitTool -FilePath 'dism.exe' -ArgumentList "/Image:$OfflineImagePath", '/Add-Driver', "/Driver:$driverDir", '/Recurse' -WhatIf:$WhatIfPreference
        }
        else {
            # 259 = drivers staged but no present device needed them; -536870365 (0xE0000223) = driver does not apply to this hardware variant.
            Invoke-KitTool -FilePath 'pnputil.exe' -ArgumentList '/add-driver', "$driverDir\*.inf", '/subdirs', '/install' -OkCode 0, 3010, 259, -536870365 -WhatIf:$WhatIfPreference
        }
    }
    else {
        $row = ConvertTo-HPKitResult @result -Result SKIPPED -Detail 'not confirmed'
        $row | Add-Member -NotePropertyName Mode -NotePropertyValue $mode
        return $row
    }

    $outcome, $detail = if ($WhatIfPreference) { 'SKIPPED', 'WhatIf: nothing run' } else { 'SUCCESS', "drivers installed ($mode)" }
    $row = ConvertTo-HPKitResult @result -Result $outcome -Detail $detail
    $row | Add-Member -NotePropertyName Mode -NotePropertyValue $mode
    $row
}

function Install-HPKitFirmware {
    <#
    .SYNOPSIS
    Run the auto-install firmware items of a baseline package, BIOS last.

    .DESCRIPTION
    Reads manifest.json in the package. Items without AutoInstall are reported MANUAL. Auto items
    run non-BIOS first and the BIOS last (it schedules the flash for the next reboot). An item
    Get-FirmwareSkipReason flags is reported SKIPPED. When an item that will run needs a reboot and
    BitLocker protection is on for the system drive, BitLocker is suspended for one reboot first.
    Each executable must resolve under the package's Firmware folder and exist, else the item is a
    FAILURE and is not launched. Exit codes map through the item's ReturnCodes; unmapped 0 is SUCCESS
    and any other code is FAILURE. This command emits results and never writes errors: the caller
    decides what counts as a failure. -WhatIf runs nothing.

    .PARAMETER PackagePath
    The package root (the folder holding manifest.json and Firmware).

    .EXAMPLE
    Install-HPKitFirmware -PackagePath D:\Packages\8549
    Runs the firmware updaters and returns one result per manifest item.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with Operation, Id, Name, Version, Result (SUCCESS, CANCEL, FAILURE, SKIPPED, MANUAL), ExitCode, Detail.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackagePath
    )

    $manifest = Get-Content -LiteralPath (Join-Path -Path $PackagePath -ChildPath 'manifest.json') -Raw | ConvertFrom-Json
    $firmware = @($manifest.Firmware | Where-Object { $_ })
    $packageRoot = [System.IO.Path]::GetFullPath($PackagePath)
    $firmwareRoot = (Join-Path -Path $packageRoot -ChildPath 'Firmware') + '\'

    foreach ($fw in $firmware | Where-Object { -not $_.AutoInstall }) {
        $detail = "manual firmware (no silent install, or device-specific): $($fw.Path)"
        Write-Warning "$($fw.Id) $($fw.Name) $($fw.Version): $detail"
        ConvertTo-HPKitResult -Operation InstallFirmware -Id $fw.Id -Name $fw.Name -Version $fw.Version -Result MANUAL -Detail $detail
    }

    # BIOS last: it schedules the flash for the next reboot.
    $auto = @($firmware | Where-Object { $_.AutoInstall })
    $auto = @($auto | Where-Object { $_.Category -notlike 'BIOS*' }) + @($auto | Where-Object { $_.Category -like 'BIOS*' })

    $plan = foreach ($fw in $auto) {
        $folder = [System.IO.Path]::GetFullPath((Join-Path -Path $packageRoot -ChildPath $fw.Path))
        $exe = [System.IO.Path]::GetFullPath((Join-Path -Path $folder -ChildPath $fw.SilentInstall.File))
        $problem = $null
        if (-not $exe.StartsWith($firmwareRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $problem = "executable is outside the package Firmware folder ($exe)"
        }
        elseif (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            $problem = "executable not found ($exe)"
        }
        [pscustomobject]@{ Item = $fw; Folder = $folder; Exe = $exe; Problem = $problem; Skip = Get-FirmwareSkipReason -Firmware $fw }
    }

    $willRun = @($plan | Where-Object { -not $_.Skip -and -not $_.Problem -and $_.Item.RebootRequired })
    if ($willRun.Count -gt 0) {
        # HpFirmwareUpdRec returns 290 in silent mode while BitLocker protection is on.
        if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
            if ($volume -and $volume.ProtectionStatus -eq 'On') {
                if ($PSCmdlet.ShouldProcess($env:SystemDrive, 'Suspend BitLocker for 1 reboot')) {
                    try {
                        $null = Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop
                    }
                    catch {
                        Write-Warning "Could not suspend BitLocker on $env:SystemDrive`: $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    foreach ($step in $plan) {
        $fw = $step.Item
        $row = @{ Operation = 'InstallFirmware'; Id = $fw.Id; Name = $fw.Name; Version = $fw.Version }

        if ($step.Skip) {
            ConvertTo-HPKitResult @row -Result SKIPPED -Detail $step.Skip
            continue
        }
        if ($step.Problem) {
            ConvertTo-HPKitResult @row -Result FAILURE -Detail $step.Problem
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$($fw.Id) $($fw.Name) $($fw.Version)", "Run $($fw.SilentInstall.File) $($fw.SilentInstall.Arguments)")) {
            ConvertTo-HPKitResult @row -Result SKIPPED -Detail 'WhatIf: nothing run'
            continue
        }

        $start = @{ FilePath = $step.Exe; WorkingDirectory = $step.Folder; Wait = $true; PassThru = $true; NoNewWindow = $true }
        if ($fw.SilentInstall.Arguments) { $start.ArgumentList = $fw.SilentInstall.Arguments }
        try {
            $code = [int](Start-Process @start).ExitCode
        }
        catch {
            ConvertTo-HPKitResult @row -Result FAILURE -Detail "failed to launch ($($_.Exception.Message))"
            continue
        }

        $known = $null
        if ($fw.ReturnCodes) { $known = $fw.ReturnCodes."$code" }
        $outcome = if ($known) { "$($known.Result)" } elseif ($code -eq 0) { 'SUCCESS' } else { 'FAILURE' }
        if ($outcome -notin 'SUCCESS', 'CANCEL') { $outcome = 'FAILURE' }
        $detail = "exit $code"
        if ($known) { $detail = "$detail - $($known.Message)" }

        switch ($outcome) {
            'SUCCESS' { Write-Information "OK   $($fw.Id) $($fw.Name): $detail" }
            'CANCEL' { Write-Warning "SKIP $($fw.Id) $($fw.Name): $detail" }
        }
        ConvertTo-HPKitResult @row -Result $outcome -ExitCode $code -Detail $detail
    }
}

Export-ModuleMember -Function ConvertTo-HPBiosVersion, Get-FirmwareSkipReason, Get-HPKitInstalledFirmware, Get-HPKitDeviceIdentity, Install-HPKitDriver, Install-HPKitFirmware
