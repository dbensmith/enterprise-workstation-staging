#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Apply an HP driver/firmware baseline package built by Build-HPDriverBaseline.ps1.

.DESCRIPTION
Runs from the package root (next to manifest.json). Standalone: HPCMSL is not needed on the target.
  Online  (default): stage+install drivers with pnputil, then run auto-install firmware (BIOS last),
                     suspending BitLocker for one reboot first. Refuses to run on a different
                     platform unless -Force.
  Offline (-OfflineImagePath): inject drivers into a mounted Windows image with DISM. Firmware is skipped;
                     it cannot be serviced offline.
Exit code 0 = all good, 1 = at least one step failed. Reboot after an online run.

.EXAMPLE
.\Install-HPDriverBaseline.ps1 -WhatIf

.EXAMPLE
.\Install-HPDriverBaseline.ps1 -OfflineImagePath C:\Mount\install
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('Path', 'ImagePath')]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$OfflineImagePath,

    [switch]$SkipFirmware,

    # Apply even if the board's platform ID does not match the manifest.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

Set-Service winmgmt -StartupType Automatic
$svc = Get-Service winmgmt -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Start-Service winmgmt
}

$manifest = Get-Content (Join-Path $scriptRoot 'manifest.json') -Raw | ConvertFrom-Json
$driverDir = Join-Path $scriptRoot 'Drivers'
$script:failures = 0

function Invoke-Tool {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Exe,

        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]]$ArgList,

        [int[]]$OkCodes = @(0, 3010)
    )
    $escapedArgs = ($ArgList | ForEach-Object {
        if ($_ -eq '') {
            '""'
        } elseif ($_ -notmatch '[\s"]') {
            $_
        } else {
            # Win32 CreateProcess argv escaping: double backslashes immediately
            # preceding a quote (or end of string, once wrapped), then escape the quote itself.
            $escaped = [regex]::Replace($_, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            "`"$escaped`""
        }
    }) -join ' '
    if (-not $PSCmdlet.ShouldProcess("$Exe $escapedArgs", 'Execute')) { return }
    $p = Start-Process -FilePath $Exe -ArgumentList $escapedArgs -Wait -PassThru -NoNewWindow
    if ($OkCodes -notcontains $p.ExitCode) { throw "$Exe failed: exit $($p.ExitCode)" }
    if ($p.ExitCode -ne 0) { Write-Warning "$Exe exit $($p.ExitCode) (accepted)" }
}

Write-Information "Baseline: $($manifest.Profile) [$($manifest.Platform)] $($manifest.Os) $($manifest.OsVer), built $($manifest.BuiltUtc)"

if ($OfflineImagePath) {
    try {
        Invoke-Tool dism.exe "/Image:$OfflineImagePath", '/Add-Driver', "/Driver:$driverDir", '/Recurse'
    }
    catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        $script:failures++
    }
    exit [int]($script:failures -gt 0)
}

$board = (Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue).Product
if (-not $board) {
    $board = Get-ItemPropertyValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BaseBoardProduct' -ErrorAction SilentlyContinue
}
$board = if ($board) { "$board".Trim() } else { $null }
if ($board -ne $manifest.Platform -and -not $Force) {
    throw "This board is platform '$board'; package targets '$($manifest.Platform)'. Use -Force to override."
}

if (Test-Path $driverDir) {
    # 259 = drivers staged but no present device needed them; -536870365 (0xE0000223) = driver does not apply to this hardware variant.
    Invoke-Tool pnputil.exe '/add-driver', "$driverDir\*.inf", '/subdirs', '/install' -OkCodes 0, 3010, 259, -536870365
}

if (-not $SkipFirmware) {
    $firmware = @($manifest.Firmware | Where-Object { $_ })
    foreach ($fw in $firmware | Where-Object { -not $_.AutoInstall }) {
        Write-Warning "Manual firmware (no silent install, or device-specific): $($fw.Id) $($fw.Name) $($fw.Version) -> $($fw.Path)"
    }

    # BIOS last: it schedules the flash for the next reboot.
    $auto = @($firmware | Where-Object AutoInstall | Sort-Object { $_.Category -like 'BIOS*' })
    if ($auto | Where-Object RebootRequired) {
        # HpFirmwareUpdRec returns 290 in silent mode while BitLocker protection is on.
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
            if ($bl -and $bl.ProtectionStatus -eq 'On') {
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

    foreach ($fw in $auto) {
        $dir = Join-Path $scriptRoot $fw.Path
        $exe = Join-Path $dir $fw.SilentInstall.File
        if (-not (Test-Path -LiteralPath $exe)) {
            Write-Error "FAIL $($fw.Id) $($fw.Name): executable not found ($exe)" -ErrorAction Continue
            $script:failures++
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$($fw.Id) $($fw.Name) $($fw.Version)", "Run $($fw.SilentInstall.File) $($fw.SilentInstall.Arguments)")) { continue }

        try {
            $code = (Start-Process -FilePath $exe -ArgumentList $fw.SilentInstall.Arguments -WorkingDirectory $dir -Wait -PassThru -NoNewWindow).ExitCode
        }
        catch {
            Write-Error "FAIL $($fw.Id) $($fw.Name): failed to launch ($($_.Exception.Message))" -ErrorAction Continue
            $script:failures++
            continue
        }

        $known = $fw.ReturnCodes."$code"
        $result = if ($known) { $known.Result } elseif ($code -eq 0) { 'SUCCESS' } else { 'FAILURE' }
        $detail = "$($fw.Id) $($fw.Name): exit $code $(if ($known) { "- $($known.Message)" })"
        switch ($result) {
            'SUCCESS' { Write-Information "OK   $detail" }
            'CANCEL' { Write-Warning "SKIP $detail" }
            default { Write-Error "FAIL $detail" -ErrorAction Continue; $script:failures++ }
        }
    }
}

Write-Information "Done with $script:failures failure(s). Reboot to finish driver and firmware installation."
exit [int]($script:failures -gt 0)
