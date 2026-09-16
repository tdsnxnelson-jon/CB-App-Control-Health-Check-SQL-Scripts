USE das;
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET DEADLOCK_PRIORITY LOW;
SET LOCK_TIMEOUT 5000;

-- Production-safe replacement for Approval Metrics+ v4.2.sql.
-- The original scans antibody_instances separately for every approval category.
-- This version calculates all categories in one serial pass and preserves the
-- CSV column contract consumed by the health-check report.

DECLARE @StartDate datetime = DATEADD(week, -4, GETDATE());

IF OBJECT_ID('tempdb..#InitializationDates') IS NOT NULL DROP TABLE #InitializationDates;
IF OBJECT_ID('tempdb..#ApprovedPublishers') IS NOT NULL DROP TABLE #ApprovedPublishers;
IF OBJECT_ID('tempdb..#InventoryCounts') IS NOT NULL DROP TABLE #InventoryCounts;
IF OBJECT_ID('tempdb..#UnapprovedEvents') IS NOT NULL DROP TABLE #UnapprovedEvents;

SELECT DISTINCT publisher_id
INTO #ApprovedPublishers
FROM dbo.TrustedPublishersGUI WITH (NOLOCK)
WHERE State = 'Approved';

CREATE UNIQUE CLUSTERED INDEX IX_ApprovedPublishers_publisher_id
    ON #ApprovedPublishers(publisher_id);

SELECT
    aig.host_id,
    MIN(aig.Date_Created) AS Initialization_Date
INTO #InitializationDates
FROM dbo.antibody_instance_groups aig WITH (NOLOCK)
WHERE ISNULL(aig.type, 0) = 0
  AND aig.antibody_id = 0
GROUP BY aig.host_id
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX IX_InitializationDates_host_id
    ON #InitializationDates(host_id);

SELECT
    fi.host_id,
    COUNT_BIG(*) AS TotalFiles,
    SUM(CASE WHEN states.simple_state = 'Approved' THEN CONVERT(bigint, 1) ELSE 0 END) AS GlobalApproval,
    SUM(CASE WHEN states.simple_state = 'Approved' AND states.state_source = 'Trusted Directory' THEN CONVERT(bigint, 1) ELSE 0 END) AS GlobalTD,
    SUM(CASE WHEN states.simple_state = 'Approved' AND states.state_source = 'Reputation' THEN CONVERT(bigint, 1) ELSE 0 END) AS GlobalRep,
    SUM(CASE
        WHEN states.simple_state <> 'Approved'
         AND fi.local_state IN (1, 4, 7, 8, 11, 12)
         AND ISNULL(groups.type, -1) <> 0
        THEN CONVERT(bigint, 1) ELSE 0 END) AS LocalRule,
    SUM(CASE
        WHEN states.simple_state <> 'Approved'
         AND fi.local_state IN (1, 4, 7, 8, 11, 12)
         AND ISNULL(groups.type, -1) = 0
        THEN CONVERT(bigint, 1) ELSE 0 END) AS LocalInitialization,
    SUM(CASE
        WHEN states.simple_state <> 'Approved'
         AND fi.local_state IN (1, 4, 7, 8, 11, 12)
         AND ISNULL(groups.type, -1) = 0
         AND
         (
             approved_publishers.publisher_id IS NOT NULL
             OR ISNULL(metadata.threat, 999) = 0
             OR metadata.trust > 0.5
         )
        THEN CONVERT(bigint, 1) ELSE 0 END) AS LocalPolicy,
    SUM(CASE WHEN fi.local_state NOT IN (1, 4, 7, 8, 11, 12) THEN CONVERT(bigint, 1) ELSE 0 END) AS Unapproved
INTO #InventoryCounts
FROM dbo.antibody_instances fi WITH (NOLOCK)
LEFT JOIN dbo.antibodies files WITH (NOLOCK) ON files.antibody_id = fi.antibody_id
LEFT JOIN dbo.antibody_states states WITH (NOLOCK) ON states.antibody_id = fi.antibody_id
LEFT JOIN dbo.antibody_instance_groups groups WITH (NOLOCK)
    ON groups.antibody_instance_group_id = fi.antibody_instance_group_id
LEFT JOIN dbo.paritycenter_antibody_metadata metadata WITH (NOLOCK)
    ON metadata.antibody_id = fi.antibody_id
LEFT JOIN #ApprovedPublishers approved_publishers
    ON approved_publishers.publisher_id = files.publisher
GROUP BY fi.host_id
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX IX_InventoryCounts_host_id
    ON #InventoryCounts(host_id);

SELECT
    e.host_id,
    COUNT_BIG(DISTINCT e.event_id) AS Total
INTO #UnapprovedEvents
FROM dbo.events e WITH (NOLOCK)
LEFT JOIN dbo.antibody_instances fi WITH (NOLOCK)
    ON fi.antibody_id = e.antibody_id AND fi.host_id = e.host_id
