# Test fixture: a vendor that lacks the InstallDrivers operation. tests/Contract.Negative.Tests.ps1 runs the
# contract test against this folder and expects a failing exit code. It reuses the complete fixture's modules.
@{
    Name         = 'FixtureMissingOp'
    Manufacturer = '^Fixture Missing\b'
    TargetModule = '..\complete\Fixture.Target.psm1'
    BuildModule  = '..\complete\Fixture.Build.psm1'
    Commands     = @{
        ListModels                  = 'Get-FixtureKitModel'
        GetVendorPack               = 'Save-FixtureKitVendorPack'
        NewCustomPack               = 'New-FixtureKitCustomPack'
        GetFirmware                 = 'Save-FixtureKitFirmware'
        GetFirmwareStickLayout      = 'Get-FixtureKitFirmwareStickLayout'
        InstallFirmware             = 'Install-FixtureKitFirmware'
        GetDeviceIdentity           = 'Get-FixtureKitDeviceIdentity'
        GetInstalledFirmwareVersion = 'Get-FixtureKitInstalledFirmware'
    }
}
