-- TvCord Supabase schema
-- Run this whole file in Supabase Dashboard -> SQL Editor.
-- Re-running is safe for the tables, indexes, functions, and policies below.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null default 'new-user' check (char_length(username) between 1 and 32),
  avatar_url text,
  banner_url text,
  status_text text not null default '' check (char_length(status_text) <= 80),
  accent_color text not null default '#e34b64' check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  profile_theme text not null default 'default',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.servers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invite_code text not null unique default upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10)),
  icon_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  type text not null default 'text' check (type in ('text','voice')),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  unique(server_id, name)
);

create table if not exists public.server_members (
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  primary key(server_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  content text not null default '' check (char_length(content) <= 4000),
  attachment_url text,
  attachment_name text,
  created_at timestamptz not null default now(),
  constraint message_has_content_or_attachment check (char_length(trim(content)) > 0 or attachment_url is not null)
);

create index if not exists channels_server_position_idx on public.channels(server_id, position);
create index if not exists server_members_user_idx on public.server_members(user_id);
create index if not exists messages_channel_created_idx on public.messages(channel_id, created_at);

create or replace function public.is_server_member(target_server uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(select 1 from public.server_members sm where sm.server_id = target_server and sm.user_id = auth.uid());
$$;

create or replace function public.can_manage_server(target_server uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists(select 1 from public.server_members sm where sm.server_id = target_server and sm.user_id = auth.uid() and sm.role in ('owner','admin'));
$$;

create or replace function public.create_server(server_name text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare new_server_id uuid;
declare clean_name text;
begin
  if auth.uid() is null then raise exception 'You must be logged in.'; end if;
  clean_name := trim(server_name);
  if clean_name is null or char_length(clean_name) < 1 or char_length(clean_name) > 80 then
    raise exception 'Server name must be between 1 and 80 characters.';
  end if;
  insert into public.servers(name, owner_id) values (clean_name, auth.uid()) returning id into new_server_id;
  insert into public.server_members(server_id, user_id, role) values (new_server_id, auth.uid(), 'owner');
  insert into public.channels(server_id, name, type, position) values (new_server_id, 'general', 'text', 0);
  return new_server_id;
end;
$$;

create or replace function public.join_server_by_invite(code text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare found_server_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be logged in.'; end if;
  select id into found_server_id from public.servers where invite_code = upper(trim(code));
  if found_server_id is null then raise exception 'That invite code was not found.'; end if;
  insert into public.server_members(server_id, user_id, role) values (found_server_id, auth.uid(), 'member')
    on conflict (server_id, user_id) do nothing;
  return found_server_id;
end;
$$;

alter table public.profiles enable row level security;
alter table public.servers enable row level security;
alter table public.channels enable row level security;
alter table public.server_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists "Profiles visible to signed-in users" on public.profiles;
create policy "Profiles visible to signed-in users" on public.profiles for select to authenticated using (true);
drop policy if exists "Users create own profile" on public.profiles;
create policy "Users create own profile" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "Users update own profile" on public.profiles;
create policy "Users update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "Members can view their servers" on public.servers;
create policy "Members can view their servers" on public.servers for select to authenticated using (public.is_server_member(id));
drop policy if exists "Owners and admins update servers" on public.servers;
create policy "Owners and admins update servers" on public.servers for update to authenticated using (public.can_manage_server(id)) with check (public.can_manage_server(id));
drop policy if exists "Owners delete servers" on public.servers;
create policy "Owners delete servers" on public.servers for delete to authenticated using (owner_id = auth.uid());

drop policy if exists "Members can view channels" on public.channels;
create policy "Members can view channels" on public.channels for select to authenticated using (public.is_server_member(server_id));
drop policy if exists "Managers create channels" on public.channels;
create policy "Managers create channels" on public.channels for insert to authenticated with check (public.can_manage_server(server_id));
drop policy if exists "Managers update channels" on public.channels;
create policy "Managers update channels" on public.channels for update to authenticated using (public.can_manage_server(server_id)) with check (public.can_manage_server(server_id));
drop policy if exists "Managers delete channels" on public.channels;
create policy "Managers delete channels" on public.channels for delete to authenticated using (public.can_manage_server(server_id));

drop policy if exists "Members can view membership" on public.server_members;
create policy "Members can view membership" on public.server_members for select to authenticated using (public.is_server_member(server_id));
drop policy if exists "Managers remove members" on public.server_members;
create policy "Managers remove members" on public.server_members for delete to authenticated using (public.can_manage_server(server_id) and user_id <> auth.uid());

drop policy if exists "Members can read channel messages" on public.messages;
create policy "Members can read channel messages" on public.messages for select to authenticated using (
  exists(select 1 from public.channels c where c.id = channel_id and public.is_server_member(c.server_id))
);
drop policy if exists "Members send messages as themselves" on public.messages;
create policy "Members send messages as themselves" on public.messages for insert to authenticated with check (
  user_id = auth.uid() and exists(select 1 from public.channels c where c.id = channel_id and public.is_server_member(c.server_id))
);
drop policy if exists "Authors edit their messages" on public.messages;
create policy "Authors edit their messages" on public.messages for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "Authors or managers delete messages" on public.messages;
create policy "Authors or managers delete messages" on public.messages for delete to authenticated using (
  user_id = auth.uid() or exists(select 1 from public.channels c where c.id = channel_id and public.can_manage_server(c.server_id))
);

grant usage on schema public to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, update, delete on public.servers to authenticated;
grant select, insert, update, delete on public.channels to authenticated;
grant select, delete on public.server_members to authenticated;
grant select, insert, update, delete on public.messages to authenticated;
grant execute on function public.create_server(text) to authenticated;
grant execute on function public.join_server_by_invite(text) to authenticated;

-- Realtime subscriptions used by the chat view.
do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
when undefined_object then null;
end $$;

-- Public media buckets. Files are public to view, but only authenticated users
-- may upload into a folder whose first path segment is their own user UUID.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', true, 26214400, array['image/*','application/pdf','text/plain','application/zip','application/x-zip-compressed'])
on conflict (id) do update set public = true, file_size_limit = 26214400;
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 10485760, array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do update set public = true, file_size_limit = 10485760;

drop policy if exists "Public can view TvCord media" on storage.objects;
create policy "Public can view TvCord media" on storage.objects for select using (bucket_id in ('attachments','avatars'));
drop policy if exists "Users upload their own TvCord media" on storage.objects;
create policy "Users upload their own TvCord media" on storage.objects for insert to authenticated with check (
  bucket_id in ('attachments','avatars') and (storage.foldername(name))[1] = auth.uid()::text
);
drop policy if exists "Users update their own TvCord media" on storage.objects;
create policy "Users update their own TvCord media" on storage.objects for update to authenticated using (
  bucket_id in ('attachments','avatars') and (storage.foldername(name))[1] = auth.uid()::text
) with check (bucket_id in ('attachments','avatars') and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "Users delete their own TvCord media" on storage.objects;
create policy "Users delete their own TvCord media" on storage.objects for delete to authenticated using (
  bucket_id in ('attachments','avatars') and (storage.foldername(name))[1] = auth.uid()::text
);
