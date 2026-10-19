# Run-time config. Dot-sourced by Kit.Core.psm1. The committed config.example.psd1 is the schema and holds only empty values; the
# operator's real values live in the git-ignored config.local.psd1 beside it. Nothing here writes a config value to any stream.

function Merge-KitConfigData {
    <#
    .SYNOPSIS
    Copy values from an incoming config into the working config, rejecting anything the schema does not have.

    .DESCRIPTION
    Private helper of Get-KitConfig. Every section and key of the incoming data must already exist in the working
    config (which starts as the example), and every value must be text. Errors name keys only, never values.

    .PARAMETER Config
    Working config: section name -> hashtable of key -> text. Changed in place.

    .PARAMETER Incoming
    Data to merge, in the same shape.

    .PARAMETER SkipEmpty
    Ignore empty values, so an empty parameter cannot clear a value that was already set.

    .OUTPUTS
    None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Incoming,
        [switch]$SkipEmpty
    )

    foreach ($section in $Incoming.Keys) {
        if (-not $Config.ContainsKey($section)) { throw "Unknown config key '$section'." }
        if ($Incoming[$section] -isnot [hashtable]) { throw "Config section '$section' must be a hashtable of keys." }
        foreach ($key in $Incoming[$section].Keys) {
            if (-not $Config[$section].ContainsKey($key)) { throw "Unknown config key '$section.$key'." }
            $value = $Incoming[$section][$key]
            if ($value -isnot [string]) { throw "Config key '$section.$key' must be text." }
            if ($SkipEmpty -and $value -eq '') { continue }
            $Config[$section][$key] = $value
        }
    }
}

function Get-KitConfig {
    <#
    .SYNOPSIS
    Load the run-time config: the example's empty defaults, then config.local.psd1, then parameter overrides.

    .DESCRIPTION
    <Root>\config.example.psd1 is the schema and the defaults. When <Root>\config.local.psd1 exists its values are
    taken, and then any non-empty -Override value wins over both. Both files are read with Import-PowerShellDataFile,
    so a file that contains code is refused and the code never runs. A section or key that the example does not have
    is refused as well.

    The function never writes a config value to the console, the information, warning or verbose streams, or any
    file. Report only whether a value is present.

    .PARAMETER Root
    Folder that holds config.example.psd1 and config.local.psd1. Defaults to the kit folder.

    .PARAMETER Override
    Values that win over the local file, in the same shape as the example: @{ Section = @{ Key = 'value' } }.
    An empty value is ignored.

    .EXAMPLE
    $config = Get-KitConfig
    if ($config.ThirdParty.InstallerUrl) { 'installer link present' }

    .OUTPUTS
    System.Management.Automation.PSCustomObject. One property per example section (a hashtable), plus Source
    ('Local' or 'Defaults') and LocalPath (the local file, or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Root = (Get-KitRoot),
        [hashtable]$Override = @{}
    )

    $examplePath = Join-Path $Root 'config.example.psd1'
    $localPath = Join-Path $Root 'config.local.psd1'
    if (-not (Test-Path -LiteralPath $examplePath -PathType Leaf)) {
        throw "Config schema config.example.psd1 not found under $Root."
    }

    # Detail of a parse failure is withheld on purpose: it can quote part of the file, and the file holds secrets.
    $config = @{}
    $schema = Import-PowerShellDataFile -LiteralPath $examplePath
    foreach ($section in $schema.Keys) {
        $config[$section] = @{}
        foreach ($key in $schema[$section].Keys) { $config[$section][$key] = $schema[$section][$key] }
    }

    $source = 'Defaults'
    $usedLocalPath = $null
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        try {
            $local = Import-PowerShellDataFile -LiteralPath $localPath
        }
        catch {
            throw 'config.local.psd1 is not a plain data file (no code, variables or expressions); fix or delete it. Detail withheld so no value is echoed.'
        }
        Merge-KitConfigData -Config $config -Incoming $local
        $source = 'Local'
        $usedLocalPath = $localPath
        Write-Verbose "Loaded config.local.psd1 from $Root."
    }
    Merge-KitConfigData -Config $config -Incoming $Override -SkipEmpty

    $result = [ordered]@{}
    foreach ($section in $schema.Keys) { $result[$section] = $config[$section] }
    $result['Source'] = $source
    $result['LocalPath'] = $usedLocalPath
    [pscustomobject]$result
}
