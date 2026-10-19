# Copy this file to config.local.psd1 in the same folder and fill in the values.
# config.local.psd1 is git-ignored and is never copied into an image. Leave a value empty to skip that step.
@{
    # Settings handed to the third-party installer package under kit\apps.
    ThirdParty = @{
        # The installer download link from the vendor's download page.
        InstallerUrl    = ''
        # The three values below are used when installing from a saved MSI instead of the link.
        IntegratorLogin = ''
        CustomerId      = ''
        InstallToken    = ''
    }
}
