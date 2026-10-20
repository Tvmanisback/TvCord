-- TvCord social features migration. Run after supabase/schema.sql.
create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  addressee_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  unique(requester_id, addressee_id),
  check (requester_id <> addressee_id)
);
create index if not exists friendships_addressee_status_idx on public.friendships(addressee_id,status);
alter table public.friendships enable row level security;
drop policy if exists "Participants view friendships" on public.friendships;
create policy "Participants view friendships" on public.friendships for select to authenticated
using (requester_id=auth.uid() or addressee_id=auth.uid());
drop policy if exists "Users send friend requests" on public.friendships;
create policy "Users send friend requests" on public.friendships for insert to authenticated
with check (requester_id=auth.uid() and status='pending');
drop policy if exists "Recipients accept requests" on public.friendships;
create policy "Recipients accept requests" on public.friendships for update to authenticated
using (addressee_id=auth.uid() and status='pending')
with check (addressee_id=auth.uid() and status='accepted');
drop policy if exists "Participants remove friendship" on public.friendships;
create policy "Participants remove friendship" on public.friendships for delete to authenticated
using (requester_id=auth.uid() or addressee_id=auth.uid());

create or replace function public.send_friend_request(target_username text)
returns uuid language plpgsql security definer set search_path=public
as $$
declare target_id uuid; new_id uuid;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 select id into target_id from public.profiles where lower(username)=lower(trim(target_username)) limit 1;
 if target_id is null then raise exception 'No user with that username was found.'; end if;
 if target_id=auth.uid() then raise exception 'You cannot add yourself.'; end if;
 if exists(select 1 from public.friendships f where
   (f.requester_id=auth.uid() and f.addressee_id=target_id) or
   (f.requester_id=target_id and f.addressee_id=auth.uid())) then
   raise exception 'A friend request or friendship already exists.';
 end if;
 insert into public.friendships(requester_id,addressee_id) values(auth.uid(),target_id) returning id into new_id;
 return new_id;
end;
$$;
grant select,insert,update,delete on public.friendships to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;

create table if not exists public.dm_conversations (
 id uuid primary key default gen_random_uuid(),
 created_at timestamptz not null default now()
);
create table if not exists public.dm_participants (
 conversation_id uuid not null references public.dm_conversations(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 primary key(conversation_id,user_id)
);
create table if not exists public.dm_messages (
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.dm_conversations(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 content text not null check(char_length(content) between 1 and 4000),
 created_at timestamptz not null default now()
);
alter table public.dm_conversations enable row level security;
alter table public.dm_participants enable row level security;
alter table public.dm_messages enable row level security;
drop policy if exists "DM participants can view conversations" on public.dm_conversations;
create policy "DM participants can view conversations" on public.dm_conversations for select to authenticated
using (exists(select 1 from public.dm_participants p where p.conversation_id=id and p.user_id=auth.uid()));
drop policy if exists "Users can view DM participants" on public.dm_participants;
create policy "Users can view DM participants" on public.dm_participants for select to authenticated
using (exists(select 1 from public.dm_participants p where p.conversation_id=dm_participants.conversation_id and p.user_id=auth.uid()));
drop policy if exists "DM participants read messages" on public.dm_messages;
create policy "DM participants read messages" on public.dm_messages for select to authenticated
using (exists(select 1 from public.dm_participants p where p.conversation_id=dm_messages.conversation_id and p.user_id=auth.uid()));
drop policy if exists "DM participants send messages" on public.dm_messages;
create policy "DM participants send messages" on public.dm_messages for insert to authenticated
with check (sender_id=auth.uid() and exists(select 1 from public.dm_participants p where p.conversation_id=dm_messages.conversation_id and p.user_id=auth.uid()));
grant select on public.dm_conversations,public.dm_participants to authenticated;
grant select,insert on public.dm_messages to authenticated;

create or replace function public.get_or_create_dm(other_user uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare conv_id uuid;
begin
 if auth.uid() is null then raise exception 'Log in first.'; end if;
 if other_user=auth.uid() then raise exception 'You cannot DM yourself.'; end if;
 if not exists(select 1 from public.friendships f where f.status='accepted' and
 ((f.requester_id=auth.uid() and f.addressee_id=other_user) or
  (f.requester_id=other_user and f.addressee_id=auth.uid()))) then
  raise exception 'You can only DM accepted friends.';
 end if;
 select p1.conversation_id into conv_id
 from public.dm_participants p1 join public.dm_participants p2 on p1.conversation_id=p2.conversation_id
 where p1.user_id=auth.uid() and p2.user_id=other_user
 and (select count(*) from public.dm_participants px where px.conversation_id=p1.conversation_id)=2
 limit 1;
 if conv_id is null then
  insert into public.dm_conversations default values returning id into conv_id;
  insert into public.dm_participants(conversation_id,user_id) values(conv_id,auth.uid()),(conv_id,other_user);
 end if;
 return conv_id;
end;
$$;
grant execute on function public.get_or_create_dm(uuid) to authenticated;
do $$ begin alter publication supabase_realtime add table public.dm_messages; exception when duplicate_object then null; when undefined_object then null; end $$;
