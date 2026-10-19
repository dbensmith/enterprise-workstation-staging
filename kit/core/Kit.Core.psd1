@{
    RootModule            = 'Kit.Core.psm1'
    ModuleVersion         = '0.1.0'
    GUID                  = '0c3f0b4d-902e-470a-83b2-14d8725d9ce1'
    Author                = 'Benjamin Smith'
    Description           = 'Vendor-neutral core for the workstation staging kit'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop')

    # The whole phase's export list lives here, written once. A name that no file defines yet is simply
    # not exported; a function a later file defines but this list omits stays private.
    FunctionsToExport     = @(
        'Select-InstallImage'
        'New-WindowsInstallIso'
        'Get-KitRoot'
        'Get-KitPackagePath'
        'ConvertTo-KitCommandLine'
        'Invoke-KitTool'
        'Get-KitVendor'
        'Test-KitVendorContract'
        'Invoke-KitVendorCommand'
        'Get-KitProfile'
        'Get-KitVerifiedValue'
        'Get-KitConfig'
        'Get-KitPublishFile'
        'Get-KitFirmwareLayout'
        'Test-FirmwareTarget'
        'Test-FirmwareStage'
        'Show-FirmwareStageFinding'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
}
