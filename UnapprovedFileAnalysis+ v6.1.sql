USE das;
SET NOCOUNT ON
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET DEADLOCK_PRIORITY LOW;
SET LOCK_TIMEOUT 5000;
IF OBJECT_ID('tempdb..#Variables') IS NOT NULL DROP TABLE #Variables
Create table #Variables (startDate datetime, endDate datetime, rowsToRetrieve int)
DECLARE @startDate datetime = DATEADD(hour, -1, GETDATE());
DECLARE @endDate datetime = GETDATE();
DECLARE @rowsToRetrieve int = 300000; -- Maximum rows per chunk; the script fails rather than truncates

-- To use a fixed, non-overlapping chunk, uncomment and edit both lines below.
--SET @startDate = '2026-09-13T01:00:00'; -- included
--SET @endDate = '2026-09-13T02:00:00'; -- excluded

insert into #Variables (startDate, endDate, rowsToRetrieve)
values (@startDate, @endDate, @rowsToRetrieve)

go
DECLARE @majorVersion int = TRY_CONVERT(int, PARSENAME(CONVERT(varchar(128), SERVERPROPERTY('ProductVersion')), 4));
DECLARE @buildNumber int = TRY_CONVERT(int, PARSENAME(CONVERT(varchar(128), SERVERPROPERTY('ProductVersion')), 2));

-- CREATE OR ALTER requires SQL Server 2016 SP1 (13.0.4001) or later.
IF @majorVersion < 13 OR (@majorVersion = 13 AND @buildNumber < 4001)
BEGIN
	RAISERROR('UnapprovedFileAnalysis requires SQL Server 2016 SP1 (13.0.4001) or newer because it uses CREATE OR ALTER FUNCTION.', 16, 1);
	SET NOEXEC ON;
END;
GO
CREATE OR ALTER FUNCTION [dbo].[tfProcessMacros](@varTarget varchar(max))
RETURNS @tblPatterns Table (Pattern nvarchar(max),PatternXP varchar(max))
As
Begin
declare @tfPattern nvarchar(max) = '', @tfPatternXP nvarchar(max) = ''

