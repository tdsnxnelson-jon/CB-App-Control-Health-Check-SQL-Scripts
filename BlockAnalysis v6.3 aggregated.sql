USE das;
SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
 BlockAnalysis v6.3 aggregated

 Preserves the complete enforcement-event scope introduced in v6.2, but
 returns one row per day and analysis/remediation combination instead of one
 row per event. EventCount contains the number of represented events.

 Only columns consumed by the health-check report are returned. Discovery,
 root-file detail, product metadata and raw event parameters were removed.
 This substantially reduces CSV size in environments with recurring blocks.

 Run on a readable secondary when possible. Validate execution plans and load
 on representative non-production data before using on a production primary.
--------------------------------------------------------------------------- */

DECLARE @thisStartDate datetime = DATEADD(week, -2, GETDATE());
DECLARE @thisEndDate datetime = GETDATE();
DECLARE @includeAllowedPrompts bit = 0;

IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust;
SELECT publisher_id, ParityCenterTrust
INTO #tmpPublisherTrust
FROM dbo.TrustedPublishersGUI;

IF OBJECT_ID('tempdb..#tmpBlockSubtypes') IS NOT NULL DROP TABLE #tmpBlockSubtypes;
SELECT es.event_subtype_id, ls.loc_text
INTO #tmpBlockSubtypes
FROM dbo.event_subtypes es WITH (NOLOCK)
JOIN dbo.loc_strings ls WITH (NOLOCK)
  ON es.string_id = ls.string_id AND ls.locale_id = 1033
WHERE ls.loc_text LIKE 'Execution block%'
   OR ls.loc_text LIKE 'Execution prompt%'
   OR ls.loc_text LIKE 'Write block%'
   OR ls.loc_text LIKE 'Write prompt%'
   OR ls.loc_text LIKE 'Process termination%'
   OR ls.loc_text LIKE '%(banned %';

CREATE UNIQUE CLUSTERED INDEX IX_tmpBlockSubtypes
ON #tmpBlockSubtypes(event_subtype_id);

