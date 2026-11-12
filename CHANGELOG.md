# Changelog

## 1.0.0 — 2026-11-12

- First public release, with HTML and four CSV reports for ordinary local app registrations.
- Recognise HTTP status metadata inside inner and aggregate exceptions, including SDK error-record wrappers.
- Stop later reads after a nested 401, 429 or server error; prefer a terminal status when an aggregate contains multiple failures.
- Keep error messages and raw server responses out of the report.
- Expand offline validation from 42 to 57 checks and clarify execution from the extracted package folder.
- Document the earlier tenant run separately from the final error-handling regression checks.

## 1.0.0-rc.1 — 2026-11-12

- Initial review candidate for ordinary local app registrations.
- Read-only application/owner collection, selected or all-app scope.
- Credential validity windows and owner evidence with explicit incomplete states.
- HTML and four CSV reports, private-field allowlist and injection protection.
- Offline checks and GitHub Actions workflow; no automatic publication.
- Final review evidence: authenticated read-only tenant run, CSV reconciliation and three sampled portal comparisons; see VALIDATION.md.
