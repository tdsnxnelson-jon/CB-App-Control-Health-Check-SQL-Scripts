use das
declare @thisStartdate datetime = DATEADD(week, -4, GETDATE())	--<== StartDate
select Subtype as 'Event', Rule_Name as 'Rule', COUNT(*) as Count,
convert(char, Timestamp, 101) as Day
from bit9_public.ExEvents
where Subtype in ('File approved (custom rule)', 'File approved (local approval)', 'File approved (system update)', 'File approved (updater)') and
Timestamp > @thisStartdate
group by Subtype, Rule_Name, convert(char, Timestamp, 101)
	