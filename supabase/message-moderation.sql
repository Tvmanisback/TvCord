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

  if body ~ '(.)\1{17,}' then
    raise exception 'TvCord moderation: repeated-character spam was blocked.';
  end if;


  -- Hate/slur filter. This is intentionally a maintained starter list, not an exhaustive lexicon.
  -- Match common spelling variants and punctuation/spacing substitutions.
  if body ~* '(^|[^[:alnum:]])(n[i1!|]gg(e|a|u)?r?s?|n[i1!|]gg(a|e)?)([^[:alnum:]]|$)' then
    raise exception 'TvCord moderation: hateful slurs are not allowed.';
  end if;

  if body ~* '(^|[^[:alnum:]])(f[a@]g(g[o0]t?|s)?|dyke|tr[a@]nn(y|ie)?)([^[:alnum:]]|$)' then
    raise exception 'TvCord moderation: hateful slurs are not allowed.';
  end if;

  if body ~* '(^|[^[:alnum:]])(k[i1!|]ke|ch[i1!|]nk|g[o0]ok|sp[i1!|]c|wetb[a@]ck)([^[:alnum:]]|$)' then
    raise exception 'TvCord moderation: hateful slurs are not allowed.';
  end if;

  if body ~* '(^|[^[:alnum:]])(r[e3]t[a@]rd(ed)?|[uυ]ntouchable)([^[:alnum:]]|$)' then
    raise exception 'TvCord moderation: hateful or demeaning slurs are not allowed.';
  end if;

  if body ~* '(discord[.]gift|nitro-free[.]|steamcommunit(y|у)[.]|free-nitro[.])' then
    raise exception 'TvCord moderation: a common phishing or fake-reward link was blocked.';
  end if;

  if body ~* '\m(send|show|share|trade|sell)[[:space:]]+(me[[:space:]]+)?(nudes?|naked pics?|explicit pics?|sexual pics?)\M' then
    raise exception 'TvCord moderation: sexual solicitation was blocked.';
  end if;

  if body ~* '\m(keep this|our chat)[[:space:]]+(a[[:space:]]+)?secret\M' and
     body ~* '\m(parents|mom|dad|guardian)\M' then
    raise exception 'TvCord moderation: a potentially unsafe secrecy request was blocked.';
  end if;

  if body ~* '\m(kill yourself|kys)\M' then
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
