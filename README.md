# atares ValueLens

> see how operational upside translates into deal value

An interactive value-lever and PE backsolve simulator for **Project Vision**,
built as a self-contained `.dc.html` page on the `dc-runtime` (React under the
hood, see `support.js`).

`ValueLens.dc.html` is the application. Open it in a browser, or deploy the repo
to any static host. EN/DE toggle in the header.

## Access model — free vs registered

ValueLens has two levels. The calculation engine is the same for both; the
difference is which inputs a user may edit.

| Role | How you get it | Model |
| --- | --- | --- |
| `guest` | default, no sign-up | **Free model:** Revenue + EBITDA -> price, volume, synergy |
| `user` | sign-up modal | **Full model:** every assumption editable |
| `admin` | passcode | Full model plus the saved-project library |

### Free model

A guest edits five things: current **Revenue**, current **EBITDA**, and the
three value drivers **price impact**, **volume impact** and **cost synergies**.
Everything else keeps its standard value, stays visible, and is shown disabled
with a lock chip and a sign-up CTA.

No volume-unit input is required. That is safe because the engine is
scale-invariant in `cust0`: revenue is `cust x arpu` where `arpu0 = rev0/cust0`,
so `cust0` cancels out of every output. Hiding it changes no number.

The price/volume economics the free model advertises are the engine's existing
behaviour, not a second calculation:

- **Price** raises revenue with no extra cost, so it flows to EBITDA at 100%.
- **Volume** scales the volume-variable share of the cost base with it, so it
  flows through at the contribution margin (`1 - varShare x opex/revenue`).

`ADV_KEYS` in `ValueLens.dc.html` lists the locked assumptions. The guard lives
in `allow()`, so the rule holds even if the disabled attributes are stripped in
the browser.

## Data captured in Supabase

| Feature | Table | Who can write | Who can read |
| --- | --- | --- | --- |
| Sign-in lead capture | `leads` | anyone, via `capture_lead()` | passcode holders, via `list_leads()` |
| Scenario library | `projects` | passcode holders | passcode holders |
| Admin passcode | `access_codes` | nobody (seeded by migration) | nobody — only compared inside the RPCs |

No table is readable through the publishable key directly; every path goes
through a `SECURITY DEFINER` function. Because the app has no Supabase Auth
session, the privileged project calls re-present the admin passcode and the
database re-verifies it on each call. The passcode is therefore held in the
admin's own `localStorage` session (`valuelens.session.v1`) until sign-out.

**Sign-in captures a name, email and company to a server.** The hero copy was
updated accordingly — it previously claimed "no data leaves the device", which
is no longer true. Make sure your privacy notice covers this before going live.

The scenario library still writes to `localStorage` first, so the tool keeps
working offline; for admins it mirrors to Supabase and reconciles on sign-in,
with the most recent write winning per scenario name.

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

…or paste the migrations in `supabase/migrations/` into the Supabase dashboard
**SQL Editor** and run them in order (`0001`, `0002`, `0003`) — or
just run `supabase/setup.sql`, which is all of them concatenated. All are
idempotent, so re-running is safe. Verify with:

```sql
select public.verify_passcode('atares2026');  -- expect: true
select count(*) from public.list_projects('atares2026');
```

### Rotate the passcode

No client change needed:

```sql
update public.access_codes set active = false;
insert into public.access_codes (label, code_hash)
values ('atares team', extensions.crypt(lower('NEW_CODE'), extensions.gen_salt('bf', 10)));
```

## TechSpheres newsletter integration — NOT connected

Sign-up collects the fields the atares TechSpheres form asks for — **salutation,
first name, last name, email** — plus an explicit consent tick, and stores them
in `public.leads` (`salutation`, `first_name`, `last_name`,
`newsletter_consent`). The consent wording is taken verbatim from the existing
atares.team newsletter form.

**No Mailchimp/newsletter integration exists in this repository**, and no API
credentials are present, so nothing is pushed to the newsletter provider yet.
Leads are captured in Supabase and wait there: `leads.newsletter_synced_at` is
null until something syncs them.

To connect it, the following is still required — none of it can be guessed:

| Needed | Why |
| --- | --- |
| Provider confirmation (Mailchimp or other) | determines the API to call |
| API key | server-side auth |
| Audience / list ID | which list to subscribe to |
| Merge-field names for salutation / first / last | Mailchimp defaults are `FNAME`/`LNAME`; the salutation field is custom |
| Single vs double opt-in | decides whether to send `subscribed` or `pending` |
| Confirmation that the ValueLens consent text satisfies the same legal basis | the wording is reused, the context is new |

Recommended shape once available: a Supabase Edge Function triggered on insert
into `leads`, holding the API key as a secret and stamping
`newsletter_synced_at` on success. The API key must not go in the browser —
`supabase-client.js` ships to every visitor.

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
