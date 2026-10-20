# Deferred items (phase 02)

## From Plan 02-05

- **builder/Build-DriverBaseline.ps1: `$PSScriptRoot` in a param default fails under Windows PowerShell 5.1 with `-File`.**
  `[string]$OutputRoot = (Join-Path $PSScriptRoot '..\staging')` together with `[CmdletBinding()]` leaves `$PSScriptRoot`
  empty at binding time, so `Build.cmd -Vendor HP -Model 840-g6` without `-OutputRoot` stops with "Cannot bind argument to
  parameter 'Path' because it is an empty string". Reproduced with a three-line script. `tests/Builder.Tests.ps1` always passes
  `-OutputRoot`, so it never sees it. Fix when that script is next opened: drop the default from the param block and set it in
  the body (`if (-not $OutputRoot) { $OutputRoot = Join-Path $PSScriptRoot '..\staging' }`), and update the AST test that pins
  the default text. `builder/Build-ToolsStick.ps1` already does this.
