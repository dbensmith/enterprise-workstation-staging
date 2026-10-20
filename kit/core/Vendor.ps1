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
    foreach ($key in 'Name', 'Manufacturer', 'TargetModule') {
        if (-not $data.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$data[$key])) {
            throw "Vendor descriptor $full lacks the required key '$key'."
        }
    }
    # An empty Commands table is valid data: the contract check then reports every operation as missing.
    if (-not $data.ContainsKey('Commands') -or $data.Commands -isnot [hashtable]) {
        throw "Vendor descriptor ${full}: Commands must be a hashtable of operation name to command name."
    }
    $folder = Split-Path -Path $full -Parent
    $buildModule = if ($data.ContainsKey('BuildModule')) { [string]$data.BuildModule } else { $null }

    [pscustomobject]@{
        PSTypeName          = 'Kit.Vendor'
        Name                = [string]$data.Name
        Manufacturer        = [string]$data.Manufacturer
        Folder              = $folder
        DescriptorPath      = $full
        TargetModulePath    = Resolve-KitVendorModulePath -Folder $folder -Module ([string]$data.TargetModule)
        BuildModulePath     = Resolve-KitVendorModulePath -Folder $folder -Module $buildModule
        TargetModuleSetting = [string]$data.TargetModule
        BuildModuleSetting  = $buildModule
        Commands            = $data.Commands
    }
}

