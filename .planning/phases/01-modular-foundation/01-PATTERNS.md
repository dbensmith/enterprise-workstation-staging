# Phase 1: Modular Foundation - Pattern Map

**Mapped:** 2026-10-09
**Files analyzed:** 30 (new or moved)
**Analogs found:** 22 / 30

All analogs are git-tracked under `src/` (verified with `git ls-files src`). Paths under `HP_Staging/` hold untracked copies of the scripts and must never be used as analogs.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `kit/core/Kit.Core.psd1` + `Kit.Core.psm1` | module manifest/loader | n/a | `src/HPDriverBaseline.psm1` (header L1-2, export L250) | role-match |
| `kit/core/IsoServicing.ps1` | service (moved) | file-I/O | `src/HPDriverBaseline.psm1` L113-248 (git mv content) | exact |
| `kit/core/Vendor.ps1` (Get-KitVendor, Test-KitVendorContract, Invoke-KitVendorCommand) | utility | transform | `src/HPDriverBaseline.psm1` `Select-BaselineSoftpaq` L34-69 (returns result objects) | partial |
| `kit/core/VendorContract.psd1` | config (data) | n/a | `src/profiles/hp-elitebook-840-g6.psd1` | partial |
| `kit/core/Profile.ps1` (Get-KitProfile, Get-KitVerifiedValue) | utility | file-I/O | `src/HPDriverBaseline.psm1` `Select-OsRelease` L4-32 (throw-with-context) | partial |
| `kit/core/Config.ps1` (Get-KitConfig) | utility | file-I/O | same as Profile.ps1 | partial |
| `kit/core/Paths.ps1` (Get-KitPackagePath, Get-KitRoot) | utility | transform | `src/Build-HPDriverBaseline.ps1` L46, L103 (code it replaces) | partial |
| `kit/vendors/hp/vendor.psd1` | config (data) | n/a | profile psd1 | partial |
| `kit/vendors/hp/HP.Target.psm1` | service | request-response (CIM) | `src/HPDriverBaseline.psm1` + test contract `src/HPDriverBaseline.Tests.ps1` L125-170 | role-match |
| `builder/vendors/hp/HP.Build.psm1` | service | batch (HPCMSL) | `src/HPDriverBaseline.psm1` L4-111 (moved) + `Initialize-HPCMSL` `src/Build-HPDriverBaseline.ps1` L58-75 | exact |
| `kit/Install-DriverBaseline.ps1` (git mv + `-LogPath`, `-Vendor`) | entry script | batch | `src/Install-HPDriverBaseline.ps1` | exact |
| `kit/Test-DeviceBaseline.ps1` (git mv + Show-* fix) | entry script | request-response | `src/Test-DeviceBaseline.ps1` | exact |
| `builder/Build-DriverBaseline.ps1` | entry script | batch | `src/Build-HPDriverBaseline.ps1` | exact |
| `builder/iso/New-BaselineIso.ps1` | entry script | file-I/O | `src/New-HPBaselineIso.ps1` | exact |
| `kit/Run.ps1` | entry/dispatcher | request-response | `src/Install-HPDriverBaseline.ps1` L1-37 (header, prefs, scriptRoot) | role-match |
| `kit/Run.cmd`, `Build.cmd` | launcher | n/a | none | no analog (RESEARCH Pattern 9) |
| `kit/profiles/hp/840-g6.psd1` | config (data) | n/a | `src/profiles/hp-elitebook-840-g6.psd1` | exact |
| `kit/profiles/hp/840-g5.psd1` | config (data) | n/a | `src/profiles/hp-elitebook-840-g6.psd1` | exact |
| `kit/config.example.psd1` | config (data) | n/a | profile psd1 | partial |
| `Test-Kit.ps1` | gate script | batch | `src/Build-HPDriverBaseline.ps1` L41-75 (param + tool bootstrap) | partial |
| `.githooks/pre-commit` | hook (sh) | n/a | none | no analog (RESEARCH Pattern 10) |
| `.gitleaks.toml` | config | n/a | none | no analog (RESEARCH Pattern 10) |
| `PSScriptAnalyzerSettings.psd1` | config | n/a | none | no analog (RESEARCH Pattern 6) |
| `.gitattributes` | config | n/a | none | no analog |
| `.gitignore` (modify) | config | n/a | existing `.gitignore` | exact |
| `tests/HP.Build.Tests.ps1` | test | n/a | `src/HPDriverBaseline.Tests.ps1` L1-60, L185-199 | exact |
| `tests/HP.Target.Tests.ps1` | test | n/a | `src/HPDriverBaseline.Tests.ps1` L125-170 | exact |
| `tests/Core.Tests.ps1` | test | n/a | `src/HPDriverBaseline.Tests.ps1` (ISO describe, ~L100-123) | exact |
| `tests/Contract.Tests.ps1` + `tests/fixtures/vendors/missing-op/*` | test | n/a | `-ForEach` data-driven Its in Tests L148-163 | role-match |
| `tests/Profiles.Tests.ps1`, `tests/Repo.Tests.ps1` | test | n/a | AST scan in Tests L172-182 | role-match |

