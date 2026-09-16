# SQL Script and Export Guide

This folder contains the SQL scripts used to collect data for the CB App Control Health Check report.

The general workflow is:

1. Run each SQL script against the App Control database in SSMS.
2. Export the result in the format listed below.
3. Upload all exports for one health-check run into it's own folder.

## Before running the scripts

- Use a read-only or readable Availability Group secondary when possible.
- If a secondary is not available, run during a low-activity maintenance window.
- Run one script at a time and monitor SQL Server CPU, runnable tasks, and AG health.
- Do not run the original `CbP_Analysis_Script.sql` on a busy production primary. Use `CbP_Analysis_Script SAFE v2.sql` instead.
- Do not mix exports from different servers, or reporting periods in the same input folder.

## Unapproved File Analysis chunks

`UnapprovedFileAnalysis+ v6.1.sql` is intended to run in time-bounded chunks. Use non-overlapping UTC/server-time ranges and keep every successful chunk for the intended period in the input folder.

For high-volume environments, the requested period should be exported as multiple smaller time chunks. If an hourly chunk still exceeds the limit, that interval should be divided further rather than increasing the row cap. For a fixed chunk, edit `UnapprovedFileAnalysis+ v6.1.sql` by uncommenting the two `SET @startDate` and `SET @endDate` lines near the top of the script, then set both values to the desired non-overlapping window.

## Exporting a single-result SQL script as CSV

Before exporting, make sure SSMS is configured to include column headers:

1. Open **Tools > Options > Query Results > SQL Server > Results to Grid**.
2. Enable **Include column headers when copying or saving the results**.
3. Select **OK**, then open a new query window before running the script. If SSMS does not apply the change, restart SSMS.

Use this procedure for scripts that return one result grid:
| Script | Export format | Filename must contain | Notes |
|---|---|---|---|
| `Approval Metrics+ v4.3 SAFE.sql` | CSV | `approval metric` | Use the SAFE version when provided. |
| `RuleAnalysis.sql` | CSV | `rule analysis` or `ruleanalysis` | One CSV export. |
| `ApprovalEventsForRulename.sql` | CSV | `approval events` or `approvalevents` | One CSV export. |
| `BlockAnalysis v6.2.sql` | CSV | `block analysis` or `blockanalysis` | Use v6.2 to include all enforcement events. |
| `BlockAnalysis v6.2 fast.sql` | CSV | `block analysis` or `blockanalysis` | Optional alternative when v6.2 is too slow; it returns less discovery detail. |
| `UnapprovedFileAnalysis+ v6.1.sql` | CSV | `unapproved file` or `unapprovedfileanalysis` | Multiple non-overlapping time chunks are supported. |
| `DatabaseErrorAnalysis.sql` | CSV | `database error` or `databaseerroranalysis` | One CSV export. |

1. Open the SQL script in SSMS.
2. Connect to the correct App Control SQL Server database.
3. Confirm the script is pointed at the intended database and reporting period.
4. Run the script.
5. In the Results pane, right-click the result grid.
6. Select **Save Results As...**.
7. Save the file as **CSV UTF-8 (`*.csv`)** when available.
8. Use a descriptive filename containing the required keyword in the table below.
9. Save the file in the health-check input folder.
10. Open the CSV in a text editor and confirm the first row contains column names such as `Computer ID`, `Event`, or `TimeStamp`, as appropriate for the script.

Do not use a headerless export: the importer cannot safely infer the complete schema, so the query must be re-exported after enabling column headers. Do not save these exports as Excel workbooks. The health-check importer expects CSV/TXT data for these scripts.

## Exporting a multi-result SQL script as RPT

These scripts return multiple result sets in one execution. Export the complete SSMS text output as one raw `.rpt` file:
| Script | Export format | Filename must contain | Notes |
|---|---|---|---|
| `FilePath_Pruning_Scope_AllVersion.sql` | RPT | `filepath pruning` or `filepath_pruning` | Raw SSMS Results to File output. |
| `CbP_Analysis_Script SAFE v2.sql` | RPT | `cbp analysis` or `cbp_analysis` | Raw SSMS Results to File output. |
| `DailyPrune_Debug_Scope.sql` | RPT | `daily prune` or `dailyprune` | Raw SSMS Results to File output. |
| `PurgeAntibodiesPeriodDays scope.sql` | RPT | `purge antibodies` or `purgeantibodiesperioddays` | Raw SSMS Results to File output. |

1. Open the SQL script in SSMS.
2. Before running it, select **Query > Results To > Results to File**. The shortcut is `Ctrl+Shift+F`.
3. Run the complete script.
4. When prompted, save the output with the `.rpt` extension.
5. Use a descriptive filename containing the required keyword in the table below.
6. Save the single `.rpt` file in the health-check input folder.

Do not manually split the result sets. Do not copy the results into Excel. The importer detects the individual result tables inside the raw SSMS output by their column names. Diagnostic messages such as statistics, DBCC output, and schema checks may also be present; that is expected.

## Exporting data from the App Control UI

The health-check report also uses two console exports. These are not SQL script outputs.

### Computers export

1. Open the App Control console.
2. Open the **Computers** page.
3. Add allcolumns to the view for the health-check run.
4. Export the computer list from the console.
5. Save it as CSV or TXT with a filename containing `computers`.
6. Put it in the same input folder as the SQL exports.

Example:

```text
Computers_20260915.csv
```

### Custom Rules export

1. Open the App Control console.
2. Open the **Custom Rules** page.
3. Add allcolumns to the view for the health-check run.
4. Save it as CSV or TXT with a filename containing `custom`.
5. Put it in the same input folder as the SQL exports.

Example:

```text
CustomRules_20260915.csv
```


