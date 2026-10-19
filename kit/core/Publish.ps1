# The one list of kit files that may leave the builder. Dot-sourced by Kit.Core.psm1. Pure: nothing here writes.

function Get-KitPublishFile {
    <#
    .SYNOPSIS
    List the kit files that may be copied into an image or onto a stick, with their kit-relative paths.

    .DESCRIPTION
    Every copy of the kit that leaves the builder must start from this list. It leaves out two kinds of file
    on purpose. A file named *.local.psd1 holds this site's own settings (the run-time config sits beside the
    launcher as config.local.psd1), and anything inside a folder named results holds serial numbers and other
    customer data from audited laptops. Neither may travel into an image. The check applies at any depth and
    ignores case. Hidden files are not listed.

    .PARAMETER Root
    The kit folder to list. Defaults to the kit folder this module belongs to.

    .EXAMPLE
    Get-KitPublishFile | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.RelativePath) }
    Copies the publishable kit files, keeping their folder layout (create the parent folders first).

    .EXAMPLE
    (Get-KitPublishFile -Root D:\Tools\kit).RelativePath
    Shows which files of a copied kit folder would be published.

    .OUTPUTS
    Kit.PublishFile: RelativePath (backslash-separated, relative to Root) and FullName. Sorted by RelativePath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Root = (Get-KitRoot)
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File) {
        $relative = $file.FullName.Substring($rootPath.Length + 1)
        if ($file.Name -like '*.local.psd1') { continue }
        if ($relative.Split('\') -contains 'results') { continue }
        $entries.Add([pscustomobject]@{
                PSTypeName   = 'Kit.PublishFile'
                RelativePath = $relative
                FullName     = $file.FullName
            })
    }
    # Ordinal and case-insensitive, so the order does not depend on the machine's culture.
    $entries.Sort([System.Comparison[object]] {
            param($left, $right)
            [string]::Compare($left.RelativePath, $right.RelativePath, [System.StringComparison]::OrdinalIgnoreCase)
        })
    $entries.ToArray()
}
