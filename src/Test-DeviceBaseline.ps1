# Unit audit: serial, spec, BIOS, OS, activation, Atera. Run as admin: irm <url> | iex
[CmdletBinding()]
param([string]$OutFile)  # not bound under irm | iex; use $env:PK_OUTFILE there
if (-not $OutFile -and $env:PK_OUTFILE) { $OutFile = $env:PK_OUTFILE }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. Some checks (WMI services, physical disk) may be restricted."
}
# WMI must run (Atera and this script depend on it); some vendor images disable it
Set-Service winmgmt -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service winmgmt -ErrorAction SilentlyContinue

$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cpu = ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name -replace '\s+', ' ').Trim()
$sn = if ($bios.SerialNumber) { $bios.SerialNumber.Trim() } else { 'UNKNOWN' }

# RAM: Query physical modules to avoid false failures from iGPU / hardware reserved memory
$ramModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
$ramBytes = ($ramModules | Measure-Object -Property Capacity -Sum).Sum
$ram = if ($ramBytes) { [math]::Round($ramBytes / 1GB) } else { [math]::Round($cs.TotalPhysicalMemory / 1GB) }

$moduleCount = $ramModules.Count
$moduleBreakdown = if ($moduleCount -gt 0) {
    ($ramModules | ForEach-Object { "$([math]::Round($_.Capacity / 1GB))GB" }) -join ' + '
} else { 'unknown' }

$ramChannelText = if ($moduleCount -ge 2) {
    "$ram GB ($moduleBreakdown - Dual/Multi-Channel)"
} elseif ($moduleCount -eq 1) {
    "$ram GB ($moduleBreakdown - Single Channel [Advisory])"
} else {
    "$ram GB"
}

# Disk: Resolve Boot / OS Physical Disk (avoids USB drive selection)
$bootDiskNumber = (Get-Disk -ErrorAction SilentlyContinue | Where-Object IsBoot).Number
$disk = if ($null -ne $bootDiskNumber) {
    Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { [int]$_.DeviceId -eq $bootDiskNumber } | Select-Object -First 1
} else {
    Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object BusType -ne 'USB' | Sort-Object DeviceId | Select-Object -First 1
}
$diskGB = if ($disk.Size) { [math]::Round($disk.Size / 1GB) } else { 0 }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationId = '55c92734-d682-4d71-9662-e190193fc00a'" -ErrorAction SilentlyContinue |
       Sort-Object -Property @{Expression = { $_.LicenseStatus -eq 1 }; Descending = $true} |
       Select-Object -First 1
if (-not $lic) {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue | Select-Object -First 1
}
$sls = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
$atera = Get-Service -Name AteraAgent -ErrorAction SilentlyContinue

# Splashtop Streamer is pushed by Atera after first check-in = proof agent phoned home
$splashCandidates = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                    Where-Object DisplayName -like 'Splashtop*'
$splash = $splashCandidates | Where-Object DisplayName -like 'Splashtop Streamer*' | Select-Object -First 1
if (-not $splash) {
    $splash = $splashCandidates | Select-Object -First 1
}
$splashSvc = Get-Service -Name SplashtopRemoteService -ErrorAction SilentlyContinue

function PF($val) {
    if ($val -is [bool]) {
        return $(if ($val) { 'PASS' } else { 'FAIL' })
    }
    if ("$val" -eq 'WARN') { return 'WARN' }
    if ("$val" -eq 'PASS') { return 'PASS' }
    return 'FAIL'
}

# OS: name by build (22000+ = Windows 11; registry ProductName still says 10)
$build = [int]$cv.CurrentBuild
$osName = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
$edition = ($os.Caption -replace '^Microsoft Windows \d+\s*', '').Trim()
$osText = "$osName $edition $($cv.DisplayVersion) (build $build.$($cv.UBR))"

# BIOS
$biosDate = if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { '?' }
$biosText = "$($bios.SMBIOSBIOSVersion) ($biosDate)"

# Screen (info & form-factor validation): EDID physical size -> diagonal inches
$mon = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue | Where-Object Active | Select-Object -First 1
$screenInches = if ($mon -and $mon.MaxHorizontalImageSize -and $mon.MaxVerticalImageSize) {
    [math]::Round(([math]::Sqrt([math]::Pow($mon.MaxHorizontalImageSize, 2) + [math]::Pow($mon.MaxVerticalImageSize, 2)) / 2.54), 1)
} else { $null }
$scr = if ($screenInches) { "{0:N1} in (EDID)" -f $screenInches } else { 'unknown' }

