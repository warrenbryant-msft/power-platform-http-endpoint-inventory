# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature from the repository
**Security** tab. Don't open a public issue containing:

- Access tokens, cookies, certificates, or credentials
- Tenant or environment identifiers
- Exported app or flow definitions
- Internal endpoint inventories
- Customer names or resource names

Include the affected script, a minimal sanitized reproduction, expected behavior,
and observed behavior.

## Sensitive output

Generated CSV files can reveal internal hostnames, paths, resource names, owners,
and governance gaps. Store reports in a protected location and delete them when
they are no longer needed.

The scripts remove query strings, fragments, and dynamic expression text from the
normal report. This doesn't make the remaining inventory suitable for public
sharing.

## Authentication

The PAC execution path uses the currently selected PAC profile. The scripts don't
read or export PAC's token cache. Never paste the output of `pac auth token` into
an issue, report, configuration file, or command history.

## Supported versions

Security fixes are applied to the latest version on `main`.
