-- TvCord attachment/report/admin hardening migration.
-- Run after schema.sql, social.sql, and launch-safety.sql in Supabase SQL Editor.
-- This configures a 50 MiB upload cap. It does NOT perform malware or sexual-image scanning.
create extension if not exists pgcrypto;

-- Keep the current bucket behavior compatible with the existing public-URL client.
-- Public attachments can be viewed by anyone who has the URL; do not upload sensitive files.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'attachments', 'attachments', true, 52428800,
  array['image/jpeg','image/png','image/webp','image/gif','application/pdf','text/plain','application/zip','application/x-zip-compressed']
)
on conflict (id) do update
set public = true,
    file_size_limit = 52428800,
    allowed_mime_types = excluded.allowed_mime_types;

-- The client cannot directly read reports. Supabase Edge Function service role handles webhook forwarding.
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

-- Account restrictions are checked on every message insert by a server-side trigger.
create table if not exists public.user_restrictions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reason text not null default 'Policy violation',
  expires_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.user_restrictions enable row level security;
revoke all on public.user_restrictions from anon, authenticated;

create or replace function public.tvcord_user_is_restricted(target_user uuid)
returns boolean language sql stable security definer set search_path=public
as $$
  select exists (
    select 1 from public.user_restrictions r
    where r.user_id = target_user and (r.expires_at is null or r.expires_at > now())
  );
$$;
revoke all on function public.tvcord_user_is_restricted(uuid) from public, anon, authenticated;

create or replace function public.tvcord_attachment_message_guard()
returns trigger language plpgsql security definer set search_path=public
as $$
declare channel_server uuid; body text;
begin
  if auth.uid() is null or new.user_id <> auth.uid() then
    raise exception 'Messages must be sent by the signed-in account.';
  end if;
  if public.tvcord_user_is_restricted(auth.uid()) then
    raise exception 'This account is restricted from sending messages.';
  end if;
  select server_id into channel_server from public.channels where id = new.channel_id;
  if channel_server is null or not public.is_server_member(channel_server) then
    raise exception 'You must be a member of this server to send messages.';
  end if;
  body := lower(coalesce(new.content, ''));
  if body ~ '(^|[^a-z])(porn|pornography|hentai|xxx|onlyfans|send nudes|nude pics|sexual services)([^a-z]|$)' then
    raise exception 'This message was blocked by TvCord safety moderation.';
  end if;
  return new;
end;
$$;
drop trigger if exists tvcord_attachment_message_guard_trigger on public.messages;
create trigger tvcord_attachment_message_guard_trigger
before insert on public.messages for each row
execute function public.tvcord_attachment_message_guard();

-- IMPORTANT: use Edge Function secrets, never put the Discord webhook or service-role key in index.html.
-- Deploy report-to-discord and admin-ban, then set:
-- DISCORD_WEBHOOK_URL = the private moderation webhook URL
-- TVCORD_ADMIN_USER_IDS = comma-separated trusted admin UUIDs
-- Supabase provides SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY to Edge Functions.
-- This trigger filters only obvious text; image/video content requires a trusted scanning service.