## Pattern Assignments

### `builder/vendors/hp/HP.Build.psm1` and `kit/core/IsoServicing.ps1` (moved code)

**Analog:** `src/HPDriverBaseline.psm1`. Split per D-05: L4-111 (`Select-OsRelease`, `Select-BaselineSoftpaq`, `Split-SoftpaqCommand`, `ConvertTo-ReturnCodeMap`) to HP.Build; L113-248 (`Select-InstallImage`, `New-WindowsInstallIso`) to core. Move bodies unchanged.

**Header** (L1-2):
```powershell
#Requires -Version 5.1
# Shared helpers for the build and ISO scripts. No HPCMSL calls and no admin needed, so Pester can test them offline.
```

**Function shape** (L4-16) - comment help inside body, `[CmdletBinding()]`, `[OutputType()]`, `[Parameter(Mandatory)]` attribute style:
```powershell
function Select-OsRelease {
    <#
    .SYNOPSIS
    ...
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$OsList,
        [Parameter(Mandatory)][ValidateSet('win10', 'win11')][string]$Os,
        [string]$OsVer
    )
```

**Error pattern** (L20-27) - plain `throw` with the available values in the message:
```powershell
throw "HP catalog does not index $osName $OsVer for this platform. Available: $($releases.OperatingSystemRelease -join ', ')"
```

**State-changing function** (L140, L160) - required by PSSA for `New-*`:
```powershell
[CmdletBinding(SupportsShouldProcess)]
...
if (-not $PSCmdlet.ShouldProcess($Path, "Build bootable ISO from $MediaPath")) { return }
```
Note: the Add-Type namespace `HPDriverBaseline.ComStreamWriter` (L162-168, L224) is vendor-named; rename to a neutral namespace (e.g. `KitCore.ComStreamWriter`) when moving to core.

**Export** (L250) - explicit list; mirror in `Kit.Core.psd1` `FunctionsToExport`:
```powershell
Export-ModuleMember -Function Select-OsRelease, Select-BaselineSoftpaq, Split-SoftpaqCommand, ConvertTo-ReturnCodeMap, Select-InstallImage, New-WindowsInstallIso
```

**Lazy HPCMSL import** - copy `Initialize-HPCMSL` from `src/Build-HPDriverBaseline.ps1` L58-75 into HP.Build.psm1 and call it inside each build op. Never top-level `Import-Module HPCMSL` or `#Requires -Modules`. Rename to an approved-verb, non-colliding name is optional (Initialize is approved).
```powershell
function Initialize-HPCMSL {
    if (Get-Module -ListAvailable -Name HPCMSL) {
        Import-Module HPCMSL
        return
    }
    Write-Information 'Installing HPCMSL from the PowerShell Gallery...'
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
    ...
```
Stub build ops (GetVendorPack etc.) must reference every pinned parameter in the NotImplemented message (RESEARCH Pattern 2).

---

### `kit/vendors/hp/HP.Target.psm1` (service, CIM)

**Analog:** module style above; behaviour contract from `src/HPDriverBaseline.Tests.ps1` L125-170.

- `ConvertTo-HPBiosVersion` - one positional string -> `[pscustomobject]@{ Family; Version=[version] }` or nothing. Parser draft in RESEARCH Pattern 8.
- `Get-FirmwareSkipReason` - one positional entry. BIOS (`Category -like 'BIOS*'`): call ONLY `Get-CimInstance -ClassName Win32_BIOS`; same family and installed >= package -> string containing `already current`; else `$null`. Device entries: call ONLY `Get-CimInstance -ClassName Win32_PnPEntity`; no `Devices` id in any `HardwareID` -> exactly `'no matching device in this PC'`.
- Must use `-ClassName` named parameter (mocks filter on `$ClassName`, L135, L165).
- Contract commands `Install-HPKitDriver`, `Install-HPKitFirmware`, `Get-HPKitDeviceIdentity`, `Get-HPKitInstalledFirmware` (names from RESEARCH Pattern 2; `HPKit` prefix avoids HPCMSL collisions).
- No HPCMSL; stock 5.1 only (CIM, pnputil, DISM).

---

### `kit/Install-DriverBaseline.ps1` (git mv of `src/Install-HPDriverBaseline.ps1`)

**Header/help/param** (L1-32) - keep; add `[string]$LogPath` and `-Vendor`:
```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator
<# .SYNOPSIS ... .EXAMPLE ... #>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('Path', 'ImagePath')]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$OfflineImagePath,
    [switch]$SkipFirmware,
    # Apply even if the board's platform ID does not match the manifest.
    [switch]$Force
)
```

