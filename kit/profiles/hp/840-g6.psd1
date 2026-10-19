# Baseline profile: HP EliteBook 840 G6.
# Platform 8549 is shared with the 840 G6 Healthcare, 850 G6, and ZBook 14u/15u G6, so the
# catalog includes sibling-only drivers; DriverExclude trims those plus OEM utilities.
# Exclude entries match a SoftPaq id exactly (e.g. 'sp152918') or a substring of its name,
# the same semantics as HPCMSL's -UnselectList.
# One standalone file per model (no shared base). Values that were not confirmed on hardware carry
# Verified = $false; read them only through Get-KitVerifiedValue.
@{
    SchemaVersion    = 1
    Vendor           = 'HP'
    ModelId          = '840-g6'
    Name             = 'HP EliteBook 840 G6'
    Platform         = '8549'
    PlatformVerified = $true
    PlatformSource   = 'HP catalog (HPCMSL 1.9.0 Get-HPDeviceDetails) used for the 2026-09-28 build'
    BiosFamily       = 'R70'
    Os               = 'win11'
    # Empty = newest release HP indexes for this platform (24H2 / 26100 as of 2026-09).
    # Set e.g. '24H2' to freeze the baseline.
    OsVer            = ''
    DriverExclude    = @(
        'AMD Video'       # Radeon dGPU on 850 G6 / ZBook 15u G6 only; 840 G6 is UMA (UHD 620)
        'DisplayLink'     # USB dock display bundle
        'Hotkey Support'  # UWP OEM utility, not a hardware driver
    )
    FirmwareExclude  = @()
    PackSelection    = @{ Preferred = 'Custom'; Allowed = @('Custom', 'Vendor') }
    FirmwareMinimum  = @{
        Version  = '01.36.00'
        SoftPaq  = 'sp174025'
        Verified = $false
        Source   = 'HP_Staging/8549-win11-24H2/manifest.json built 2026-09-28 (HPCMSL 1.9.0); not bench-checked'
    }
    BiosDefaults     = @{
        Settings = @{ 'Secure Boot' = 'Enable'; 'TPM Device' = 'Available'; 'TPM State' = 'Enable' }
        Verified = $false
        Source   = 'Best-known values; setting names and values unconfirmed on hardware'
    }
}
