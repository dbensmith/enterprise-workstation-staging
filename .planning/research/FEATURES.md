# Feature Research

**Domain:** Used business-laptop provisioning/refurbishing toolkit (vendor-neutral, PowerShell 5.1, one operator on site, two USB sticks, unreliable internet)
**Researched:** 2026-10-05
**Confidence:** MEDIUM (industry-process patterns and Atera/HP/Excel constraints verified from vendor docs and web sources; central-store comparison mixes verified facts with engineering judgement, flagged per row)

## Framing

Commercial refurb suites (Blancco, Eurosoft PC Builder, ITAD/R2 SOPs) assume a bench, a network, a PXE/imaging server and a technician with a monitor. This project is the opposite: a phone-reading operator, stock Windows targets, no module installs, and an unreliable link. So "table stakes" below = what the refurb domain universally does (asset identity, hardware health, sanitization evidence, firmware, image, QA report, audit trail), implemented in a minimal, offline-tolerant, scriptable shape. Fleet-management features (PXE, SCCM/MDT task sequences, Autopilot registration, grading UIs) are anti-features here.

The existing validated system (HPCMSL baseline, ISO servicing, installer, `Test-DeviceBaseline.ps1` audit) is not re-researched. Features below that overlap it are marked "extends existing".

## Feature Landscape

