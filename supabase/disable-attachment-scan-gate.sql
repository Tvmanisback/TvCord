-- TvCord attachment send fix.
-- Run in Supabase Dashboard -> SQL Editor.
-- This removes the stale "must have a clean scanner verdict" gate because
-- attachment scanning is currently disabled. It does NOT mark files as scanned
-- or safe. Attachments remain private and users should report unsafe content.

create or replace function public.tvcord_attachment_message_guard()
returns trigger language plpgsql security definer set search_path=public, storage
as $$
declare channel_server uuid;
begin
  if auth.uid() is null or new.user_id <> auth.uid() then
    raise exception 'Messages must be sent by the signed-in account.';
  end if;

  if public.tvcord_user_is_restricted(auth.uid()) then
    raise exception 'This account is restricted from sending messages.';
  end if;

  select server_id into channel_server
  from public.channels
  where id = new.channel_id;

  if channel_server is null or not public.is_server_member(channel_server) then
    raise exception 'You must be a member of this server to send messages.';
  end if;

  if new.attachment_url is not null then
    if new.attachment_url like 'http://%' or new.attachment_url like 'https://%'
       or new.attachment_url like '/%' or new.attachment_url like '%..%' then
      raise exception 'Attachments must use a private storage object path.';
    end if;

    -- Require a real object in the private bucket, inside the sender's own folder.
    if not exists (
      select 1
      from storage.objects o
      where o.bucket_id = 'attachments'
        and o.name = new.attachment_url
        and (storage.foldername(o.name))[1] = auth.uid()::text
    ) then
      raise exception 'Attachment was not found in your private upload folder.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists tvcord_attachment_message_guard_trigger on public.messages;
create trigger tvcord_attachment_message_guard_trigger
before insert on public.messages
for each row execute function public.tvcord_attachment_message_guard();
