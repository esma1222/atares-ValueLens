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
