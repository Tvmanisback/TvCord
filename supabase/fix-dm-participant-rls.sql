-- Fix recursive RLS policies on direct-message tables.
-- Run this in the Supabase SQL Editor for the live project.

create or replace function public.tvcord_is_dm_participant(p_conversation_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.dm_participants p
    where p.conversation_id = p_conversation_id
      and p.user_id = p_user_id
  );
$$;

revoke all on function public.tvcord_is_dm_participant(uuid, uuid) from public, anon;
grant execute on function public.tvcord_is_dm_participant(uuid, uuid) to authenticated;

drop policy if exists "DM participants can view conversations" on public.dm_conversations;
create policy "DM participants can view conversations"
on public.dm_conversations for select to authenticated
using (public.tvcord_is_dm_participant(id, auth.uid()));

drop policy if exists "Users can view DM participants" on public.dm_participants;
create policy "Users can view DM participants"
on public.dm_participants for select to authenticated
using (public.tvcord_is_dm_participant(conversation_id, auth.uid()));

drop policy if exists "DM participants read messages" on public.dm_messages;
create policy "DM participants read messages"
on public.dm_messages for select to authenticated
using (public.tvcord_is_dm_participant(conversation_id, auth.uid()));

drop policy if exists "DM participants send messages" on public.dm_messages;
create policy "DM participants send messages"
on public.dm_messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and public.tvcord_is_dm_participant(conversation_id, auth.uid())
);
