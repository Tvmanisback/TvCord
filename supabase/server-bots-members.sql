-- Let server members see installed TvCord bots in the members sidebar.
-- Run after supabase/bots.sql and supabase/bot-settings-invites.sql.
create or replace function public.get_tvcord_server_bots(p_server_id uuid)
returns table(bot_id uuid, name text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Log in first.';
  end if;

  if not exists (
    select 1
    from public.server_members sm
    where sm.server_id = p_server_id
      and sm.user_id = auth.uid()
  ) then
    raise exception 'You must be a member of this server to view its bots.';
  end if;

  return query
    select b.id, b.name, bs.created_at
    from public.tvcord_bot_servers bs
    join public.tvcord_bots b on b.id = bs.bot_id
    where bs.server_id = p_server_id
    order by b.name;
end;
$$;

revoke all on function public.get_tvcord_server_bots(uuid) from public, anon;
grant execute on function public.get_tvcord_server_bots(uuid) to authenticated;
