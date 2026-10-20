-- TvCord attachment/report/admin hardening migration.
-- Run after schema.sql, social.sql, and launch-safety.sql in Supabase SQL Editor.
-- This configures a 50 MiB upload cap. It does NOT perform malware or sexual-image scanning.
create extension if not exists pgcrypto;

-- Keep attachments private. Only the authenticated Edge Functions can read them and mint short-lived signed URLs after membership checks.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'attachments', 'attachments', false, 52428800,
  array['image/jpeg','image/png','image/webp','image/gif','application/pdf','text/plain','application/zip','application/x-zip-compressed']
)
on conflict (id) do update
set public = false,
    file_size_limit = 52428800,
    allowed_mime_types = excluded.allowed_mime_types;

-- A file cannot be attached to a message until the trusted scanner records a clean verdict.
create table if not exists public.attachment_scan_results (
  object_path text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  safe boolean not null default false,
  scanner text not null,
  scanned_at timestamptz not null default now()
);
alter table public.attachment_scan_results enable row level security;
revoke all on public.attachment_scan_results from anon, authenticated;

-- Stop the old public media policy from making private attachments readable.
drop policy if exists "Public can view TvCord media" on storage.objects;
drop policy if exists "Authenticated users view own TvCord attachments" on storage.objects;
create policy "Authenticated users view own TvCord attachments" on storage.objects
for select to authenticated using (
  bucket_id = 'avatars' or (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text)
);

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
grant insert, select on public.content_reports to authenticated;
drop policy if exists "Users submit reports" on public.content_reports;
create policy "Users submit reports" on public.content_reports
for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists "Users view their own reports" on public.content_reports;
create policy "Users view their own reports" on public.content_reports
for select to authenticated using (reporter_id = auth.uid());

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
  if new.attachment_url is not null then
    if new.attachment_url like 'http://%' or new.attachment_url like 'https://%' then
      raise exception 'Attachments must use a private scanned storage path.';
    end if;
    if not exists (
      select 1 from public.attachment_scan_results sr
      where sr.object_path = new.attachment_url
        and sr.user_id = auth.uid()
        and sr.safe = true
    ) then
      raise exception 'Attachment has not passed server-side safety scanning.';
    end if;
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
