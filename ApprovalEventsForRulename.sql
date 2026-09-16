USE das;
SET NOCOUNT ON
IF OBJECT_ID('tempdb..#Variables') IS NOT NULL DROP TABLE #Variables
Create table #Variables (startDate datetime, rowsToRetrieve int)
insert into #Variables values(
DATEADD(week, -2, GETDATE()),	--<== StartDate
300000					--<== Rows
)
declare @thisStartdate datetime = DATEADD(week, -4, GETDATE())	--<== StartDate
declare @thisRowsToRetrieve int = 300000							--<== Rows

select @thisStartdate = startDate, @thisRowsToRetrieve = rowsToRetrieve from #Variables

IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust
select publisher_id, ParityCenterTrust into #tmpPublisherTrust from dbo.TrustedPublishersGUI
SELECT top (@thisRowsToRetrieve)
  E.time AS 'TimeStamp',
  CONVERT(DATE, E.time , 112) AS 'TimeDate',
  C.hostname AS 'ComputerName',
  p.name AS 'Policy',
  un.username AS 'UserName',
  eSubtype.loc_text AS 'Subtype',
  COALESCE(mr.name, r.name) AS 'RuleName',
  --mr.name as 'mr.name',
  --r.name as 'r.name',
  ISNULL(pfn.filename_ci,'') AS 'ProcessShort',
  '"'+REPLACE(REPLACE(REPLACE(isnull(CASE WHEN ISNULL(os.platform_id,1)=1 THEN ppn.pathname_ci+N'\'+NULLIF(pfn.filename_ci,N'') ELSE ppn.pathname_ci+N'/'+NULLIF(pfn.filename_ci,N'') END,''),CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'ProcessFull',
  '"'+REPLACE(REPLACE(REPLACE(epn.pathname_ci,CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'FilePath',
  '"'+REPLACE(REPLACE(REPLACE(efn.filename_ci,CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'FileNameShort',
  '"'+REPLACE(REPLACE(REPLACE(isnull( CASE WHEN ISNULL(os.platform_id,1)=1 THEN epn.pathname_ci+N'\'+NULLIF(efn.filename_ci,N'') ELSE epn.pathname_ci+N'/'+NULLIF(efn.filename_ci,N'') END,''),CHAR(9),''),CHAR(10),''),CHAR(13),'')+'"' AS 'FileNameFull',
  auc.usage_counter AS 'FilePrevalence', 
  s.simple_state AS 'FileState', 
  s.state_source AS 'FileStateReason', 
  a.first_execution_date 'FileFirstExecution', -- 
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
  '"'+ISNULL(E.param3,'')+'"' as 'CommandLine'
FROM
	dbo.events E with (nolock)
	LEFT JOIN dbo.hostmain C WITH (NOLOCK) ON E.host_id = C.host_id
	LEFT JOIN dbo.host_groups p with (nolock) on p.host_group_id = c.host_group_id
	LEFT JOIN dbo.operating_systems os with (nolock) on os.operating_system_id = C.operating_system_id
	LEFT JOIN dbo.event_subtypes es WITH (nolock) ON e.subtype = es.event_subtype_id
	LEFT JOIN dbo.loc_strings eSubtype WITH (nolock) ON es.string_id = eSubtype.string_id AND eSubtype.locale_id = 1033
	LEFT JOIN dbo.rules r WITH (nolock) ON r.rule_id=e.rule_id AND e.rule_type IS NULL
	LEFT JOIN dbo.rules mr WITH (nolock) ON mr.rule_id=r.master_rule_id AND e.rule_type IS NULL
	LEFT JOIN dbo.filenames efn with (nolock) on efn.filename_id = e.filename_id
	LEFT JOIN dbo.pathnames epn with (nolock) on epn.pathname_id = e.pathname_id
	LEFT JOIN dbo.usernames un with (nolock) on un.username_id = e.username_id
	LEFT JOIN dbo.filenames pfn with (nolock) on pfn.filename_id = e.process_filename_id
	LEFT JOIN dbo.pathnames ppn with (nolock) on ppn.pathname_id = e.process_pathname_id
	LEFT JOIN dbo.antibodies a WITH (NOLOCK) ON e.antibody_id = a.antibody_id
	LEFT JOIN dbo.antibodies_usage_count auc WITH (NOLOCK) ON auc.antibody_id = a.antibody_id
	LEFT JOIN dbo.antibody_states s WITH (NOLOCK) ON s.antibody_id = a.antibody_id
	LEFT JOIN dbo.antibody_metadata am WITH (NOLOCK) ON a.antibody_id = am.antibody_id
	LEFT JOIN dbo.publishers pb WITH (NOLOCK) ON a.publisher = pb.publisher_id
	LEFT JOIN dbo.companies co WITH (NOLOCK) ON co.company_id=a.company_id
	LEFT JOIN dbo.product_names pn WITH (nolock) ON pn.product_name_id = a.product_name_id
	LEFT JOIN dbo.product_names pr WITH (nolock) ON pr.product_name_id = CASE WHEN gen_flags & 0x80000 <> 0 THEN a.product_name_id ELSE 0 End	
	LEFT JOIN #tmpPublisherTrust FP with (nolock) on FP.publisher_id = a.publisher
	left join dbo.antibody_instances ai WITH (NOLOCK)ON E.antibody_id = ai.antibody_id and e.host_Id = ai.host_id and e.filename_id = ai.filename_id and e.pathname_id = ai.pathname_id
	LEFT JOIN dbo.antibodies RFC WITH (NOLOCK)ON RFC.antibody_id = E.root_antibody_id
	LEFT JOIN dbo.publishers rpb WITH (NOLOCK) ON RFC.publisher = rpb.publisher_id
	LEFT JOIN dbo.antibody_metadata ram WITH (NOLOCK) ON RFC.antibody_id = ram.antibody_id	
	LEFT JOIN dbo.companies rco WITH (NOLOCK) ON rco.company_id = RFC.company_id
	LEFT JOIN dbo.product_names rp WITH (nolock) ON rp.product_name_id = RFC.product_name_id
	LEFT JOIN #tmpPublisherTrust RFP with (nolock) on RFC.publisher = RFP.publisher_id
	LEFT JOIN dbo.antibodies PFC WITH (NOLOCK)ON PFC.antibody_id = E.process_antibody_id
	LEFT JOIN dbo.publishers ppb WITH (NOLOCK) ON PFC.publisher = ppb.publisher_id
	LEFT JOIN dbo.antibody_metadata pam WITH (NOLOCK) ON PFC.antibody_id = pam.antibody_id	
	LEFT JOIN dbo.companies pco WITH (NOLOCK) ON pco.company_id = PFC.company_id
	LEFT JOIN dbo.product_names pp WITH (nolock) ON pp.product_name_id = PFC.product_name_id
	LEFT JOIN #tmpPublisherTrust PFP with (nolock) on PFC.publisher = PFP.publisher_id
WHERE
    eSubtype.loc_text = 'File Approved (custom rule)' 
AND E.time > @thisStartdate
and isnull(r.name,'') <> 'Approve writes from trusted processes'

ORDER BY Timestamp DESC

IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust

GO