### Table Stakes (Users Expect These)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Per-serial result record (one JSON/CSV per laptop, serial as key) | Every refurb workflow keys the audit trail on serial; the tracker joins on it | LOW | Extends `Test-DeviceBaseline.ps1`. Include `schemaVersion`, serial, vendor, model, platform ID, stage results, overall verdict, tool version, ISO 8601 UTC timestamp (`...Z`). Result files accumulate on the Tools stick `results/` folder. |
| Read-only Assess mode (hardware inventory + health before purchase) | Buy/no-buy decision is the whole point of assess; refurb SOPs always do intake testing | MEDIUM | Must change nothing on the target. Capture: serial, model, CPU, RAM, disk size and SMART/wear (`Get-PhysicalDisk`/`Get-StorageReliabilityCounter`), battery design vs full-charge capacity (`powercfg /batteryreport` or WMI `BatteryStaticData`/`BatteryFullChargedCapacity`), BIOS version vs latest known, TPM present/ready, Secure Boot state, activation state. |
| Lock/ownership red-flag checks during Assess | A used business laptop with a BIOS setup password, enterprise management lock, or encrypted disk with unknown key is unusable or a brick; this is the single most expensive buy mistake | MEDIUM | HP exposes password-set state via WMI `root\HP\InstrumentedBIOS` (`HP_BIOSPassword` class; no module needed). Also flag: BitLocker/device-encryption on, domain/Azure AD joined, MDM enrolled, Absolute/Computrace persistence in BIOS. Report as RED/YELLOW, never attempt to bypass. (Confidence MEDIUM: class names need phase-level verification.) |
| Auto-detect vendor, model, platform ID | Needed to choose firmware, driver pack and profile without operator typing; already in the project requirements | LOW | `Win32_ComputerSystem`/`Win32_BaseBoard` plus HP `Win32_BIOS`/baseboard product ID. Vendor module interface selects behavior. |
| Mode selector (Assess / Deploy) with `-Mode` parameter | Operator works from a phone; the fewest taps wins. Matches expected "minimal selector" | LOW | Interactive menu falls back to parameter. Default to Assess (the safe one). |
| Enforced stage ordering with gate checks | Domain norm: firmware first so later steps do not fight a stale BIOS; flashing after imaging means re-doing work | MEDIUM | Order: assess, BIOS flash, BIOS defaults, UEFI diagnostics, image, first logon (drivers, online check, Atera, verify, upload). Persist stage state (file on stick or `C:\ProgramData\<tool>\state.json`) so a re-run resumes rather than restarts. Out-of-date firmware in Deploy = warn/stop with the Windows-flash fallback offered. |
| Firmware staging in the exact vendor flash-tool layout | Direct incident cause (2026-10-05, five units). Refurb shops treat firmware as step one | MEDIUM | HP F10 USB update expects the BIOS binary under `Hewlett-Packard\BIOS\New` (or `EFI\HP\BIOS\New`) on a FAT32 volume, with the BIOS update utility/signature under `Hewlett-Packard\BIOSUpdate` (sources: HP support forum threads; MEDIUM). Build must produce the layout, then self-check it (list files, verify paths and hashes) before the operator walks into the shop. Also stage `HPFirmwareUpdRec64.exe` as Windows fallback. |
| Staged-layout validation at build time ("pre-flight check") | Failure was silent until on-site; builders in this domain fail loudly | LOW | Post-build assertion that each required path exists per model and file hashes match the vendor manifest. Cheapest high-value feature given the incident. |
| BIOS-defaults step with verification | After a flash, stale or seller-altered settings (boot order, Secure Boot, passwords, TPM off) break imaging and diagnostics | MEDIUM | Resetting to defaults stays a manual F9/F10 step (automation is out of scope). The feature is verifying it happened: read key settings via HP WMI (no module install) at Verify and WARN if they differ from the profile's expected defaults. Note: HP's WMI interface has no bulk reset; the bulk reset is HPCMSL `Set-HPBIOSSettingDefaults`, which is unavailable on targets (no module installs). |
| UEFI diagnostics from the stick, latest version | HP PC Hardware Diagnostics UEFI is the vendor-approved hardware test; BIOS checks USB first, then drive, then built-in, so the stick version wins (HP docs, HIGH) | MEDIUM | Needs the FAT/FAT32 volume HP expects (installer creates an `HP_TOOLS` partition; exact folder tree needs phase-level confirmation, LOW). Conflict to resolve in roadmap: the Tools stick holds both the diagnostics tree and BIOS layout; both want `HP_TOOLS`-style FAT32 root (single FAT32 volume, check collision). Diagnostics are run by hand on the laptop (no result file); operator records pass/fail via a quick prompt at first logon so it still lands in the per-serial record. |
| Secure disk sanitization policy (documented) | Refurb/ITAD SOPs (NIST 800-88, R2) require sanitization evidence before resale; used business laptops hold prior-owner data | MEDIUM | Image step repartitions the boot disk, which is a "Clear" in practice; at minimum record method and result. SSD secure-erase/crypto-erase is differentiator tier. Do not claim certificate-grade erasure without a real tool. |
| Wi-Fi handled at Windows setup network screen, never stored | Already decided; table stakes for secrets hygiene | LOW | Image must contain no Wi-Fi profile or key. Verify step greps for `netsh wlan show profiles` entries created by the image. |
| Driver install tolerant of mismatched hardware | Mixed-generation images (G5/G6) are routine in refurb; one failing INF must not abort | MEDIUM | `pnputil` per-INF with exit-code tolerance (harmless codes such as 259 "no more data" and 3010 reboot-required map to WARN). Select pack by platform ID where overlap is unsafe. Extends existing `Install-HPDriverBaseline.ps1`. |
| Offline-first first-logon sequence | First boot at a shop often has no internet; the workflow cannot stall | MEDIUM | Offline steps (drivers, local `User` account setup) run unconditionally. Online steps (Atera, upload) are queued behind a "confirmed online" gate. |
| Real online check (not "network connected") | NLA "connected" is true on captive portals and dead uplinks; this is the Atera MSI trap | MEDIUM | Request to the real endpoints. Atera documents outbound TCP 443 and 8883 plus hosts including `agent-api.atera.com`, `agent-api-v2.atera.com`, `agenthb.atera.com`, `ps.atera.com`, `pubsub.atera.com`, `ps.pndsn.com` (Atera support docs, HIGH). Practical check: HTTPS GET to `agent-api.atera.com` via `Invoke-WebRequest -UseBasicParsing` with TLS 1.2 set explicitly (PS 5.1 default can be older), timeout 5-10 s, accept any HTTP response as "reachable", retry with backoff for a bounded window, then defer with WARN. |
| Gated Atera install (never start the MSI offline) | Atera needs internet to install; an offline attempt hangs on an OTP/token prompt, and silent `/qn` hangs without the right properties (Atera docs, MEDIUM-HIGH) | MEDIUM | Customer-specific installer/link/properties come from gitignored local config or the Tools stick, never the repo. After install, confirm the `AteraAgent` service exists and is running; otherwise YELLOW "pending". Include a `Verify` re-check. |
| Verify always last | Core order requirement; verification before Atera/upload gives false PASS | LOW | Extends `Test-DeviceBaseline.ps1`: add firmware-current check, defaults check, Atera/Splashtop, driver error count (`Get-PnpDevice` with problem codes), activation, account state. |
| Green/yellow/red output, harmless exit codes as warnings | Operator reads on a phone; shop noise must not look like failure | LOW | Three-state result per check (`Pass`/`Warn`/`Fail`), overall verdict = worst non-ignored state; short narrow lines (phone width ~40-50 cols). |
| ISO 8601 UTC timestamps on every result | Already decided; the only safe merge key across sites | LOW | `(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')`. Also record tool version and a monotonic run ID. |
| Upload everything newer than the store (catch-up sync) | Offline results must reach the store later from any laptop that has internet | MEDIUM | See "Results sync" below. Idempotent keyed upsert, bounded retry, never blocks Verify or imaging. |
| Source ISO selection with confirmation | Operator must not accidentally build with the wrong ISO | LOW | List `src/iso/`, show build/edition, ask Y/N; ask for path if none. |
| No secrets in repo, secret-scan check | Repo may be public; already required | LOW | gitleaks/pre-commit or CI secret scan; local config file schema committed as `.example`. |
| Pester tests for the pure logic | Existing practice | LOW | Test ordering gate, state machine, result schema, online-gate decisions, layout validator. |

