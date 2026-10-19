# Third-party installers (PSAppDeployToolkit)

One folder per application. Each folder is a PSAppDeployToolkit (PSADT v4) package that
the first-logon run installs silently, after drivers and the online gate, before Verify.

Layout of one package:

    kit/apps/<AppName>/
        Invoke-AppDeployToolkit.ps1   PSADT entry script (Install / Uninstall)
        Files/                        vendor installer (MSI/EXE); gitignored
        app.psd1                      run-time settings, see _Example/app.example.psd1

Rules:

- Vendor binaries, download links, MSI properties and tokens never go in git. Everything
  in `kit/apps/` is ignored except this file and `_Example/`.
- Run order is alphabetical by folder name. Prefix with `10-`, `20-` to force an order.
- `RequiresInternet = $true` packages wait for the online gate and defer with a warning
  when offline.
- `Detection` tells Verify how to confirm the install (a service running, or an
  Add/Remove Programs name).
- Run one package by hand: `powershell -File kit\apps\<AppName>\Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode Silent`
