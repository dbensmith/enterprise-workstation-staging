# Vendor interface mechanism: contract table, descriptor reader, contract checker. Dot-sourced by Kit.Core.psm1.
# Descriptors (vendor.psd1) and the contract table (VendorContract.psd1) are data only and are read with
# Import-PowerShellDataFile, which rejects code. Nothing here names a vendor.

function Get-KitVendorContractTable {
    # Private. The contract entries in table order.
    [CmdletBinding()]
    [OutputType([System.Array])]
    param()

    $table = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'VendorContract.psd1')
    , @($table.Operations)
}

function ConvertTo-KitContractViolation {
    # Private. One violation record.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Vendor,
        [AllowEmptyString()][string]$Operation = '',
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Detail
    )

    [pscustomobject]@{
        PSTypeName = 'Kit.ContractViolation'
        Vendor     = $Vendor
        Operation  = $Operation
        Kind       = $Kind
        Detail     = $Detail
    }
}

function Resolve-KitVendorModulePath {
    # Private. A module path from a descriptor: relative to the descriptor folder, or as-is when rooted.
    # $null when the key is absent or the file does not exist.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [AllowNull()][AllowEmptyString()][string]$Module
    )

    if ([string]::IsNullOrWhiteSpace($Module)) { return $null }
    $path = if ([IO.Path]::IsPathRooted($Module)) { $Module } else { Join-Path -Path $Folder -ChildPath $Module }
    $full = [IO.Path]::GetFullPath($path)
    if (Test-Path -LiteralPath $full -PathType Leaf) { $full } else { $null }
}

function Read-KitVendorDescriptor {
    # Private. Read one vendor.psd1 into a Kit.Vendor object. Throws when the file is not valid data
    # or lacks a required key.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Vendor descriptor not found: $full"
    }
    $data = Import-PowerShellDataFile -LiteralPath $full
    foreach ($key in 'Name', 'Manufacturer', 'TargetModule', 'Commands') {
        if (-not $data.ContainsKey($key) -or $null -eq $data[$key] -or "$($data[$key])" -eq '') {
            throw "Vendor descriptor $full lacks the required key '$key'."
        }
    }
    if ($data.Commands -isnot [hashtable]) {
        throw "Vendor descriptor ${full}: Commands must be a hashtable of operation name to command name."
    }
    $folder = Split-Path -Path $full -Parent
    $buildModule = if ($data.ContainsKey('BuildModule')) { [string]$data.BuildModule } else { $null }

    [pscustomobject]@{
        PSTypeName       = 'Kit.Vendor'
        Name             = [string]$data.Name
        Manufacturer     = [string]$data.Manufacturer
        Folder           = $folder
        DescriptorPath   = $full
        TargetModulePath = Resolve-KitVendorModulePath -Folder $folder -Module ([string]$data.TargetModule)
        BuildModulePath  = Resolve-KitVendorModulePath -Folder $folder -Module $buildModule
        Commands         = $data.Commands
    }
}

function Get-KitVendor {
    <#
    .SYNOPSIS
    Read a vendor descriptor and return the vendor it describes.

    .DESCRIPTION
    A descriptor (vendor.psd1) is data only: Name, Manufacturer (a regex), TargetModule, BuildModule and
    the Commands table that maps each contract operation to a command name. Module paths are relative
    to the descriptor folder, or rooted. A module path is $null when the file does not exist.

    .PARAMETER DescriptorPath
    Path of one vendor.psd1.

    .EXAMPLE
    Get-KitVendor -DescriptorPath .\vendors\contoso\vendor.psd1

    .OUTPUTS
    Kit.Vendor
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$DescriptorPath
    )

    Read-KitVendorDescriptor -Path $DescriptorPath
}

function Test-KitVendorContract {
    <#
    .SYNOPSIS
    Check one vendor descriptor against the contract table and return every violation.

    .DESCRIPTION
    For each contract entry, in table order, the descriptor must map the operation to a command that its
    plane's module exports, and the command must accept every pinned parameter name. Violations come back
    as Kit.ContractViolation objects with Vendor, Operation, Kind and Detail; no output means the vendor
    satisfies the contract. The check only reads: it writes no file.

    .PARAMETER DescriptorPath
    Path of the vendor.psd1 to check.

    .PARAMETER Plane
    Which planes to check. Defaults to both.

    .EXAMPLE
    Test-KitVendorContract -DescriptorPath .\vendors\contoso\vendor.psd1

    .OUTPUTS
    Kit.ContractViolation
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$DescriptorPath,
        [ValidateSet('Build', 'Target')][string[]]$Plane = @('Build', 'Target')
    )

    $vendor = Read-KitVendorDescriptor -Path $DescriptorPath
    $contract = Get-KitVendorContractTable

    $modules = @{}
    try {
        foreach ($name in $Plane) {
            $path = if ($name -eq 'Build') { $vendor.BuildModulePath } else { $vendor.TargetModulePath }
            $modules[$name] = Import-Module -Name $path -Force -PassThru
        }

        foreach ($entry in $contract) {
            if ($Plane -notcontains $entry.Plane) { continue }
            if (-not $vendor.Commands.ContainsKey($entry.Name)) {
                ConvertTo-KitContractViolation -Vendor $vendor.Name -Operation $entry.Name -Kind 'MissingOperation' `
                    -Detail "Commands has no entry for '$($entry.Name)'."
                continue
            }
            $commandName = [string]$vendor.Commands[$entry.Name]
            $module = $modules[$entry.Plane]
            if (-not $module.ExportedCommands.ContainsKey($commandName)) {
                ConvertTo-KitContractViolation -Vendor $vendor.Name -Operation $entry.Name -Kind 'CommandNotFound' `
                    -Detail "$commandName is not exported by $($module.Path)"
                continue
            }
            $available = @($module.ExportedCommands[$commandName].Parameters.Keys)
            foreach ($parameter in $entry.Parameters) {
                if ($available -notcontains $parameter) {
                    ConvertTo-KitContractViolation -Vendor $vendor.Name -Operation $entry.Name -Kind 'MissingParameter' `
                        -Detail $parameter
                }
            }
        }
    }
    finally {
        foreach ($module in $modules.Values) {
            if ($module) { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
        }
    }
}
