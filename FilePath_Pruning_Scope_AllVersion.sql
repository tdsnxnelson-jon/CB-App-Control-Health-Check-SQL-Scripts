-- ------------------------------------------------------------
-- STEP A: Get counts for orphaned PATH and FILE names
-- ------------------------------------------------------------
use DAS

GO
set nocount on
-- 1. Set statistics (so we can see the time it takes)
SET STATISTICS TIME on
SET STATISTICS IO on

-- 2. Declare variables
declare @Orph_PATHNAME decimal(15,2);
declare @Orph_FILENAME decimal(15,2);

-- 3. Get orphaned pathnames
-- select count(1) from [dbo].[OrphanedPathnameIds] (nolock)
select @Orph_PATHNAME = count(1) from dbo.pathnames with(nolock) where pathname_id not in (
			select distinct pathname_id from dbo.antibodies with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.antibody_instances with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.antibody_instances_deleted with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.antibody_instance_groups with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.temp_antibody_instances with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.processing_temp_antibody_instances1 with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.processing_temp_antibody_instances2 with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.processing_temp_antibody_instances3 with (nolock) where pathname_id is not null
			union
			select distinct old_pathname_id from dbo.temp_antibody_instances with (nolock) where old_pathname_id is not null
			union
			select distinct old_pathname_id from dbo.processing_temp_antibody_instances1 with (nolock) where old_pathname_id is not null
			union
			select distinct old_pathname_id from dbo.processing_temp_antibody_instances2 with (nolock) where old_pathname_id is not null
			union
			select distinct old_pathname_id from dbo.processing_temp_antibody_instances3 with (nolock) where old_pathname_id is not null
			union
			select distinct pathname_id from dbo.antibody_instances_snapshots with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.approval_requests with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.internal_events with (nolock) where pathname_id is not null
			union
			select distinct process_pathname_id from dbo.internal_events with (nolock) where process_pathname_id is not null
			union
			select distinct process_pathname_id from dbo.events with (nolock) where process_pathname_id is not null
			union
			select distinct process_pathname_id from dbo.remote_events with (nolock) where process_pathname_id is not null
			union
			select distinct process_pathname_id from dbo.remote_internal_events with (nolock) where process_pathname_id is not null
			union
			select distinct process_pathname_id from dbo.approval_requests with (nolock) where process_pathname_id is not null
			union
			select distinct pathname_id from dbo.events with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.remote_events with (nolock) where pathname_id is not null
			union
			select distinct pathname_id from dbo.remote_internal_events with (nolock) where pathname_id is not null
			union
			select distinct file_path_id from dbo.notification_files with (nolock) where file_path_id is not null
			union
			select distinct proc_path_id from dbo.notification_files with (nolock) where proc_path_id is not null
			union
			select distinct proc_path_id from dbo.notification_directories with (nolock) where proc_path_id is not null
			union
			select distinct dir_path_id from dbo.notification_directories with (nolock) where dir_path_id is not null
			union
			select distinct proc_path_id from dbo.notification_regkeys with (nolock) where proc_path_id is not null
			union
			select distinct pathname_id from dbo.uploaded_files with (nolock) where pathname_id is not null
		)



print '   Count of orphaned PATH names: ' + CONVERT(varchar(50), CAST(@Orph_PATHNAME AS money), 1) + ' rows'

