# Test fixture: a vendor that implements the whole contract. Data only (D-07).
@{
    Name         = 'Fixture'
    Manufacturer = '^Fixture Inc\b'
    TargetModule = 'Fixture.Target.psm1'
    BuildModule  = 'Fixture.Build.psm1'
    Commands     = @{
        ListModels                  = 'Get-FixtureKitModel'
        GetVendorPack               = 'Save-FixtureKitVendorPack'
        NewCustomPack               = 'New-FixtureKitCustomPack'
        GetFirmware                 = 'Save-FixtureKitFirmware'
        InstallDrivers              = 'Install-FixtureKitDriver'
        InstallFirmware             = 'Install-FixtureKitFirmware'
        GetDeviceIdentity           = 'Get-FixtureKitDeviceIdentity'
        GetInstalledFirmwareVersion = 'Get-FixtureKitInstalledFirmware'
    }
}