**Preferences + root** (L34-37) - shared by all entry scripts:
```powershell
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
```
D-04 change: today it reads `manifest.json` from `$scriptRoot` (L45-46). The installer no longer lives in the package, so take a `-PackagePath` (contract parameter name) and read `Join-Path $PackagePath 'manifest.json'`. Import core via `Join-Path $PSScriptRoot 'core\Kit.Core.psd1'`.

**Error accumulation** (L47, L76-86) - keep `$script:failures` counter + `exit [int]($script:failures -gt 0)`:
```powershell
try { Invoke-Tool dism.exe "/Image:$OfflineImagePath", '/Add-Driver', "/Driver:$driverDir", '/Recurse' }
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    $script:failures++
}
exit [int]($script:failures -gt 0)
```
Wrap the body in the `Start-Transcript`/`try`/`finally Stop-Transcript` from RESEARCH Pattern 8. `Invoke-Tool` (L49-76, argv escaping + OkCodes) is target-plane shared logic: candidate to move to `HP.Target.psm1` or core so `Install-HPKitDriver` can reuse it.

---

### `builder/Build-DriverBaseline.ps1` (git mv of `src/Build-HPDriverBaseline.ps1`)

Keep help block (L3-40) and `[CmdletBinding(SupportsShouldProcess)]` param (L41-52). Change:
- L44 profile default -> `Join-Path $PSScriptRoot '..\kit\profiles\hp\840-g6.psd1'`; add `-Vendor HP`, `-Model 840-g6`.
- L46 `[string]$OutputRoot = 'C:\HP_Staging'` -> default `Join-Path $PSScriptRoot '..\staging'`; L103 `$packageDir = Join-Path $OutputRoot ('{0}-{1}-{2}' ...)` -> `Get-KitPackagePath`.
- L56 `Import-Module (Join-Path $PSScriptRoot 'HPDriverBaseline.psm1') -Force` -> two relative imports (core + `vendors\hp\HP.Build.psm1`).
- Stop copying the installer into the package (D-04).

### `builder/iso/New-BaselineIso.ps1` (git mv of `src/New-HPBaselineIso.ps1`)
- L68, L74 `C:\HP_Staging\...` defaults -> staging scheme.
- L137 answer-file `<Path>` must match the new installer location/params; it copies `kit/` (minus `config.local.psd1`) into the image instead of the package's installer.

### `kit/Test-DeviceBaseline.ps1` (git mv)
Lines 262-274 and 313-318 hold all 13 `Write-Host` findings. Move them into `Show-*` functions (e.g. `Show-AuditLine`, `Show-SaveResult`); PSSA ignores `Write-Host` inside `Show-*`. Keep it self-contained (no module import) for later `irm | iex`.

### `kit/Run.ps1`
Copy header + preferences pattern from Install L1-37 (minus `#Requires -RunAsAdministrator`; self-elevate instead per RESEARCH Pattern 9). Thin `-Mode Audit|Install` dispatcher using `& (Join-Path $PSScriptRoot '...ps1') @args`.

---

### `kit/profiles/hp/840-g6.psd1` and `840-g5.psd1`

**Analog:** `src/profiles/hp-elitebook-840-g6.psd1` (git mv to 840-g6). Keep leading `#` comment block explaining platform siblings and exclude semantics (L1-5), keep existing keys, then add `SchemaVersion`, `Vendor`, `ModelId`, `BiosFamily`, `PackSelection`, `FirmwareMinimum{...Verified}`, `BiosDefaults{...Verified}` per RESEARCH Pattern 4. G5: `83B2`, `Q78`, `01.31.00`, `sp157750`, `PlatformVerified = $false`.

### `kit/core/VendorContract.psd1`, `kit/vendors/hp/vendor.psd1`, `kit/config.example.psd1`
Same `@{ }` data-only style as the profile, with `#` comments per key. Content verbatim from RESEARCH Patterns 2 and 11. Values in config.example stay `''`. Load all with `Import-PowerShellDataFile`.

---

### Tests (`tests/*.Tests.ps1`)

**Analog:** `src/HPDriverBaseline.Tests.ps1`.

**Module import + `$script:` fixtures** (L1-18) - change path to `Join-Path $PSScriptRoot '..\builder\vendors\hp\HP.Build.psm1'` etc.:
```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'HPDriverBaseline.psm1') -Force
    # Fixtures mirror live HPCMSL 1.9.0 output for platform 8549 (2026-09-28).
    $script:osList = @( [pscustomobject]@{ ... } )
}
```
Keep the `$script:` prefix (avoids PSUseDeclaredVarsMoreThanAssignments).

