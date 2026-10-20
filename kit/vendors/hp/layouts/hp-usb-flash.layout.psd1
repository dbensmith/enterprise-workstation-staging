# HP Tools stick layout. Data only: read with Import-PowerShellDataFile, never run.
#
# Each group is a candidate placement for HP's pre-Windows BIOS tools (the recommended default layout in
# 02-RESEARCH.md). Every group has its own Verified block. After the bench in docs\firmware-bench-checklist.md,
# fill the Verified block of each folder that worked and delete the groups that did not.
#
# EFI\HP\SystemDiags and EFI\HP\BIOSUpdate are written by HP's own diagnostics installer and arrive inside the
# Diag-Tree capture. They are not BIOS image placements, so they have no group of their own.
#
# The two DEVFW groups stay off by default (Default = $false) because that name holds one model only.
@{
    SchemaVersion = 1
    VolumeLabel   = 'HP_TOOLS'
    FileSystem    = 'FAT32'
    Captures      = @(
        @{ Name = 'diagnostics-sp171653'; PackageId = 'sp171653'; Version = '10.8.5.0'; Snapshot = 'captures\diagnostics-sp171653.snapshot.psd1' }
    )
    Groups        = @(
        @{ Id = 'F10-New'; Folder = 'Hewlett-Packard\BIOS\New'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'F10-New-ESP'; Folder = 'EFI\HP\BIOS\New'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Diag-Current'; Folder = 'Hewlett-Packard\BIOS\Current'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Diag-Current-ESP'; Folder = 'EFI\HP\BIOS\Current'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Diag-Tree'; Folder = 'EFI\HP'; Source = 'Captured:diagnostics-sp171653'; Closed = $false; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Esc-DEVFW'; Folder = 'HP\DEVFW'; Source = 'FlashImage'; Closed = $true; Default = $false
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'Esc-DEVFW-ESP'; Folder = 'EFI\HP\DEVFW'; Source = 'FlashImage'; Closed = $true; Default = $false
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
    )
}