set @tfPattern = @varTarget		
if RIGHT(@tfPattern,1) = '\' set @tfPattern = @tfPattern + '%';
if CHARINDEX('\\',@tfPattern) <> 1
	begin
	if left(@tfPattern,1) = '\' set @tfPattern = '%' + @tfPattern;
	if charindex('<windows>',@tfPattern) = 1 set @tfPattern = replace(@tfPattern,'<windows>','c:\windows\');
	else if  charindex('<system>',@tfPattern) = 1  set @tfPattern = replace(@tfPattern,'<system>','c:\windows\system32\');
	else if charindex('<systemx86>',@tfPattern) = 1 set @tfPattern = replace(@tfPattern,'<systemx86>','c:\windows\syswow64\');
	else if charindex('<ProgramFiles>',@tfPattern) = 1 set @tfPattern = replace(@tfPattern,'<ProgramFiles>','c:\program files\');
	else if charindex('<ProgramFilesx86>',@tfPattern) = 1 set @tfPattern = replace(@tfPattern,'<ProgramFilesx86>','c:\program files (x86)\');
	else if charindex('<Profile>',@tfPattern) = 1 begin set @tfPatternXP = @tfPattern; set @tfPattern = replace(@tfPattern,'<Profile>','c:\users\%\'); set @tfPatternXP = replace(@tfPatternXP,'<Profile>','c:\documents and settings\%\'); set @tfPatternXP = replace(@tfPatternXP,'\\','\'); end
	else if charindex('<InternetCache>',@tfPattern) = 1 begin set @tfPatternXP = @tfPattern; set @tfPattern = replace(@tfPattern,'<InternetCache>','c:\users\%\appdata\local\microsoft\windows\temporary internet files\'); set @tfPatternXP = replace(@tfPatternXP,'<InternetCache>','c:\documents and settings\%\local settings\temporary internet files\'); set @tfPatternXP = replace(@tfPatternXP,'\\','\'); end
	else if charindex('<CommonAppData>',@tfPattern) = 1 begin set @tfPatternXP = @tfPattern; set @tfPattern = replace(@tfPattern,'<CommonAppData>','c:\programdata\'); set @tfPatternXP = replace(@tfPatternXP,'<CommonAppData>','c:\documents and settings\all users\application data\'); set @tfPatternXP = replace(@tfPatternXP,'\\','\'); end
	else if charindex('<LocalAppData>',@tfPattern) = 1 begin set @tfPatternXP = @tfPattern; set @tfPattern = replace(@tfPattern,'<LocalAppData>','c:\users\%\appdata\local\'); set @tfPatternXP = replace(@tfPatternXP,'<LocalAppData>','c:\documents and settings\%\local settings\application data\'); set @tfPatternXP = replace(@tfPatternXP,'\\','\'); end
	else if charindex('<AppData>',@tfPattern) = 1 begin set @tfPatternXP = @tfPattern; set @tfPattern = replace(@tfPattern,'<AppData>','c:\users\%\appdata\roaming\'); set @tfPatternXP = replace(@tfPatternXP,'<AppData>','c:\documents and settings\%\application data\'); set @tfPatternXP = replace(@tfPatternXP,'\\','\'); end
	set @tfPattern = replace(@tfPattern,'\\','\');
	end
else
	begin
		if LEN(@tfPattern) = 1 and left(@tfPattern,1) = '\' set @tfPattern = '%\%';
		if RIGHT(@tfPattern,1) = '\' set @tfPattern = @tfPattern + '%';
	end
if CHARINDEX('\',@tfPattern) = 0 set @tfPattern = '%' + @tfPattern;
set @tfPattern = replace(@tfPattern,'%%','%');
if @tfPatternXP = '' set @tfPatternXP = @tfPattern;
insert @tblPatterns values(@tfPattern,@tfPatternXP);
return
End
go
IF OBJECT_ID('tempdb..#CustomRules') IS NOT NULL
    DROP TABLE #CustomRules
CREATE TABLE #CustomRules
	(Name nvarchar(128),Status nvarchar(10),Platform nvarchar(62),RuleType nvarchar(40),ExecuteAction nvarchar(40),WriteAction nvarchar(40),Path nvarchar(max),Process nvarchar(max),
	 UserOrGroup nvarchar(max),Policies nvarchar(max),LastModified datetime,Discription nvarchar(max),RuleRank bigint)
declare @thisStartdate datetime,@thisEnddate datetime,@thisRowsToRetrieve int,@thisName nvarchar(128),@thisStatus nvarchar(10),@thisPlatform nvarchar(62),@thisPolicy nvarchar(128),@thisDateModified datetime,
		@thisRuleType nvarchar(40),@thisExecuteAction nvarchar(40),@thisWriteAction nvarchar(40),@thisPath nvarchar(max),@thisProcess nvarchar(max),@thisUserOrGroup nvarchar(max),
		@thisDescription nvarchar(max),@thisRuleRank bigint,@lastRuleRank bigint = 0,@lastProcess nvarchar(max) = '',@lastExecuteAction nvarchar(40) = '',@lastWriteAction nvarchar(40) = '',
		@PathPattern nvarchar(max) = '',@PathPatternXP nvarchar(max) = '',@ProcessPattern nvarchar(max) = '',@ProcessPatternXP nvarchar(max) = '',@ruleOrder bigint = 1,
		@policyOrder bigint = 10000,@inputUG nvarchar(max) = '',@outputUG nvarchar(max) = '',@indexUG bigint;
select @thisStartdate = #Variables.startdate, @thisEnddate = #Variables.endDate, @thisRowsToRetrieve = #Variables.rowsToRetrieve from #Variables;
if @thisStartdate >= @thisEnddate
begin
	RAISERROR('StartDate must be earlier than EndDate.', 16, 1);
	RETURN;
end;
if @thisRowsToRetrieve < 1
begin
	RAISERROR('RowsToRetrieve must be greater than zero.', 16, 1);
	RETURN;
end;
declare	thisRuleCursor cursor for
		select distinct mr.name as 'Name',
		CASE ISNULL(mr.enabled, 0) WHEN 1 THEN 'Enabled' ELSE 'Disabled' END AS 'Status',
		pl.name AS 'Platform',
		pt.name as 'RuleType',
		CASE WHEN ISNULL(pe.rule_operation_id,'00000000-0000-0000-0000-000000000000') = '00000000-0000-0000-0000-000000000000' THEN '' ELSE CASE WHEN isnull(r.op_type,mr.exec_op_type) = mr.exec_op_type THEN pe.name Else '' End END as 'ExecuteAction',
		CASE WHEN ISNULL(pw.rule_operation_id,'00000000-0000-0000-0000-000000000000') = '00000000-0000-0000-0000-000000000000' THEN '' ELSE CASE WHEN isnull(r.op_type,mr.op_type) = mr.op_type THEN pw.name ELSE '' End END as 'WriteAction',
		replace(replace(isnull(r.pattern, mr.pattern),'*','%'),'?','_') as 'Path', 
		replace(replace(isnull(r.procname, mr.procname),'*','%'),'?','_') as 'Process',
		replace(replace(isnull(mr.user_names, '*'),'*','%'),'?','_') as 'User or Group',
		ISNULL(sg.display_name, 'All Policies') AS 'Policies',
		mr.date_modified as 'DateModified',
		isnull(mr.description,'') as 'Description',
		-ISNULL(mr.priority_bucket, r.priority_bucket)*100000000 + 
		CASE WHEN r.master_rule_id = 0 OR r.master_rule_id = -1  
		THEN -(ISNULL(r.group_priority,0)*100000) -(ISNULL(r.priority, 0))
		ELSE -(ISNULL(mr.group_priority,0)*100000) -(ISNULL(mr.priority, 0) + isnull(r.priority,0)) 
		END AS 'RuleRank'
		from dbo.rules mr with (nolock)
		left join dbo.rules r with (nolock) on r.master_rule_id = mr.rule_id
		left JOIN dbo.rule_operations pe WITH (nolock) ON mr.exec_action_mask = pe.action_mask AND mr.exec_negation_mask = pe.negation_mask AND mr.exec_op_type = pe.op_type AND pe.rule_type = 17
		LEFT JOIN dbo.rule_operations pw WITH (nolock) ON isnull(r.action_mask,mr.action_mask) = pw.action_mask AND isnull(r.negation_mask,mr.negation_mask) = pw.negation_mask AND isnull(r.op_type,mr.op_type) = pw.op_type AND pw.rule_type = 17
		LEFT JOIN dbo.platforms pl WITH(NOLOCK) ON ISNULL(mr.platform_id,0) = pl.platform_id
		LEFT JOIN dbo.state_groups sg WITH (nolock) ON sg.state_group_id = mr.state_group_id
		LEFT JOIN dbo.custom_rule_types pt WITH (nolock) ON mr.type_id = pt.custom_rule_type_id
		where mr.rule_type = 17 and mr.deleted = 0 and mr.hidden = 0 and (r.deleted = 0 or (r.deleted = 1 and (r.op_type <> 0 or r.exec_op_type <> 0)))
		and pl.name = 'Windows'
		and mr.enabled = 1 
		and (CASE WHEN ISNULL(pe.rule_operation_id,'00000000-0000-0000-0000-000000000000') = '00000000-0000-0000-0000-000000000000' THEN '' ELSE CASE WHEN isnull(r.op_type,mr.exec_op_type) = mr.exec_op_type THEN pe.name Else '' End END in ('Allow','Allow and Promote') or
			 CASE WHEN ISNULL(pw.rule_operation_id,'00000000-0000-0000-0000-000000000000') = '00000000-0000-0000-0000-000000000000' THEN '' ELSE CASE WHEN isnull(r.op_type,mr.op_type) = mr.op_type THEN pw.name ELSE '' End END in ('Approve','Approve as Installer','Ignore'))
		order by RuleRank,Process,Path;
	open thisRuleCursor;
	fetch next from thisRuleCursor
		into @thisName,@thisStatus,@thisPlatform,@thisRuleType,@thisExecuteAction,@thisWriteAction,@thisPath,@thisProcess,@thisUserOrGroup,@thisPolicy,@thisDateModified,@thisDescription,@thisRuleRank;
	WHILE @@FETCH_STATUS = 0
	BEGIN
		if @thisRuleRank = @lastRuleRank
			begin
				if @thisProcess <> @lastProcess set @lastProcess = @thisProcess;
				if @thisExecuteAction <> @lastExecuteAction set @lastExecuteAction = @thisExecuteAction;
 				if @thisWriteAction <> @lastWriteAction set @lastWriteAction = @thisWriteAction;
			end
		 else
			begin
				set @lastRuleRank = @thisRuleRank; 
				set @lastProcess = @thisProcess;
				set @lastExecuteAction = @thisExecuteAction;
				set @lastWriteAction = @thisWriteAction;
			end
		set @inputUG = @thisUserOrGroup;
		WHILE @inputUG <> ''
		BEGIN
		if LEFT(@inputUG,1) = '|'
			set @inputUG = right(@inputUG,len(@inputUG)-1);
		if @inputUG = '' BREAK;
		set @indexUG = charindex('|',@inputUG);
		if @indexUG > 0
			begin
				set @outputUG = LEFT(@inputUG,@indexUG-1);
				set @inputUG = RIGHT(@inputUG,LEN(@inputUG)-@indexUG);
			end
		else
			begin	
				set @outputUG = @inputUG;
				set @inputUG = '';
			end
		 -- Path Fixups
		 select @PathPattern = Pattern, @PathPatternXP = PatternXP from dbo.tfProcessMacros(@thisPath)
		 -- Process Fixups
		 if @thisProcess = '='
			begin
				set @thisProcess = '';
				set @outputUG = 'NT AUTHORITY\SYSTEM';
			end
		 select @ProcessPattern = Pattern, @ProcessPatternXP = PatternXP from tfProcessMacros(@thisProcess)
		 insert into #CustomRules values(@thisName,@thisStatus,@thisPlatform,@thisRuleType,@thisExecuteAction,@thisWriteAction,@PathPattern,@ProcessPattern,@outputUG,@thisPolicy,@thisDateModified,@thisDescription,@thisRuleRank);
		 if @PathPatternXP <> @PathPattern or @ProcessPatternXP <> @ProcessPattern
			  insert into #CustomRules values(@thisName,@thisStatus,@thisPlatform,@thisRuleType,@thisExecuteAction,@thisWriteAction,@PathPatternXP,@ProcessPatternXP,@outputUG,@thisPolicy,@thisDateModified,@thisDescription,@thisRuleRank);
		 set @ruleOrder = @ruleOrder + 1;
		END
		fetch next from thisRuleCursor
			into @thisName,@thisStatus,@thisPlatform,@thisRuleType,@thisExecuteAction,@thisWriteAction,@thisPath,@thisProcess,@thisUserOrGroup,@thisPolicy,@thisDateModified,@thisDescription,@thisRuleRank;
	END 
	CLOSE thisRuleCursor;
	DEALLOCATE thisRuleCursor;
IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust
select publisher_id, ParityCenterTrust into #tmpPublisherTrust from dbo.TrustedPublishersGUI
IF OBJECT_ID('tempdb..#TargetEvents') IS NOT NULL DROP TABLE #TargetEvents
CREATE TABLE #TargetEvents (event_id bigint NOT NULL PRIMARY KEY, event_time datetime NOT NULL)
DECLARE @RowsToStage int = CASE WHEN @thisRowsToRetrieve = 2147483647 THEN @thisRowsToRetrieve ELSE @thisRowsToRetrieve + 1 END;

INSERT INTO #TargetEvents (event_id, event_time)
SELECT TOP (@RowsToStage) E.event_id, E.time
FROM dbo.events E
JOIN dbo.event_subtypes es WITH (NOLOCK) ON E.subtype = es.event_subtype_id
JOIN dbo.loc_strings eSubtype WITH (NOLOCK)
	ON es.string_id = eSubtype.string_id AND eSubtype.locale_id = 1033
JOIN dbo.filenames efn WITH (NOLOCK) ON efn.filename_id = E.filename_id
WHERE eSubtype.loc_text = 'New unapproved file to computer'
	AND E.time >= @thisStartdate
	AND E.time < @thisEnddate
	AND efn.filename_ci NOT LIKE '%.jar'
	AND efn.filename_ci NOT LIKE '%.class'
	AND efn.filename_ci NOT LIKE '%.mui'
	AND LEFT(E.param1, 25) NOT IN
			('DiscoveredBy[IntegrityChe', 'DiscoveredBy[ProcessStart',
			 'DiscoveredBy[LoadedImageC', 'DiscoveredBy[AnalysisType')
ORDER BY E.time, E.event_id
OPTION (MAXDOP 1);

IF (SELECT COUNT_BIG(*) FROM #TargetEvents) > @thisRowsToRetrieve
BEGIN
		RAISERROR('The selected window exceeds RowsToRetrieve. Use a smaller, non-overlapping StartDate/EndDate chunk; no partial results were returned.', 16, 1);
		RETURN;
END;

SELECT
  E.time AS 'TimeStamp',
  CONVERT(DATE, E.time , 112) AS 'TimeDate',
  C.hostname AS 'ComputerName',
  p.name AS 'Policy',
  un.username AS 'UserName',
  eSubtype.loc_text AS 'Subtype',
  Case
	When CRd.Name is not null then 'Rule: ' + CRd.Name
	When epn.pathname_ci like '%\netlogon%' then 'Logon Script'
	When epn.pathname_ci like '%\sysvol\%' then 'Logon Script'
	When epn.pathname_ci like '\\%' and  ISNULL(pfn.filename_ci,'') like '\\%' then 'Remote Application'
	When epn.pathname_ci like '\\%' and  ISNULL(pfn.filename_ci,'') not like '\\%' then 'Remote Execution'
	When epn.pathname_ci not like '\\%' and  ISNULL(pfn.filename_ci,'') like '\\%' then 'Remote Writing Local'
	Else 'Unapproved' 
  End as RuleName,
    Case
	When LEFT(ISNULL(E.param1,''),12) = 'DiscoveredBy' then Substring(E.param1,14,CHARINDEX('FileCreated',E.param1)-16)
	Else ''
  End as 'DiscoveredBy',
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
  '"'+REPLACE(REPLACE(REPLACE(pb.name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' AS 'Publisher', 
  CASE WHEN a.publisher = 0 THEN '' ELSE ISNULL(pb.simple_state, 'Unapproved') End as 'PublisherState', 
  isnull(FP.ParityCenterTrust,'') as 'PublisherTrust',
  '"'+REPLACE(REPLACE(REPLACE(co.company,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' AS 'Company', 
  '"'+REPLACE(REPLACE(REPLACE(pn.product_name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' AS 'Product', 
  '"'+REPLACE(REPLACE(REPLACE(pr.product_name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' AS 'ProgramName', 
  a.hash as 'FileHash', 
  case when isnull(PFC.Hash,'') = '' then RFC.Hash else PFC.Hash end as 'RootHash',
  case when isnull(PFC.Hash,'') = '' then '"'+REPLACE(REPLACE(REPLACE(rpb.name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' else '"'+REPLACE(REPLACE(REPLACE(ppb.name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' end as 'RootPublisher',
  case when isnull(PFC.Hash,'') = '' then CASE WHEN RFC.publisher = 0 THEN '' ELSE ISNULL(rpb.simple_state, 'Unapproved') End else  CASE WHEN PFC.publisher = 0 THEN '' ELSE ISNULL(ppb.simple_state, 'Unapproved') End end as 'RootPublisherState',
  case when isnull(PFC.Hash,'') = '' then isnull(RFP.ParityCenterTrust,'') else isnull(PFP.ParityCenterTrust,'') end as 'RootPublisherTrust',
  case when isnull(PFC.Hash,'') = '' then '"'+REPLACE(REPLACE(REPLACE(rco.company,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' else '"'+REPLACE(REPLACE(REPLACE(pco.company,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' end as 'RootCompany',
  case when isnull(PFC.Hash,'') = '' then '"'+REPLACE(REPLACE(REPLACE(rp.product_name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' else '"'+REPLACE(REPLACE(REPLACE(pp.product_name,CHAR(9),' '),CHAR(10),' '),CHAR(13),' ')+'"' end as 'RootProduct',
  case when isnull(PFC.Hash,'') = '' then ISNULL(ram.trust_value, -1) else ISNULL(pam.trust_value, -1) end as 'RootTrust',
  case when isnull(PFC.Hash,'') = '' then dbo.GlobalFlags(RFC.flags|RFC.gen_flags) else dbo.GlobalFlags(PFC.flags|PFC.gen_flags) end as 'RootFileFlags',
  '"'+ISNULL(E.param1,'')+'"' as 'Param1',
  '"'+ISNULL(E.param2,'')+'"' as 'Param2',
  '"'+ISNULL(E.param3,'')+'"' as 'Param3',
  isnull(CRd.Name,'') as 'CustomRuleName',
  replace(replace(isnull(CRd.Process,''),'%','*'),'_','?') as 'CustomRuleProcess',
  replace(replace(isnull(CRd.Path,''),'%','*'),'_','?') as 'CustomRulePath',
  replace(replace(isnull(CRd.UserOrGroup,''),'%','*'),'_','?') as 'CustomRuleUser',
  isnull(CRd.Policies,'') as CustomRulePolicies,
  CRd.LastModified as CustomRuleLastModified
FROM
	#TargetEvents target
	JOIN dbo.events E ON E.event_id = target.event_id
	LEFT JOIN dbo.hostmain C WITH (NOLOCK) ON E.host_id = C.host_id
	LEFT JOIN dbo.host_groups p with (nolock) on p.host_group_id = c.host_group_id
	LEFT JOIN dbo.operating_systems os with (nolock) on os.operating_system_id = C.operating_system_id
	LEFT JOIN dbo.event_subtypes es WITH (nolock) ON e.subtype = es.event_subtype_id
	LEFT JOIN dbo.loc_strings eSubtype WITH (nolock) ON es.string_id = eSubtype.string_id AND eSubtype.locale_id = 1033
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
    outer apply (
		select top 1 *
		from #CustomRules CR
		where isnull(epn.pathname_ci,'') + '\' + isnull(efn.filename_ci,'') like CR.Path
		  and isnull(CASE WHEN ISNULL(os.platform_id,1)=1 THEN ppn.pathname_ci+N'\'+NULLIF(pfn.filename_ci,N'') ELSE ppn.pathname_ci+N'/'+NULLIF(pfn.filename_ci,N'') END,'') like CR.Process
		  and isnull(un.username,'') like CR.UserOrGroup
		  and (CR.Policies = 'All Policies' or CR.Policies = p.name)
		order by RuleRank, Process, Path
	) crd
WHERE
    eSubtype.loc_text = 'New unapproved file to computer' 
AND E.time >= @thisStartdate
AND E.time < @thisEnddate
AND (efn.filename_ci not like '%.jar' AND efn.filename_ci not like '%.class' AND efn.filename_ci not like '%.mui')
AND left(e.param1,25) not in ('DiscoveredBy[IntegrityChe','DiscoveredBy[ProcessStart','DiscoveredBy[LoadedImageC','DiscoveredBy[AnalysisType') 
and not ( isnull(crd.Name,'') <> '' and epn.pathname_ci like '\\%' )
ORDER BY Timestamp DESC
OPTION (MAXDOP 1)
--select * from #CustomRules order by RuleRank, Process, Path
go
IF OBJECT_ID('tempdb..#CustomRules') IS NOT NULL DROP TABLE #CustomRules
IF OBJECT_ID('tempdb..#Variables') IS NOT NULL DROP TABLE #Variables
IF OBJECT_ID('tempdb..#tmpPublisherTrust') IS NOT NULL DROP TABLE #tmpPublisherTrust
IF OBJECT_ID('tempdb..#TargetEvents') IS NOT NULL DROP TABLE #TargetEvents
GO