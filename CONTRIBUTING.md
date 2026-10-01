# Contributing

Contributions are welcome for reproducible connector formats, parser fixes,
additional fixture coverage, documentation, and supported administrative APIs.

## Before opening a pull request

1. Don't include real tenant exports, endpoint inventories, app packages, or
   customer data.
2. Use fictional domains such as `contoso.com` in fixtures.
3. Run:

   ```powershell
   Invoke-Pester .\tests\EndpointInventory.Tests.ps1
   ```

4. Confirm no generated CSV, `.msapp`, extracted canvas source, PAC log, or token
   material is staged.
5. Explain which connector and source shape the change covers.

## Design expectations

- Keep live operations read-only.
- Fail explicitly on incomplete acquisition.
- Redact query strings, fragments, credentials, and dynamic expression content.
- Prefer supported PAC or documented admin APIs.
- Add a positive fixture and a negative false-positive case for parser changes.
- Preserve header-only output for valid zero-result scans.

## Issues

Public issues must contain only sanitized examples. Follow
[SECURITY.md](SECURITY.md) for vulnerabilities or sensitive reports.
