# PSScriptAnalyzer settings for Test-Kit.ps1.
# This file may only ENABLE extra rules. The project forbids lint suppression of any kind:
# no rule exclusion, rule inclusion or severity filter here, no suppression attributes in code.
# Findings are fixed in the code. tests\Repo.Tests.ps1 enforces this shape.
@{
    Rules = @{
        # Flag syntax that Windows PowerShell 5.1 cannot parse (the kit runs on stock 5.1).
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
