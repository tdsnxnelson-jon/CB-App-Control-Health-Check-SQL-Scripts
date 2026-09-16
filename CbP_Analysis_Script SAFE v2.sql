USE das;
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET DEADLOCK_PRIORITY LOW;
SET LOCK_TIMEOUT 5000;

/*
Production-safe replacement for CbP_Analysis_Script.sql.

This script is intentionally read-only and returns only the five result sets
used by the CB App Control Health Check report. Run it on a readable AG
secondary when available, or during a low-activity period.
*/

DECLARE @Now datetime = GETDATE();
DECLARE @OneDayAgo datetime = DATEADD(day, -1, @Now);
DECLARE @ThreeDaysAgo datetime = DATEADD(day, -3, @Now);
DECLARE @TwentyOneDaysAgo datetime = DATEADD(day, -21, @Now);
DECLARE @HostCountNotDeleted bigint;
DECLARE @HostCount int;
DECLARE @AvgEvents bigint;
DECLARE @AvgFileOps bigint;
DECLARE @TempABSize bigint;

/* Agent sync percentage. */
SELECT
    'overall (all non deleted)' AS 'Type',
    CAST(100 - AVG(100.0 * hs.ab_queue_size / (1 + hs.ab_cache_size)) + 0.5 AS int) AS 'Agent Sync Percent'
FROM dbo.host_state hs WITH (NOLOCK)
JOIN dbo.hostmain hm WITH (NOLOCK) ON hm.host_id = hs.host_id
WHERE hm.deleted = 0
  AND hs.last_poll_date > @ThreeDaysAgo
UNION ALL
SELECT
    'non-disabled (defcon <> 80)' AS 'Type',
    CAST(100 - AVG(100.0 * hs.ab_queue_size / (1 + hs.ab_cache_size)) + 0.5 AS int) AS 'Agent Sync Percent'
FROM dbo.host_state hs WITH (NOLOCK)
JOIN dbo.hostmain hm WITH (NOLOCK) ON hm.host_id = hs.host_id
WHERE hm.deleted = 0
  AND hs.defcon_id <> 80
  AND hs.last_poll_date > @ThreeDaysAgo
OPTION (MAXDOP 1);

/* Average daily load per recently connected host. */
SELECT @HostCountNotDeleted = COUNT_BIG(*)
FROM dbo.hostmain WITH (NOLOCK)
WHERE deleted = 0;

SELECT
    @HostCount = COUNT(*),
    @AvgFileOps = AVG(CONVERT(bigint, ab_queue_diff) + CONVERT(bigint, Total_Ab_Operations_diff)),
    @AvgEvents = AVG(CONVERT(bigint, Total_Events_Diff))
FROM dbo.HostsPerformanceGUI WITH (NOLOCK)
WHERE Last_Poll > @OneDayAgo
OPTION (MAXDOP 1);

SELECT
    @HostCountNotDeleted AS 'Total non-deleted host count',
    @HostCount AS 'Count of Hosts Included',
    @AvgFileOps AS 'Average No. of File Operations (FO)/host',
    @AvgEvents AS 'Average No. of Events/host';

/* Current server and endpoint queue backlog. */
SELECT @TempABSize = COUNT_BIG(*)
FROM dbo.temp_antibody_instances WITH (NOLOCK)
OPTION (MAXDOP 1);

SELECT
    SUM(CONVERT(bigint, hs.ab_queue_size)) AS 'FO Queue 1: Agent-Side backlog (overall - including disabled)',
    SUM(CONVERT(bigint, hs.event_queue_size)) AS 'EVENT (Queue) backlog (overall)',
    @TempABSize AS 'FO Queue 2: Server side backlog (size of Temp AB Table) (overall - including disabled)'
FROM dbo.host_state hs WITH (NOLOCK)
JOIN dbo.hostmain hm WITH (NOLOCK) ON hm.host_id = hs.host_id
WHERE hs.last_poll_date > @OneDayAgo
  AND hm.deleted = 0
OPTION (MAXDOP 1);

