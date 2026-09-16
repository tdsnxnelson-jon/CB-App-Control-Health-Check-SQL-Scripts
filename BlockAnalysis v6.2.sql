USE das;
SET NOCOUNT ON

/* ---------------------------------------------------------------------------
 BlockAnalysis v6.2

 Fixes undercounting present in v6.1:
   1. v6.1 only returned two "Execution prompt%" subtypes. All High-enforcement
      silent blocks, custom-rule blocks, banned-file/publisher blocks, write
      blocks and terminations were dropped. Subtypes are now resolved by
      pattern from dbo.loc_strings instead of hard-coded strings.
   2. v6.1 drove off the "New unapproved file to computer" discovery event, so
      a block was only visible if the file was FIRST SEEN inside the reporting
      window. The block event is now the driver; discovery is an optional
      lookup.
   3. v6.1 filtered on the discovery time, not the block time, so the window
      did not actually mean "blocks in the last N weeks". @thisStartdate now
      filters eb.time.
   4. v6.1 matched discovery<->block on host+antibody+filename+pathname, losing
      any block recorded at a different path than the discovery event. The
      lookup is now host+antibody only, TOP 1 by earliest discovery.

 Output columns are a superset of v6.1. New: BlockOutcome, BlockCategory,
 DiscoveryTimeStamp. Semantics changed: TimeStamp/TimeDate are now the BLOCK
 time (v6.1 used the discovery time), and BlockProcessFull is now the process
 that attempted the blocked action (v6.1 repeated the blocked file's path).

 Perf note: the discovery OUTER APPLY scans dbo.events by host_id+antibody_id.
 On very large event tables, comment it out (and the columns that use `e`) if
 the query runs long - it only supplies Subtype/DiscoveredBy/ProcessShort/
 ProcessFull/DiscoveryTimeStamp.
--------------------------------------------------------------------------- */

declare @thisStartdate datetime = DATEADD(week, -2, GETDATE())	--<== StartDate

IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust
select publisher_id, ParityCenterTrust into #tmpPublisherTrust from dbo.TrustedPublishersGUI

-- Every enforcement subtype that represents a block / prompt / termination.
IF OBJECT_ID('tempdb..#tmpBlockSubtypes') IS NOT NULL DROP TABLE #tmpBlockSubtypes
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
   OR ls.loc_text LIKE '%(banned %'
CREATE UNIQUE CLUSTERED INDEX IX_tmpBlockSubtypes ON #tmpBlockSubtypes(event_subtype_id)

-- Uncomment to verify which subtypes this server actually matched:
-- SELECT loc_text FROM #tmpBlockSubtypes ORDER BY loc_text

declare @NewUnapprovedSubtype int =
	(SELECT TOP 1 es.event_subtype_id
	 FROM dbo.event_subtypes es WITH (NOLOCK)
		JOIN dbo.loc_strings ls WITH (NOLOCK)
			ON es.string_id = ls.string_id AND ls.locale_id = 1033
	 WHERE ls.loc_text = 'New unapproved file to computer')

