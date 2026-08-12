# atares ValueLens

> see how operational upside translates into deal value

An interactive value-lever and PE backsolve simulator for **Project Vision**,
built as a self-contained `.dc.html` page on the `dc-runtime` (React under the
hood, see `support.js`).

`ValueLens.dc.html` is the application. Open it in a browser, or deploy the repo
to any static host. EN/DE toggle in the header.

## Access model

| Role | How you get it | What it allows |
| --- | --- | --- |
| `guest` | default | one exploratory run; each assumption can be set once |
| `user` | sign-in modal (name + email + company) | unrestricted sliders |
| `admin` | passcode | unrestricted, plus the saved-project library |

Roles, the guest allowance and the saved-project library are held in
`localStorage` (`valuelens.session.v1`, `valuelens.guest.v1`,
`valuelens.projects.v1`).

## Admin passcode (Supabase-backed)

The admin passcode is **not** stored in the client. The browser sends the
entered code to the `verify_passcode` Postgres RPC on Supabase, which compares
it to a bcrypt hash in the locked-down `public.access_codes` table and returns
only `true`/`false`.

- Client wiring: `supabase-client.js` (`window.WTTAuth.verifyPasscode`), loaded
  in `ValueLens.dc.html` alongside the `@supabase/supabase-js` CDN build.
- Server side: `supabase/migrations/0001_passcode_gate.sql`.

The current passcode is **`atares2026`**.

### Required one-time setup

The hosted project (`oldfpsvbmwhkbtfrzmdi`) needs the migration applied once.
**Until it is, the admin modal shows "Connection unavailable" and no passcode
will work.** Either:

```bash
supabase login                          # or export SUPABASE_ACCESS_TOKEN
supabase link --project-ref oldfpsvbmwhkbtfrzmdi
supabase db push
```

…or paste `supabase/migrations/0001_passcode_gate.sql` into the Supabase
dashboard **SQL Editor** and run it. The migration is idempotent, so re-running
it is safe. Verify with:

```sql
select public.verify_passcode('atares2026');  -- expect: true
```

### Rotate the passcode

No client change needed:

```sql
update public.access_codes set active = false;
insert into public.access_codes (label, code_hash)
values ('atares team', extensions.crypt(lower('NEW_CODE'), extensions.gen_salt('bf', 10)));
```

## Deployment

Static hosting. `vercel.json` rewrites `/` to `/ValueLens.dc.html`, so the site
root serves the app with a clean URL — without it, hosts return **404
NOT_FOUND** at `/`, because the app file is never served as the default
document. On a host other than Vercel, add the equivalent rewrite or an
`index.html`.

## Configuration

| What | Where |
| --- | --- |
| Project URL + publishable key | `supabase-client.js`, `.env.example` |
| Project ref link | `supabase/config.toml` |
| Root URL rewrite | `vercel.json` |

The **publishable** key is intended to be public; it can only do what row-level
security allows, and `access_codes` is readable by no one. Never commit the
service-role key or a database password.

## Notes

- Assets: `atares-logo-navy.svg`, `atares-logo-white.svg`, and the `bg-*.jpg`
  section backgrounds.
- `uploads/` holds source material (RfP, proposal, pitchbook fill guide, the
  backsolve calculator, brand assets, screenshots) and is not part of the
  running app.
- The viewer's browser needs internet access to reach the unpkg (React) and
  jsDelivr (supabase-js) CDNs. Offline, the simulator still runs; only the admin
  passcode gate is unavailable.