### Differentiators (Competitive Advantage)

Not expected of a basic script, but they are what make this beat a checklist plus ad-hoc scripts.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Write-only upload credential on laptops, read credential only on the operator's PC | A leaked laptop/stick URL can add junk but cannot expose the fleet table. Directly satisfies "no stored credentials on targets" and "data exposed if a URL leaks" | MEDIUM | Possible with Azure Blob SAS (create/write-only, short expiry) or with Airtable tokens scoped to write only; not possible with a single Apps Script URL (see store comparison). |
| Idempotent store-and-forward: conditional create keyed by `serial + timestamp` | Catch-up sync works without reading the store: "already exists" (HTTP 409/412, or a no-op upsert) means skip. The stick is the carrier, so no per-laptop "uploaded" flag can exist; idempotency replaces it | MEDIUM | Key = `<serial>_<utcTimestamp>` (filesystem-safe). Append-only raw log plus a derived "latest per serial" view for the tracker. |
| Append-only history plus a derived latest-per-serial view | The tracker wants newest per serial with no duplicates; the audit trail wants every attempt (FAIL then PASS) | MEDIUM | Build the derived view in the store (sheet formula, Power Query group-by, or a "latest" blob/endpoint), not in the laptop script. |
| Resumable stage state machine | A phone-operated flow with reboots, BitLocker suspends and shop-internet drops needs "continue where I left off" | MEDIUM | State file with stage, attempt count, last verdict; each stage idempotent. Run history appended into the per-serial result. |
| Firmware-currency check against a pinned manifest | Operator sees "BIOS 01.xx.yy is current/out of date" without internet at the shop | MEDIUM | Build step writes `firmware-manifest.json` (model, platform ID, latest version, hash) onto the Tools stick; Assess/Verify compare. Stops the "latest" ambiguity that caused wrong-folder confusion. |
| Platform-ID pack selection with a G5+G6 shared image | One image works on either model | HIGH | Overlap analysis is a research item. Fail-soft: install everything applicable, mark non-applicable INF failures as WARN. |
| Custom latest-driver pack alongside vendor pack | Published packs are often stale | HIGH | HPCMSL `New-HPDriverPack` (build machine only). Provenance recorded (pack versions) in the per-serial result so a laptop can be traced to a build. |
| Self-update from GitHub with version pinning and hash verification | `irm <url> \| iex` is convenient but runs whatever is at the URL | MEDIUM | Serve a tiny bootstrapper from a tagged release (not `main`), verify a SHA-256 of the payload from a pinned manifest, pull only scripts (not ISO/packs). Falls back to the on-stick copy offline. |
| Background sync (optional) | Operator does not wait for upload | MEDIUM | Project says SHOULD only if simple. A detached `Start-Job`/`Start-Process` with a log file is acceptable; a scheduled task or service is overbuilding. |
| Condition scoring/grade from the data (A/B/C) | Matches refurb-industry practice, speeds buy decisions | MEDIUM | Derive from battery wear %, disk wear/SMART, RAM/CPU thresholds, lock flags; keep rules in a data file. Cosmetic/manual items only as optional operator-typed fields. |
| Per-model profiles (`.psd1`) driving expected values | Existing pattern (`profiles/hp-elitebook-840-g6.psd1`) scales to G5 and to Dell/Lenovo modules | LOW | Add expected BIOS settings, firmware minimum, pack selection data. |
| Vendor interface behind modules | Adding Dell/Lenovo is a new module, not a restructure | MEDIUM | Interface: list models, fetch vendor pack, build custom pack, fetch firmware, install drivers, install firmware. Contract tests (Pester) run against each module. |
| Dry-run / `-WhatIf` in Deploy | Test on the bench before the shop | LOW | Cheap with `SupportsShouldProcess`. |
| Blank-password `User` setup that survives first logon | Needed to avoid forced password creation | MEDIUM | `net user User *` prompts and cannot run unattended. Candidate: unattend `<LocalAccount>` with blank password plus `Set-LocalUser -PasswordNeverExpires $true` and `net user User /logonpasswordchg:no` (the pre-existing candidates). Note Windows policy `LimitBlankPasswordUse` blocks network logons (including RDP/SMB) for blank-password local accounts; console logon and Atera/Splashtop agents are unaffected. Document the trade-off in the result. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| PXE/network-boot imaging server, MDT/SCCM task sequences | "Real" refurb shops use them | Needs a server and LAN at every vendor shop; MDT is being retired; contradicts two-stick, offline-tolerant, one-operator model | USB-first ISO plus scripts (existing approach) |
| Autopilot hardware-hash registration | Looks like modern provisioning | Used-laptop buyer is not an Autopilot tenant in this flow; registration needs Intune/Graph credentials on the laptop | Out of scope; capture serial only |
| Storing Wi-Fi password in image or repo | Saves a typing step at setup | Violates secrets constraint; image would leak it | Operator types it at the setup network screen (existing decision) |
| Automated pre-Windows firmware flash and BIOS-defaults reset | Removes the manual F10/F9 steps | Explicitly wish-list/out of scope; requires UEFI shell tooling and risks bricking | Verify-only plus operator instructions; fix the staging layout instead |
| Bypassing BIOS passwords, MDM locks, or Absolute | Rescue purchased locked units | Legal and security exposure; unreliable | Detect in Assess and recommend "do not buy" |
| Uploading BitLocker recovery keys, Wi-Fi keys, or local passwords to the central store | "Convenient escrow" | Highly sensitive data in a lightly protected store | Keep results to health/inventory data only; schema allow-list, no free-form env dump |
| Upload from a long-running agent or scheduled task | Guarantees eventual sync | Overbuild; target is a stock laptop being handed off | Sync at each run, with idempotent catch-up from the stick |
| Bidirectional sync (tracker edits flow back to laptops) | Single pane of glass | Conflicts, auth, scope creep | Store is write-from-laptop, read-from-tracker only |
| Per-laptop stored upload secret baked into the image | Easy upload | Secret in every image; leaks with any laptop | Run-time credential from the Tools stick or local config (gitignored), write-only where the store allows |
| Building the Excel tracker workbook | Natural extension | Operator owns it (Out of Scope) | Provide a clean pull endpoint and column schema doc |
| GUI app / WinForms front end | Looks friendlier | Phone-first operator, PS 5.1 stock targets; UI adds fragility | Color text menu plus parameters |
| Cosmetic/grade capture UI | Refurb-industry staple | Not what the operator needs at purchase | Optional free-text notes in the record |
| Auto-update from `main` without pinning | Always-latest scripts | Supply-chain risk; a bad commit breaks every shop run | Tagged release plus hash check |
| Dell/Lenovo modules in milestone 1 | Vendor-neutrality | Out of scope per PROJECT.md | Ship the interface and one HP module first |