SELECT
  eb.time AS 'TimeStamp',
  CONVERT(DATE, eb.time , 112) AS 'TimeDate',
  h.hostname AS 'ComputerName',
  p.name AS 'Policy',
  un.username AS 'UserName',
  CASE WHEN e.time IS NULL THEN '' ELSE 'New unapproved file to computer' END AS 'Subtype',
  ebsubtype.loc_text AS 'BlockSubtype',
  CASE
	WHEN ebsubtype.loc_text LIKE '%allow%' THEN 'Allowed'
	WHEN ebsubtype.loc_text LIKE '%prompt%' AND ebsubtype.loc_text LIKE '%block%' THEN 'Blocked (prompt)'
	WHEN ebsubtype.loc_text LIKE '%prompt%' THEN 'Prompted'
	ELSE 'Blocked'
  END AS 'BlockOutcome',
  CASE
	WHEN ebsubtype.loc_text LIKE 'Write%' THEN 'Write'
	WHEN ebsubtype.loc_text LIKE 'Process termination%' THEN 'Termination'
	ELSE 'Execution'
  END AS 'BlockCategory',
  eb.time AS 'BlockTimeStamp',
  e.time AS 'DiscoveryTimeStamp',
  -- process that attempted the blocked action
  '"'+REPLACE(REPLACE(REPLACE(isnull(CASE WHEN ISNULL(os.platform_id,1)=1 THEN bppn.pathname_ci+N'\'+NULLIF(bpfn.filename_ci,N'') ELSE bppn.pathname_ci+N'/'+NULLIF(bpfn.filename_ci,N'') END,''),CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'BlockProcessFull',
  Case
	When ebpn.pathname_ci like '%\netlogon%' then 'Logon Script'
	When ebpn.pathname_ci like '%\sysvol\%' then 'Logon Script'
	When ebpn.pathname_ci like '\\%' and  ISNULL(bpfn.filename_ci,'') like '\\%' then 'Remote Application'
	When ebpn.pathname_ci like '\\%' and  ISNULL(bpfn.filename_ci,'') not like '\\%' then 'Remote Execution'
	When ebpn.pathname_ci not like '\\%' and  ISNULL(pfn.filename_ci,'') like '\\%' then 'Remote Writing Local'
	When s.state_source <> '' then 'Approved: ' + s.state_source
	When ISNULL(pb.simple_state,'') = 'Approved' then 'Approved Publisher: ' + pb.name
	When ISNULL(rpb.simple_state,'') = 'Approved' and dbo.GlobalFlags(RFC.flags|RFC.gen_flags) like 'Installer%' then 'Approved Publisher: ' + rpb.name
	When ISNULL(ppb.simple_state,'') = 'Approved' and dbo.GlobalFlags(PFC.flags|PFC.gen_flags) like 'Installer%' then 'Approved Publisher: ' + ppb.name
	Else 'Unapproved'
  End as RuleName,
    Case
	When LEFT(ISNULL(e.param1,''),12) = 'DiscoveredBy' then Substring(e.param1,14,CHARINDEX('FileCreated',e.param1)-16)
	Else ''
  End as 'DiscoveredBy',
  -- process that originally wrote the file (from the discovery event, if still present)
  ISNULL(pfn.filename_ci,'') AS 'ProcessShort',
  '"'+REPLACE(REPLACE(REPLACE(isnull(CASE WHEN ISNULL(os.platform_id,1)=1 THEN ppn.pathname_ci+N'\'+NULLIF(pfn.filename_ci,N'') ELSE ppn.pathname_ci+N'/'+NULLIF(pfn.filename_ci,N'') END,''),CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'ProcessFull',
  '"'+REPLACE(REPLACE(REPLACE(ebpn.pathname_ci,CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'FilePath',
  '"'+REPLACE(REPLACE(REPLACE(ebfn.filename_ci,CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'FileNameShort',
  '"'+REPLACE(REPLACE(REPLACE(isnull( CASE WHEN ISNULL(os.platform_id,1)=1 THEN ebpn.pathname_ci+N'\'+NULLIF(ebfn.filename_ci,N'') ELSE ebpn.pathname_ci+N'/'+NULLIF(ebfn.filename_ci,N'') END,''),CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'FileNameFull',
  auc.usage_counter AS 'FilePrevalence',
  s.simple_state AS 'FileState',
  s.state_source AS 'FileStateReason',
  a.first_execution_date 'FileFirstExecution',
  case when isnull(ai.local_flags,'') = '' then '' else CASE WHEN (ai.local_flags&16384)=16384 THEN 'Yes' ELSE 'No' END end AS 'Executed',
  CASE WHEN isnull(ai.local_state,'') = '' Then 'Deleted' else dbo.DetailedLocalState(ai.local_state, NULL) end as Local_State,
  ISNULL(am.trust_value, -1) AS 'FileTrust',
  dbo.GlobalFlags(a.flags|a.gen_flags) AS 'FileFlags',
  '"'+pb.name+'"' AS 'Publisher',
  CASE WHEN a.publisher = 0 THEN '' ELSE ISNULL(pb.simple_state, 'Unapproved') End as 'PublisherState',
  isnull(FP.ParityCenterTrust,'') as 'PublisherTrust',
  '"'+co.company+'"' AS 'Company',
  '"'+pn.product_name+'"' AS 'Product',
  '"'+pr.product_name+'"' AS 'ProgramName',
  a.hash as 'FileHash',
  case when isnull(PFC.Hash,'') = '' then RFC.Hash else PFC.Hash end as 'RootHash',
  case when isnull(PFC.Hash,'') = '' then '"'+rpb.name+'"' else '"'+ppb.name+'"' end as 'RootPublisher',
  case when isnull(PFC.Hash,'') = '' then CASE WHEN RFC.publisher = 0 THEN '' ELSE ISNULL(rpb.simple_state, 'Unapproved') End else  CASE WHEN PFC.publisher = 0 THEN '' ELSE ISNULL(ppb.simple_state, 'Unapproved') End end as 'RootPublisherState',
  case when isnull(PFC.Hash,'') = '' then isnull(RFP.ParityCenterTrust,'') else isnull(PFP.ParityCenterTrust,'') end as 'RootPublisherTrust',
  case when isnull(PFC.Hash,'') = '' then '"'+rco.company+'"' else '"'+pco.company+'"' end as 'RootCompany',
  case when isnull(PFC.Hash,'') = '' then '"'+rp.product_name+'"' else '"'+pp.product_name+'"' end as 'RootProduct',
  case when isnull(PFC.Hash,'') = '' then ISNULL(ram.trust_value, -1) else ISNULL(pam.trust_value, -1) end as 'RootTrust',
  case when isnull(PFC.Hash,'') = '' then dbo.GlobalFlags(RFC.flags|RFC.gen_flags) else dbo.GlobalFlags(PFC.flags|PFC.gen_flags) end as 'RootFileFlags',
  '"'+ISNULL(eb.param1,'')+'"' as 'Param1',
  '"'+ISNULL(eb.param2,'')+'"' as 'Param2',
  '"'+ISNULL(eb.param3,'')+'"' as 'Param3'
FROM
	dbo.events eb with (nolock)
	JOIN #tmpBlockSubtypes bst ON bst.event_subtype_id = eb.subtype
	LEFT JOIN dbo.event_subtypes ebs WITH (nolock) ON eb.subtype = ebs.event_subtype_id
	LEFT JOIN dbo.loc_strings ebsubtype WITH (nolock) ON ebs.string_id = ebsubtype.string_id AND ebsubtype.locale_id = 1033
	LEFT JOIN dbo.hostmain h WITH (NOLOCK) ON eb.host_id = h.host_id
	LEFT JOIN dbo.host_groups p with (nolock) on p.host_group_id = h.host_group_id
	LEFT JOIN dbo.operating_systems os with (nolock) on os.operating_system_id = h.operating_system_id
	LEFT JOIN dbo.usernames un with (nolock) on un.username_id = eb.username_id
	LEFT JOIN dbo.filenames ebfn with (nolock) on ebfn.filename_id = eb.filename_id
	LEFT JOIN dbo.pathnames ebpn with (nolock) on ebpn.pathname_id = eb.pathname_id
	LEFT JOIN dbo.filenames bpfn with (nolock) on bpfn.filename_id = eb.process_filename_id
	LEFT JOIN dbo.pathnames bppn with (nolock) on bppn.pathname_id = eb.process_pathname_id
	-- optional: earliest "New unapproved file to computer" for this file on this host
	OUTER APPLY (
		SELECT TOP 1 d.time, d.param1, d.process_filename_id, d.process_pathname_id
		FROM dbo.events d with (nolock)
		WHERE d.host_id = eb.host_id
		  AND d.antibody_id = eb.antibody_id
		  AND d.subtype = @NewUnapprovedSubtype
		ORDER BY d.time ASC
	) e
	LEFT JOIN dbo.filenames pfn with (nolock) on pfn.filename_id = e.process_filename_id
	LEFT JOIN dbo.pathnames ppn with (nolock) on ppn.pathname_id = e.process_pathname_id
	LEFT JOIN dbo.antibodies a WITH (NOLOCK) ON eb.antibody_id = a.antibody_id
	LEFT JOIN dbo.antibodies_usage_count auc WITH (NOLOCK) ON auc.antibody_id = a.antibody_id
	LEFT JOIN dbo.antibody_states s WITH (NOLOCK) ON s.antibody_id = a.antibody_id
	LEFT JOIN dbo.antibody_metadata am WITH (NOLOCK) ON a.antibody_id = am.antibody_id
	LEFT JOIN dbo.publishers pb WITH (NOLOCK) ON a.publisher = pb.publisher_id
	LEFT JOIN dbo.companies co WITH (NOLOCK) ON co.company_id=a.company_id
	LEFT JOIN dbo.product_names pn WITH (nolock) ON pn.product_name_id = a.product_name_id
	LEFT JOIN dbo.product_names pr WITH (nolock) ON pr.product_name_id = CASE WHEN a.gen_flags & 0x80000 <> 0 THEN a.product_name_id ELSE 0 End
	LEFT JOIN #tmpPublisherTrust FP with (nolock) on FP.publisher_id = a.publisher
	left join dbo.antibody_instances ai WITH (NOLOCK) ON eb.antibody_id = ai.antibody_id and eb.host_Id = ai.host_id and eb.filename_id = ai.filename_id and eb.pathname_id = ai.pathname_id
	LEFT JOIN dbo.antibodies RFC WITH (NOLOCK) ON RFC.antibody_id = eb.root_antibody_id
	LEFT JOIN dbo.publishers rpb WITH (NOLOCK) ON RFC.publisher = rpb.publisher_id
	LEFT JOIN dbo.antibody_metadata ram WITH (NOLOCK) ON RFC.antibody_id = ram.antibody_id
	LEFT JOIN dbo.companies rco WITH (NOLOCK) ON rco.company_id = RFC.company_id
	LEFT JOIN dbo.product_names rp WITH (nolock) ON rp.product_name_id = RFC.product_name_id
	LEFT JOIN #tmpPublisherTrust RFP with (nolock) on RFC.publisher = RFP.publisher_id
	LEFT JOIN dbo.antibodies PFC WITH (NOLOCK) ON PFC.antibody_id = eb.process_antibody_id
	LEFT JOIN dbo.publishers ppb WITH (NOLOCK) ON PFC.publisher = ppb.publisher_id
	LEFT JOIN dbo.antibody_metadata pam WITH (NOLOCK) ON PFC.antibody_id = pam.antibody_id
	LEFT JOIN dbo.companies pco WITH (NOLOCK) ON pco.company_id = PFC.company_id
	LEFT JOIN dbo.product_names pp WITH (nolock) ON pp.product_name_id = PFC.product_name_id
	LEFT JOIN #tmpPublisherTrust PFP with (nolock) on PFC.publisher = PFP.publisher_id
WHERE
	eb.time > @thisStartdate
ORDER BY eb.time DESC

IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust
IF OBJECT_ID('tempdb..#tmpBlockSubtypes') IS NOT NULL DROP TABLE #tmpBlockSubtypes

GO
