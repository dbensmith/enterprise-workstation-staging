# Native command wrapper shared by the target and the builder. Dot-sourced by Kit.Core.psm1.

function ConvertTo-KitCommandLine {
    <#
    .SYNOPSIS
    Join arguments into one Windows command line using CreateProcess argv escaping.

    .DESCRIPTION
    An empty value becomes two quotes. A value without whitespace or quotes passes unchanged.
    Any other value has the backslashes before each quote doubled and the quote escaped, has its
    trailing backslashes doubled, and is wrapped in double quotes. Values are joined with single spaces.

    .PARAMETER ArgumentList
    The arguments, one array element per argument.

    .EXAMPLE
    ConvertTo-KitCommandLine -ArgumentList '/add-driver', 'C:\my drivers\*.inf'
    Returns /add-driver "C:\my drivers\*.inf".

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList
    )

    $escaped = foreach ($argument in $ArgumentList) {
        if ($argument -eq '') {
            '""'
        }
        elseif ($argument -notmatch '[\s"]') {
            $argument
        }
        else {
            # Double the backslashes immediately before a quote, escape the quote, then double the
            # trailing backslashes (they would otherwise escape the closing quote added below).
            $value = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
            $value = [regex]::Replace($value, '(\\+)$', '$1$1')
            '"{0}"' -f $value
        }
    }
    $escaped -join ' '
}

function Invoke-KitTool {
    <#
    .SYNOPSIS
    Run a native command, wait for it, and fail on an exit code outside -OkCode.

    .DESCRIPTION
    Builds the command line with ConvertTo-KitCommandLine, so callers pass plain argument values.
    An exit code outside -OkCode throws "<file> failed: exit <code>". An accepted non-zero code
    (3010 means restart required) writes a warning and continues. Under -WhatIf no process starts.

    .PARAMETER FilePath
    The program to run.

    .PARAMETER ArgumentList
    The arguments, one array element per argument.

    .PARAMETER OkCode
    Exit codes that count as success. Default 0 and 3010.

    .EXAMPLE
    Invoke-KitTool pnputil.exe '/add-driver', 'C:\drivers\*.inf', '/subdirs', '/install'
    Installs the drivers; exit 3010 only warns.

    .EXAMPLE
    Invoke-KitTool dism.exe '/Online', '/Cleanup-Image', '/CheckHealth' -WhatIf
    Shows the command without running it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$FilePath,
        [Parameter(Position = 1)][string[]]$ArgumentList = @(),
        [int[]]$OkCode = @(0, 3010)
    )

    $line = ConvertTo-KitCommandLine -ArgumentList $ArgumentList
    if (-not $PSCmdlet.ShouldProcess("$FilePath $line", 'Execute')) { return }

    $start = @{ FilePath = $FilePath; Wait = $true; PassThru = $true; NoNewWindow = $true }
    if ($line) { $start.ArgumentList = $line }
    $process = Start-Process @start

    if ($OkCode -notcontains $process.ExitCode) { throw "$FilePath failed: exit $($process.ExitCode)" }
    if ($process.ExitCode -ne 0) { Write-Warning "$FilePath exit $($process.ExitCode) (accepted)" }
}
