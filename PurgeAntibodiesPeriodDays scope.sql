use das;

 

print ''

print '------------------------------------------------------------------'

print 'Step 2: Scope - PruneAntibodies'

print '------------------------------------------------------------------'

print ''

DECLARE @maxAgeDays INTEGER, @rowcnt INTEGER

SET @maxAgeDays = CONVERT(INTEGER, (SELECT value FROM dbo.shepherd_configs (nolock) WHERE name = 'PurgeAntibodiesPeriodDays'))

print 'Table: [antibodies]'

IF (ISNULL(@maxAgeDays, 0)>0)

BEGIN

print 'maxAgeDays: [' + convert(varchar(20),@maxAgeDays) + ']';

print 'Cutoff Date: [' + convert(varchar(30), dateadd(day, -@maxAgeDays, GETUTCDATE())) + '] (post-prune we should have nothing older than this date)';

print '------------------------------------------------------------------'

end

IF (ISNULL(@maxAgeDays, 0)=0)

begin

print 'No max age defined for [antibodies]; this is the shepherd config value [PurgeAntibodiesPeriodDays]'

end

select 'Total row count' as 'Table: [antibodies]', count(1) 'Count' from antibodies (nolock) B

union

select '0 prev count' as 'Table: [antibodies]', count(1) 'Count' from antibodies (nolock) B where isnull(b.date_zero_file_count,0) > 0

union

select '0 prev count that meet the criterion' as 'Table: [antibodies]', count(1) 'Count'

from antibodies (nolock) B

WHERE

date_zero_file_count is not null and date_zero_file_count < dateadd(day, -@maxAgeDays, GETUTCDATE())

AND NOT EXISTS (SELECT 1 FROM dbo.file_rules fr WITH (nolock) WHERE fr.antibody_id = B.antibody_id)
AND NOT EXISTS (SELECT 1 FROM dbo.antibody_groups ag WITH (nolock) WHERE ag.antibody_id = B.antibody_id)
AND NOT EXISTS (SELECT 1 FROM dbo.antibody_instance_groups aig WITH (nolock) WHERE aig.antibody_id = B.antibody_id)
AND NOT EXISTS (SELECT 1 FROM dbo.antibody_instances_snapshots ais WITH (nolock) WHERE ais.antibody_id = B.antibody_id)