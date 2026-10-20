-- TvCord report-permission repair.
-- Run in Supabase SQL Editor for the same project used by TvCord.
-- This restores authenticated report submission and lets a reporter read only their own report row.

begin;

alter table public.content_reports enable row level security;
grant insert, select on table public.content_reports to authenticated;
revoke all on table public.content_reports from anon;

drop policy if exists "Users submit reports" on public.content_reports;
create policy "Users submit reports"
on public.content_reports
for insert to authenticated
with check (reporter_id = auth.uid());

drop policy if exists "Users view their own reports" on public.content_reports;
create policy "Users view their own reports"
on public.content_reports
for select to authenticated
using (reporter_id = auth.uid());

commit;