# -------------------------------------------------------------
# CPU & Chassis Qualification:
# - Form Factor: Strictly 13" and 14" models only (15"+ strictly prohibited)
# - Intel i5/i7/i9 or Core Ultra / Core series equivalents, 8th gen or later
# - No AMD, no i3-class Intel
# - G5 equivalents (HP 830/840 G5, Dell Latitude 7390/7490/5390/5490, ThinkPad T480/L380/X380) trigger warning
# - G6+ equivalents (HP G6+, Dell *00+, ThinkPad *90 / T14 Gen 1+) succeed
# -------------------------------------------------------------
$isIntel = $cpu -match 'Intel'
$isAmd   = $cpu -match 'AMD|Ryzen|Athlon'
$isI3    = $cpu -match '\bi3\b|\bCore\s+3\b|\bUltra\s+3\b|\bCeleron\b|\bPentium\b|\bAtom\b'

$cpuGen   = 0
$isUltra  = $cpu -match 'Core(?:\(TM\))?\s+Ultra\s+[579]'
$isCore14 = $cpu -match 'Core(?:\(TM\))?\s+[579]\s+\d{3}'
$isCoreI  = $cpu -match 'i[579]-(\d{4,5})'

if ($isCoreI) {
    $num = $Matches[1]
    if ($num -match '^(1[0-4])\d{2,3}') {
        $cpuGen = [int]$Matches[1]
    } else {
        $cpuGen = [int]$num.Substring(0, 1)
    }
} elseif ($isUltra -or $isCore14) {
    $cpuGen = 14  # Ultra Series 1/2 and Core Series 1 (Gen 14+ equivalent)
}

# Resolve model name (handles Lenovo machine type vs marketing name in CSP Version)
$mfg = "$($cs.Manufacturer)".Trim()
$rawModel = "$($cs.Model)".Trim()
$cspVersion = "$($csp.Version)".Trim()

$friendlyModel = if ($cspVersion -and $cspVersion -ne 'None' -and $cspVersion -notmatch '^\d+$' -and $cspVersion -match 'ThinkPad|ThinkCentre|ThinkStation|IdeaPad|Yoga|Slim') {
    $cspVersion
} else {
    $rawModel
}
$cleanModel = ($friendlyModel -replace "^$([regex]::Escape($mfg))\s*", '').Trim()
$modelDisplay = if ($mfg) { "$mfg $cleanModel" } else { $cleanModel }

$fullPlatform = "$mfg $friendlyModel $rawModel"

# Form Factor Validation: Strictly 13" and 14" models (13.0" - 14.5" displays accepted)
# Rejects 15"+ (e.g. HP 850, Dell 55xx, ThinkPad T15/T580) and Sub-13" (e.g. Dell 7290, ThinkPad X280)
$is15PlusModel = ($fullPlatform -match '\b(850|855|860|865|650|655|450|455)\b') -or
                 ($fullPlatform -match 'Latitude\s+[357]5\d{2}\b') -or
                 ($fullPlatform -match 'ThinkPad\s+(T5\d0|T1[56]|L5\d0|L15|P1[56]|P5\d|E15|E16)\b')
$isSub13Model  = ($fullPlatform -match '\b(820|720)\b') -or
                 ($fullPlatform -match 'Latitude\s+[357]2\d{2}\b') -or
                 ($fullPlatform -match 'ThinkPad\s+(X2\d0|11e)\b')

$isScreenOutOfRange = ($null -ne $screenInches -and ($screenInches -lt 12.9 -or $screenInches -ge 15.0))
$sizeDisqualified = $is15PlusModel -or $isSub13Model -or $isScreenOutOfRange

# G5 Tier Equivalents (Strictly 13" and 14"):
# HP: EliteBook 830 G5 (13.3") or 840 G5 (14.0")
# Dell: Latitude 13"/14" xx90 series (7390, 5390, 7490, 5490)
# Lenovo: ThinkPad 13"/14" xx80 series & X1 Carbon Gen 6 (T480, T480s, L380, X380, X1 Carbon 6th/Gen 6)
$isHpG5     = ($fullPlatform -match 'HP|Hewlett-Packard|EliteBook|ProBook') -and (($fullPlatform -match '\b8[34]0.*G5\b') -or ($fullPlatform -match '\bG5\b' -and $fullPlatform -match '8[34]0') -or ($fullPlatform -match '8[34]0' -and $cpuGen -eq 8 -and $cpu -match '8[2356]50U'))
$isDellG5   = ($fullPlatform -match 'Dell|Latitude') -and ($fullPlatform -match 'Latitude\s+[357][34]90\b')
$isLenovoG5 = ($fullPlatform -match 'Lenovo|ThinkPad') -and (
    ($fullPlatform -match 'ThinkPad\s+([TL]480|T480s|L380|X380)') -or
    ($fullPlatform -match 'X1\s+(?:Carbon|Titanium|Yoga)' -and (($fullPlatform -match '(?:6th|Gen\s*6|20K[HG])') -or ($cpuGen -eq 8 -and $cpu -match '8[2356]50U')))
)

