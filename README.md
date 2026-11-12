# Entra App Credentials Audit

A read-only PowerShell audit of **locally registered applications**, their stored client-secret/key credential metadata and their owners. Produces a self-contained HTML report and four UTF-8 CSV files.

**Version:** `1.0.0`. Author: [Tiago Carvalho](https://www.tiagoscarvalho.com). MIT licensed. The author header is attribution, **not an Authenticode signature**. This package does not install modules, sign in, grant consent, rotate credentials, assign owners or delete objects.

[Download v1.0.0](https://github.com/TiagoSScarvalho/entra-app-credentials-audit/releases/download/v1.0.0/entra-app-credentials-audit-v1.0.0.zip) · [Release notes and ZIP checksum](https://github.com/TiagoSScarvalho/entra-app-credentials-audit/releases/tag/v1.0.0) · [Report a reproducible issue](https://github.com/TiagoSScarvalho/entra-app-credentials-audit/issues)

Use the named release ZIP and extract it before running the tool. Keep the launcher and companion module in the same folder. GitHub hosts the source, downloads and offline validation workflow; the collector never sends reports to GitHub or downloads code while running.

## What you get

| File | Purpose |
|---|---|
| `report.html` | Triage, evidence and query coverage; works locally without a web service |
| `applications.csv` | One row per returned app, ownership state and credential findings |
| `credentials.csv` | One row per stored password/key credential; identifiers and validity dates only |
| `owners.csv` | Returned owner IDs/types, names when available and collection completeness |
| `coverage.csv` | Each collection read, returned count, paging, completeness and safe error category |

The output includes identifiers and internal application/owner names. Keep it private. No secret value, secret hint, certificate bytes, token, private key or raw server error is exported. Graph can return public certificate metadata while selecting `keyCredentials`; the exporter discards the certificate bytes.

## Requirements and permissions

- PowerShell 7.4 or newer; Microsoft.Graph.Authentication 2.37.0 or newer.
- Microsoft Graph **Global cloud**, delegated work/school account. This first version does not support app-only authentication or sovereign-cloud endpoints.
- `Application.Read.All` is the documented minimum delegated permission for both application and owner reads. Admin consent must already be in place, or be reviewed by an authorised administrator before connecting.
- The signed-in user must also be allowed to read the applications. The Microsoft endpoint documentation lists supported roles and default user permissions; do not assign Global Administrator just to run an inventory. Existing broader scopes are accepted but are not recommended or requested by this script.
- Application owners can be users or service principals. With minimum permissions, an owner may have only an ID and type. This still counts as an owner; a missing name is not an ownerless app.

Install the official module yourself if it is absent:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -MinimumVersion 2.37.0
```

Review the source and your organisation's execution policy. Do not disable execution policy or security software to run it. If policy requires signed scripts, use an approved signing/review process; this release is unsigned. Check `SHA256SUMS.txt` against the downloaded files with `Get-FileHash`; hashes detect changed files but do not prove publisher identity when the manifest is delivered through the same channel.

## Start with one app

In Entra, open **Entra ID → App registrations → All applications → your application → Overview**. Copy its **Object ID**, not its Application (client) ID and not the Object ID under Enterprise applications.

Open PowerShell 7 in the extracted package folder. Replace both placeholders:

```powershell
Import-Module Microsoft.Graph.Authentication
$tenantId = '<your-tenant-guid>'
$appObjectId = '<app-registration-object-guid>'
Connect-MgGraph -TenantId $tenantId -Scopes 'Application.Read.All' -ContextScope Process -NoWelcome
Get-MgContext | Select-Object TenantId, Account, AuthType, Environment

./Get-EntraAppCredentialAudit.ps1 -ExpectedTenantId $tenantId `
    -ApplicationObjectId $appObjectId -OutputPath ./PilotAudit
```

Use a **new output folder** on every run. Existing folders are refused, protecting earlier evidence. Connect and run in the same PowerShell process. The tool checks the tenant, delegated authentication, Global environment and an accepted read scope before querying. A wrong application ID yields incomplete coverage rather than an empty successful pilot.

If WAM reports that a window handle must be configured, run the connection in a normal interactive PowerShell 7 window. Do not work around Conditional Access or grant extra permissions to solve a window problem.

## Audit all app registrations

After comparing the pilot with Entra:

```powershell
./Get-EntraAppCredentialAudit.ps1 -ExpectedTenantId $tenantId `
    -AllApplications -OutputPath ./AllAppsAudit

Disconnect-MgGraph
```

Only `GET /v1.0/applications` and `GET /v1.0/applications/{id}/owners` are used. Application metadata and owners are paged. A selected app uses an ID filter on the applications collection. No credentials or owner relationships are changed. The script does not disconnect a connection you supplied.

## Interpret the report

Read **Coverage** first. `COMPLETE` means the stated reads finished; it is not an assurance that the tenant is secure. `PARTIAL` preserves collected rows and flags missing evidence. Zero returned rows is not a clean bill of health. Inventory is collected over multiple requests and is not an atomic snapshot.

Credential expiry windows are disjoint: `Expired` (end ≤ run timestamp), `Within7Days`, `Within30Days` (more than 7), `Within60Days` (more than 30), `Beyond60Days`, or `Unknown`. The two dashboard counts separate expired from future credentials due within 60 days. Exact UTC timestamps determine the bucket. CSV `DaysRemaining` is rounded up for display. `Validity` independently records future start dates, invalid date ranges and missing dates.

An expired credential is not proof of an outage. Another valid credential may exist, and the expired credential may be unused. No stored password/key credentials may be legitimate for a public client, federation or another design. A certificate/key credential is not proof that it is currently used. `OtherKeyCredential` avoids calling every key an X.509 certificate.

`NoOwner` requires a successful, complete query returning zero owners. `SingleOwner` is a continuity review: Microsoft recommends at least two owners. `Unknown` means the collection could not be completed. Partial owner rows are retained but do not produce a definitive owner count. Names do not establish that the person is active, available or responsible for the workload.

CSV text that could be interpreted as a spreadsheet formula is prefixed with an apostrophe. HTML text is encoded. Empty CSV files retain their headers. Raw Graph error messages are omitted; `coverage.csv` records an HTTP status where available and a controlled category.

## What this version does not audit

- Enterprise application/service-principal-only credentials and SAML signing certificates.
- Managed identities, deleted registrations or credentials owned by another tenant.
- Federated identity credentials, permissions/consent, credential usage, sign-in activity or application health.
- Agent identity blueprints or other explicit derived application types. These can be returned by `/applications`; they are listed as `ExcludedObjectType` and excluded from credential/owner findings.
- Owner account status or the adequacy of role assignments.

Do not infer complete workload identity coverage from this app-registration inventory.

## Verify a finding and plan the follow-up

1. Match the report's Object ID and client ID with **App registrations → application → Overview**.
2. Open **Certificates & secrets**. Select **Client secrets** or **Certificates** and compare the credential ID and expiry. The report uses UTC; the portal may display local dates. Do not reveal or copy a secret value.
3. Open **Owners** under the same app registration. Do not use the enterprise application's Owners page for this comparison.
4. Confirm the workload and accountable people outside this report. Plan renewal with overlap and an actual workload test; do not remove an old credential merely because it appears expired here.
5. Review managed identity or workload identity federation where supported; if a stored credential is required, evaluate a certificate rather than defaulting to a client secret.
6. Rerun into a new folder after an approved change and compare by Object ID and Key ID. This package performs no remediation.

## Errors and scale

| Observation | Next action |
|---|---|
| `AccessDenied` / HTTP 403 | Review consent, signed-in user's access and selected scope; never interpret as no owners |
| `AuthenticationRequired` / HTTP 401 | Reconnect in an interactive session, then run into a new folder |
| `Throttled` / HTTP 429 | Let Graph's retry guidance govern the next run; don't loop the script immediately |
| `ServiceUnavailable` | Retain partial results, wait for service recovery and rerun |
| `SelectedApplicationNotReturned` | Check the local app-registration Object ID and whether the app still exists |
| `QueryFailed` | A safe generic error when the SDK exposes no HTTP status; use a controlled admin investigation, not raw error uploads |

The Graph SDK handles its own HTTP retries. If it still surfaces a 429, 401 or server error, remaining network requests are stopped and marked unattempted. The tool does not add an unbounded retry loop. An owner failure can coexist with successful credential metadata. Microsoft documents a tenant throttle of 150 requests/minute when selecting application `keyCredentials`; large tenants should pilot first. This release reads owners sequentially.

## Offline validation

```powershell
./tests/Test-Audit.ps1
```

These tests use synthetic data and mocked Graph calls, without authentication or network access. They exercise UTC boundaries, limited and failed owner reads, paging, throttling, HTML/CSV injection handling and the no-overwrite/tenant guards. Offline results do not replace a real tenant comparison.

## Microsoft references

- [List applications](https://learn.microsoft.com/en-us/graph/api/application-list?view=graph-rest-1.0)
- [List owners](https://learn.microsoft.com/en-us/graph/api/application-list-owners?view=graph-rest-1.0)
- [Application resource and owners](https://learn.microsoft.com/en-us/graph/api/resources/application?view=graph-rest-1.0)
- [Password credential metadata](https://learn.microsoft.com/en-us/graph/api/resources/passwordcredential?view=graph-rest-1.0)
- [Key credential metadata](https://learn.microsoft.com/en-us/graph/api/resources/keycredential?view=graph-rest-1.0)
- [Graph throttling guidance](https://learn.microsoft.com/en-us/graph/throttling)
- [Security operations for applications](https://learn.microsoft.com/en-us/entra/architecture/security-operations-applications)
- [Graph PowerShell authentication](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands)
- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Application objects and service principals](https://learn.microsoft.com/en-us/entra/identity-platform/app-objects-and-service-principals)

## Recorded validation

The release candidate was exercised against a real tenant and selected results were compared with the Entra portal. Operational counts, identifiers, screenshots and raw reports are withheld from this public repository. The private evidence records the environment and comparison results.

Version `1.0.0` fixes recognition of HTTP statuses inside nested and aggregate exceptions. Its 57 offline checks passed, including nested 401/429/503 failures and stopping later requests. Direct and wrapped HTTP 429 exceptions from the installed Graph SDK were also checked offline. The live inventory was not rerun after this error-handling change. The live environment used an existing administrative account and consent; restricted non-admin access, the declared minimum dependency versions, multi-page responses and service failures were not separately exercised live. See [VALIDATION.md](VALIDATION.md) for the evidence boundaries. Raw tenant reports are not included.

Documentation checked 12 November 2026. The accompanying article is being prepared for final editorial review.