;WITH BlockEvents AS (
  SELECT
    CONVERT(date, eb.time) AS TimeStamp,
    h.hostname AS ComputerName,
    p.name AS Policy,
    un.username AS UserName,
    bst.loc_text AS BlockSubtype,
    CASE
      WHEN bst.loc_text LIKE '%allow%' THEN 'Allowed'
      WHEN bst.loc_text LIKE '%prompt%' AND bst.loc_text LIKE '%block%' THEN 'Blocked (prompt)'
      WHEN bst.loc_text LIKE '%prompt%' THEN 'Prompted'
      ELSE 'Blocked'
    END AS BlockOutcome,
    CASE
      WHEN bst.loc_text LIKE 'Write%' THEN 'Write'
      WHEN bst.loc_text LIKE 'Process termination%' THEN 'Termination'
      ELSE 'Execution'
    END AS BlockCategory,
    ISNULL(
      CASE
        WHEN ISNULL(os.platform_id, 1) = 1
          THEN bppn.pathname_ci + N'\' + NULLIF(bpfn.filename_ci, N'')
        ELSE bppn.pathname_ci + N'/' + NULLIF(bpfn.filename_ci, N'')
      END,
      ''
    ) AS BlockProcessFull,
    CASE
      WHEN ebpn.pathname_ci LIKE '%\netlogon%' THEN 'Logon Script'
      WHEN ebpn.pathname_ci LIKE '%\sysvol\%' THEN 'Logon Script'
      WHEN ebpn.pathname_ci LIKE '\\%' AND ISNULL(bppn.pathname_ci, '') LIKE '\\%' THEN 'Remote Application'
      WHEN ebpn.pathname_ci LIKE '\\%' AND ISNULL(bppn.pathname_ci, '') NOT LIKE '\\%' THEN 'Remote Execution'
      WHEN ebpn.pathname_ci NOT LIKE '\\%' AND ISNULL(bppn.pathname_ci, '') LIKE '\\%' THEN 'Remote Writing Local'
      WHEN s.state_source <> '' THEN 'Approved: ' + s.state_source
      WHEN ISNULL(pb.simple_state, '') = 'Approved' THEN 'Approved Publisher: ' + pb.name
      WHEN ISNULL(rpb.simple_state, '') = 'Approved'
        AND dbo.GlobalFlags(RFC.flags | RFC.gen_flags) LIKE 'Installer%'
        THEN 'Approved Publisher: ' + rpb.name
      WHEN ISNULL(ppb.simple_state, '') = 'Approved'
        AND dbo.GlobalFlags(PFC.flags | PFC.gen_flags) LIKE 'Installer%'
        THEN 'Approved Publisher: ' + ppb.name
      ELSE 'Unapproved'
    END AS RuleName,
    ISNULL(ebpn.pathname_ci, '') AS FilePath,
    ISNULL(ebfn.filename_ci, '') AS FileNameShort,
    ISNULL(a.hash, '') AS FileHash,
    ISNULL(s.simple_state, '') AS FileState,
    ISNULL(am.trust_value, -1) AS FileTrust,
    ISNULL(dbo.GlobalFlags(a.flags | a.gen_flags), '') AS FileFlags,
    ISNULL(pb.name, '') AS Publisher,
    CASE
      WHEN a.publisher = 0 THEN ''
      ELSE ISNULL(pb.simple_state, 'Unapproved')
    END AS PublisherState,
    ISNULL(FP.ParityCenterTrust, '') AS PublisherTrust
  FROM dbo.events eb WITH (NOLOCK)
  JOIN #tmpBlockSubtypes bst ON bst.event_subtype_id = eb.subtype
  LEFT JOIN dbo.hostmain h WITH (NOLOCK) ON eb.host_id = h.host_id
  LEFT JOIN dbo.host_groups p WITH (NOLOCK) ON p.host_group_id = h.host_group_id
  LEFT JOIN dbo.operating_systems os WITH (NOLOCK) ON os.operating_system_id = h.operating_system_id
  LEFT JOIN dbo.usernames un WITH (NOLOCK) ON un.username_id = eb.username_id
  LEFT JOIN dbo.filenames ebfn WITH (NOLOCK) ON ebfn.filename_id = eb.filename_id
  LEFT JOIN dbo.pathnames ebpn WITH (NOLOCK) ON ebpn.pathname_id = eb.pathname_id
  LEFT JOIN dbo.filenames bpfn WITH (NOLOCK) ON bpfn.filename_id = eb.process_filename_id
  LEFT JOIN dbo.pathnames bppn WITH (NOLOCK) ON bppn.pathname_id = eb.process_pathname_id
  LEFT JOIN dbo.antibodies a WITH (NOLOCK) ON eb.antibody_id = a.antibody_id
  LEFT JOIN dbo.antibody_states s WITH (NOLOCK) ON s.antibody_id = a.antibody_id
  LEFT JOIN dbo.antibody_metadata am WITH (NOLOCK) ON a.antibody_id = am.antibody_id
  LEFT JOIN dbo.publishers pb WITH (NOLOCK) ON a.publisher = pb.publisher_id
  LEFT JOIN #tmpPublisherTrust FP WITH (NOLOCK) ON FP.publisher_id = a.publisher
  LEFT JOIN dbo.antibodies RFC WITH (NOLOCK) ON RFC.antibody_id = eb.root_antibody_id
  LEFT JOIN dbo.publishers rpb WITH (NOLOCK) ON RFC.publisher = rpb.publisher_id
  LEFT JOIN dbo.antibodies PFC WITH (NOLOCK) ON PFC.antibody_id = eb.process_antibody_id
  LEFT JOIN dbo.publishers ppb WITH (NOLOCK) ON PFC.publisher = ppb.publisher_id
  WHERE eb.time >= @thisStartDate
    AND eb.time < @thisEndDate
    AND (@includeAllowedPrompts = 1 OR bst.loc_text NOT LIKE '%allow%')
)
SELECT
  TimeStamp,
  ComputerName,
  Policy,
  UserName,
  BlockSubtype,
  BlockOutcome,
  BlockCategory,
  BlockProcessFull,
  RuleName,
  FilePath,
  FileNameShort,
  FileHash,
  FileState,
  FileTrust,
  FileFlags,
  Publisher,
  PublisherState,
  PublisherTrust,
  COUNT_BIG(*) AS EventCount
FROM BlockEvents
GROUP BY
  TimeStamp,
  ComputerName,
  Policy,
  UserName,
  BlockSubtype,
  BlockOutcome,
  BlockCategory,
  BlockProcessFull,
  RuleName,
  FilePath,
  FileNameShort,
  FileHash,
  FileState,
  FileTrust,
  FileFlags,
  Publisher,
  PublisherState,
  PublisherTrust
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust;
IF OBJECT_ID('tempdb..#tmpBlockSubtypes') IS NOT NULL DROP TABLE #tmpBlockSubtypes;

GO