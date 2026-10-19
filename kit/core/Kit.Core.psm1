#Requires -Version 5.1
# Vendor-neutral core shared by kit/ (target laptop, Tools stick) and builder/ (PC). Loads offline on stock Windows PowerShell 5.1: no vendor tools, no admin, no internet at import. Never name a vendor in this folder (tests/Core.Tests.ps1 enforces it).

foreach ($coreFile in (Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File | Sort-Object -Property Name)) {
    . $coreFile.FullName
}
