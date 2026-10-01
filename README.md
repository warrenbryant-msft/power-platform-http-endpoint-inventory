# Power Platform HTTP Endpoint Inventory

Inventory configured HTTP destinations in Power Automate cloud flows and Power
Apps canvas apps before introducing Power Platform data policy endpoint filters.

The project is read-only. It doesn't modify, save, enable, disable, or execute
apps and flows.

> [!IMPORTANT]
> The generated reports can contain confidential internal hostnames, paths,
> resource names, and owner information. By default, the scripts refuse to write
> reports inside a Git worktree.

## Why this exists

Power Platform inventory can identify resources that use many connectors, but an
endpoint-filtering rollout needs more detail:

- Which cloud flows contain built-in or connector-based HTTP actions?
- Which canvas apps invoke HTTP with Microsoft Entra ID?
- Which static hosts and paths are configured?
- Which endpoints are dynamic or cannot be resolved automatically?
- What allow patterns would preserve known workloads?

This repository fills that analysis gap. It complements, rather than replaces,
Power Platform admin center inventory and data policy impact planning.

## Commands

| Script | Purpose |
|---|---|
| `Export-PowerPlatformHttpEndpointInventory.ps1` | Recommended entry point. Runs both workload scanners and produces a normalized combined report. |
| `Export-PowerAutomateHttpEndpoints.ps1` | Scans Power Automate cloud-flow definitions. |
| `Export-PowerAppsHttpEndpoints.ps1` | Scans Power Apps canvas-app connection references and Power Fx formulas. |

## Requirements

- PowerShell 7 or later
- Power Platform CLI (`pac`) 2.12.2 or later
- An authenticated PAC user profile
- Power Platform Administrator, Global Administrator, Dynamics 365
  Administrator, or equivalent read access to the target resources

The PAC `power-automate` and `power-apps` admin command groups are preview
features. See [Limitations](docs/LIMITATIONS.md).

## Quick start

Confirm the active PAC profile:

```powershell
pac auth list
pac auth who
```

Run the combined inventory for one or more environments:

```powershell
.\scripts\Export-PowerPlatformHttpEndpointInventory.ps1 `
  -EnvironmentName @(
    "<environment-guid-1>",
    "<environment-guid-2>"
  ) `
  -OutputDirectory "C:\ProtectedAdminData\HttpEndpointInventory" `
  -Verbose
```

The output directory contains:

```text
PowerAutomateHttpEndpoints.csv
PowerAppsHttpEndpoints.csv
PowerPlatformHttpEndpoints.csv
```

The combined report includes:

```text
EnvironmentName
ResourceType
ResourceId
ResourceName
Connector
ConnectorId
OperationId
ConfiguredEndpoint
Classification
StaticHost
SuggestedAllowPattern
ResolutionStatus
```

## Workload-specific usage

### Power Automate

Use the active PAC profile:

```powershell
.\scripts\Export-PowerAutomateHttpEndpoints.ps1 `
  -UsePacCli `
  -EnvironmentName "<environment-guid>" `
  -OutputPath "C:\ProtectedAdminData\PowerAutomateHttpEndpoints.csv"
```

Analyze previously exported flow definitions:

```powershell
.\scripts\Export-PowerAutomateHttpEndpoints.ps1 `
  -DefinitionPath ".\exported-flow-definitions.json" `
  -OutputPath "C:\ProtectedAdminData\PowerAutomateHttpEndpoints.csv"
```

The legacy `Microsoft.PowerApps.Administration.PowerShell` module is also
supported through `-UseAdminPowerShell`.

### Power Apps

Use the active PAC profile:

```powershell
.\scripts\Export-PowerAppsHttpEndpoints.ps1 `
  -UsePacCli `
  -EnvironmentName "<environment-guid>" `
  -OutputPath "C:\ProtectedAdminData\PowerAppsHttpEndpoints.csv"
```

Analyze an already extracted canvas app:

```powershell
pac canvas download `
  --environment "<environment-guid>" `
  --name "<app-id>" `
  --extract-to-directory ".\extracted-app" `
  --overwrite

.\scripts\Export-PowerAppsHttpEndpoints.ps1 `
  -SourcePath ".\extracted-app" `
  -OutputPath "C:\ProtectedAdminData\PowerAppsHttpEndpoints.csv"
```

PAC mode downloads only canvas apps whose admin metadata reports an HTTP-family
connector. Temporary source is removed after scanning.

## Endpoint classifications

| Classification | Meaning |
|---|---|
| `Static` | The complete endpoint is a literal value. |
| `StaticHostDynamicPath` | The host is known but some path content is dynamic. |
| `Dynamic` | A static host couldn't be established. |
| `RelativeStatic` | A literal relative URL was found, but its connection base URL couldn't be resolved. |
| `NotExposed` | An HTTP operation exists but no endpoint parameter was returned. |

Query strings and URL fragments are removed from reports. Dynamic Power Fx and
workflow expressions are replaced with placeholders.

## Safe report handling

Endpoint reports should be treated as internal security and architecture data.

- Write them to a protected administrative directory.
- Don't commit them to source control.
- Don't attach unredacted reports to public issues.
- Delete extracted canvas source when analysis is complete.
- Review owner and resource fields before sharing a report.

The repository `.gitignore` excludes common report, canvas-package, extracted
source, and PAC log artifacts.

To intentionally write inside a Git worktree, supply
`-AllowOutputInGitWorktree`. This should normally be used only by tests.

## Validation

Automated regression coverage includes:

- Static, relative, and dynamic cloud-flow HTTP endpoints
- Nested flow actions
- HTTP Webhook
- HTTP with Microsoft Entra ID
- Canvas-app connection-reference correlation
- Static, relative, and dynamic Power Fx connector calls
- Query-string redaction
- Header-only empty reports
- Non-HTTP false-positive prevention
- Combined flow and app report normalization

Live read-only validation was also performed in isolated demo environments:

- 35 cloud-flow definitions across five environments
- Seven Power Apps in a separate canvas-app inventory pass
- PAC canvas source download and parsing
- Positive HTTP canvas-app parsing injected into authentic PAC-extracted source

The demo resources contained no pre-existing HTTP workloads, so positive endpoint
coverage is fixture-based. No app or flow was uploaded, modified, or executed.

## Important limitations

This project inventories configured definitions, not every destination reached
at runtime. Dynamic values require owner review. It doesn't currently cover:

- Code apps or arbitrary browser `fetch` calls
- Custom connector OpenAPI `servers`, `host`, or `basePath`
- `Launch()` navigation
- Power Automate desktop HTTP/browser/UI automation
- Endpoint values obtained only from runtime data
- Actual run-history traffic

Read [docs/LIMITATIONS.md](docs/LIMITATIONS.md) before using the output to build
deny-by-default endpoint rules.

## Tests

Run all fixture cases directly:

```powershell
.\tests\cases\Test-PowerAutomateFixtures.ps1
.\tests\cases\Test-PowerAppsFixtures.ps1
.\tests\cases\Test-CombinedInventory.ps1
```

Or run through Pester:

```powershell
Invoke-Pester .\tests\EndpointInventory.Tests.ps1
```

## Support

This is an independent community project and isn't an official Microsoft
product. Use it at your own risk. For contribution guidance, see
[CONTRIBUTING.md](CONTRIBUTING.md). For vulnerability reporting, see
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
