-- TvCord production-hardening baseline.
-- This migration intentionally disables public attachment delivery until a trusted
-- moderation/scanning worker is configured. It does NOT claim complete protection.
create extension if not exists pgcrypto;

-- Keep uploaded files private; never expose an unscanned public bucket.
update storage.buckets
set public=false,
    file_size_limit=10485760,
    allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif','application/pdf','text/plain']
where id='attachments';

-- Quarantine metadata for uploads. A trusted server-side worker must scan files and
-- set status='approved'; client users cannot read/update this table.
create table if not exists public.attachment_moderation (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  object_path text not null unique,
  mime_type text not null,
  byte_size bigint not null check(byte_size between 1 and 10485760),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  reason text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
alter table public.attachment_moderation enable row level security;
revoke all on public.attachment_moderation from anon, authenticated;

-- Signup gate: email must be confirmed before an account may post.
create or replace function public.tvcord_require_verified_sender()
returns trigger language plpgsql security definer set search_path=public,auth
as $$
declare confirmed_at timestamptz; restricted boolean;
begin
 if auth.uid() is null or new.user_id <> auth.uid() then
   raise exception 'Messages must be sent by the signed-in account.';
 end if;
 select email_confirmed_at into confirmed_at from auth.users where id=auth.uid();
 if confirmed_at is null then raise exception 'Verify your email before sending messages.'; end if;
 if public.tvcord_user_is_restricted(auth.uid()) then
   raise exception 'This account is restricted. Contact TvmanMods@proton.me for review.';
 end if;
 return new;
end $$;
drop trigger if exists tvcord_require_verified_sender_trigger on public.messages;
create trigger tvcord_require_verified_sender_trigger before insert on public.messages
for each row execute function public.tvcord_require_verified_sender();

-- Reports remain private; users can submit only as themselves.
create table if not exists public.content_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references auth.users(id) on delete cascade,
 message_id uuid references public.messages(id) on delete set null,
 reported_user_id uuid references auth.users(id) on delete set null,
 reason text not null check(reason in ('sexual_content','harassment','hate','spam','scam','self_bot','underage_safety','violence','privacy','other')),
 details text not null default '' check(char_length(details)<=1000),
 status text not null default 'open' check(status in ('open','reviewing','resolved','dismissed')),
 created_at timestamptz not null default now()
);
alter table public.content_reports enable row level security;
revoke all on public.content_reports from anon, authenticated;
grant insert on public.content_reports to authenticated;
drop policy if exists "Users submit reports" on public.content_reports;
create policy "Users submit reports" on public.content_reports for insert to authenticated with check(reporter_id=auth.uid());

-- Server-side moderation must fail closed if a sender is not a server member.
create or replace function public.tvcord_membership_guard()
returns trigger language plpgsql security definer set search_path=public
as $$
declare sid uuid; body text;
begin
 if auth.uid() is null or new.user_id<>auth.uid() then raise exception 'Invalid sender.'; end if;
 select server_id into sid from public.channels where id=new.channel_id;
 if sid is null or not exists(select 1 from public.server_members sm where sm.server_id=sid and sm.user_id=auth.uid()) then
   raise exception 'You must be a member of this server to send messages.';
 end if;
 body:=lower(coalesce(new.content,''));
 if body ~ '(^|[^a-z])(porn|pornography|hentai|xxx|onlyfans|send nudes|nude pics|sexual services)([^a-z]|$)' then
   raise exception 'This message was blocked by TvCord safety moderation.';
 end if;
 if length(body)-length(replace(body,'http://',''))>3 or length(body)-length(replace(body,'https://',''))>3 then
   raise exception 'Too many links in one message.';
 end if;
 return new;
end $$;
drop trigger if exists tvcord_membership_guard_trigger on public.messages;
create trigger tvcord_membership_guard_trigger before insert on public.messages
for each row execute function public.tvcord_membership_guard();

-- IMPORTANT OPERATIONS:
-- 1. Enable Supabase CAPTCHA and email confirmations in Auth settings.
-- 2. Configure a trusted upload-scanning worker (e.g. moderation API) to scan private
--    storage objects and update attachment_moderation only via service-role credentials.
-- 3. Do not expose service-role keys in GitHub Pages/browser code.
-- 4. Until the scanner exists, attachments stay private and cannot be safely published.
