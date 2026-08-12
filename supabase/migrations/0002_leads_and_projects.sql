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
