# SQL Script and Export Guide

This folder contains the SQL scripts and collection tool for the CB App Control Health Check report. For each run, keep all exports together in one folder and do not mix servers or reporting periods.

## Recommended workflow

### 1. Export the console data

Two required inputs come from the App Control console, not SQL. Export them before collection or provide their paths when running the PowerShell script:

- **Computers:** Open the **Computers** page, add all columns to the view, and export the list as CSV or TXT. The filename must contain `computers`, for example `Computers_20260915.csv`.
- **Custom Rules:** Open the **Custom Rules** page, add all columns to the view, and export the list as CSV or TXT. The filename must contain `custom`, for example `CustomRules_20260915.csv`.

### 2. Run the collection script

`Collect-HealthCheckData.ps1` runs each SQL script in sequence and writes the results in the formats and filenames expected by the report tool. It also copies the two console exports into the output folder and can zip the completed collection.

Run it from this folder on a Windows machine with SQL Server connectivity and Windows PowerShell 5.1 or later. No extra modules are required:

```powershell
powershell -ExecutionPolicy Bypass -File .\Collect-HealthCheckData.ps1 `
  -Server SQLHOST01 -ReadOnlyIntent `
  -ComputersExport C:\Exports\Computers_20260915.csv `
  -CustomRulesExport C:\Exports\CustomRules_20260915.csv -Zip
