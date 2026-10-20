-- TvCord compatibility fixes for PostgREST profile joins and social queries.
-- Run after schema.sql and social.sql in Supabase SQL Editor.
do $$ begin
  alter table public.messages drop constraint if exists messages_user_id_fkey;
  alter table public.messages add constraint messages_user_id_fkey foreign key (user_id) references public.profiles(id) on delete cascade;
exception when others then raise; end $$;
do $$ begin
  alter table public.server_members drop constraint if exists server_members_user_id_fkey;
  alter table public.server_members add constraint server_members_user_id_fkey foreign key (user_id) references public.profiles(id) on delete cascade;
exception when others then raise; end $$;
do $$ begin
  alter table public.friendships drop constraint if exists friendships_requester_id_fkey;
  alter table public.friendships add constraint friendships_requester_id_fkey foreign key (requester_id) references public.profiles(id) on delete cascade;
  alter table public.friendships drop constraint if exists friendships_addressee_id_fkey;
  alter table public.friendships add constraint friendships_addressee_id_fkey foreign key (addressee_id) references public.profiles(id) on delete cascade;
exception when others then raise; end $$;
-- Keep channel messages available to Supabase Realtime.
do $$ begin alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; when undefined_object then null; end $$;
