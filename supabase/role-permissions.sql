-- TvCord custom role permission and restriction storage
-- Run this in Supabase SQL Editor after community-features.sql.
alter table public.server_roles
  add column if not exists permissions jsonb not null default '[]'::jsonb,
  add column if not exists restrictions jsonb not null default '[]'::jsonb;

alter table public.server_roles
  drop constraint if exists server_roles_permissions_array_check,
  add constraint server_roles_permissions_array_check
    check (jsonb_typeof(permissions) = 'array' and jsonb_array_length(permissions) <= 30),
  drop constraint if exists server_roles_restrictions_array_check,
  add constraint server_roles_restrictions_array_check
    check (jsonb_typeof(restrictions) = 'array' and jsonb_array_length(restrictions) <= 30);

comment on column public.server_roles.permissions is 'Selected permission option indexes from the TvCord role permission catalog; maximum 30.';
comment on column public.server_roles.restrictions is 'Selected restriction option indexes from the TvCord role restriction catalog; maximum 30.';
