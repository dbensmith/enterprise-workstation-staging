# Test fixture: the profile of the fixture vendor's second model. Data only.
@{
    SchemaVersion    = 1
    Vendor           = 'Fixture'
    ModelId          = 'm2'
    Name             = 'Fixture Model 2'
    Platform         = '0001'
    PlatformVerified = $true
    PlatformSource   = 'Test fixture'
    BiosFamily       = 'F01'
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
