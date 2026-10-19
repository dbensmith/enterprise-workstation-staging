# Kit and package paths. Dot-sourced by Kit.Core.psm1. Pure: nothing here touches the disk.

function Get-KitRoot {
    <#
    .SYNOPSIS
    Return the kit folder: the parent of kit\core, wherever the kit is copied to.

    .DESCRIPTION
    Callers locate kit-relative files (vendor modules, profiles) from this root instead of
    guessing relative paths. A dot-sourced core file runs with $PSScriptRoot set to kit\core.

    .EXAMPLE
    Join-Path (Get-KitRoot) 'vendors'

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    [System.IO.Path]::GetFullPath((Split-Path -Path $PSScriptRoot -Parent))
}

function Get-KitPackagePath {
    <#
    .SYNOPSIS
    Return the output folder for one vendor, model and OS release: <OutputRoot>\<vendor>\<ModelId>\<Os>-<OsVer>.

    .DESCRIPTION
    The vendor folder is lowercased; the other segments keep their case. Two models of one vendor get
    distinct folders under one vendor folder. Every segment must start with a letter or digit and hold
    only letters, digits, dot, underscore and hyphen, so an empty value, a path separator or a leading
    dot cannot walk out of the output root. The function only computes the path: it creates nothing.

    .PARAMETER OutputRoot
    Folder that holds every package. The caller chooses it.

    .PARAMETER Vendor
    Vendor folder name; lowercased in the result.

    .PARAMETER ModelId
    Model folder name, for example a short model-and-generation id.

    .PARAMETER Os
    OS family, for example win11.

    .PARAMETER OsVer
    OS release, for example 24H2.

    .EXAMPLE
    Get-KitPackagePath -OutputRoot D:\staging -Vendor Contoso -ModelId m100-g2 -Os win11 -OsVer 24H2
    Returns D:\staging\contoso\m100-g2\win11-24H2.

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Vendor,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$ModelId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Os,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$OsVer
    )

    Join-Path $OutputRoot (Join-Path $Vendor.ToLowerInvariant() (Join-Path $ModelId ('{0}-{1}' -f $Os, $OsVer)))
}