## Results Sync and Central Store Comparison

### What "expected behavior" looks like

- **Per-serial record plus append-only history.** One file per run: `<serial>_<utc>.json` on the Tools stick. A derived "latest per serial" view serves the tracker. (Pattern, MEDIUM; matches ITAD audit-trail practice of retaining every test event.)
- **Catch-up semantic.** Every script run with internet enumerates all result files on the stick, for any laptop, and uploads those the store lacks. Because the stick travels between laptops, "uploaded" state cannot be stored on any single laptop; the dedupe must be server-side (conditional create or upsert) or by asking the store which keys exist.
- **Non-blocking.** Sync failures produce YELLOW, never FAIL, and never block imaging or verification. Bounded retries with backoff; short timeout. TLS 1.2 forced (`[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`) for PS 5.1.
- **Excel pulls newest per serial.** Excel desktop and Excel for the web can run Power Query refresh; Excel for iPhone/iPad/Android has no Power Query and cannot refresh queries (Microsoft docs and community, MEDIUM-HIGH). Therefore "pullable from mobile Excel" realistically means: the workbook is refreshed on desktop/web, and the phone shows cached data; or the operator reads results natively in the store's own app. This is a product-level fact the roadmap should surface.

### Store options compared

Ratings: Credentials on laptop = what a stolen/leaked laptop or stick exposes. Confidence column: how well I verified the row.

