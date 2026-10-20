-- TvCord launch safety migration.
-- Run in Supabase Dashboard -> SQL Editor after schema.sql, social.sql, and moderation.sql.
-- This strengthens enforcement but cannot guarantee detection of every violation.
create extension if not exists pgcrypto;

create table if not exists public.user_restrictions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null default 'Policy violation',
  expires_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.user_restrictions enable row level security;
revoke all on public.user_restrictions from anon, authenticated;

create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  message_id uuid references public.messages(id) on delete set null,
  reported_user_id uuid references auth.users(id) on delete set null,
  reason text not null check (reason in ('sexual_content','harassment','hate','spam','scam','self_bot','underage_safety','violence','privacy','other')),
  details text not null default '' check (char_length(details) <= 1000),
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);
alter table public.content_reports enable row level security;
revoke all on public.content_reports from anon, authenticated;
grant insert on public.content_reports to authenticated;
drop policy if exists "Users submit reports" on public.content_reports;
create policy "Users submit reports" on public.content_reports
for insert to authenticated with check (reporter_id = auth.uid());
-- No client-side SELECT: reports must be reviewed using the Supabase dashboard/service role.

create table if not exists public.user_message_rate_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  recent_times timestamptz[] not null default '{}'
);
alter table public.user_message_rate_limits enable row level security;
revoke all on public.user_message_rate_limits from anon, authenticated;

create or replace function public.tvcord_user_is_restricted(target_user uuid)
returns boolean language sql stable security definer set search_path=public
as $$
 select exists(select 1 from public.user_restrictions r
 where r.user_id=target_user and (r.expires_at is null or r.expires_at > now()));
$$;
revoke all on function public.tvcord_user_is_restricted(uuid) from public, anon, authenticated;

create or replace function public.tvcord_safety_message_guard()
returns trigger language plpgsql security definer set search_path=public
as $$
declare t text; recent timestamptz[]; now_at timestamptz := clock_timestamp(); channel_server uuid;
begin
 if auth.uid() is null or new.user_id <> auth.uid() then
   raise exception 'Messages must be sent by the signed-in account.';
 end if;
 if public.tvcord_user_is_restricted(auth.uid()) then
   raise exception 'Your account is temporarily restricted from sending messages. Contact % for review.', 'TvmanMods@proton.me';
 end if;
 select server_id into channel_server from public.channels where id=new.channel_id;
 if channel_server is null or not public.is_server_member(channel_server) then
   raise exception 'You must be a member of this server to send messages.';
 end if;
 t := lower(coalesce(new.content,''));
 if t ~ '(^|[^a-z])(porn|pornography|hentai|xxx|onlyfans|send nudes|nude pics|sexual services)([^a-z]|$)' then
   raise exception 'This message was blocked by TvCord safety moderation.';
 end if;
 if t ~ '(discord\.gg/|bit\.ly/|tinyurl\.com/).*(discord\.gg/|bit\.ly/|tinyurl\.com/)' then
   raise exception 'This message contains too many suspicious links.';
 end if;
 insert into public.user_message_rate_limits as mr(user_id,recent_times)
 values(auth.uid(),array[now_at])
 on conflict(user_id) do update set recent_times =
   array_append(array(select x from unnest(mr.recent_times) x where x > now_at - interval '10 seconds'),now_at)
 returning recent_times into recent;
 if coalesce(array_length(recent,1),0)>6 then
   raise exception 'Slow down: you are sending messages too quickly.';
 end if;
 return new;
end $$;
drop trigger if exists tvcord_safety_guard on public.messages;
create trigger tvcord_safety_guard before insert on public.messages
for each row execute function public.tvcord_safety_message_guard();

-- Make sure reports are never publicly readable through normal client roles.
drop policy if exists "Reports readable by reporter" on public.content_reports;

-- Add basic attachment MIME/size checks to the bucket. Image files remain subject to
-- provider-side policies; actual image/video content scanning needs a moderation API.
update storage.buckets set file_size_limit=10485760,
 allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif','application/pdf','text/plain']
where id='attachments';

-- Contact point used by the app and legal pages: TvmanMods@proton.me