$isG5Equivalent = $isHpG5 -or $isDellG5 -or $isLenovoG5

$cpuStatus = 'FAIL'
$cpuNote   = ''

if ($sizeDisqualified) {
    $cpuStatus = 'FAIL'
    $cpuNote = if ($null -ne $screenInches -and $screenInches -ge 15.0) {
        "Screen ($screenInches in) exceeds 14-inch limit (13-14 in only)"
    } elseif ($null -ne $screenInches -and $screenInches -lt 12.9) {
        "Screen ($screenInches in) below 13-inch limit (13-14 in only)"
    } elseif ($isSub13Model) {
        'Sub-13-inch chassis prohibited (13-14 in only)'
    } else {
        '15-inch+ form factor prohibited (13-14 in only)'
    }
} elseif ($isAmd) {
    $cpuStatus = 'FAIL'
    $cpuNote   = 'AMD not permitted'
} elseif (-not $isIntel) {
    $cpuStatus = 'FAIL'
    $cpuNote   = 'Non-Intel processor'
} elseif ($isI3) {
    $cpuStatus = 'FAIL'
    $cpuNote   = 'i3/entry-class not permitted'
} elseif ($cpuGen -lt 8) {
    $cpuStatus = 'FAIL'
    $cpuNote   = if ($cpuGen -gt 0) { "Gen $cpuGen < 8th Gen minimum" } else { 'Pre-8th Gen Intel' }
} elseif ($isG5Equivalent) {
    $cpuStatus = 'WARN'
    $cpuNote = if ($isHpG5) {
        'G5 advisory warning (13-14 in acceptable, G6+ recommended)'
    } elseif ($isDellG5) {
        'Dell Latitude *90 advisory warning (13-14 in G5 eq - acceptable, *00+ recommended)'
    } else {
        'ThinkPad *80 advisory warning (13-14 in G5 eq - acceptable, *90/T14 recommended)'
    }
} else {
    $cpuStatus = 'PASS'
    $cpuNote   = if ($isUltra) { 'Core Ultra' } else { "Gen $cpuGen" }
}

# Spec checks (screen size validated above)
$ramOk  = $ram -ge 15
$nvmeOk = "$($disk.BusType)" -eq 'NVMe'
$sizeOk = $diskGB -ge 230   # Tolerates 240GB / 256GB SSD provisioning variances

$specStatus = if ($cpuStatus -eq 'FAIL' -or -not $ramOk -or -not $nvmeOk -or -not $sizeOk) {
    'FAIL'
} elseif ($cpuStatus -eq 'WARN') {
    'WARN'
} else {
    'PASS'
}

