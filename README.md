# WTT Value Lever Simulator — Project Vision

An interactive PE backsolve / value-lever simulator for **Project Vision**
(EnBW / EKB · WTT CampusOne), built as a self-contained `.dc.html` page on the
`dc-runtime` (React under the hood, see `support.js`).

- `WTT Value Simulator.dc.html` — main simulator with the value-lever sliders,
  DCF/LBO backsolve, tornado sensitivities, and a passcode-gated **calculation
  audit** view.
- `WTT Value Simulator (EBITDA 2026 version).dc.html` — variant, no audit gate.

Open either file in a browser. EN/DE toggle top-right. The audit view opens with
`Ctrl/Cmd + Shift + A`, then the team passcode.

## Passcode gate (Supabase-backed)

The audit passcode is **not** stored in the client. The browser sends the entered
code to the `verify_passcode` Postgres RPC on Supabase, which compares it to a
bcrypt hash in the locked-down `public.access_codes` table and returns only
`true`/`false`.

- Client wiring: `supabase-client.js` (`window.WTTAuth.verifyPasscode`), loaded
  in `WTT Value Simulator.dc.html` alongside the `@supabase/supabase-js` CDN
  build.
- Server side: `supabase/migrations/0001_passcode_gate.sql`.

The current passcode is **`atares2026`** (preserved from the original build).

### One-time setup: apply the migration

The hosted project (`oldfpsvbmwhkbtfrzmdi`) needs the migration applied once. With
the [Supabase CLI](https://supabase.com/docs/guides/cli):

```bash
supabase login                          # or export SUPABASE_ACCESS_TOKEN
supabase link --project-ref oldfpsvbmwhkbtfrzmdi
supabase db push
```

Or paste the contents of `supabase/migrations/0001_passcode_gate.sql` into the
Supabase dashboard **SQL Editor** and run it once.

Until the migration is applied, entering any passcode shows **"Connection
unavailable"** rather than unlocking.

### Rotate the passcode

Run in the SQL Editor (no client change needed):

```sql
update public.access_codes set active = false;
insert into public.access_codes (label, code_hash)
values ('atares team', extensions.crypt('NEW_CODE', extensions.gen_salt('bf', 10)));
```

## Configuration

| What | Where |
| --- | --- |
| Project URL + publishable key | `supabase-client.js`, `.env.example` |
| Project ref link | `supabase/config.toml` |

The **publishable** key is intended to be public; it can only do what row-level
security allows, and `access_codes` is readable by no one. Never commit the
service-role key or a database password.

## Notes

- `uploads/` holds source material (RfP, proposal, pitchbook fill guide, the
  backsolve calculator, brand assets) and is not part of the running app.
- Requires internet access in the viewer's browser to reach Supabase and the
  supabase-js CDN. Offline, the simulator still runs; only the audit gate is
  unavailable.
