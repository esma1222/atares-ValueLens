-- atares ValueLens — complete Supabase setup.
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Safe to run more than once.

-- Passcode gate for the WTT Value Simulator "calculation audit" view.
--
-- Goal: keep the existing passcode UX, but stop shipping the passcode in the
-- client. The code is stored only as a bcrypt hash in a table that the
-- anon/publishable key can never read, and the browser verifies a candidate
-- through a SECURITY DEFINER function that returns nothing but true/false.

-- pgcrypto provides crypt() / gen_salt(). On Supabase it lives in the
-- dedicated `extensions` schema.
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Access-code store (never exposed to the client)
-- ---------------------------------------------------------------------------
create table if not exists public.access_codes (
  id         uuid        primary key default gen_random_uuid(),
  label      text        not null,
  code_hash  text        not null,
  active     boolean     not null default true,
  created_at timestamptz not null default now()
);

comment on table public.access_codes is
  'Bcrypt hashes of team passcodes for the value-simulator audit gate. Read only via verify_passcode().';

-- RLS on, and no policies are created: the anon and authenticated roles can
-- match no rows, so the publishable key cannot read the hashes. Only the
-- SECURITY DEFINER function below (owned by the migration/postgres role) can.
alter table public.access_codes enable row level security;
revoke all on table public.access_codes from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verification RPC
-- ---------------------------------------------------------------------------
create or replace function public.verify_passcode(candidate text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  -- Codes are stored and compared lower-cased: bcrypt is case-sensitive, and
  -- the original gate accepted any capitalisation. Normalising here (not only
  -- in the browser) keeps that true regardless of the caller.
  select exists (
    select 1
    from public.access_codes ac
    where ac.active
      and ac.code_hash = crypt(lower(btrim(candidate)), ac.code_hash)
  );
$$;

comment on function public.verify_passcode(text) is
  'Returns true when the candidate matches an active team passcode. Never returns the passcode itself.';

revoke all on function public.verify_passcode(text) from public;
grant execute on function public.verify_passcode(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Seed the current atares team passcode
-- ---------------------------------------------------------------------------
-- Preserves the original code ('atares2026'). Store the hash of the LOWER-CASE
-- code — verify_passcode() lower-cases the candidate before comparing.
-- Rotate it later with:
--   update public.access_codes set active = false;                 -- retire old
--   insert into public.access_codes (label, code_hash)
--   values ('atares team', extensions.crypt(lower('NEW_CODE'), extensions.gen_salt('bf', 10)));
insert into public.access_codes (label, code_hash)
select 'atares team', extensions.crypt(lower('atares2026'), extensions.gen_salt('bf', 10))
where not exists (select 1 from public.access_codes);

-- This whole migration is idempotent (guarded creates + a guarded seed), so it
-- is safe to re-run against a project where it was already applied.


-- ValueLens: server-side lead capture and the admin scenario library.
--
-- Access model note: the app has no Supabase Auth session — the admin role is
-- established by a shared team passcode. So every privileged call re-presents
-- that passcode and the SECURITY DEFINER function verifies it server-side via
-- the same bcrypt check used by verify_passcode(). Neither table is readable
-- through PostgREST directly; the RPCs below are the only way in.

-- ---------------------------------------------------------------------------
-- Shared guard
-- ---------------------------------------------------------------------------
create or replace function public.is_valid_passcode(candidate text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1
    from public.access_codes ac
    where ac.active
      and ac.code_hash = crypt(lower(btrim(candidate)), ac.code_hash)
  );
$$;

revoke all on function public.is_valid_passcode(text) from public;
-- Not granted to anon: internal helper, called only by the functions below.

-- ---------------------------------------------------------------------------
-- Leads captured by the sign-in modal
-- ---------------------------------------------------------------------------
create table if not exists public.leads (
  id         uuid        primary key default gen_random_uuid(),
  name       text        not null,
  email      text        not null,
  company    text,
  lang       text,
  created_at timestamptz not null default now()
);

comment on table public.leads is
  'ValueLens sign-in captures. Written only via capture_lead(); read only via list_leads() with the team passcode.';

alter table public.leads enable row level security;
revoke all on table public.leads from anon, authenticated;

create index if not exists leads_created_at_idx on public.leads (created_at desc);

-- Write-only entry point for the browser: accepts a lead, returns nothing.
create or replace function public.capture_lead(
  p_name text,
  p_email text,
  p_company text default null,
  p_lang text default null
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

  insert into public.leads (name, email, company, lang)
  values (
    left(btrim(p_name), 200),
    left(lower(btrim(p_email)), 320),
    left(btrim(coalesce(p_company, '')), 200),
    left(coalesce(p_lang, ''), 8)
  );
end;
$$;

revoke all on function public.capture_lead(text, text, text, text) from public;
grant execute on function public.capture_lead(text, text, text, text) to anon, authenticated;

-- Admin read-back (the dashboard works too; this keeps it in-app if wanted).
create or replace function public.list_leads(passcode text)
returns table (name text, email text, company text, lang text, created_at timestamptz)
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
    select l.name, l.email, l.company, l.lang, l.created_at
    from public.leads l
    order by l.created_at desc
    limit 1000;
end;
$$;

revoke all on function public.list_leads(text) from public;
grant execute on function public.list_leads(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Saved scenarios (admin scenario library)
-- ---------------------------------------------------------------------------
create table if not exists public.projects (
  name       text        primary key,
  data       jsonb       not null,
  saved_at   timestamptz not null default now()
);

comment on table public.projects is
  'ValueLens saved scenarios. Reachable only through the passcode-gated project RPCs.';

alter table public.projects enable row level security;
revoke all on table public.projects from anon, authenticated;

create or replace function public.list_projects(passcode text)
returns table (name text, data jsonb, saved_at timestamptz)
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
    select p.name, p.data, p.saved_at
    from public.projects p
    order by p.name;
end;
$$;

create or replace function public.save_project(passcode text, p_name text, p_data jsonb)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_saved_at timestamptz;
begin
  if not public.is_valid_passcode(passcode) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'name required' using errcode = '22023';
  end if;

  insert into public.projects (name, data, saved_at)
  values (left(btrim(p_name), 200), p_data, now())
  on conflict (name) do update
    set data = excluded.data,
        saved_at = excluded.saved_at
  returning saved_at into v_saved_at;

  return v_saved_at;
end;
$$;

create or replace function public.delete_project(passcode text, p_name text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_valid_passcode(passcode) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.projects where name = btrim(p_name);
end;
$$;

revoke all on function public.list_projects(text) from public;
revoke all on function public.save_project(text, text, jsonb) from public;
revoke all on function public.delete_project(text, text) from public;

grant execute on function public.list_projects(text) to anon, authenticated;
grant execute on function public.save_project(text, text, jsonb) to anon, authenticated;
grant execute on function public.delete_project(text, text) to anon, authenticated;

-- Idempotent: safe to re-run.


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