LEFT JOIN dbo.antibodies files WITH (NOLOCK) ON files.antibody_id = e.antibody_id
LEFT JOIN dbo.antibody_states states WITH (NOLOCK) ON states.antibody_id = e.antibody_id
LEFT JOIN dbo.publishers publisher WITH (NOLOCK) ON publisher.publisher_id = files.publisher
LEFT JOIN dbo.pathnames event_path WITH (NOLOCK) ON event_path.pathname_id = e.pathname_id
WHERE e.time >= @StartDate
  AND e.subtype = 1003
  AND ((fi.local_flags & 16384) = 16384 OR files.first_execution_date IS NOT NULL)
  AND ISNULL(states.state_source, '') <> 'Reputation'
  AND ISNULL(publisher.simple_state, '') <> 'Approved'
  AND event_path.pathname NOT LIKE '\\%'
  AND LEFT(e.param1, 25) IN
      ('DiscoveredBy[Kernel:Creat', 'DiscoveredBy[Kernel:MmapW',
       'DiscoveredBy[Kernel:Renam', 'DiscoveredBy[Kernel:Write',
       'DiscoveredBy[MSICallback]')
GROUP BY e.host_id
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX IX_UnapprovedEvents_host_id
    ON #UnapprovedEvents(host_id);

SELECT
    host.host_id AS 'Computer ID',
    host.display_hostname AS 'Computer Name',
    host_state.Connected AS 'Connected',
    CONVERT(varchar(10), host.bit9_version_major) + '.'
        + CONVERT(varchar(10), host.bit9_version_minor) + '.'
        + CONVERT(varchar(10), host.bit9_version_point) + '.'
        + CONVERT(varchar(10), host.bit9_version_build)
        + CASE WHEN host.bit9_version_debug = 1 THEN 'DEBUG' ELSE '' END AS 'Agemt Version',
    host_state.last_poll_date AS 'Last Polled',
    initialization.Initialization_Date AS 'Initialized',
    ISNULL(platform.name, N'Unknown') AS 'Platform',
    policy.name AS 'Policy',
    CASE
        WHEN (host_state.synch_flags & 1) = 1
          OR host_state.ab_cache_size < host_state.ab_queue_size
          OR host_state.ab_cache_size <= 0
          OR (host.refresh_flags & 1) = 1 THEN 0
        WHEN host_state.ab_queue_size <= 0 THEN 100
        ELSE 100 - (100 * host_state.ab_queue_size + host_state.ab_cache_size / 2) / host_state.ab_cache_size
    END AS '%Sync',
    dbo.GetPolicyStatus(host_state.synch_flags, host_state.debug_flags, host.host_group_id, 0) AS 'ConfigStatus',
    inventory.GlobalApproval AS '#Global Approval',
    inventory.GlobalTD AS '#Global TD',
    inventory.GlobalRep AS '#Global Rep',
    inventory.GlobalApproval - inventory.GlobalTD - inventory.GlobalRep AS '#Global Oth',
    inventory.LocalInitialization AS '#Local Approval: Initialization',
    inventory.LocalInitialization - inventory.LocalPolicy AS '#Local Approval: UnValidated',
    inventory.LocalPolicy AS '#Local Approval: Policy',
    inventory.LocalRule AS '#Local Approval: Rule',
    inventory.Unapproved AS '#Unapproved',
    inventory.TotalFiles AS '#Files',
    ISNULL(events.Total, 0) AS '#Unapprove Events',
    CONVERT(decimal(38, 10),
        (inventory.GlobalApproval + inventory.LocalInitialization + inventory.LocalRule) * 1.0
        / NULLIF(inventory.TotalFiles, 0)) AS '%Whitelist',
    CONVERT(decimal(38, 10),
        inventory.GlobalApproval * 1.0 / NULLIF(inventory.TotalFiles, 0)) AS '%Global'
FROM dbo.hostmain host WITH (NOLOCK)
LEFT JOIN dbo.host_groups policy WITH (NOLOCK) ON policy.host_group_id = host.host_group_id
LEFT JOIN dbo.host_state host_state WITH (NOLOCK) ON host_state.host_id = host.host_id
LEFT JOIN dbo.operating_systems os WITH (NOLOCK) ON os.operating_system_id = host.operating_system_id
LEFT JOIN dbo.platforms platform WITH (NOLOCK) ON platform.platform_id = os.platform_id
JOIN #InventoryCounts inventory ON inventory.host_id = host.host_id
LEFT JOIN #InitializationDates initialization ON initialization.host_id = host.host_id
LEFT JOIN #UnapprovedEvents events ON events.host_id = host.host_id
WHERE host.deleted = 0
  AND inventory.TotalFiles > 0
ORDER BY CONVERT(decimal(38, 10), inventory.GlobalApproval * 1.0 / NULLIF(inventory.TotalFiles, 0))
OPTION (MAXDOP 1);

DROP TABLE #UnapprovedEvents;
DROP TABLE #InventoryCounts;
DROP TABLE #ApprovedPublishers;
DROP TABLE #InitializationDates;