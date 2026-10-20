-- TvCord profile customization fields
-- Run this in Supabase SQL Editor.
alter table public.profiles
  add column if not exists profile_background text not null default '#17181c',
  add column if not exists profile_accent text not null default '#e34b64',
  add column if not exists profile_decoration text not null default 'none',
  add column if not exists nameplate text not null default 'none';

alter table public.profiles
  drop constraint if exists profiles_profile_background_hex_check,
  add constraint profiles_profile_background_hex_check
    check (profile_background ~ '^#[0-9A-Fa-f]{6}
  drop constraint if exists profiles_profile_accent_hex_check,
  add constraint profiles_profile_accent_hex_check
    check (profile_accent ~ '^#[0-9A-Fa-f]{6}$'),
  drop constraint if exists profiles_profile_decoration_check,
  add constraint profiles_profile_decoration_check
    check (profile_decoration in ('none','rainbow','gold','blue')),
  drop constraint if exists profiles_nameplate_check,
  add constraint profiles_nameplate_check
    check (nameplate in ('none','gold','ocean','amethyst'));

comment on column public.profiles.profile_background is 'User-selected profile card background color.';
comment on column public.profiles.profile_accent is 'User-selected profile accent color.';
comment on column public.profiles.profile_decoration is 'Selected profile picture decoration preset.';
comment on column public.profiles.nameplate is 'Selected profile nameplate preset.';
 or profile_background in ('default','midnight','ocean','sunset','forest','galaxy')),
  drop constraint if exists profiles_profile_accent_hex_check,
  add constraint profiles_profile_accent_hex_check
    check (profile_accent ~ '^#[0-9A-Fa-f]{6}$'),
  drop constraint if exists profiles_profile_decoration_check,
  add constraint profiles_profile_decoration_check
    check (profile_decoration in ('none','rainbow','gold','blue')),
  drop constraint if exists profiles_nameplate_check,
  add constraint profiles_nameplate_check
    check (nameplate in ('none','gold','ocean','amethyst'));

comment on column public.profiles.profile_background is 'User-selected profile card background color.';
comment on column public.profiles.profile_accent is 'User-selected profile accent color.';
comment on column public.profiles.profile_decoration is 'Selected profile picture decoration preset.';
comment on column public.profiles.nameplate is 'Selected profile nameplate preset.';
