# ROU SPA maintenance instructions

The user requires every important rule or interaction change to be reflected in
`ROU_SPA_OPERATING_MANUAL.md`, because 問管家 reads that manual.

- Read the relevant manual sections before changing booking, schedules,
  attendance, roles, membership, reviews, POS, payments, inventory, payroll,
  reports, reminders, resets, synchronization, request deadlines or AI behavior.
- Update the affected manual sections in the same change as the implementation.
  Describe who can act, the actual conditions and units, the effect on related
  modules, failure/retry behavior and the source files. Remove superseded rules
  rather than leaving contradictory instructions. Keep the manual in Traditional
  Chinese and update its review date when appropriate.
- Distinguish fixed rules, configurable initial defaults, current database
  settings and saved historical snapshots. Never invent live business values or
  claim an unapplied migration is already active.
- For purely visual changes with no operation or rule changes, review the
  manual for impact; do not add irrelevant implementation history.
- After reviewing/updating the manual, run
  `node scripts/check-operating-manual.mjs --record` if its contents or tracked
  sources changed. Run the manual check and appropriate tests/build. Updating
  fingerprints alone is not a substitute for documenting an important change.
- 問管家 reads the manual bundled with the deployed server on every question,
  not a live download from GitHub. Include and deploy the manual with authorized
  website releases. A GitHub-only edit does not update production AI context.
- Keep credentials, private customer records, precise location records and real
  individual payroll values out of the manual and maintenance reports.

The source fingerprint check is in `scripts/check-operating-manual.mjs` and its
review record is `docs/manual-sources.json`.
