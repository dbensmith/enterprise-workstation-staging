# Test fixture: a neutral firmware layout for the core, fixture-vendor and master-script tests.
# Data only. It is read with Import-PowerShellDataFile and names no real vendor, model or folder.
@{
    SchemaVersion = 1
    VolumeLabel   = 'FX_TOOLS'
    FileSystem    = 'FAT32'
    Captures      = @(
        @{ Name = 'fx-diag'; PackageId = 'fxdiag1'; Version = '1.0'; Snapshot = 'fx-diag.snapshot.psd1' }
    )
    Groups        = @(
        @{ Id = 'G-New'; Folder = 'Vendor\BIOS\New'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'G-Current'; Folder = 'Vendor\BIOS\Current'; Source = 'BiosImage'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'G-Diag'; Folder = 'EFI\FX'; Source = 'Captured:fx-diag'; Closed = $false; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'G-Win'; Folder = 'firmware\fx\{Platform}'; Source = 'WindowsFlashTool'; Closed = $true; Default = $true
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
        @{ Id = 'G-Dev'; Folder = 'FX\DEVFW'; Source = 'FlashImage'; Closed = $true; Default = $false
            Verified = @{ Status = $false; Model = @(); Bios = ''; Date = ''; By = '' } }
    )
}
