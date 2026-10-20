# The vendor interface contract (D-08, D-09): seven operations and two helpers, each in one plane.
# Data only. Test-KitVendorContract checks every vendor descriptor against this table by name and by
# parameter name; tests/Contract.Tests.ps1 runs that check over every vendor.psd1 it finds.
#   Plane Build  = runs on the builder PC (downloads, pack building).
#   Plane Target = runs on the laptop from the Tools stick.
# Operations is an array, not a hashtable, because a hashtable loaded from .psd1 has no order.
@{
    SchemaVersion = 1
    Operations    = @(
        @{ Name = 'ListModels'; Kind = 'Operation'; Plane = 'Build'; Parameters = @() }
        @{ Name = 'GetVendorPack'; Kind = 'Operation'; Plane = 'Build'; Parameters = @('ModelProfile', 'OsVer', 'OutputPath') }
        @{ Name = 'NewCustomPack'; Kind = 'Operation'; Plane = 'Build'; Parameters = @('ModelProfile', 'OsVer', 'OutputPath') }
        @{ Name = 'GetFirmware'; Kind = 'Operation'; Plane = 'Build'; Parameters = @('ModelProfile', 'OsVer', 'OutputPath') }
        @{ Name = 'GetFirmwareStickLayout'; Kind = 'Operation'; Plane = 'Build'; Parameters = @('ModelProfile', 'PackagePath', 'LayoutPath') }
        @{ Name = 'InstallDrivers'; Kind = 'Operation'; Plane = 'Target'; Parameters = @('PackagePath', 'OfflineImagePath') }
        @{ Name = 'InstallFirmware'; Kind = 'Operation'; Plane = 'Target'; Parameters = @('PackagePath') }
        @{ Name = 'GetDeviceIdentity'; Kind = 'Helper'; Plane = 'Target'; Parameters = @() }
        @{ Name = 'GetInstalledFirmwareVersion'; Kind = 'Helper'; Plane = 'Target'; Parameters = @() }
    )
}
