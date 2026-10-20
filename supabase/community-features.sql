-- TvCord community systems: server profiles, discovery, roles, custom emoji and TvBoosters.
-- Run in Supabase SQL Editor after schema.sql and social.sql.

alter table public.servers
  add column if not exists banner_url text,
  add column if not exists description text not null default '',
  add column if not exists level integer not null default 1 check (level >= 1),
  add column if not exists total_boosters integer not null default 0 check (total_boosters >= 0),
  add column if not exists discoverable boolean not null default false;

create table if not exists public.server_roles (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 32),
  color text not null default '#aeb4c0' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  unique(server_id, name)
);
create table if not exists public.member_roles (
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references public.server_roles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(server_id,user_id,role_id)
);
create table if not exists public.server_emojis (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (name ~ '^[a-zA-Z0-9_]{2,32}$'),
  image_url text not null,
  uploaded_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(server_id,name)
);
create table if not exists public.tvbooster_wallets (
  user_id uuid not null references auth.users(id) on delete cascade,
  month_start date not null,
  balance integer not null default 2 check (balance >= 0),
  primary key(user_id,month_start)
);
create index if not exists server_roles_server_idx on public.server_roles(server_id,position);
create index if not exists server_emojis_server_idx on public.server_emojis(server_id);
create index if not exists servers_discovery_idx on public.servers(discoverable,level);

alter table public.server_roles enable row level security;
alter table public.member_roles enable row level security;
alter table public.server_emojis enable row level security;
alter table public.tvbooster_wallets enable row level security;
revoke all on public.tvbooster_wallets from anon,authenticated;

drop policy if exists "Members view server roles" on public.server_roles;
create policy "Members view server roles" on public.server_roles for select to authenticated using (public.is_server_member(server_id));
drop policy if exists "Managers manage server roles" on public.server_roles;
create policy "Managers manage server roles" on public.server_roles for all to authenticated using (public.can_manage_server(server_id)) with check (public.can_manage_server(server_id));
drop policy if exists "Members view member roles" on public.member_roles;
create policy "Members view member roles" on public.member_roles for select to authenticated using (public.is_server_member(server_id));
drop policy if exists "Managers manage member roles" on public.member_roles;
create policy "Managers manage member roles" on public.member_roles for all to authenticated using (public.can_manage_server(server_id)) with check (public.can_manage_server(server_id));
drop policy if exists "Members view custom emojis" on public.server_emojis;
create policy "Members view custom emojis" on public.server_emojis for select to authenticated using (public.is_server_member(server_id));
drop policy if exists "Managers manage custom emojis" on public.server_emojis;
create policy "Managers manage custom emojis" on public.server_emojis for all to authenticated using (public.can_manage_server(server_id)) with check (public.can_manage_server(server_id));

-- Monthly balance is materialized on demand, so every user receives two tokens per calendar month.
create or replace function public.get_my_tvboosters()
returns integer language plpgsql security definer set search_path=public
as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 insert into public.tvbooster_wallets(user_id,month_start,balance)
 values(auth.uid(),date_trunc('month',now())::date,2)
 on conflict(user_id,month_start) do nothing;
 select balance into n from public.tvbooster_wallets
 where user_id=auth.uid() and month_start=date_trunc('month',now())::date;
 return coalesce(n,0);
end $$;