/* Daily throughput. Every large history table is bounded before grouping. */
;WITH FileOps AS
(
    SELECT
        CONVERT(date, ste.execution_time) AS 'Date',
        SUM(ISNULL(CONVERT(bigint, ste.output_size), 0)) AS Files_Processed,
        SUM(ISNULL(CONVERT(bigint, ste.duration_ms), 0)) AS Time_Spent_Processing_Files_MS
    FROM dbo.scheduled_task_executions ste WITH (NOLOCK)
    JOIN dbo.scheduled_tasks st WITH (NOLOCK) ON st.task_id = ste.task_id
    WHERE st.task LIKE 'ProcessFileInstances%'
      AND ste.execution_time >= @TwentyOneDaysAgo
    GROUP BY CONVERT(date, ste.execution_time)
), DailyEvents AS
(
    SELECT
        CONVERT(date, e.date_created) AS receivedDate,
        COUNT(DISTINCT e.host_id) AS hosts,
        COUNT_BIG(*) AS events
    FROM dbo.events e WITH (NOLOCK)
    WHERE e.date_created >= @TwentyOneDaysAgo
    GROUP BY CONVERT(date, e.date_created)
), Antibodies AS
(
    SELECT CONVERT(date, creation_date) AS Date_Created, COUNT_BIG(*) AS countABs
    FROM dbo.antibodies WITH (NOLOCK)
    WHERE creation_date >= @TwentyOneDaysAgo
    GROUP BY CONVERT(date, creation_date)
), AntibodyInstances AS
(
    SELECT CONVERT(date, date_created) AS Date_Created, COUNT_BIG(*) AS countABInst
    FROM dbo.antibody_instances WITH (NOLOCK)
    WHERE date_created >= @TwentyOneDaysAgo
    GROUP BY CONVERT(date, date_created)
), FileRules AS
(
    SELECT CONVERT(date, date_created) AS Date_Created, COUNT_BIG(*) AS countFRs
    FROM dbo.file_rules WITH (NOLOCK)
    WHERE date_created >= @TwentyOneDaysAgo
    GROUP BY CONVERT(date, date_created)
), ScheduledTasks AS
(
    SELECT CONVERT(date, execution_time) AS 'Date', SUM(CONVERT(bigint, duration_ms)) AS Duration_MS
    FROM dbo.scheduled_task_executions WITH (NOLOCK)
    WHERE execution_time >= @TwentyOneDaysAgo
    GROUP BY CONVERT(date, execution_time)
)
SELECT
    fo.Date AS 'Date',
    CONVERT(varchar(20), fo.Files_Processed) AS 'FO_Processed',
    abs.countABs AS 'ABs_Created',
    abi.countABInst AS 'AbInst_Created',
    fr.countFRs AS 'FRs_Created',
    CONVERT(decimal(18, 2), fo.Time_Spent_Processing_Files_MS / 3600000.0) AS 'FO_ProcessingTimeSpent(HR)',
    CONVERT(bigint, fo.Files_Processed / NULLIF(de.hosts, 0)) AS 'FO_PerHost',
    CONVERT(varchar(20), de.events) AS 'E_Total',
    de.hosts AS 'E_Hosts',
    CONVERT(bigint, de.events / NULLIF(de.hosts, 0)) AS 'E_PerHost',
    CONVERT(decimal(18, 2), st.Duration_MS / 3600000.0) AS 'ScheduleTasks_Total(HR)'
FROM FileOps fo
LEFT JOIN DailyEvents de ON de.receivedDate = fo.Date
LEFT JOIN Antibodies abs ON abs.Date_Created = fo.Date
LEFT JOIN AntibodyInstances abi ON abi.Date_Created = fo.Date
LEFT JOIN FileRules fr ON fr.Date_Created = fo.Date
LEFT JOIN ScheduledTasks st ON st.Date = fo.Date
ORDER BY fo.Date DESC
OPTION (MAXDOP 1);

/* Performance history: preserve the established report schema. */
IF EXISTS
(
    SELECT 1
    FROM dbo.shepherd_configs WITH (NOLOCK)
    WHERE name = 'DBSchemaVersion' AND value LIKE '7.2.%'
)
BEGIN
    SELECT TOP (21)
        File_Rate_M,
        Projected_File_Rate_M,
        BackLog_Rate_M,
        Projected_BackLog_Rate_M,
        AB_BackLog_M,
        AB_Rows_M,
        SQL_Latency_Ms,
        date_created
    FROM dbo.PerformanceHistory(1440)
    ORDER BY date_created DESC
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    SELECT TOP (21)
        File_Rate_M,
        Projected_File_Rate_M,
        BackLog_Rate_M,
        Projected_BackLog_Rate_M,
        AB_BackLog_M,
        AB_Rows_M,
        date_created
    FROM dbo.PerformanceHistory(1440)
    ORDER BY date_created DESC
    OPTION (MAXDOP 1);
END;