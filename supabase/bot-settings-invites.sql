-- Bot settings and server installs. Run after bots.sql and the main server schema.
create table if not exists public.tvcord_bot_servers (
 bot_id uuid not null references public.tvcord_bots(id) on delete cascade,
 server_id uuid not null references public.servers(id) on delete cascade,
 installed_by uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(bot_id,server_id)
);
alter table public.tvcord_bot_servers enable row level security;
revoke all on public.tvcord_bot_servers from anon,authenticated;
create or replace function public.update_tvcord_bot_settings(p_bot_id uuid,p_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b public.tvcord_bots%rowtype; n text:=btrim(coalesce(p_name,''));
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 if length(n)<1 or length(n)>50 then raise exception 'Bot name must be 1 to 50 characters.'; end if;
 update public.tvcord_bots set name=n where id=p_bot_id and owner_id=auth.uid() returning * into b;
 if not found then raise exception 'Bot not found.'; end if;
 return jsonb_build_object('id',b.id,'name',b.name);
end; $$;
create or replace function public.invite_tvcord_bot_to_server(p_bot_id uuid,p_server_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b public.tvcord_bots%rowtype; s public.servers%rowtype;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 select * into b from public.tvcord_bots where id=p_bot_id and owner_id=auth.uid();
 if not found then raise exception 'Bot not found or not owned by you.'; end if;
 if not public.can_manage_server(p_server_id) then raise exception 'You must own or manage that server to invite a bot.'; end if;
 select * into s from public.servers where id=p_server_id;
 if not found then raise exception 'Server not found.'; end if;
 insert into public.tvcord_bot_servers(bot_id,server_id,installed_by) values(b.id,s.id,auth.uid()) on conflict do nothing;
 return jsonb_build_object('ok',true,'bot_id',b.id,'server_id',s.id,'server_name',s.name);
end; $$;
create or replace function public.get_my_tvcord_bot_servers(p_bot_id uuid)
returns table(server_id uuid,server_name text,installed_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 if not exists(select 1 from public.tvcord_bots where id=p_bot_id and owner_id=auth.uid()) then raise exception 'Bot not found or not owned by you.'; end if;
 return query select s.id,s.name,bs.created_at from public.tvcord_bot_servers bs join public.servers s on s.id=bs.server_id where bs.bot_id=p_bot_id order by s.name;
end; $$;
create or replace function public.remove_tvcord_bot_from_server(p_bot_id uuid,p_server_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 if not exists(select 1 from public.tvcord_bots where id=p_bot_id and owner_id=auth.uid()) then raise exception 'Bot not found or not owned by you.'; end if;
 if not public.can_manage_server(p_server_id) then raise exception 'You must own or manage that server.'; end if;
 delete from public.tvcord_bot_servers where bot_id=p_bot_id and server_id=p_server_id;
 return found;
end; $$;
revoke all on function public.update_tvcord_bot_settings(uuid,text) from public,anon;
revoke all on function public.invite_tvcord_bot_to_server(uuid,uuid) from public,anon;
revoke all on function public.get_my_tvcord_bot_servers(uuid) from public,anon;
revoke all on function public.remove_tvcord_bot_from_server(uuid,uuid) from public,anon;
grant execute on function public.update_tvcord_bot_settings(uuid,text) to authenticated;
grant execute on function public.invite_tvcord_bot_to_server(uuid,uuid) to authenticated;
grant execute on function public.get_my_tvcord_bot_servers(uuid) to authenticated;
grant execute on function public.remove_tvcord_bot_from_server(uuid,uuid) to authenticated;
