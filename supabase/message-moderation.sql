-- TvCord message safety guard
-- Run this in Supabase SQL Editor after reviewing it.
-- This is a lightweight rule-based filter, not an AI classifier or a guarantee of safety.

create or replace function public.tvcord_moderate_message()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  body text;
begin
  body := coalesce(new.content, '');

  if char_length(body) > 4000 then
    raise exception 'TvCord moderation: messages are limited to 4,000 characters.';
  end if;

  if body ~ '(.)\\1{17,}' then
    raise exception 'TvCord moderation: repeated-character spam was blocked.';
  end if;

  if body ~* '(discord[.]gift|nitro-free[.]|steamcommunitу[.]|free-nitro[.])' then
    raise exception 'TvCord moderation: a common phishing or fake-reward link was blocked.';
  end if;

  if body ~* '\\m(send|show|share|trade|sell)[[:space:]]+(me[[:space:]]+)?(nudes?|naked pics?|explicit pics?|sexual pics?)\\M' then
    raise exception 'TvCord moderation: sexual solicitation was blocked.';
  end if;

  if body ~* '\\m(keep this|our chat)[[:space:]]+(a[[:space:]]+)?secret\\M' and
     body ~* '\\m(parents|mom|dad|guardian)\\M' then
    raise exception 'TvCord moderation: a potentially unsafe secrecy request was blocked.';
  end if;

  if body ~* '\\m(kill yourself|kys)\\M' then
    raise exception 'TvCord moderation: abusive or harmful language was blocked.';
  end if;

  return new;
end;
$$;

drop trigger if exists tvcord_message_moderation_guard on public.messages;
create trigger tvcord_message_moderation_guard
before insert or update of content on public.messages
for each row
execute function public.tvcord_moderate_message();
