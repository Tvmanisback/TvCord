-- TvCord server stickers
-- Run this once in Supabase SQL Editor after deploying the matching frontend.

create table if not exists public.server_stickers (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9_]{2,32}$'),
  image_url text not null,
  uploaded_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (server_id, name)
);

create index if not exists server_stickers_server_id_idx
  on public.server_stickers(server_id);

alter table public.server_stickers enable row level security;

drop policy if exists "Server members can view stickers" on public.server_stickers;
create policy "Server members can view stickers"
on public.server_stickers for select
to authenticated
using (
  exists (
    select 1
    from public.server_members sm
    where sm.server_id = server_stickers.server_id
      and sm.user_id = auth.uid()
  )
);

drop policy if exists "Server managers can create stickers" on public.server_stickers;
create policy "Server managers can create stickers"
on public.server_stickers for insert
to authenticated
with check (
  uploaded_by = auth.uid()
  and exists (
    select 1
    from public.servers s
    where s.id = server_stickers.server_id
      and (
        s.owner_id = auth.uid()
        or exists (
          select 1
          from public.server_members sm
          where sm.server_id = s.id
            and sm.user_id = auth.uid()
            and sm.role = 'admin'
        )
      )
  )
);

drop policy if exists "Server managers can delete stickers" on public.server_stickers;
create policy "Server managers can delete stickers"
on public.server_stickers for delete
to authenticated
using (
  exists (
    select 1
    from public.servers s
    where s.id = server_stickers.server_id
      and (
        s.owner_id = auth.uid()
        or exists (
          select 1
          from public.server_members sm
          where sm.server_id = s.id
            and sm.user_id = auth.uid()
            and sm.role = 'admin'
        )
      )
  )
);
