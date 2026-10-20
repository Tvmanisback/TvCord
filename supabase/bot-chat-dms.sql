-- TvCord bot chat gateway + direct messages.
-- Run AFTER supabase/bots.sql in Supabase SQL Editor.
-- This adds database support; a hosted HTTPS gateway/SDK is still needed for
-- long-running bot connections and real-time event delivery.

create extension if not exists pgcrypto with schema extensions;

-- Human-to-human DMs.
create table if not exists public.dm_conversations (
  id uuid primary key default gen_random_uuid(),
  user_low uuid not null references auth.users(id) on delete cascade,
  user_high uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (user_low < user_high),
  unique (user_low, user_high)
);

-- Upgrade older installations where dm_conversations already exists but only
-- has id/created_at. Keep old rows intact; newly created conversations get both
-- participant IDs through get_or_create_dm().
alter table public.dm_conversations
  add column if not exists user_low uuid references auth.users(id) on delete cascade;
alter table public.dm_conversations
  add column if not exists user_high uuid references auth.users(id) on delete cascade;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.dm_conversations'::regclass
      and conname = 'dm_conversations_user_pair_unique'
  ) then
    alter table public.dm_conversations
      add constraint dm_conversations_user_pair_unique unique (user_low, user_high);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.dm_conversations'::regclass
      and conname = 'dm_conversations_user_pair_order_check'
  ) then
    alter table public.dm_conversations
      add constraint dm_conversations_user_pair_order_check
      check (user_low is null or user_high is null or user_low < user_high);
  end if;
end $migration$;

create table if not exists public.dm_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.dm_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (length(trim(content)) between 1 and 4000),
  created_at timestamptz not null default now()
);

create index if not exists dm_messages_conversation_created_idx
  on public.dm_messages(conversation_id, created_at);

alter table public.dm_conversations enable row level security;
alter table public.dm_messages enable row level security;

drop policy if exists "Participants can view DM conversations" on public.dm_conversations;
create policy "Participants can view DM conversations"
  on public.dm_conversations for select to authenticated
  using (auth.uid() in (user_low, user_high));

drop policy if exists "Participants can view DM messages" on public.dm_messages;
create policy "Participants can view DM messages"
  on public.dm_messages for select to authenticated
  using (exists (
    select 1 from public.dm_conversations c
    where c.id = conversation_id and auth.uid() in (c.user_low, c.user_high)
  ));

drop policy if exists "Participants can send DM messages" on public.dm_messages;
create policy "Participants can send DM messages"
  on public.dm_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.dm_conversations c
      where c.id = conversation_id and auth.uid() in (c.user_low, c.user_high)
    )
  );

grant select, insert on public.dm_conversations to authenticated;
grant select, insert on public.dm_messages to authenticated;