| Option | Auth on laptop | PS 5.1 | Cost | Excel pull (desktop/web; mobile) | Newest per serial / dedupe | Exposure if URL/token leaks | Confidence |
|--------|----------------|--------|------|----------------------------------|----------------------------|------------------------------|-----------|
| **Google Apps Script web app writing to a Google Sheet** (`doPost` appends/upserts under `LockService`; `doGet` returns latest-per-serial CSV/JSON) | One capability URL (anonymous "Anyone" deployment); can add a shared-secret field checked in script | Simple `Invoke-RestMethod -Method Post` with JSON; follows the 302 redirect | Free (consumer limits: 6 min per execution, ~30 concurrent web app executions, daily quotas) | Power Query "From Web" on the `doGet` URL works on desktop/web; mobile Excel cannot refresh, but the Sheet is viewable in the Sheets app | Upsert/dedupe done in script; `LockService` handles concurrent runs; `doGet` can return the key list for catch-up | Leaked URL allows junk writes and (if the same URL serves `doGet`) reads of everything; mitigate with a separate secret param and rotating the deployment | MEDIUM |
| **Google Form POST (`formResponse`) to linked Sheet** | None (form URL is public) | `Invoke-WebRequest` with form-encoded body; fragile field IDs | Free | Sheet published as CSV for Power Query, which makes the whole sheet readable by anyone with the link | Append-only; dedupe via sheet formula/Power Query; no read-back, so no catch-up check without extra published CSV | Anyone with the form URL can spam; CSV publish link exposes all data | MEDIUM |
| **Azure Blob Storage with write-only SAS** (blob per `serial_timestamp`, `If-None-Match: *`) | Short-expiry SAS with Create/Write only on laptops; read/list SAS only on operator PC | `Invoke-RestMethod -Method Put` with `x-ms-blob-type: BlockBlob`; works on 5.1 | Cents per month | Power Query Azure Blob connector combines JSON files (desktop; web support to verify); no mobile refresh | Idempotent by key (409/412 = exists, skip); latest-per-serial computed in Power Query or by a "latest" index blob | Leaked write SAS permits spam/overwrite of nothing existing; cannot read; best leak profile | MEDIUM (design based on Azure semantics; confirm during phase) |
| **Power Automate flow with "When an HTTP request is received"** writing to Excel/SharePoint/List | SAS in URL (or Entra OAuth, which needs app credentials) | Plain POST works; URL contains signature | The HTTP trigger is a premium capability needing paid licensing in most tenants (verify for the target tenant) | Excel on OneDrive/SharePoint is native for the tracker; mobile Excel opens it (cached/live data, no query refresh needed if the flow writes straight into the workbook table) | Flow can do "get row / update or add"; throughput and run limits apply | "Anyone with the URL can run the flow" (Microsoft guidance); regenerate key to revoke | MEDIUM-HIGH for the leak model, MEDIUM for licensing |
| **Microsoft Graph to OneDrive/SharePoint Excel** | App registration with client secret or interactive/device-code login on laptop | Doable but needs token handling in PS 5.1 | M365 license already present | Native Excel, best tracker experience | Table row ops; messy concurrency | Secret on laptop; tenant data at risk | HIGH that it violates "no credentials on laptops" |
| **Microsoft Forms / Lists** | Forms: no supported public API; Lists: Graph auth | Forms not scriptable cleanly | M365 | Forms-to-Excel is native | Append only | Forms link public | MEDIUM (not recommended) |
| **Airtable** (`performUpsert` on `serial`+key fields) | Personal access token (scope: write only, single base) | `Invoke-RestMethod` bearer; works | Free tier has small record cap; paid for more | Power Query with Authorization header on desktop; Airtable app on mobile | Native upsert, good | Leaked token can write (and read if scope allows) a base; scope-down helps | MEDIUM |
| **Private GitHub repo / cloud bucket** | PAT with repo contents write, or bucket keys | Contents API with token works | Free | Raw API with token in Power Query is awkward | Commit conflicts under concurrent runs; history is large | A repo PAT is high blast radius; also "files committed to a private repo" risks mixing results with source | MEDIUM (not recommended) |