function Get-KitVendor {
    <#
    .SYNOPSIS
    Find vendor descriptors and return the vendors they describe.

    .DESCRIPTION
    A descriptor (vendor.psd1) is data only: Name, Manufacturer (a regex), TargetModule, BuildModule and
    the Commands table that maps each contract operation to a command name. Module paths are relative
    to the descriptor folder, or rooted. A module path is $null when the file does not exist.

    With no selector every vendor under the roots is returned. -Name and -Manufacturer pick one vendor
    (-Manufacturer matches the laptop's manufacturer string against each descriptor's regex), and
    -DescriptorPath reads one file. Two descriptors that declare the same Name make every scan throw
    rather than letting one shadow the other, and so does a root with no descriptor at all.

    .PARAMETER Name
    Vendor name, compared case-insensitively.

    .PARAMETER Manufacturer
    A manufacturer string, for example the one WMI reports. Exactly one descriptor must match.

    .PARAMETER DescriptorPath
    Path of one vendor.psd1.

    .PARAMETER VendorRoot
    Folders searched recursively for vendor.psd1. Defaults to the vendors folder under the kit.

    .EXAMPLE
    Get-KitVendor -Manufacturer (Get-CimInstance Win32_ComputerSystem).Manufacturer

    .EXAMPLE
    Get-KitVendor -DescriptorPath .\vendors\contoso\vendor.psd1

    .OUTPUTS
    Kit.Vendor
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName')][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'ByManufacturer')][string]$Manufacturer,
        [Parameter(Mandatory, ParameterSetName = 'ByPath')][string]$DescriptorPath,
        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ByManufacturer')]
        [string[]]$VendorRoot = @(Join-Path -Path (Get-KitRoot) -ChildPath 'vendors')
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        return Read-KitVendorDescriptor -Path $DescriptorPath
    }

    $files = @(foreach ($root in $VendorRoot) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -Filter 'vendor.psd1' -File -Recurse | Sort-Object -Property FullName
            }
        })
    if ($files.Count -eq 0) {
        throw "No vendor descriptors (vendor.psd1) under $($VendorRoot -join ', ')"
    }
    $vendors = @(foreach ($file in $files) { Read-KitVendorDescriptor -Path $file.FullName })

    foreach ($group in ($vendors | Group-Object -Property Name)) {
        if ($group.Count -gt 1) {
            throw "Vendor '$($group.Name)' is declared by more than one descriptor: $(($group.Group | ForEach-Object { $_.DescriptorPath }) -join ', ')"
        }
    }

    switch ($PSCmdlet.ParameterSetName) {
        'ByName' {
            $selected = @($vendors | Where-Object { $_.Name -ieq $Name })
            $wanted = $Name
        }
        'ByManufacturer' {
            $selected = @($vendors | Where-Object { $Manufacturer -match $_.Manufacturer })
            $wanted = $Manufacturer
        }
        default {
            return $vendors | Sort-Object -Property Name
        }
    }
    if ($selected.Count -eq 0) {
        throw "No vendor matches '$wanted'. Available: $(($vendors | ForEach-Object { $_.Name } | Sort-Object) -join ', ')"
    }
    if ($selected.Count -gt 1) {
        throw "Vendor selection '$wanted' is ambiguous: it matches $(($selected | ForEach-Object { $_.Name }) -join ', ')"
    }
    $selected[0]
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

    try {
        $vendor = Read-KitVendorDescriptor -Path $DescriptorPath
    }
    catch {
        ConvertTo-KitContractViolation -Vendor $DescriptorPath -Kind 'InvalidDescriptor' -Detail $_.Exception.Message
        return
    }
    $contract = Get-KitVendorContractTable

    $modules = @{}
    try {
        # Planes load in a fixed order (Build, then Target) whatever order -Plane lists them in.
        foreach ($name in 'Build', 'Target') {
            if ($Plane -notcontains $name) { continue }
            $path = if ($name -eq 'Build') { $vendor.BuildModulePath } else { $vendor.TargetModulePath }
            $setting = if ($name -eq 'Build') { $vendor.BuildModuleSetting } else { $vendor.TargetModuleSetting }
            if (-not $path) {
                $declared = if ($setting) { $setting } else { 'not declared in the descriptor' }
                ConvertTo-KitContractViolation -Vendor $vendor.Name -Kind 'ModuleNotFound' -Detail "$name module file not found: $declared"
                continue
            }
            try {
                $modules[$name] = Import-Module -Name $path -Force -PassThru -ErrorAction Stop
            }
            catch {
                ConvertTo-KitContractViolation -Vendor $vendor.Name -Kind 'ModuleNotFound' -Detail "$name module $path failed to import: $($_.Exception.Message)"
            }
        }

        foreach ($entry in $contract) {
            if ($Plane -notcontains $entry.Plane) { continue }
            if (-not $vendor.Commands.ContainsKey($entry.Name)) {
                ConvertTo-KitContractViolation -Vendor $vendor.Name -Operation $entry.Name -Kind 'MissingOperation' `
                    -Detail "Commands has no entry for '$($entry.Name)'."
                continue
            }
            $module = $modules[$entry.Plane]
            if (-not $module) { continue }
            $commandName = [string]$vendor.Commands[$entry.Name]
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

        $known = @($contract | ForEach-Object { $_.Name })
        foreach ($key in ($vendor.Commands.Keys | Sort-Object)) {
            if ($known -notcontains $key) {
                ConvertTo-KitContractViolation -Vendor $vendor.Name -Operation ([string]$key) -Kind 'UnknownOperation' `
                    -Detail "Commands key '$key' is not an operation in the contract."
            }
        }
    }
    finally {
        foreach ($module in $modules.Values) {
            if ($module) { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-KitVendorCommand {
    <#
    .SYNOPSIS
    Run one contract operation through the vendor's mapped command.

    .DESCRIPTION
    Looks up the operation's plane in the contract table, imports that plane's module (an already loaded
    copy is reused), and runs the command the vendor's Commands table maps the operation to. Callers stay
    vendor-neutral: the vendor is a parameter. A Build operation needs the vendor's build module, which
    the Tools stick does not carry, and throws when it is absent.

    .PARAMETER Vendor
    A Kit.Vendor from Get-KitVendor.

    .PARAMETER Operation
    One of the contract operations or helpers.

    .PARAMETER Parameters
    Parameters passed to the command by splatting.

    .EXAMPLE
    Invoke-KitVendorCommand -Vendor $vendor -Operation InstallFirmware -Parameters @{ PackagePath = 'D:\fw' }

    .OUTPUTS
    Whatever the vendor command returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Vendor,
        [Parameter(Mandatory)]
        [ValidateSet('ListModels', 'GetVendorPack', 'NewCustomPack', 'GetFirmware', 'GetFirmwareStickLayout', 'InstallDrivers', 'InstallFirmware', 'GetDeviceIdentity', 'GetInstalledFirmwareVersion')]
        [string]$Operation,
        [hashtable]$Parameters = @{}
    )

    $contract = Get-KitVendorContractTable
    $entry = $contract | Where-Object { $_.Name -eq $Operation }
    $modulePath = if ($entry.Plane -eq 'Build') { $Vendor.BuildModulePath } else { $Vendor.TargetModulePath }
    if (-not $modulePath) {
        throw "Vendor '$($Vendor.Name)' has no $($entry.Plane) module here. Build operations need the builder/ folder, which is not copied to the Tools stick."
    }
    if (-not $Vendor.Commands.ContainsKey($Operation)) {
        throw "Vendor '$($Vendor.Name)' maps no command to the operation '$Operation'."
    }
    $commandName = [string]$Vendor.Commands[$Operation]
    $module = Import-Module -Name $modulePath -Global -PassThru -ErrorAction Stop
    if (-not $module.ExportedCommands.ContainsKey($commandName)) {
        throw "Vendor '$($Vendor.Name)' maps $Operation to '$commandName', which $modulePath does not export."
    }
    $command = $module.ExportedCommands[$commandName]
    & $command @Parameters
}
