-- Allow authenticated-by-token TvCord bots to send messages without pretending
-- to be the human owner. Run this in Supabase SQL Editor after bot-chat-dms.sql,
-- production-hardening.sql, and launch-safety.sql.

create or replace function public.tvcord_require_verified_sender()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  sender uuid;
  confirmed_at timestamptz;
begin
  if new.bot_id is not null and new.user_id is null
     and current_setting('request.jwt.claim.role', true) = 'service_role' then
    select owner_id into sender
      from public.tvcord_bots
      where id = new.bot_id;
    if sender is null then raise exception 'Unknown bot sender.'; end if;
    select email_confirmed_at into confirmed_at
      from auth.users where id = sender;
    if confirmed_at is null then raise exception 'The bot owner must verify their email.'; end if;
    if public.tvcord_user_is_restricted(sender) then
      raise exception 'The bot owner account is restricted.';
    end if;
    return new;
  end if;

  if auth.uid() is null or new.user_id is distinct from auth.uid() or new.bot_id is not null then
    raise exception 'Messages must be sent by the signed-in account.';
  end if;
  select email_confirmed_at into confirmed_at from auth.users where id = auth.uid();
  if confirmed_at is null then raise exception 'Verify your email before sending messages.'; end if;
  if public.tvcord_user_is_restricted(auth.uid()) then
    raise exception 'This account is restricted. Contact TvmanMods@proton.me for review.';
  end if;
  return new;
end;
$$;

create or replace function public.tvcord_membership_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
  body text;
  sender uuid;
begin
  if new.bot_id is not null and new.user_id is null
     and current_setting('request.jwt.claim.role', true) = 'service_role' then
    select owner_id into sender from public.tvcord_bots where id = new.bot_id;
    if sender is null then raise exception 'Unknown bot sender.'; end if;
  else
    if auth.uid() is null or new.user_id is distinct from auth.uid() or new.bot_id is not null then
      raise exception 'Invalid sender.';
    end if;
    sender := auth.uid();
  end if;

  select server_id into sid from public.channels where id = new.channel_id;
  if sid is null or not exists (
    select 1 from public.server_members sm
    where sm.server_id = sid and sm.user_id = sender
  ) then
    raise exception 'The bot owner must be a member of this server to send messages.';
  end if;

  body := lower(coalesce(new.content, ''));
  if body ~ '(^|[^a-z])(porn|pornography|hentai|xxx|onlyfans|send nudes|nude pics|sexual services)([^a-z]|$)' then
    raise exception 'This message was blocked by TvCord safety moderation.';
  end if;
  if length(body) - length(replace(body, 'http://', '')) > 3
     or length(body) - length(replace(body, 'https://', '')) > 3 then
    raise exception 'Too many links in one message.';
  end if;
  return new;
end;
$$;

create or replace function public.tvcord_safety_message_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t text;
  recent timestamptz[];
  now_at timestamptz := clock_timestamp();
  channel_server uuid;
  sender uuid;
begin
  if new.bot_id is not null and new.user_id is null
     and current_setting('request.jwt.claim.role', true) = 'service_role' then
    select owner_id into sender from public.tvcord_bots where id = new.bot_id;
    if sender is null then raise exception 'Unknown bot sender.'; end if;
    if public.tvcord_user_is_restricted(sender) then
      raise exception 'The bot owner account is restricted from sending messages.';
    end if;
  else
    if auth.uid() is null or new.user_id is distinct from auth.uid() or new.bot_id is not null then
      raise exception 'Messages must be sent by the signed-in account.';
    end if;
    sender := auth.uid();
    if public.tvcord_user_is_restricted(sender) then
      raise exception 'Your account is temporarily restricted from sending messages. Contact TvmanMods@proton.me for review.';
    end if;
  end if;

  select server_id into channel_server from public.channels where id = new.channel_id;
  if channel_server is null or not exists (
    select 1 from public.server_members sm
    where sm.server_id = channel_server and sm.user_id = sender
  ) then
    raise exception 'You must be a member of this server to send messages.';
  end if;

  t := lower(coalesce(new.content, ''));
  if t ~ '(^|[^a-z])(porn|pornography|hentai|xxx|onlyfans|send nudes|nude pics|sexual services)([^a-z]|$)' then
    raise exception 'This message was blocked by TvCord safety moderation.';
  end if;
  if t ~ '(discord\.gg/|bit\.ly/|tinyurl\.com/).*(discord\.gg/|bit\.ly/|tinyurl\.com/)' then
    raise exception 'This message contains too many suspicious links.';
  end if;

  if new.bot_id is null then
    insert into public.user_message_rate_limits as mr(user_id, recent_times)
    values(sender, array[now_at])
    on conflict(user_id) do update set recent_times =
      array_append(
        array(select x from unnest(mr.recent_times) x where x > now_at - interval '10 seconds'),
        now_at
      )
    returning recent_times into recent;
    if coalesce(array_length(recent, 1), 0) > 6 then
      raise exception 'Slow down: you are sending messages too quickly.';
    end if;
  end if;
  return new;
end;
$$;