### Recommended direction (feature level)

Primary candidates: **Apps Script web app on a Google Sheet** (fastest to ship, free, simplest PS call, Excel can pull via web query) and **Azure Blob with a write-only SAS** (best leak model, naturally idempotent). Decision for the roadmap: pick by whether the operator values zero-setup (Apps Script) or leak-resistance (Blob). Either way, put the split in place: laptops get a write-only or capability URL supplied at run time (Tools stick, gitignored config), and only the operator's PC holds any read credential. Avoid Graph/OneDrive-direct and repo-as-database. Final comparison needs a dedicated research task (STACK/ARCHITECTURE) with live verification of quotas, PS 5.1 redirect behavior, and the Excel-for-web Power Query connector coverage.

## Feature Dependencies

```
Auto-detect vendor/model/platform
    └──requires──> Vendor module interface
                       └──requires──> Per-model profile (.psd1)

Per-serial result record (ISO 8601 UTC)
    └──requires──> Verify (always last)
    └──required by──> Results sync
                          └──requires──> Real online check
                          └──requires──> Central store (write endpoint)
                                             └──enhanced by──> Latest-per-serial view (Excel pull)

Stage-order gate (assess > firmware > defaults > diagnostics > image > first-logon)
    └──requires──> Resumable stage state
    └──requires──> Firmware staging in exact layout
                       └──requires──> Staged-layout validation (build-time)
                       └──enhanced by──> Firmware manifest (currency check)

First-logon offline steps (drivers, User account)
    └──precedes──> Online gate
                       └──requires──> Real online check (Atera endpoints)
                                          └──gates──> Atera install
                                          └──gates──> Results upload
                       (Verify runs after Atera, before upload)

Platform-ID pack selection ──enhances──> Driver install tolerance (G5+G6 image)

Self-update (irm|iex) ──conflicts──> Offline-only runs  (needs on-stick fallback)
Background sync ──conflicts──> Simplicity ("don't overbuild")
BIOS-defaults automation ──conflicts──> Out of scope (verify only)
```

### Dependency Notes

- **Per-serial record requires Verify:** the record is only trustworthy once Verify has run last; upload sends exactly that file.
- **Results sync requires the online gate:** reuse the same endpoint-reachability helper for Atera and the store (different hosts, same code).
- **Idempotent upsert requires a stable key:** the key must be `serial + UTC timestamp` (or run ID) generated before any upload so retries and re-runs on other laptops cannot create duplicates.
- **Firmware layout validation precedes everything on site:** it is the incident's direct countermeasure and costs almost nothing.
- **Diagnostics vs flash on one stick:** both rely on HP's FAT32/`HP_TOOLS` conventions; confirm they can coexist on the Tools stick before committing to the two-stick split.

## MVP Recommendation

