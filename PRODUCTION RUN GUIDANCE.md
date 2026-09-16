# Production Run Guidance

Do not run the original `CbP_Analysis_Script.sql` on a busy production primary.
It executes application procedures and performs several unbounded diagnostic
scans. Use `CbP_Analysis_Script SAFE v2.sql` instead.

## Recommended execution

1. Prefer a readable Availability Group secondary.
2. Otherwise run during the lowest-activity maintenance window.
3. Run one script at a time and monitor CPU, runnable tasks, and AG health.
4. Stop the session if production latency or the AG health threshold degrades.
5. Use `Approval Metrics+ v4.3 SAFE.sql`; it scans the file inventory once and
   forces serial aggregation instead of scanning it once per metric.

## Unapproved file chunks

`UnapprovedFileAnalysis+ v6.1.sql` now defaults to the previous one-hour window.
Set `startDate` and `endDate` to explicit, non-overlapping UTC/server-time ranges
using inclusive start and exclusive end boundaries:

```sql
'2026-09-13T00:00:00', -- StartDate: included
'2026-09-13T01:00:00', -- EndDate: excluded
300000                 -- Maximum candidates in this chunk
```

If the window contains more than 300,000 candidate events, the script raises
error 50003 before the wide enrichment query and returns no partial export.
Split that window further rather than increasing the limit.

Export each successful result to a uniquely named CSV containing
`UnapprovedFileAnalysis`, for example:

```text
UnapprovedFileAnalysis_20260913_0000_0100.csv
UnapprovedFileAnalysis_20260913_0100_0200.csv
```

The health-check app loads and concatenates all matching Unapproved File
Analysis CSV chunks. Keep only chunks for the intended analysis period in the
input folder to avoid duplicate or stale data.

## Why not raise the row limit?

The previous `TOP (300000)` was applied after broad joins, sorting, and custom
rule pattern matching, so it neither bounded the expensive work nor indicated
that the export was incomplete. Raising it increases CPU, memory-grant, tempdb,
network, and SSMS export pressure. Time-bounded chunks constrain each query and
still allow the report to analyze the complete period.