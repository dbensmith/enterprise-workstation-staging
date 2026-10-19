param(
    [string[]]$VendorRoot = @(
        (Join-Path $PSScriptRoot '..\kit\vendors'),
        (Join-Path $PSScriptRoot 'fixtures\vendors\complete')
    )
)

# Read the parameter at file level: the analyzer does not see a use inside the BeforeDiscovery block.
$script:vendorRoots = $VendorRoot

BeforeDiscovery {
    # An empty -ForEach throws in Pester 6, so a run that finds no descriptor fails loudly instead of passing vacuously.
    $script:descriptors = @(foreach ($root in $script:vendorRoots) {
            if (Test-Path -LiteralPath $root) {
                foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'vendor.psd1' -File -Recurse) {
                    @{ Name = $file.Directory.Name; Descriptor = $file.FullName }
                }
            }
        })
    $script:operationNames = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\kit\core\VendorContract.psd1')).Operations |
            ForEach-Object { $_.Name })
}

Describe 'Vendor <Name> contract' -ForEach $script:descriptors {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force
        $script:violations = @(Test-KitVendorContract -DescriptorPath $Descriptor)
    }

    It 'maps <_> to a command with the pinned parameters' -ForEach $script:operationNames {
        $operation = $_
        $problems = @($script:violations | Where-Object { $_.Operation -eq $operation } |
                ForEach-Object { '{0} {1} {2}' -f $_.Operation, $_.Kind, $_.Detail })
        $problems | Should -BeNullOrEmpty
    }

    It 'has a valid descriptor' {
        $problems = @($script:violations | Where-Object { -not $_.Operation } |
                ForEach-Object { '{0} {1}' -f $_.Kind, $_.Detail })
        $problems | Should -BeNullOrEmpty
    }
}
