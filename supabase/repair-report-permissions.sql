-- TvCord report permission repair. Safe to rerun in Supabase SQL Editor.
begin;
alter table public.content_reports enable row level security;
grant usage on schema public to authenticated;
grant insert, select on table public.content_reports to authenticated;
revoke all on table public.content_reports from anon;
drop policy if exists "Users submit reports" on public.content_reports;
create policy "Users submit reports" on public.content_reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists "Users view their own reports" on public.content_reports;
create policy "Users view their own reports" on public.content_reports for select to authenticated using (reporter_id = auth.uid());
commit;
