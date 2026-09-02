-- ValueLens sign-up now collects the fields the atares TechSpheres newsletter
-- form asks for (salutation, first name, last name) plus an explicit record of
-- the newsletter consent the user gave.
--
-- capture_lead() is replaced rather than overloaded: the old 4-argument version
-- is dropped so PostgREST cannot resolve to a signature that silently discards
-- the new fields.

alter table public.leads add column if not exists salutation text;
alter table public.leads add column if not exists first_name text;
alter table public.leads add column if not exists last_name text;
alter table public.leads add column if not exists newsletter_consent boolean not null default false;
alter table public.leads add column if not exists newsletter_synced_at timestamptz;

comment on column public.leads.newsletter_consent is
  'True when the user ticked the atares newsletter consent at sign-up.';
comment on column public.leads.newsletter_synced_at is
  'Set once the lead has been pushed to the newsletter provider; null = not yet synced.';

drop function if exists public.capture_lead(text, text, text, text);

create or replace function public.capture_lead(
  p_name text,
  p_email text,
  p_company text default null,
  p_lang text default null,
  p_salutation text default null,
  p_first_name text default null,
  p_last_name text default null,
  p_newsletter_consent boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(btrim(p_name), '') = '' or p_email !~ '^.+@.+\..+$' then
    raise exception 'invalid lead' using errcode = '22023';
  end if;

  insert into public.leads (
    name, email, company, lang,
    salutation, first_name, last_name, newsletter_consent
  )
  values (
    left(btrim(p_name), 200),
    left(lower(btrim(p_email)), 320),
    left(btrim(coalesce(p_company, '')), 200),
    left(coalesce(p_lang, ''), 8),
    case when lower(coalesce(p_salutation, '')) in ('mr', 'ms', 'diverse')
         then lower(p_salutation) end,
    left(btrim(coalesce(p_first_name, '')), 100),
    left(btrim(coalesce(p_last_name, '')), 100),
    coalesce(p_newsletter_consent, false)
  );
end;
$$;

revoke all on function public.capture_lead(text, text, text, text, text, text, text, boolean) from public;
grant execute on function public.capture_lead(text, text, text, text, text, text, text, boolean) to anon, authenticated;

-- list_leads() returns the new columns too.
drop function if exists public.list_leads(text);

create or replace function public.list_leads(passcode text)
returns table (
  salutation text, first_name text, last_name text, name text,
  email text, company text, lang text,
  newsletter_consent boolean, newsletter_synced_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_valid_passcode(passcode) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
    select l.salutation, l.first_name, l.last_name, l.name,
           l.email, l.company, l.lang,
           l.newsletter_consent, l.newsletter_synced_at,
           l.created_at
    from public.leads l
    order by l.created_at desc
    limit 1000;
end;
$$;

revoke all on function public.list_leads(text) from public;
grant execute on function public.list_leads(text) to anon, authenticated;

-- Idempotent: safe to re-run.