```

For an Availability Group listener, `-ReadOnlyIntent` requests routing to a readable secondary. Omit it if the server does not support read-only routing. If the console export paths are omitted, the script prompts for them; press Enter to skip one. Skipped exports must be added to the output folder before running the report.

The script runs only one SQL script at a time and uses `CbP_Analysis_Script SAFE v2.sql`. Prefer a readable secondary for production collection. If one is unavailable, use a low-activity window and monitor SQL Server CPU, runnable tasks, and Availability Group health. Do not run the original `CbP_Analysis_Script.sql` on a busy production primary.

### 3. Review the collection output

By default, the script creates `HealthCheckExport_<timestamp>` in the current directory. Use `-OutputFolder` to choose another location. Check the completion messages and warnings: if an SQL script fails, collection continues, but the report tool skips the missing input and that report section will be empty. Add any missing console exports before using the folder. If the script already zipped the folder, update the ZIP after adding files.

The `-Zip` option creates `<output folder>.zip`. Windows PowerShell's `Compress-Archive` cannot handle archives over 2 GB; in that case, the script leaves the folder unzipped and tells you to compress it manually.

## Collection parameters

Run with `-Help` to print the usage message. The main options are:

- `-Server` (required): SQL Server instance, such as `SQLHOST01`, `SQLHOST01\INSTANCE`, or an Availability Group listener.
- `-Database`: initial database (default: `das`; the scripts also switch to `das`).
- `-OutputFolder`: output location (default: `HealthCheckExport_<timestamp>` in the current directory). Created if missing.
- `-SqlCredential (Get-Credential)`: SQL login instead of Windows integrated authentication.
- `-ReadOnlyIntent`: request routing to a readable Availability Group secondary.
- `-UnapprovedStart` and `-UnapprovedEnd`: inclusive start and exclusive end of the Unapproved File Analysis period (default: the last 7 days). Windows exceeding the row cap are automatically split into smaller, non-overlapping chunks.
- `-ComputersExport` and `-CustomRulesExport`: paths to the console CSV/TXT exports to copy into the output folder.
- `-Zip`: zip the output folder when collection finishes, subject to the 2 GB limit described above.
- `-CommandTimeoutSec`: per-batch timeout in seconds (default: `3600`; `0` means unlimited).
- `-NonInteractive`: never prompt, for example in scheduled runs. Missing console exports are reported as warnings.
- `-Help`: show usage and exit.

## Manual SSMS collection (fallback)

Use the procedures below only when collecting with the PowerShell script is not suitable. The same production cautions apply: use a readable secondary when possible; otherwise run during a low-activity window, execute one script at a time, and monitor the server. Keep all exports for a run together in one input folder.

### Single-result scripts: CSV

Before exporting, configure SSMS to include column headers:

1. Open **Tools > Options > Query Results > SQL Server > Results to Grid**.
2. Enable **Include column headers when copying or saving the results**.
3. Select **OK**, then open a new query window before running the script. If SSMS does not apply the change, restart SSMS.

Use this procedure for scripts that return one result grid:

| Script | Export format | Filename must contain | Notes |
|---|---|---|---|
| `Approval Metrics+ v4.3.sql` | CSV | `approval metric` | Use the SAFE version when one is provided. |
| `RuleAnalysis.sql` | CSV | `rule analysis` or `ruleanalysis` | One CSV export. |
| `ApprovalEventsForRulename.sql` | CSV | `approval events` or `approvalevents` | One CSV export. |
| `BlockAnalysis v6.3 aggregated.sql` | CSV | `block analysis` or `blockanalysis` | Recommended. Includes all enforcement events and aggregates duplicates into `EventCount`. |
| `UnapprovedFileAnalysis+ v6.1.sql` | CSV | `unapproved file` or `unapprovedfileanalysis` | Multiple non-overlapping time chunks are supported. |
| `DatabaseErrorAnalysis.sql` | CSV | `database error` or `databaseerroranalysis` | One CSV export. |

For each script:

1. Open the SQL script in SSMS and connect to the correct App Control SQL Server.
2. Confirm the database and reporting period, then run the script.
3. In the Results pane, right-click the result grid and select **Save Results As...**.
4. Save as **CSV UTF-8 (`*.csv`)** when available. Include the required filename keyword from the table above and save it in the health-check input folder.
5. Open the CSV in a text editor and confirm the first row contains column names such as `Computer ID`, `Event`, or `TimeStamp`, as appropriate.

Do not use a headerless export or save these results as Excel workbooks. The importer expects CSV data with column names; a headerless export must be rerun after enabling the SSMS option.

### Multi-result scripts: RPT

These scripts return multiple result sets in one execution. Export the complete SSMS text output as one raw `.rpt` file:

| Script | Export format | Filename must contain | Notes |
|---|---|---|---|
| `FilePath_Pruning_Scope_AllVersion.sql` | RPT | `filepath pruning` or `filepath_pruning` | Raw SSMS Results to File output. |
| `CbP_Analysis_Script SAFE v2.sql` | RPT | `cbp analysis` or `cbp_analysis` | Raw SSMS Results to File output. |
| `DailyPrune_Debug_Scope.sql` | RPT | `daily prune` or `dailyprune` | Raw SSMS Results to File output. |
| `PurgeAntibodiesPeriodDays scope.sql` | RPT | `purge antibodies` or `purgeantibodiesperioddays` | Raw SSMS Results to File output. |

For each script:

1. Open the script in SSMS and select **Query > Results To > Results to File** (shortcut: `Ctrl+Shift+F`).
2. Run the complete script and save the output with the `.rpt` extension.
3. Include the required filename keyword from the table above and save the single file in the health-check input folder.

Do not split the result sets or copy them into Excel. The importer finds result tables in the raw SSMS output by their column names. Diagnostic messages such as statistics, DBCC output, and schema checks may also be present; that is expected.

### Unapproved File Analysis time chunks

`UnapprovedFileAnalysis+ v6.1.sql` can be exported as multiple CSV files. Use non-overlapping UTC/server-time ranges and keep every successful chunk for the intended period in the input folder. The PowerShell collector handles this automatically, including splitting a window when it exceeds the script's row cap.

For manual collection, low-volume environments may be able to use a longer time window. For high-volume environments, use smaller time chunks. If an hourly chunk still exceeds the limit, divide that interval further rather than increasing the row cap. To set a fixed chunk, edit `UnapprovedFileAnalysis+ v6.1.sql`: uncomment the two `SET @startDate` and `@endDate` lines near the top and set the desired non-overlapping range.


