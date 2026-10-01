# Limitations and interpretation

## Configured definitions aren't runtime telemetry

The scanners inspect app and flow definitions. They don't prove that an endpoint
was recently reached, successfully reached, or reached with a particular user.
Combine this inventory with owner review and, where appropriate, run-history or
downstream API telemetry.

## Dynamic endpoint values

Power Platform endpoint filtering has documented limitations for environment
variables, custom inputs, and dynamically constructed runtime endpoints. This
project labels dynamic and unresolved values instead of treating them as safe.

A suggested host allow pattern means only that a static host could be derived
from the definition. It isn't a security recommendation by itself.

## Canvas apps

The Power Apps scanner covers canvas apps that use HTTP-family connectors and
whose source can be downloaded through PAC.

It doesn't cover:

- Code apps
- Arbitrary browser network calls
- Model-driven app behavior except connector use inside an embedded canvas app
- Apps the administrator can't download
- Connector values hidden from both app source and admin metadata

PAC currently requires SourceCode-format canvas apps to be opened and validated
in Power Apps Studio before they can be repacked. Repacking isn't required for
read-only scanning.

## Custom connectors

Custom connectors are not yet resolved. A complete custom-connector analysis
must retrieve each OpenAPI definition and evaluate:

- OpenAPI 3 `servers`
- Swagger 2 `host`
- `basePath`
- Operation paths
- Environment-specific connection parameters

Custom connector host governance is also a separate Power Platform data policy
surface.

## Cloud flows

The flow scanner covers built-in HTTP, HTTP Webhook, and known connector-based
HTTP operations found in cloud-flow definitions.

It doesn't cover:

- Desktop flows
- Runtime-generated destinations that leave no static host in the definition
- Traffic performed by custom code outside the captured connector/action shapes

## Preview administrative surfaces

The PAC `power-automate` and `power-apps` command groups are preview. Response
shapes and availability can change. Acquisition errors are written to a separate
error CSV and fail the run unless `-AllowPartialResults` is explicitly supplied.

## Data policy rollout

Endpoint filtering rules are ordered and can affect apps and flows at design time
and runtime. Don't move directly from this report to a tenant-wide deny rule.

Use a staged rollout:

1. Review static and dynamic classifications.
2. Confirm unresolved resources with their owners.
3. Pilot in a nonproduction environment.
4. Validate design-time save and runtime execution.
5. Roll out by environment with a support and rollback plan.
