-- TvCord basic server-side moderation and anti-spam safeguards.
-- Run in Supabase Dashboard -> SQL Editor after schema.sql.
-- This is a baseline, not an image classifier or a way to prove whether a client is a self-bot.

create table if not exists public.message_rate_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  recent_times timestamptz[] not null default '{}'
);
alter table public.message_rate_limits enable row level security;
revoke all on public.message_rate_limits from anon, authenticated;

create or replace function public.tvcord_moderate_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recent timestamptz[];
  now_at timestamptz := clock_timestamp();
  clean text;
begin
  if auth.uid() is null or new.user_id <> auth.uid() then
    raise exception 'Messages must be sent by the signed-in account.';
  end if;

  clean := lower(coalesce(new.content, ''));

  -- Block common explicit sexual-content terms in text. This is deliberately
  -- a basic keyword filter and will have false positives/false negatives.
  if clean ~ '(^|[^a-z])(porn|pornography|hentai|xxx|onlyfans|nudes|nude pics|send nudes|sexual services)([^a-z]|$)' then
    raise exception 'This message was blocked by TvCord safety moderation. Sexual content is not allowed.';
  end if;

  -- Stop repeated URL floods.
  if length(clean) - length(replace(clean, 'http://', '')) > 3
     or length(clean) - length(replace(clean, 'https://', '')) > 3 then
    raise exception 'Too many links in one message.';
  end if;

  insert into public.message_rate_limits as mr(user_id, recent_times)
  values (new.user_id, array[now_at])
  on conflict (user_id) do update
    set recent_times = array_append(
      array(select t from unnest(mr.recent_times) t
            where t > now_at - interval '10 seconds'),
      now_at
    )
  returning recent_times into recent;

  if coalesce(array_length(recent, 1), 0) > 6 then
    raise exception 'You are sending messages too quickly. Please wait a few seconds.';
  end if;

  return new;
end;
$$;

drop trigger if exists tvcord_moderate_message_before_insert on public.messages;
create trigger tvcord_moderate_message_before_insert
before insert on public.messages
for each row execute function public.tvcord_moderate_message();

-- Keep delete permissions scoped to the author or server owner/admin.
drop policy if exists "Authors or managers delete messages" on public.messages;
create policy "Authors or managers delete messages" on public.messages
for delete to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.channels c
    where c.id = channel_id and public.can_manage_server(c.server_id)
  )
);
