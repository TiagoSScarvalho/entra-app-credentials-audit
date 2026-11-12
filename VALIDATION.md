# Validation record

Version: **1.0.0**, 12 November 2026.

## Tenant validation boundary

The release candidate was exercised with a delegated Graph connection in a real tenant. Selected credential and ownership results were compared with the Entra portal, and report totals were reconciled with the CSV files. No application, credential or owner relationship was changed.

Operational counts, application names, identifiers, screenshots and raw reports are not published in this repository. These comparisons do not establish workload health or prove that a credential is currently used.

The authenticated inventory predates the final nested-error correction. A second authenticated inventory was not run after that correction. The successful-collection and report logic is unchanged.

## Offline checks

57 checks passed locally on PowerShell 7.6.9 for **1.0.0**. Run `./tests/Test-Audit.ps1` without credentials or network calls to reproduce them.

The checks cover UTC expiry boundaries, future starts, invalid or missing dates, limited-information owners, incomplete collections, pagination, unexpected next links, GET-only requests, selected-app and tenant guards, HTML/CSV handling, empty CSV headers and no overwrite of previous reports.

Regression cases cover nested and aggregate HTTP 401, 429 and 503 exceptions, stopping subsequent requests, excluding raw error details, mixed aggregate statuses and non-terminal denied reads. An additional offline check using the installed Graph SDK's HTTP exception type passed both directly and inside an aggregate wrapper. No throttling or service failure was deliberately induced in the tenant.

The workflow in `.github/workflows/validate.yml` runs the offline checks on GitHub Actions. Check the repository's Actions tab for the actual hosted results.

## Limits

- The live application collection used one page. Pagination and failures were exercised with offline fixtures.
- No deliberate expiry, owner removal, throttling or permission denial was introduced in the tenant.
- Minimum dependency versions, other platforms/clouds and restricted non-admin role combinations were not all live-tested.
- No assessment of credential usage, application health, permission risk, federated credentials or service-principal-only credentials.
- An expired credential or missing owner is a review finding, not proof of compromise or an outage.
