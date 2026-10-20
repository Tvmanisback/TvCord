-- TvCord external bot registry and one-time secret tokens.
-- Run this whole file in the Supabase SQL Editor.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.tvcord_bots (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(name) between 1 and 50),
  language text not null check (language in ('JavaScript','Python','Ruby','Lua')),
  filename text not null check (filename in ('bot.js','bot.py','bot.rb','bot.lua')),
  token_hash text not null,
  token_prefix text not null,
  created_at timestamptz not null default now()
);

-- Update older installations that used TvCord.* as the bot entry filename.
alter table public.tvcord_bots drop constraint if exists tvcord_bots_filename_check;
alter table public.tvcord_bots add constraint tvcord_bots_filename_check
  check (filename in ('bot.js','bot.py','bot.rb','bot.lua'));

create index if not exists tvcord_bots_owner_created_idx
  on public.tvcord_bots(owner_id, created_at desc);

alter table public.tvcord_bots enable row level security;
drop policy if exists "Owners can view their TvCord bots" on public.tvcord_bots;
create policy "Owners can view their TvCord bots"
  on public.tvcord_bots for select to authenticated
  using (owner_id = auth.uid());

revoke all on public.tvcord_bots from anon, authenticated;
grant select (id, name, language, filename, token_prefix, created_at)
  on public.tvcord_bots to authenticated;

create or replace function public.create_tvcord_bot(
  p_name text,
  p_language text,
  p_filename text,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_token text;
  v_id uuid;
  v_name text := btrim(coalesce(p_name, ''));
begin
  if v_user is null then
    raise exception 'Log in to create a bot.';
  end if;
  if length(v_name) < 1 or length(v_name) > 50 then
    raise exception 'Bot name must be 1 to 50 characters.';
  end if;
  if p_filename not in ('bot.js','bot.py','bot.rb','bot.lua') then
    raise exception 'Choose a bot entry file named bot.js, bot.py, bot.rb, or bot.lua.';
  end if;
  if (p_filename = 'bot.js' and p_language <> 'JavaScript')
    or (p_filename = 'bot.py' and p_language <> 'Python')
    or (p_filename = 'bot.rb' and p_language <> 'Ruby')
    or (p_filename = 'bot.lua' and p_language <> 'Lua') then
    raise exception 'The selected language does not match the bot entry file extension.';
  end if;
  if position('TvCord' in coalesce(p_source, '')) = 0 then
    raise exception 'Import the TvCord API library in your bot source.';
  end if;
  if length(coalesce(p_source, '')) > 1000000 then
    raise exception 'Bot source file is too large (1 MB maximum).';
  end if;

  v_token := 'tvc_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.tvcord_bots(owner_id, name, language, filename, token_hash, token_prefix)
  values (
    v_user, v_name, p_language, p_filename,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    left(v_token, 12)
  )
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id, 'name', v_name, 'language', p_language,
    'filename', p_filename, 'token', v_token
  );
end;
$$;

create or replace function public.rotate_tvcord_bot_token(p_bot_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_token text;
  v_bot public.tvcord_bots%rowtype;
begin
  if v_user is null then raise exception 'Log in first.'; end if;
  v_token := 'tvc_' || encode(extensions.gen_random_bytes(32), 'hex');
  update public.tvcord_bots
    set token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'),
        token_prefix = left(v_token, 12)
    where id = p_bot_id and owner_id = v_user
    returning * into v_bot;
  if not found then raise exception 'Bot not found.'; end if;
  return jsonb_build_object('id', v_bot.id, 'name', v_bot.name, 'token', v_token);
end;
$$;

create or replace function public.delete_tvcord_bot(p_bot_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Log in first.'; end if;
  delete from public.tvcord_bots where id = p_bot_id and owner_id = auth.uid();
  return found;
end;
$$;

revoke all on function public.create_tvcord_bot(text,text,text,text) from public, anon;
revoke all on function public.rotate_tvcord_bot_token(uuid) from public, anon;
revoke all on function public.delete_tvcord_bot(uuid) from public, anon;
grant execute on function public.create_tvcord_bot(text,text,text,text) to authenticated;
grant execute on function public.rotate_tvcord_bot_token(uuid) to authenticated;
grant execute on function public.delete_tvcord_bot(uuid) to authenticated;
