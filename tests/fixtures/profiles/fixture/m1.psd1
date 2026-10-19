# Test fixture: the profile of the fixture vendor's only model. Data only.
@{
    SchemaVersion    = 1
    Vendor           = 'Fixture'
    ModelId          = 'm1'
    Name             = 'Fixture Model 1'
    Platform         = '0000'
    PlatformVerified = $true
    PlatformSource   = 'Test fixture'
    BiosFamily       = 'F00'
    Os               = 'win11'
    OsVer            = ''
    DriverExclude    = @()
    FirmwareExclude  = @()
    PackSelection    = @{ Preferred = 'Custom'; Allowed = @('Custom') }
    FirmwareMinimum  = @{
        Version  = '01.00.00'
        Verified = $true
        Source   = 'Test fixture'
    }
    BiosDefaults     = @{
        Settings = @{}
        Verified = $true
        Source   = 'Test fixture'
    }
}
