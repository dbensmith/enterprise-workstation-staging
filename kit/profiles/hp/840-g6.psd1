# Baseline profile: HP EliteBook 840 G6.
# Platform 8549 is shared with the 840 G6 Healthcare, 850 G6, and ZBook 14u/15u G6, so the
# catalog includes sibling-only drivers; DriverExclude trims those plus OEM utilities.
# Exclude entries match a SoftPaq id exactly (e.g. 'sp152918') or a substring of its name,
# the same semantics as HPCMSL's -UnselectList.
@{
    Name            = 'HP EliteBook 840 G6'
    Platform        = '8549'
    Os              = 'win11'
    # Empty = newest release HP indexes for this platform (24H2 / 26100 as of 2026-09).
    # Set e.g. '24H2' to freeze the baseline.
    OsVer           = ''
    DriverExclude   = @(
        'AMD Video'       # Radeon dGPU on 850 G6 / ZBook 15u G6 only; 840 G6 is UMA (UHD 620)
        'DisplayLink'     # USB dock display bundle
        'Hotkey Support'  # UWP OEM utility, not a hardware driver
    )
    FirmwareExclude = @()
}
