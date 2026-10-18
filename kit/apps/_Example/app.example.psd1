# Copy this file to app.psd1 inside your package folder (kit/apps/<AppName>/).
# app.psd1 is ignored by git. Keep every value here empty or generic.
@{
    DisplayName      = 'Example application'
    RequiresInternet = $false
    OnlineEndpoint   = ''     # HTTPS URL probed by the online gate when RequiresInternet is $true
    TimeoutSeconds   = 600    # hard limit for the silent install
    Detection        = @{
        Service     = ''      # Windows service name that must be Running after install
        DisplayName = ''      # or an Add/Remove Programs DisplayName (wildcards allowed)
    }
}