create or replace function public.get_or_create_dm(other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  low_id uuid;
  high_id uuid;
  conversation uuid;
begin
  if me is null then raise exception 'Log in first.'; end if;
  if other_user is null or other_user = me then
    raise exception 'Choose another user to message.';
  end if;
  if not exists (select 1 from auth.users where id = other_user) then
    raise exception 'User not found.';
  end if;
  low_id := least(me, other_user);
  high_id := greatest(me, other_user);
  insert into public.dm_conversations(user_low, user_high)
    values (low_id, high_id)
    on conflict (user_low, user_high) do nothing;
  select id into conversation from public.dm_conversations
    where user_low = low_id and user_high = high_id;
  return conversation;
end;
$$;

revoke all on function public.get_or_create_dm(uuid) from public, anon;
grant execute on function public.get_or_create_dm(uuid) to authenticated;

-- Allow registered bots to appear as senders in server channels.
alter table public.messages alter column user_id drop not null;
alter table public.messages add column if not exists bot_id uuid
  references public.tvcord_bots(id) on delete set null;

alter table public.messages drop constraint if exists messages_sender_check;
alter table public.messages add constraint messages_sender_check
  check (
    (user_id is not null and bot_id is null)
    or (user_id is null and bot_id is not null)
  );

create index if not exists messages_bot_created_idx
  on public.messages(bot_id, created_at desc) where bot_id is not null;

-- Bot DMs use the same conversation UI concept but keep bot identities separate
-- from human auth accounts.
create table if not exists public.tvcord_bot_dm_messages (
  id uuid primary key default gen_random_uuid(),
  bot_id uuid not null references public.tvcord_bots(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  sender_kind text not null check (sender_kind in ('user','bot')),
  content text not null check (length(trim(content)) between 1 and 4000),
  created_at timestamptz not null default now()
);

create index if not exists tvcord_bot_dm_messages_thread_idx
  on public.tvcord_bot_dm_messages(bot_id, user_id, created_at);

alter table public.tvcord_bot_dm_messages enable row level security;
drop policy if exists "Users can read their bot DMs" on public.tvcord_bot_dm_messages;
create policy "Users can read their bot DMs"
  on public.tvcord_bot_dm_messages for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Users can send bot DMs" on public.tvcord_bot_dm_messages;
create policy "Users can send bot DMs"
  on public.tvcord_bot_dm_messages for insert to authenticated
  with check (
    user_id = auth.uid()
    and sender_kind = 'user'
    and exists (select 1 from public.tvcord_bots b where b.id = bot_id)
  );

grant select, insert on public.tvcord_bot_dm_messages to authenticated;

-- Human sends a command/message to a bot. Bots can poll for these messages.
create or replace function public.send_tvcord_bot_dm(p_bot_id uuid, p_content text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  new_id uuid;
  clean_content text := trim(coalesce(p_content, ''));
begin
  if me is null then raise exception 'Log in first.'; end if;
  if not exists (select 1 from public.tvcord_bots where id = p_bot_id) then
    raise exception 'Bot not found.';
  end if;
  if length(clean_content) < 1 or length(clean_content) > 4000 then
    raise exception 'Message must be 1 to 4000 characters.';
  end if;
  insert into public.tvcord_bot_dm_messages(bot_id, user_id, sender_kind, content)
    values (p_bot_id, me, 'user', clean_content) returning id into new_id;
  return new_id;
end;
$$;

-- Token-authenticated channel message. The bot owner must be a member of the
-- target server; bots cannot impersonate human users.
create or replace function public.tvcord_bot_send_channel_message(
  p_token text, p_channel_id uuid, p_content text
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  b public.tvcord_bots%rowtype;
  new_id uuid;
  clean_content text := trim(coalesce(p_content, ''));
begin
  select * into b from public.tvcord_bots
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then raise exception 'Invalid bot token.'; end if;
  if length(clean_content) < 1 or length(clean_content) > 4000 then
    raise exception 'Message must be 1 to 4000 characters.';
  end if;
  if not exists (
    select 1 from public.channels c
    join public.server_members sm on sm.server_id = c.server_id
    where c.id = p_channel_id and sm.user_id = b.owner_id
  ) then raise exception 'The bot owner must be a member of that server.'; end if;
  insert into public.messages(channel_id, user_id, bot_id, content)
    values (p_channel_id, null, b.id, clean_content) returning id into new_id;
  return new_id;
end;
$$;

-- Token-authenticated bot replies in a user's bot DM thread.
create or replace function public.tvcord_bot_send_dm_message(
  p_token text, p_user_id uuid, p_content text
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  b public.tvcord_bots%rowtype;
  new_id uuid;
  clean_content text := trim(coalesce(p_content, ''));
begin
  select * into b from public.tvcord_bots
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then raise exception 'Invalid bot token.'; end if;
  if length(clean_content) < 1 or length(clean_content) > 4000 then
    raise exception 'Message must be 1 to 4000 characters.';
  end if;
  if not exists (
    select 1 from public.tvcord_bot_dm_messages m
    where m.bot_id = b.id and m.user_id = p_user_id
  ) then raise exception 'No DM thread exists for this user yet.'; end if;
  insert into public.tvcord_bot_dm_messages(bot_id, user_id, sender_kind, content)
    values (b.id, p_user_id, 'bot', clean_content) returning id into new_id;
  return new_id;
end;
$$;

-- Polling endpoint for small hosted bots. Returns recent server messages visible
-- to the bot owner and pending bot DMs. Call every few seconds from the bot host.
create or replace function public.tvcord_bot_poll(p_token text, p_since timestamptz default now() - interval '60 seconds')
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  b public.tvcord_bots%rowtype;
  result jsonb;
begin
  select * into b from public.tvcord_bots
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then raise exception 'Invalid bot token.'; end if;

  select jsonb_build_object(
    'bot', jsonb_build_object('id', b.id, 'name', b.name),
    'channel_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'channel_id', m.channel_id, 'content', m.content,
        'user_id', m.user_id, 'bot_id', m.bot_id, 'created_at', m.created_at
      ) order by m.created_at)
      from public.messages m
      join public.channels c on c.id = m.channel_id
      join public.server_members sm on sm.server_id = c.server_id and sm.user_id = b.owner_id
      where m.created_at > coalesce(p_since, now() - interval '60 seconds')
        and m.bot_id is distinct from b.id
    ), '[]'::jsonb),
    'dm_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'user_id', d.user_id, 'content', d.content,
        'created_at', d.created_at
      ) order by d.created_at)
      from public.tvcord_bot_dm_messages d
      where d.bot_id = b.id and d.sender_kind = 'user'
        and d.created_at > coalesce(p_since, now() - interval '60 seconds')
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke all on function public.send_tvcord_bot_dm(uuid,text) from public, anon;
revoke all on function public.tvcord_bot_send_channel_message(text,uuid,text) from public, anon, authenticated;
revoke all on function public.tvcord_bot_send_dm_message(text,uuid,text) from public, anon, authenticated;
revoke all on function public.tvcord_bot_poll(text,timestamptz) from public, anon, authenticated;
grant execute on function public.send_tvcord_bot_dm(uuid,text) to authenticated;
grant execute on function public.tvcord_bot_send_channel_message(text,uuid,text) to service_role;
grant execute on function public.tvcord_bot_send_dm_message(text,uuid,text) to service_role;
grant execute on function public.tvcord_bot_poll(text,timestamptz) to service_role;