# Activation: licensed + OEM channel + not KMS/GVLK; compare installed key to firmware (OA3) key
$licMap   = @{0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB Grace'; 3 = 'OOT Grace'; 4 = 'Non-Genuine Grace'; 5 = 'Notification'; 6 = 'Extended Grace' }
$chan     = "$($lic.ProductKeyChannel)"
$fwKey    = "$($sls.OA3xOriginalProductKey)"
$fwLast   = if ($fwKey.Length -ge 5) { $fwKey.Substring($fwKey.Length - 5) } else { 'none' }
$kms      = ($chan -like '*GVLK*') -or ($chan -like 'Volume*') -or $lic.KeyManagementServiceMachine -or $sls.KeyManagementServiceMachine
$keyMatch = if ($fwLast -eq 'none') { 'NO FIRMWARE KEY' } elseif ($fwLast -eq $lic.PartialProductKey) { 'MATCH' } else { 'DIFFERENT' }
$actOk    = ($lic.LicenseStatus -eq 1) -and ($chan -like 'OEM*') -and -not $kms

$splashText = if ($splash) { "$($splash.DisplayName) $($splash.DisplayVersion)" } elseif ($splashSvc) { "service $($splashSvc.Status)" } else { 'NOT INSTALLED' }
$ateraOk    = $atera -and $atera.Status -eq 'Running'

$cpuDisplayText = if ($cpuNote) { "$cpu ($cpuNote)" } else { $cpu }
$specDisplayText = switch ($specStatus) {
    'PASS' { '[PASS]' }
    'WARN' { '[WARN] PASS (G5/Tier-1 advisory warning)' }
    'FAIL' { '[FAIL]' }
}

$lines = @(
    "=============================================="
    " SERIAL     : $sn"
    " COMPUTER   : $env:COMPUTERNAME"
    " MODEL      : $modelDisplay"
    " CHECKED    : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    "----------------------------------------------"
    " CPU   [$(PF $cpuStatus)] $cpuDisplayText"
    " RAM   [$(PF $ramOk)] $ramChannelText"
    " DISK  [$(PF ($nvmeOk -and $sizeOk))] $($disk.FriendlyName) | $($disk.BusType) | $diskGB GB"
    " SCREEN [info] $scr"
    " BIOS         $biosText"
    " OS           $osText"
    "----------------------------------------------"
    " Status       $($licMap[[int]$lic.LicenseStatus])"
    " Channel      $chan"
    " Key (inst.)  *****-$($lic.PartialProductKey)"
    " Key (firm.)  *****-$fwLast   -> $keyMatch"
    " KMS/GVLK     $(if ($kms) { 'DETECTED' } else { 'none' })"
    "----------------------------------------------"
    " SPEC        : $specDisplayText"
    " ACTIVATION  : [$(PF $actOk)]"
    " ATERA       : [$(PF $ateraOk)] agent $(if ($atera) { $atera.Status } else { 'NOT INSTALLED' })"
    "               Splashtop [info]: $splashText"
    "=============================================="
)

# Output with visual highlights for photo/camera clarity
foreach ($line in $lines) {
    if ($line -match '\[PASS\]') {
        Write-Host $line.Substring(0, $line.IndexOf('[PASS]')) -NoNewline
        Write-Host '[PASS]' -ForegroundColor Green -NoNewline
        Write-Host $line.Substring($line.IndexOf('[PASS]') + 6)
    } elseif ($line -match '\[WARN\]') {
        Write-Host $line.Substring(0, $line.IndexOf('[WARN]')) -NoNewline
        Write-Host '[WARN]' -ForegroundColor Yellow -NoNewline
        Write-Host $line.Substring($line.IndexOf('[WARN]') + 6)
    } elseif ($line -match '\[FAIL\]') {
        Write-Host $line.Substring(0, $line.IndexOf('[FAIL]')) -NoNewline
        Write-Host '[FAIL]' -ForegroundColor Red -NoNewline
        Write-Host $line.Substring($line.IndexOf('[FAIL]') + 6)
    } else {
        Write-Host $line
    }
}

# Where to save the .txt: the stick this script ran from if it is removable, otherwise the removable drive
# with the earliest letter (D: before E:). Fixed disks are never a default (e.g. when run from the web).
$removable = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Removable' } | Sort-Object DriveLetter)
$runRoot = if ($PSScriptRoot) { [string]$PSScriptRoot.Substring(0, 1) } else { $null }
$usb = $removable | Where-Object { $runRoot -and $_.DriveLetter -eq $runRoot } | Select-Object -First 1
if (-not $usb) { $usb = $removable | Select-Object -First 1 }
$safeSn = ($sn -replace '[^\w\.-]', '_')
$defaultOut = if ($usb) { "$($usb.DriveLetter):\results\$safeSn.txt" } else { $null }

# -OutFile (or $env:PK_OUTFILE for irm | iex) answers the "save where?" question; a folder gets <serial>.txt inside it
$target = $null
if ($OutFile) {
    $target = $OutFile
} else {
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
                   -not ([Environment]::GetCommandLineArgs() -contains '-NonInteractive')
    if ($interactive) {
        $hint = if ($defaultOut) { "Enter = $defaultOut" } else { 'no removable drive found' }
        $answer = (Read-Host "Save results to a file? Type a path ($hint), or 'n' to skip").Trim().Trim('"')
        if ($answer -match '^(n|no)$') { $target = $null }
        elseif ($answer) { $target = $answer }
        else { $target = $defaultOut }
    } else {
        $target = $defaultOut
    }
}

if ($target) {
    if ((Test-Path -LiteralPath $target -PathType Container) -or $target -match '[\/]$') {
        $target = Join-Path $target "$safeSn.txt"
    }
    try {
        $dir = Split-Path -Path $target -Parent
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
        $lines | Set-Content -Path $target -Encoding UTF8 -Force -ErrorAction Stop
        Write-Host "Saved: $target" -ForegroundColor Green
    } catch {
        Write-Host "Could not save to $target - photo the screen." -ForegroundColor Yellow
    }
} else {
    Write-Host "Not saved (no removable USB drive or save skipped) - photo the screen." -ForegroundColor Yellow
}
