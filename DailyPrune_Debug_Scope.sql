use DAS;
set nocount on
select getdate() as 'Start Time'
select name,value from shepherd_configs where name in ('DBSchemaVersion', 'ParityServerVersion') ;
select * from dbo.validation_schema ;
print ''

-- ---------------------------------------------------------------------
-- Title:	DailyPruneTask Debug
-- Description: To help identify where the DailyPruneTask may be 
--				erroring out and to give you the expected results.
-- ---------------------------------------------------------------------
-- Step 1: ProcessDailyStats (does it run or not)
-- ---------------------------------------------------------------------
		print ''
		print '------------------------------------------------------------------'
		print 'Step 1: ProcessDailyStats (does it run or not)'
		print '------------------------------------------------------------------'
		print ''
		-- Intentionally not executed: this diagnostic must not modify customer data.
		print 'Skipped ProcessDailyStats (maintenance action; run separately if approved)'

------------------------------------------------------------------------
-- Step 2: Scope: PruneDeletedAntibodyInstancesAndGroups
------------------------------------------------------------------------

		DECLARE @chunk_size INTEGER
		SET @chunk_size = (SELECT chunk_size FROM dbo.scheduled_tasks WITH (nolock) WHERE task = 'DailyPruneTask') 

		declare @maxDeletedAgeSec int;
		SET @maxDeletedAgeSec = CONVERT(INTEGER, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeFileInstancePeriod'))
		IF ISNULL(@maxDeletedAgeSec, -1)<0 
			SET @maxDeletedAgeSec = CONVERT(INTEGER, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeEventLogPeriod'))
		SET @maxDeletedAgeSec = ISNULL(@maxDeletedAgeSec, -1)
		print '------------------------------------------------------------------'
		print 'chunk_size:  [' + convert(varchar(20),@chunk_size) + ']';
		print 'maxDeletedAgeSec (from PurgeFileInstancePeriod or PurgeEventLogPeriod): [' + convert(varchar(20),@maxDeletedAgeSec) + ']';
		print 'Cutoff Date: [' + convert(varchar(30), dateadd(second, -@maxDeletedAgeSec, GETUTCDATE())) + '] '
		print '(post-prune we should have nothing older than this date)';
		print '------------------------------------------------------------------'
		-- > PruneDeletedAntibodyInstancesAndGroups

		-- step 1: prune old deleted files 			
		-- 		   Table: [antibody_instances_deleted]
			print ''
			print '------------------------------------------------------------------'
			print 'Step 2: PruneDeletedAntibodyInstancesAndGroups - Table [antibody_instances_deleted]'
			print '------------------------------------------------------------------'
			print '';

			select case when date_deleted < dateadd(second, -@maxDeletedAgeSec, GETUTCDATE()) then 'DELETE' else 'KEEP' end as 'Table: [antibody_instances_deleted]',
				count(1) 'count'
				from dbo.antibody_instances_deleted (nolock)
				group by case when date_deleted < dateadd(second, -@maxDeletedAgeSec, GETUTCDATE()) then 'DELETE' else 'KEEP' end

			select 'Max date_deleted' as 'Table: [antibody_instances_deleted]', max(date_deleted) 
				from dbo.antibody_instances_deleted (nolock)
			union
			select 'Min date_deleted'  as 'Table: [antibody_instances_deleted]', Min(date_deleted) 
				from dbo.antibody_instances_deleted (nolock)

			print 'Table: [antibody_instances_deleted]'
			
			select convert(varchar, date_deleted, 111) 'date_deleted', count(1) 'Count'
				from dbo.antibody_instances_deleted (nolock)
				group by convert(varchar, date_deleted, 111)
				order by convert(varchar, date_deleted, 111)

		-- step 2: mark old ab groups for deletion (fill in date_zero_file_count with GetUTCDate())
		-- 		   Table: [antibody_instance_groups]
			print ''
			print '------------------------------------------------------------------'
			print 'Step 2: PruneDeletedAntibodyInstancesAndGroups - Table [antibody_instance_groups]'
			print '------------------------------------------------------------------'
			print ''
			-- EXEC dbo.DropTable '#jtmpAIG'
			
			-- SELECT aig.antibody_instance_group_id INTO #jtmpAIG 
			-- 	FROM dbo.antibody_instance_groups aig WITH (nolock) 
			-- 	LEFT JOIN (
			-- 			SELECT antibody_instance_group_id 
			-- 			FROM dbo.antibody_instances WITH (nolock) 
			-- 			GROUP BY antibody_instance_group_id
			-- 		) 
			-- 		a ON a.antibody_instance_group_id=aig.antibody_instance_group_id
			-- 	WHERE date_zero_file_count IS NULL AND a.antibody_instance_group_id IS NULL
	
		-- step 3: delete these 
		-- 		   Table: [antibody_instance_groups]
			SET @maxDeletedAgeSec = ISNULL(CONVERT(INTEGER, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeFileInstanceGroupPeriod')), -1)
			print '------------------------------------------------------------------'
			print 'chunk_size:  [' + convert(varchar(20),@chunk_size) + ']';
			print 'maxDeletedAgeSec (from PurgeFileInstanceGroupPeriod): [' + convert(varchar(20),@maxDeletedAgeSec) + ']';
			print 'Cutoff Date: [' + convert(varchar(30), dateadd(second, -@maxDeletedAgeSec, GETUTCDATE())) + '] '
			print '(post-prune we should have nothing older than this date)';
			print '------------------------------------------------------------------'
			EXEC dbo.DropTable '#AIG_TO_DELETE'
			SELECT antibody_instance_group_id
				INTO #AIG_TO_DELETE
				FROM dbo.antibody_instance_groups WITH (nolock)
				WHERE 
					(
						(date_zero_file_count IS NOT NULL )
						AND
						(type<=1 OR date_zero_file_count < DATEADD(second, -@maxDeletedAgeSec, GETUTCDATE()))
					);
			
			select case when isnull(F.antibody_instance_group_id, 0) = 0 then 'KEEP' else 'DELETE' end as 'Table: [antibody_instance_groups]',  count(1) 'Count'
				FROM dbo.antibody_instance_groups (nolock) AG
				left  join #AIG_TO_DELETE F on AG.antibody_instance_group_id = F.antibody_instance_group_id
				group by case when isnull(F.antibody_instance_group_id, 0) = 0 then 'KEEP' else 'DELETE' end
	

			select 'Max date_zero_file_count' as 'Table: [antibody_instance_groups]', max(date_zero_file_count) 
				from dbo.antibody_instance_groups (nolock)
			union
			select 'Min date_zero_file_count'  as 'Table: [antibody_instance_groups]', Min(date_zero_file_count) 
				from dbo.antibody_instance_groups (nolock)

			print 'Table: [antibody_instance_groups]'
			select convert(varchar, date_zero_file_count, 111), count(1)
				from antibody_instance_groups (nolock)
				group by convert(varchar, date_zero_file_count, 111)
				order by convert(varchar, date_zero_file_count, 111)


-- --------------------------------------------
-- Step 3: Scope - PruneAntibodies
-- --------------------------------------------
			print ''
			print '------------------------------------------------------------------'
			print 'Step 3: Scope - PruneAntibodies'
			print '------------------------------------------------------------------'
			print ''
			DECLARE @maxAgeDays INTEGER, @rowcnt INTEGER
			SET @maxAgeDays = CONVERT(INTEGER, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeAntibodiesPeriodDays'))
			
			print 'Table: [antibodies]'
			IF (ISNULL(@maxAgeDays, 0)>0)
				BEGIN
						print 'maxAgeDays (from PurgeAntibodiesPeriodDays): [' + convert(varchar(20),@maxAgeDays) + ']';
						print 'Cutoff Date: [' + convert(varchar(30), dateadd(day, -@maxAgeDays, GETUTCDATE())) + '] (post-prune we should have nothing older than this date)';
						print '------------------------------------------------------------------'
				end
			IF (ISNULL(@maxAgeDays, 0)=0)
				begin
					print 'No max age defined for [antibodies]; this is the shepherd config value [PurgeAntibodiesPeriodDays]'
				end

			select 'Total row count' as 'Table: [antibodies]', count(1) 'Count' from antibodies  (nolock) B
			union 
			select '0 prev count' as 'Table: [antibodies]', count(1) 'Count' from antibodies  (nolock) B where isnull(b.date_zero_file_count,0) > 0
			union 
			select '0 prev count that meet the criterion' as 'Table: [antibodies]', count(1) 'Count' 
				from antibodies  (nolock)
				WHERE 
					date_zero_file_count is not null and date_zero_file_count < dateadd(day, -@maxAgeDays, GETUTCDATE())
					AND NOT EXISTS (SELECT 1 FROM dbo.file_rules fr WITH (nolock) WHERE fr.antibody_id = antibodies.antibody_id)
					AND NOT EXISTS (SELECT 1 FROM dbo.antibody_groups ag WITH (nolock) WHERE ag.antibody_id = antibodies.antibody_id)
					AND NOT EXISTS (SELECT 1 FROM dbo.antibody_instance_groups aig WITH (nolock) WHERE aig.antibody_id = antibodies.antibody_id)
					AND NOT EXISTS (SELECT 1 FROM dbo.antibody_instances_snapshots ais WITH (nolock) WHERE ais.antibody_id = antibodies.antibody_id)

					
			select convert(varchar, creation_date, 111) 'Date', 
				count(1) 'Total_Count_of_ABs_By_Creation_Date', 
				0 '0_prev_by_Zero_fill_Date',
				0 '0_prev_that_meet_criterion_by_Zero_fill_Date',
				0 'file_rules', 0 'ab_groups', 0 'ab_instance_groups', 0 'ab_instances_snapshots', 0 'totals'
				into #jtmp
				from antibodies  (nolock) B
				group by convert(varchar, creation_date, 111)
				order by convert(varchar, creation_date, 111);

			;with cte as
			(
			select count(1) 'Count', convert(varchar, date_zero_file_count, 111) 'date_zero_file_count'
				from antibodies  (nolock) B
				where
					date_zero_file_count is not null and date_zero_file_count < dateadd(day, -@maxAgeDays, GETUTCDATE())
				group by convert(varchar, date_zero_file_count, 111)
			)
			update #jtmp
				set #jtmp.[0_prev_by_Zero_fill_Date] = cte.Count
				from  #jtmp
				join cte on cte.date_zero_file_count = #jtmp.Date

			;with cte as
			(
			select count(1) 'Count', convert(varchar, date_zero_file_count, 111) 'date_zero_file_count'
				from antibodies  (nolock) B
				where
					date_zero_file_count is not null and date_zero_file_count < dateadd(day, -@maxAgeDays, GETUTCDATE())
					AND NOT EXISTS (SELECT 1 FROM dbo.file_rules fr WITH (nolock) WHERE fr.antibody_id = B.antibody_id)
					AND NOT EXISTS (SELECT 1 FROM dbo.antibody_groups ag WITH (nolock) WHERE ag.antibody_id = B.antibody_id)
					AND NOT EXISTS (SELECT 1 FROM dbo.antibody_instance_groups aig WITH (nolock) WHERE aig.antibody_id = B.antibody_id)
					AND NOT EXISTS (SELECT 1 FROM dbo.antibody_instances_snapshots ais WITH (nolock) WHERE ais.antibody_id = B.antibody_id)
				group by convert(varchar, date_zero_file_count, 111)
			)
			update #jtmp
				set #jtmp.[0_prev_that_meet_criterion_by_Zero_fill_Date] = cte.Count
				from  #jtmp
				join cte on cte.date_zero_file_count = #jtmp.Date


			EXEC dbo.DropTable '#jtmp2'
			select antibody_id, date_zero_file_count
				into #jtmp2
				from antibodies (nolock) B
				where isnull(b.date_zero_file_count,0) > 0 ;

			-- File Rules
			;with cte as
			(
				select count(1) 'count', convert(varchar, A.date_zero_file_count, 111) 'date_zero_file_count'
					from #jtmp2 A
					join file_rules B with (nolock) on A.antibody_id = B.antibody_id
					group by convert(varchar, A.date_zero_file_count, 111)
			
			)	
			update #jtmp
				set #jtmp.file_rules = cte.count
				from #jtmp
				join cte on cte.date_zero_file_count = #jtmp.Date;

			-- antibody_groups
			;with cte as
			(
				select count(1) 'count', convert(varchar, A.date_zero_file_count, 111) 'date_zero_file_count'
					from #jtmp2 A
					join antibody_groups B with (nolock) on A.antibody_id = B.antibody_id
					group by convert(varchar, A.date_zero_file_count, 111)
			
			)	
			update #jtmp
				set #jtmp.ab_groups = cte.count
				from #jtmp
				join cte on cte.date_zero_file_count = #jtmp.Date;
			

			-- antibody_instance_groups
			;with cte as
			(
				select count(1) 'count', convert(varchar, A.date_zero_file_count, 111) 'date_zero_file_count'
					from #jtmp2 A
					join antibody_instance_groups B with (nolock) on A.antibody_id = B.antibody_id
					group by convert(varchar, A.date_zero_file_count, 111)
			
			)	
			update #jtmp
				set #jtmp.ab_instance_groups = cte.count
				from #jtmp
				join cte on cte.date_zero_file_count = #jtmp.Date;



			-- antibody_instances_snapshots
			;with cte as
			(
				select count(1) 'count', convert(varchar, A.date_zero_file_count, 111) 'date_zero_file_count'
					from #jtmp2 A
					join antibody_instances_snapshots B with (nolock) on A.antibody_id = B.antibody_id
					group by convert(varchar, A.date_zero_file_count, 111)
			
			)	
			update #jtmp
				set #jtmp.ab_instances_snapshots = cte.count
				from #jtmp
				join cte on cte.date_zero_file_count = #jtmp.Date;

			select * from #jtmp;



-- --------------------------------------------
-- Step 4: TODO - finish scope on these ones (they are not usually the problem)
-- --------------------------------------------
		-- Still to Cope
				--		DELETE FROM dbo.antibody_drift_variables WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.antibody_groups_antibodies WHERE antibody_id IN (select antibody_id FROM #del_antibodies)      
				--		DELETE FROM dbo.antibodies_usage_count WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.antibodies_lookup WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.antibody_instances_deleted WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.antibody_metadata WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.antibody_states WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.paritycenter_antibody_metadata WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.alert_event_data WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)
				--		DELETE FROM dbo.antibody_groups_antibodies WHERE antibody_id IN (SELECT antibody_id FROM #del_antibodies)


		--	EXEC dbo.UpdateShepherdConfig 'DBMaintenanceInProgress', '0'
		--	EXEC dbo.PruneStatistics
		--	EXEC dbo.EventCountingCleanup
		--	EXEC dbo.RemediateAntibodyErrors
		--	EXEC dbo.EventPruneTask @chunk_size 


-- --------------------------------------------
-- Step 5: SCOPE - EventPruneTask
-- --------------------------------------------
			print ''
			print '------------------------------------------------------------------'
			print 'Step 5: SCOPE - EventPruneTask'
			print '------------------------------------------------------------------'
			print ''
			DECLARE @threshold bigint, @target BIGINT, @maxEventAgeSec INTEGER
			SET @threshold = CONVERT(bigint, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeEventThreshold'))
			SET @target = CONVERT(bigint, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeEventTarget'))
			SET @maxEventAgeSec = CONVERT(INTEGER, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeEventLogPeriod'))

	
--			EXEC dbo.EventPruning @maxEventAgeSec, @threshold, @target, @chunk_size, 'events'
	
--				> EventPruning (events only, still need to do internalevents)
			
--					-- Max Age (@maxEventAgeSec => 	@max_age_sec => @targetTime_IN)
			declare @targetTime datetime;
			SET @targetTime = dateadd(second, -@maxEventAgeSec, GETUTCDATE())

			print 'Table: Events'
			print 'Max Age - maxEventAgeSec: [' + convert(varchar(20),@maxEventAgeSec) + ']';
			print 'Cutoff Date: [' + convert(varchar(30), @targetTime) + '] (post-prune we should have nothing older than this date)';
			

			--	delete FROM dbo.events WHERE date_created < @targetTime_IN

			select case when date_created < @targetTime then 'DELETE' else 'KEEP' end as 'Table: [events]',
				count(1) 'count'
				from dbo.events (nolock)
				group by case when date_created < @targetTime then 'DELETE' else 'KEEP' end

			select 'Max date_created' as 'Table: [events]', MAX(date_created) 
				from dbo.events (nolock)
			union
			select 'Min date_created'  as 'Table: [events]', Min(date_created) 
				from dbo.events (nolock)
			
			print 'Table: [events]'
			
			select convert(varchar, date_created, 111) 'date_created', count(1) 'Count'
				from dbo.events (nolock)
				group by convert(varchar, date_created, 111)
				order by convert(varchar, date_created, 111)

--					-- Max Size (@threshold => @max_size
--					-- Delete Percentage (@target => @delete_perc)
			declare @rowct bigint;
			SET @rowct = 0;
			SELECT @rowct = MAX(rows) FROM dbo.sysindexes WITH (nolock) WHERE id = OBJECT_ID('events') AND indid < 2

			DECLARE @max_event_id bigint
			SELECT @max_event_id = MAX (event_id) FROM dbo.events WITH (nolock);

			DECLARE @min_event_id bigint
			SELECT @min_event_id = MIN(event_id) FROM dbo.events WITH (nolock);

			DECLARE @New_min_event_id bigint
			SELECT @New_min_event_id = MIN(event_id) FROM dbo.events WITH (nolock)
				where date_created > @targetTime
			;
			
			DECLARE @new_size bigint
			declare @max_size bigint;
			declare @delete_perc int;
			set @delete_perc = @target;
			set @max_size = @threshold;
			SET @new_size = ( @max_size * ( (100 - @delete_perc )) / 100)
			
			declare @NewMaxSize bigint;
			set @NewMaxSize = @max_event_id - @new_size;

			print 'Table: Events'
			print 'Row Count: [' + convert(varchar(20), @rowct) + ']'
			print '@max_event_id: [' + convert(varchar(20), @max_event_id) + ']'
			print '@min_event_id: [' + convert(varchar(20), @min_event_id) + ']'
			print 'Max size (@max_size): [' + convert(varchar(20),@max_size) + ']';
			print 'Percent (@delete_perc): [' + convert(varchar(20),@delete_perc) + ']';
			print 'New Size (@new_size): [' + convert(varchar(20),@new_size) + ']';
			print 'New Min Event ID (@NewMaxSize): [' + convert(varchar(20),@NewMaxSize) + ']';
			
			if (@max_size is not null and @max_size <> 0 and @delete_perc is not null and @delete_perc > 0 and @delete_perc <= 100)
				begin
					if (@rowct > @max_size)
						begin
							select case when event_id < @NewMaxSize then 'DELETE' else 'KEEP' end as 'Table: [events]',
								count(1) 'count'
								from dbo.events (nolock)
								group by case when event_id < @NewMaxSize then 'DELETE' else 'KEEP' end

							
						end
				end

			select case when event_id < @New_min_event_id then 'DELETE' else 'KEEP' end as 'Table: [event_rule_events]',
				count(1) 'count'
				from dbo.event_rule_events (nolock)
				group by case when event_id < @New_min_event_id then 'DELETE' else 'KEEP' end

			select case when event_id < @New_min_event_id then 'DELETE' else 'KEEP' end as 'Table: [alert_event_data]',
				count(1) 'count'
				from dbo.alert_event_data (nolock)
				group by case when event_id < @New_min_event_id then 'DELETE' else 'KEEP' end

-- --------------------------------------------
-- Step 6: SCOPE - Delete Tracked Files
-- --------------------------------------------
	print ''
	print '------------------------------------------------------------------'
	print 'Step 6: SCOPE - Delete Tracked Files'
	print '------------------------------------------------------------------'
	print ''
			
	DECLARE @deleteDisabledTrackingThresholdHours INTEGER, @deleteThresholdHours INTEGER
	-- Get deletion threshold for pruning obsolete instances (deleted or non-tracking hosts)
	SELECT @deleteThresholdHours = CAST(value AS INTEGER) FROM dbo.shepherd_configs (nolock) WHERE name='ConfigurationTrackingDeleteRetentionHours'
	SELECT @deleteDisabledTrackingThresholdHours = CAST(value AS INTEGER) FROM dbo.shepherd_configs (nolock) WHERE name='ConfigurationTrackingDisabledDeleteRetentionHours'
	SET @deleteThresholdHours = ISNULL(@deleteThresholdHours, -1)
	SET @deleteDisabledTrackingThresholdHours = ISNULL(@deleteDisabledTrackingThresholdHours, -1)

	select @deleteDisabledTrackingThresholdHours
	select @deleteThresholdHours
	
	;with cte as
	(
		SELECT host_id FROM dbo.hostmain WITH (nolock)
		WHERE 
			(
				(
					@deleteDisabledTrackingThresholdHours>=0 AND
					host_group_id IN (
						SELECT host_group_id FROM dbo.host_groups WITH (nolock)
						WHERE date_tracking_disabled IS NOT NULL AND
							date_tracking_disabled<dateadd(hour, -@deleteDisabledTrackingThresholdHours, getdate())
					)
				)
				OR 
				(
					@deleteThresholdHours >= 0 AND deleted=1 AND 
					(delete_date IS NULL OR delete_date<dateadd(hour, -@deleteThresholdHours, getdate())) 
				)
				OR 
				(
					@deleteThresholdHours >= 0 AND upgrade_state & 8 = 8 AND -- Uninstalled
					(uninstall_date IS NULL OR uninstall_date<dateadd(hour, -@deleteThresholdHours, getdate())) 
				)
			)
			AND EXISTS (SELECT * FROM dbo.antibody_instances ai WITH (nolock) WHERE ai.host_id = hostmain.host_id)
		)
		select count(1) 'Count of hosts included in Deleted Tracked Hosts' from cte;		
		

-- --------------------------------------------
-- Step 7: TODO - finish scope on these ones (they are not usually the problem)
-- --------------------------------------------
		--	EXEC dbo.NotificationPruneTask @chunk_size 
		--	EXEC dbo.VerifyDatabaseSizeLimit
		--	EXEC dbo.PruneFileUploads @chunk_size
		--	EXEC dbo.console_Update_PortletData_SoftwareCategories
		--	EXEC dbo.PruneExpiredSessions @chunk_size

		--	EXEC dbo.MeterPruning @chunk_size
		--	EXEC dbo.PruneDeletedHosts
		--	EXEC dbo.PruneAlerts @chunk_size
		--	-- Daily truncation of duplicate hosts table

-- --------------------------------------------
-- Step 8: Clean up
-- --------------------------------------------		
EXEC dbo.DropTable '#jtmpAIG'
EXEC dbo.DropTable '#AIG_TO_DELETE'
EXEC dbo.DropTable '#jtmp'
EXEC dbo.DropTable '#jtmp2'

select getdate() as 'End Time'