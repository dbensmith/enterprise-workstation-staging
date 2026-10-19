# Baseline profile: HP EliteBook 840 G5.
# Platform 83B2 is taken from a third-party driver table and a forum BIOS dump; HP's own SoftPaq page does
# not state it (PlatformVerified = $false). Confirm with Get-HPDeviceDetails -Platform 83B2 and on a real unit.
# Exclude entries match a SoftPaq id exactly (e.g. 'sp152918') or a substring of its name,
# the same semantics as HPCMSL's -UnselectList.
# One standalone file per model (no shared base). Values that were not confirmed on hardware carry
# Verified = $false; read them only through Get-KitVerifiedValue.
@{
    SchemaVersion    = 1
    Vendor           = 'HP'
    ModelId          = '840-g5'
    Name             = 'HP EliteBook 840 G5'
    Platform         = '83B2'
    PlatformVerified = $false
    PlatformSource   = 'Third-party driver table and forum BIOS dump; HP page sp157750 does not state it. Confirm with Get-HPDeviceDetails -Platform 83B2 and on a real unit'
    BiosFamily       = 'Q78'
    Os               = 'win11'
    # Empty = newest release HP indexes for this platform.
    # Set e.g. '24H2' to freeze the baseline.
    OsVer            = ''
    # Mirrors the 840 G6 list. Check it against the 83B2 catalog on the first G5 build.
    DriverExclude    = @(
        'AMD Video'       # Radeon dGPU on 850 G6 / ZBook 15u G6 only; the 840 line is UMA
        'DisplayLink'     # USB dock display bundle
        'Hotkey Support'  # UWP OEM utility, not a hardware driver
    )
    FirmwareExclude  = @()
    PackSelection    = @{ Preferred = 'Custom'; Allowed = @('Custom', 'Vendor') }
    FirmwareMinimum  = @{
        Version  = '01.31.00'
        SoftPaq  = 'sp157750'
        Verified = $false
        Source   = 'ftp.hp.com sp157750: HP Firmware Pack (Q78) 01.31.00, 2025-04-30, lists the 840 G5; not bench-checked'
    }
    BiosDefaults     = @{
        Settings = @{ 'Secure Boot' = 'Enable'; 'TPM Device' = 'Available'; 'TPM State' = 'Enable' }
        Verified = $false
        Source   = 'Best-known values; setting names and values unconfirmed on hardware'
    }
}