Prioritize (milestone 1):
1. Modular repo skeleton with vendor interface plus HP module; per-model profile; build output separation.
2. Firmware staging in exact vendor layout with build-time layout validation and Windows-tool fallback (fixes the live incident).
3. Assess mode (read-only) with health plus lock/ownership red flags, writing a per-serial result file (ISO 8601 UTC).
4. Stage-order enforcement with resumable state; Deploy with firmware gate and BIOS-defaults verification.
5. First-logon chain: offline steps, real online check, gated Atera, Verify last, then upload.
6. Central store with idempotent upload (one store chosen after research), plus secret-scan and no-secrets config pattern.

One differentiator to include early: **idempotent conditional-create sync with a write-only credential** because it solves offline catch-up, dedupe, and leak exposure in one design choice.

Defer: custom latest-driver packs (HIGH complexity), G5+G6 combined image beyond a safe subset, condition scoring, background sync, self-update hash pinning (ship a simple tagged-release bootstrapper first), Dell/Lenovo modules.

## Sources

- Reconext, "Eliminating Variability in Laptop Refurbishment with End-to-End Automation": https://www.reconext.com/eliminating-variability-laptop-refurbishment-automation/ (MEDIUM, industry process)
- Eurosoft PC Builder Refurbishment: https://www.eurosoft-uk.com/products/pc-builder/pc-builder-refurbishment/ (MEDIUM; diagnostics, erase, BIOS flash, imaging, COA reporting in one framework)
- R2/ITAD Refurbishment and Grading SOP: https://www.decideagree.com/refurbishment-grading-standards-sop-testing-data-wipe-release/ (MEDIUM; sanitization evidence, grading)
- HP, Testing for hardware failures (UEFI diagnostics from USB): https://support.hp.com/us-en/document/ish_2854458-2733239-16 (HIGH for USB-first search order)
- HP Support Community threads on BIOS USB layout and HP_TOOLS (`Hewlett-Packard\BIOS\New`, `BIOSUpdate`): https://h30434.www3.hp.com/t5/Notebooks-Archive-Read-Only/How-to-use-the-HP-BIOS-update-uefi-utility/td-p/337347 (MEDIUM; forum, confirm against HP doc in phase research)
- HP Client Management Script Library, `Set-HPBIOSSettingDefaults` and BIOS WMI limitations: https://developers.hp.com/hp-client-management/doc/set-hpbiossettingdefaults (HIGH)
- Atera, Install an Atera Agent via the Command Prompt / Install Atera's Windows Agent / Agent FAQ: https://support.atera.com/hc/en-us/articles/115015902648-Install-an-Atera-Agent-via-the-Command-Prompt (MEDIUM-HIGH; search summary only, page returned HTTP 403 to direct fetch)
- Atera, Firewall settings (ports 443/8883 and host list): https://support.atera.com/hc/en-us/articles/360015461139-Firewall-settings-for-Atera-s-integrations (HIGH via search summary)
- Microsoft, Regenerate SAS key for HTTP trigger flows / Power Automate HTTP trigger security: https://learn.microsoft.com/en-us/power-automate/regenerate-sas-key (HIGH)
- Google Apps Script quotas: https://developers.google.com/apps-script/guides/services/quotas (HIGH)
- Apps Script `doPost` to Sheet patterns: https://gist.github.com/mhawksey/1276293/eb4db55a7559d9ac4a2600acb60b0af5f9a347fc (MEDIUM)
- Microsoft, Power Query in Excel for the web and mobile limitations: https://support.microsoft.com/en-us/office/use-power-query-in-excel-for-the-web-02652946-de70-48d8-8a34-3db96998ff5a ; https://support.microsoft.com/en-us/office/power-query-data-sources-in-excel-versions-e9332067-8e49-46fc-97ff-f2e1bfa0cb16 (MEDIUM-HIGH)

Open items needing phase-level verification: exact HP UEFI diagnostics USB folder tree; HP WMI class names for password/ownership flags; Power Automate HTTP trigger licensing for the target tenant; Azure Blob conditional-create behavior from PS 5.1; Excel-for-web Power Query connector coverage for Blob/Web with anonymous or SAS auth.