-- 4. Get orphaned filenames
--select @Orph_FILENAME = count(1) from [dbo].[OrphanedfilenameIds] (nolock)
	select @Orph_FILENAME = count(1) from dbo.filenames with(nolock) where filename_id not in (
			select distinct filename_id from dbo.antibodies with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.antibody_instances with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.antibody_instances_deleted with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.antibody_instance_groups with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.temp_antibody_instances with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.processing_temp_antibody_instances1 with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.processing_temp_antibody_instances2 with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.processing_temp_antibody_instances3 with (nolock) where filename_id is not null
			union
			select distinct old_filename_id from dbo.temp_antibody_instances with (nolock) where old_filename_id is not null
			union
			select distinct old_filename_id from dbo.processing_temp_antibody_instances1 with (nolock) where old_filename_id is not null
			union
			select distinct old_filename_id from dbo.processing_temp_antibody_instances2 with (nolock) where old_filename_id is not null
			union
			select distinct old_filename_id from dbo.processing_temp_antibody_instances3 with (nolock) where old_filename_id is not null
			union
			select distinct filename_id from dbo.antibody_instances_snapshots with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.approval_requests with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.internal_events with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.events with (nolock) where filename_id is not null
			union
			select distinct process_filename_id from dbo.internal_events with (nolock) where process_filename_id is not null
			union
			select distinct process_filename_id from dbo.events with (nolock) where process_filename_id is not null
			union
			select distinct filename_id from dbo.remote_internal_events with (nolock) where filename_id is not null
			union
			select distinct filename_id from dbo.remote_events with (nolock) where filename_id is not null
			union
			select distinct process_filename_id from dbo.remote_internal_events with (nolock) where process_filename_id is not null
			union
			select distinct process_filename_id from dbo.remote_events with (nolock) where process_filename_id is not null
			union
			select distinct process_filename_id from dbo.approval_requests with (nolock) where process_filename_id is not null
			union
			select distinct file_name_id from dbo.notification_files with (nolock) where file_name_id is not null
			union
			select distinct proc_name_id from dbo.notification_files with (nolock) where proc_name_id is not null
			union
			select distinct proc_name_id from dbo.notification_directories with (nolock) where proc_name_id is not null
			union
			select distinct proc_name_id from dbo.notification_regkeys with (nolock) where proc_name_id is not null
			union
			select distinct filename_id from dbo.uploaded_files with (nolock) where filename_id is not null
		)


print '   Count of orphaned FILE names: ' + CONVERT(varchar(50), CAST(@Orph_FILENAME AS money), 1) + ' rows'

-- ------------------------------------------------------------
-- STEP B: Get total row counts and space for tables
-- ------------------------------------------------------------

Declare @tmp table (TableName varchar(30), RowsCount bigint, TotalSpaceKB bigint, UsedSpaceKB bigint, UnusedSpaceKB bigint, OrphanedRowsCount bigint, OrphanedPercent decimal(9,6), OrphanedSpaceKB bigint, NonOrphanedSpaceKB bigint)
-- 5. Get table stats

insert into @tmp (TableName, RowsCount, TotalSpaceKB, UsedSpaceKB, UnusedSpaceKB, OrphanedRowsCount)
SELECT 
    t.NAME AS TableName,
       p.rows as 'RowCount',
    SUM(a.total_pages) * 8 AS TotalSpaceKB, 
    SUM(a.used_pages) * 8 AS UsedSpaceKB, 
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8 AS UnusedSpaceKB,
	case when  t.name = 'pathnames' then @Orph_PATHNAME
		when t.name = 'filenames' then @Orph_FILENAME
	end
FROM 
    sys.tables t
INNER JOIN      
    sys.indexes i ON t.OBJECT_ID = i.object_id
INNER JOIN 
    sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
INNER JOIN 
	sys.allocation_units a ON (a.type IN (1, 3) AND p.hobt_id = a.container_id)
		OR (a.type = 2 AND p.partition_id = a.container_id)
LEFT OUTER JOIN 
    sys.schemas s ON t.schema_id = s.schema_id
WHERE 
    t.NAME NOT LIKE 'dt%' 
    AND t.is_ms_shipped = 0
    AND i.OBJECT_ID > 255 
       AND t.name in ('pathnames','filenames')
GROUP BY 
    t.Name, s.Name, p.Rows
ORDER BY 
    UsedSpaceKB desc


-- ------------------------------------------------------------
-- STEP C: Calculate
-- ------------------------------------------------------------
-- Calculate orphaned percent
update @tmp set OrphanedPercent = cast(OrphanedRowsCount as decimal(20,2)) / cast(RowsCount as decimal(20,2)) ;

-- Calculate orphaned space and non-orphaned space
update @tmp set OrphanedSpaceKB = UsedSpaceKB * OrphanedPercent;
update @tmp set NonOrphanedSpaceKB = UsedSpaceKB - OrphanedSpaceKB;

-- ------------------------------------------------------------
-- STEP D: Return the results
-- ------------------------------------------------------------
select * from @tmp;


-- 6. turn statistics back to off
SET STATISTICS TIME off
SET STATISTICS IO off