create or replace function public.boost_server(target_server uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare wallet integer; lvl integer; total integer;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 perform public.get_my_tvboosters();
 select balance into wallet from public.tvbooster_wallets
 where user_id=auth.uid() and month_start=date_trunc('month',now())::date for update;
 if coalesce(wallet,0)<2 then raise exception 'You need 2 TvBoosters to boost a server.'; end if;
 if not public.is_server_member(target_server) then raise exception 'Join the server before boosting it.'; end if;
 update public.tvbooster_wallets set balance=balance-2
 where user_id=auth.uid() and month_start=date_trunc('month',now())::date returning balance into wallet;
 update public.servers set total_boosters=total_boosters+1,level=level+1
 where id=target_server returning level,total_boosters into lvl,total;
 return jsonb_build_object('balance',wallet,'level',lvl,'total_boosters',total);
end $$;

create or replace function public.give_tvboosters(target_user uuid, amount integer)
returns integer language plpgsql security definer set search_path=public
as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 if amount<1 or amount>100 then raise exception 'Amount must be between 1 and 100.'; end if;
 if not exists(select 1 from public.server_members sm where sm.server_id in
   (select server_id from public.server_members where user_id=auth.uid() and role in ('owner','admin'))
   and sm.user_id=target_user) then raise exception 'You can only grant TvBoosters to a member of a server you manage.'; end if;
 perform public.get_my_tvboosters();
 insert into public.tvbooster_wallets(user_id,month_start,balance)
 values(target_user,date_trunc('month',now())::date,2+amount)
 on conflict(user_id,month_start) do update set balance=public.tvbooster_wallets.balance+amount
 returning balance into n;
 return n;
end $$;

create or replace function public.get_discoverable_servers()
returns table(id uuid,name text,description text,icon_url text,banner_url text,level integer,total_boosters integer,member_count bigint,invite_code text)
language sql stable security definer set search_path=public
as $$
 select s.id,s.name,s.description,s.icon_url,s.banner_url,s.level,s.total_boosters,
        count(sm.user_id) as member_count,s.invite_code
 from public.servers s left join public.server_members sm on sm.server_id=s.id
 where s.discoverable=true and s.level>=10
 group by s.id
 having count(sm.user_id)>=15
 order by s.level desc,count(sm.user_id) desc,s.name;
$$;

create or replace function public.set_server_discovery(target_server uuid, enabled boolean)
returns boolean language plpgsql security definer set search_path=public
as $$
declare n bigint; lvl integer;
begin
 if not public.can_manage_server(target_server) then raise exception 'Only server owners and admins can change discovery.'; end if;
 select count(*) into n from public.server_members where server_id=target_server;
 select level into lvl from public.servers where id=target_server;
 if enabled and (n<15 or lvl<10) then raise exception 'Discovery requires at least 15 members and server level 10.'; end if;
 update public.servers set discoverable=enabled where id=target_server;
 return enabled;
end $$;

create or replace function public.ensure_tvcord_home_server(admin_id uuid, joining_user uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare home public.servers%rowtype; cid uuid; names text[] := array[
 'welcome','announcements','rules','general','introductions','chat','media','memes','gaming','music',
 'art','pets','suggestions','questions','bot-commands','clips','off-topic','help','events','polls',
 'voice-lounge','gaming-voice','music-voice','chill-voice'
]; types text[] := array[
 'text','text','text','text','text','text','text','text','text','text',
 'text','text','text','text','text','text','text','text','text','text',
 'voice','voice','voice','voice'
]; i integer;
begin
 if auth.uid() is not null and auth.uid()<>joining_user and current_user<>'service_role' then raise exception 'Not authorized.'; end if;
 perform pg_advisory_xact_lock(hashtext('tvcord-single-home-server'));
 select * into home from public.servers where lower(name)='tvcord' order by created_at asc limit 1 for update;
 if home.id is null then
  insert into public.servers(name,owner_id,description) values('TvCord',admin_id,'The official TvCord community server') returning * into home;
 else
  update public.servers set owner_id=admin_id where id=home.id and owner_id<>admin_id returning * into home;
  if home.id is null then select * into home from public.servers where lower(name)='tvcord' order by created_at asc limit 1; end if;
 end if;
 insert into public.server_members(server_id,user_id,role) values(home.id,admin_id,'owner')
 on conflict(server_id,user_id) do update set role='owner';
 insert into public.server_members(server_id,user_id,role) values(home.id,joining_user,case when joining_user=admin_id then 'owner' else 'member' end)
 on conflict(server_id,user_id) do nothing;
 for i in 1..array_length(names,1) loop
  insert into public.channels(server_id,name,type,position) values(home.id,names[i],types[i],i-1)
  on conflict(server_id,name) do update set type=excluded.type,position=excluded.position;
 end loop;
 return jsonb_build_object('ok',true,'server_id',home.id,'admin_user_id',admin_id,'is_admin',joining_user=admin_id);
end $$;
revoke all on function public.ensure_tvcord_home_server(uuid,uuid) from public,anon,authenticated;
grant execute on function public.ensure_tvcord_home_server(uuid,uuid) to service_role;
grant execute on function public.get_my_tvboosters() to authenticated;
grant execute on function public.boost_server(uuid) to authenticated;
grant execute on function public.give_tvboosters(uuid,integer) to authenticated;
grant execute on function public.get_discoverable_servers() to authenticated;
grant execute on function public.set_server_discovery(uuid,boolean) to authenticated;

-- Role and emoji writes are limited by RLS to server managers; clients cannot edit wallet rows.

-- Do not expose server invite codes through anonymous RPC calls.
revoke all on function public.get_my_tvboosters() from public,anon;
revoke all on function public.boost_server(uuid) from public,anon;
revoke all on function public.give_tvboosters(uuid,integer) from public,anon;
revoke all on function public.get_discoverable_servers() from public,anon;
revoke all on function public.set_server_discovery(uuid,boolean) from public,anon;
grant execute on function public.get_my_tvboosters() to authenticated;
grant execute on function public.boost_server(uuid) to authenticated;
grant execute on function public.give_tvboosters(uuid,integer) to authenticated;
grant execute on function public.get_discoverable_servers() to authenticated;
grant execute on function public.set_server_discovery(uuid,boolean) to authenticated;

-- Server settings are a separate permission granted only by the server owner.
alter table public.server_roles add column if not exists can_manage_server boolean not null default false;

create or replace function public.can_manage_server(target_server uuid)
returns boolean language sql stable security definer set search_path=public
as $$
 select exists(
   select 1 from public.server_members sm
   where sm.server_id=target_server and sm.user_id=auth.uid() and sm.role in ('owner','admin')
 ) or exists(
   select 1 from public.member_roles mr
   join public.server_roles sr on sr.id=mr.role_id and sr.server_id=mr.server_id
   where mr.server_id=target_server and mr.user_id=auth.uid() and sr.can_manage_server=true
 );
$$;

create or replace function public.is_tvcord_admin()
returns boolean language sql stable security definer set search_path=public
as $$
 select exists(
   select 1 from public.servers s
   join public.server_members sm on sm.server_id=s.id
   where lower(s.name)='tvcord' and sm.user_id=auth.uid() and sm.role in ('owner','admin')
 );
$$;

create or replace function public.give_tvboosters(target_user uuid, amount integer)
returns integer language plpgsql security definer set search_path=public
as $$
declare n integer;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 if not public.is_tvcord_admin() then raise exception 'Only TvCord administrators can give TvBoosters.'; end if;
 if amount<1 or amount>100 then raise exception 'Amount must be between 1 and 100.'; end if;
 if not exists(select 1 from public.server_members sm
   where sm.user_id=target_user and sm.server_id=(select s.id from public.servers s where lower(s.name)='tvcord' order by s.created_at asc limit 1))
 then raise exception 'The recipient must be a member of the official TvCord server.'; end if;
 perform public.get_my_tvboosters();
 insert into public.tvbooster_wallets(user_id,month_start,balance)
 values(target_user,date_trunc('month',now())::date,2+amount)
 on conflict(user_id,month_start) do update set balance=public.tvbooster_wallets.balance+amount
 returning balance into n;
 return n;
end $$;

revoke all on function public.is_tvcord_admin() from public,anon;
grant execute on function public.is_tvcord_admin() to authenticated;
revoke all on function public.give_tvboosters(uuid,integer) from public,anon;
grant execute on function public.give_tvboosters(uuid,integer) to authenticated;
