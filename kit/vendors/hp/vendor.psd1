# HP vendor descriptor. Data only (D-07): read with Import-PowerShellDataFile, never run.
@{
    # Vendor name, as passed to Get-KitVendor -Name and builder\Build-DriverBaseline.ps1 -Vendor.
    Name         = 'HP'

    # Regex matched against the laptop's manufacturer string (Win32_ComputerSystem.Manufacturer).
    Manufacturer = '^(HP|Hewlett-Packard)\b'

    # Target-plane module. Ships on the Tools stick; path is relative to this folder.
    TargetModule = 'HP.Target.psm1'

    # Build-plane module. Lives in builder\ and is absent on the Tools stick, so the resolved
    # BuildModulePath is $null there and build operations refuse to run.
    BuildModule  = '..\..\..\builder\vendors\hp\HP.Build.psm1'

    # Contract operation -> command name. Names are checked against HPCMSL 1.9.0 exports; none collide.
    Commands     = @{
        ListModels                  = 'Get-HPKitModel'
        GetVendorPack               = 'Save-HPKitVendorPack'
        NewCustomPack               = 'New-HPKitCustomPack'
        GetFirmware                 = 'Save-HPKitFirmware'
        InstallDrivers              = 'Install-HPKitDriver'
        InstallFirmware             = 'Install-HPKitFirmware'
        GetDeviceIdentity           = 'Get-HPKitDeviceIdentity'
        GetInstalledFirmwareVersion = 'Get-HPKitInstalledFirmware'
    }
}