**Data-driven It** (L148-153) - template for Contract.Tests one-It-per-operation:
```powershell
It 'skips the BIOS when the installed version is <installed> (same or newer)' -ForEach @(
    @{ installed = 'R70 Ver. 01.36.00' }
    @{ installed = 'R70 Ver. 01.37.00' }
) { ... }
```

**Mock** (L135) - in HP.Target.Tests add `-ModuleName HP.Target` to every `Mock`/`Should -Invoke`, plus a default throwing mock:
```powershell
Mock Get-CimInstance { [pscustomobject]@{ SMBIOSBIOSVersion = $script:installedBios } } -ParameterFilter { $ClassName -eq 'Win32_BIOS' }
```
Drop the AST dot-sourcing at L127-129 (functions now live in a module).

**AST extraction of standalone scripts** (L172-182) - reuse for the answer-file test and the new installer `param()` binding test and Repo/Profile static scans:
```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'New-HPBaselineIso.ps1'), [ref]$null, [ref]$null)
$text = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '*<unattend*' }, $true)[0].Value
```
Replace the L180 string-only `BeLike '*Install-HPDriverBaseline.ps1 -LogPath*'` with a check that each `-Name` token exists in the installer's `ParamBlock.Parameters`.

**TestDrive** usage (ISO describe, ~L118-121) - template for contract negative tests and hook-proof temp repo:
```powershell
$null = New-Item $bare -ItemType Directory
{ New-WindowsInstallIso -MediaPath $bare -Path (Join-Path $TestDrive 'bare.iso') } | Should -Throw '*Boot file missing*etfsboot.com'
```

---

### `Test-Kit.ps1`
Copy the help block + `[CmdletBinding()]` param style from `src/Build-HPDriverBaseline.ps1` L3-52 and the TLS/NuGet bootstrap from L64-70 for `-InstallTools`. Switches: `-PreCommit`, `-ScanHistory`, `-InstallHook`, `-InstallTools`. Order and commands: RESEARCH Pattern 10. Explicit lint paths `kit`, `builder`, `tests`, root `*.ps1` (never `.`).

### `.gitignore` (modify)
Existing file groups entries under `# Heading` comments. Add `staging/` under "Staging & build artifacts" and `.tools/` under a new "Local tools" heading. Keep `HP_Staging/`, `*.local.psd1`, `results/`.

## Shared Patterns

### Script header and preferences
**Source:** `src/Install-HPDriverBaseline.ps1` L1-37, `src/Build-HPDriverBaseline.ps1` L1-56
**Apply to:** every entry script (`Run.ps1`, `Install-DriverBaseline.ps1`, `Build-DriverBaseline.ps1`, `New-BaselineIso.ps1`, `Test-Kit.ps1`)
`#Requires -Version 5.1`, full comment help with `.EXAMPLE`, `[CmdletBinding(SupportsShouldProcess)]`, `$ErrorActionPreference = 'Stop'`, `$InformationPreference = 'Continue'`, `Write-Information` for progress (no `Write-Host` outside `Show-*`).

### Relative imports (D-03)
**Source:** `src/Build-HPDriverBaseline.ps1` L56 `Import-Module (Join-Path $PSScriptRoot 'HPDriverBaseline.psm1') -Force`
**Apply to:** all entry scripts and tests; never absolute paths.

### Errors
Module functions: `throw "<what failed>. Available: <options>"` (psm1 L21, L26, L82, L128). Entry scripts: `try/catch` -> `Write-Error ... -ErrorAction Continue` + `$script:failures++`, single `exit [int]($script:failures -gt 0)`.

### Offline testability
Header comment psm1 L2: no HPCMSL, no admin at import. Applies to `Kit.Core`, `HP.Target`, `HP.Build`.

## No Analog Found

| File | Role | Reason | Use |
|---|---|---|---|
| `kit/Run.cmd`, `Build.cmd` | batch launcher | no .cmd files in repo | RESEARCH Pattern 9 (CRLF, `set "PSModulePath="`) |
| `.githooks/pre-commit` | sh hook | no hooks yet | RESEARCH Pattern 10 (LF) |
| `.gitleaks.toml` | config | new tool | RESEARCH Pattern 10 |
| `PSScriptAnalyzerSettings.psd1` | config | new tool | RESEARCH Pattern 6 (enable-only) |
| `.gitattributes` | config | none exists | RESEARCH structure (`*.cmd eol=crlf`, `.githooks/* eol=lf`) |
| `tests/fixtures/vendors/missing-op/*` | fixture | new concept | copy HP vendor.psd1 minus one op |
| `kit/core/Vendor.ps1` contract logic | utility | no descriptor logic exists | RESEARCH Pattern 3 |

## Metadata

**Analog search scope:** `src/` (all 7 tracked files), `.gitignore`
**Files scanned:** 8
**Pattern extraction date:** 2026-10-09
