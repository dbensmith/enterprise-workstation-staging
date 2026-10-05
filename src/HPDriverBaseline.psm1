#Requires -Version 5.1
# Shared helpers for the build and ISO scripts. No HPCMSL calls and no admin needed, so Pester can test them offline.

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

function Select-InstallImage {
    <#
    .SYNOPSIS
    Pick the image to service from Get-WindowsImage output: -Edition by exact name, or the only
    image when the WIM/ESD holds one. Throws with the available names otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Image,
        [string]$Edition
    )

    $match = if ($Edition) { $Image | Where-Object ImageName -EQ $Edition } elseif ($Image.Count -eq 1) { $Image[0] }
    if (-not $match) {
        $reason = if ($Edition) { "Edition '$Edition' not found." } else { "Install image holds $($Image.Count) editions; choose one with -Edition." }
        throw "$reason Available: $($Image.ImageName -join '; ')"
    }
    $match
}

function New-WindowsInstallIso {
    <#
    .SYNOPSIS
    Build a UEFI + legacy BIOS bootable UDF ISO from a Windows media folder using IMAPI2, which
    ships with Windows (no ADK/oscdimg). Boot catalog matches Microsoft media (oscdimg -u2 -udfver102
    -bootdata:2#p0,e,b<etfsboot.com>#pEF,e,b<efisys.bin>).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        # Folder holding the media: boot\etfsboot.com, efi\microsoft\boot\efisys.bin, sources\...
        [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Container })][string]$MediaPath,
        [Parameter(Mandatory)][string]$Path,
        [ValidateLength(1, 32)][string]$VolumeName = 'WINDOWS'
    )

    $biosBoot = Join-Path $MediaPath 'boot\etfsboot.com'
    $uefiBoot = Join-Path $MediaPath 'efi\microsoft\boot\efisys.bin'
    foreach ($file in $biosBoot, $uefiBoot) {
        if (-not (Test-Path $file -PathType Leaf)) { throw "Boot file missing: $file" }
    }
    # IMAPI2 uses legacy Win32 paths; past MAX_PATH it fails with a bare "path not found".
    # Windows media nests ~150 chars deep (sources\replacementmanifests\...), so the media root must be short.
    $longest = Get-ChildItem -Path $MediaPath -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending | Select-Object -First 1
    if ($longest -and $longest.FullName.Length -ge 260) {
        throw "Path exceeds IMAPI2's 260-character limit ($($longest.FullName.Length)): $($longest.FullName). Use a shorter media/work folder."
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "Build bootable ISO from $MediaPath")) { return }

    if (-not ('HPDriverBaseline.ComStreamWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace HPDriverBaseline {
    public static class ComStreamWriter {
        // Copy an IMAPI2 result IStream to a file in 4 MB chunks.
        public static void Save(object comStream, string path) {
            var source = (IStream)comStream;
            var buffer = new byte[4 * 1024 * 1024];
            IntPtr read = Marshal.AllocHGlobal(sizeof(int));
            try {
                using (var target = File.Create(path)) {
                    while (true) {
                        source.Read(buffer, buffer.Length, read);
                        int n = Marshal.ReadInt32(read);
                        if (n <= 0) break;
                        target.Write(buffer, 0, n);
                    }
                }
            } finally { Marshal.FreeHGlobal(read); }
        }
    }
}
'@
    }

    # Every COM object here holds open file handles until closed/released; without this the media
    # folder stays locked (e.g. WorkRoot cleanup fails) until the process exits.
    $com = [System.Collections.Generic.List[object]]::new()
    try {
        $bootOptions = foreach ($boot in @(@{ File = $biosBoot; Platform = 0x00 }, @{ File = $uefiBoot; Platform = 0xEF })) {
            $stream = New-Object -ComObject ADODB.Stream
            $com.Add($stream)
            $stream.Type = 1  # binary
            $stream.Open()
            $stream.LoadFromFile($boot.File)
            $option = New-Object -ComObject IMAPI2FS.BootOptions
            $com.Add($option)
            $option.AssignBootImage($stream)
            $option.PlatformId = $boot.Platform
            $option.Emulation = 0  # no emulation
            # Unwrap: IMAPI2 cannot marshal PowerShell's PSObject wrapper into its SAFEARRAY.
            $option.psobject.BaseObject
        }

        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $com.Add($image)
        $image.FileSystemsToCreate = 4  # UDF only
        $image.UDFRevision = 0x102
        $image.FreeMediaBlocks = 0      # no media-size cap (install.wim is > 4 GB)
        $image.VolumeName = $VolumeName
        $image.BootImageOptionsArray = [object[]]$bootOptions
        $root = $image.Root
        $com.Add($root)
        $root.AddTree((Resolve-Path $MediaPath).ProviderPath, $false)
        $result = $image.CreateResultImage()
        $com.Add($result)
        $imageStream = $result.ImageStream
        $com.Add($imageStream)
        [HPDriverBaseline.ComStreamWriter]::Save($imageStream, $Path)
    }
    finally {
        foreach ($obj in $com) {
            if ($obj.PSObject.Methods['Close'] -and $obj.State) { $obj.Close() }  # ADODB.Stream: State 1 = open
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj.psobject.BaseObject)
        }
        # IMAPI2's per-file items are COM objects PowerShell never sees; collecting releases their handles now.
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }

    # IMAPI2 records the UEFI entry's load size as the whole 2880-sector image; Microsoft media uses 1.
    # Patch the 2-byte sector count (offset 6) of catalog entry 3 so the catalog is byte-identical.
    $file = [IO.File]::Open($Path, 'Open', 'ReadWrite')
    try {
        $reader = [IO.BinaryReader]::new($file)
        $file.Position = 17 * 2048 + 0x47   # El Torito boot record -> catalog LBA
        $file.Position = [long]$reader.ReadUInt32() * 2048 + 3 * 32 + 6
        $file.Write([byte[]](1, 0), 0, 2)
    }
    finally { $file.Dispose() }

    Get-Item $Path
}

Export-ModuleMember -Function Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap, Select-InstallImage, New-WindowsInstallIso
