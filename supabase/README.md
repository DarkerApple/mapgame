# Georama × Supabase — accounts backend

Username + password accounts (with optional email verification), backed by a
Supabase **Edge Function** + Postgres. Passwords are hashed by Supabase Auth;
each account gets a per-user *synthetic* email so users only ever type a
username. Game stats live in `profiles.stats` (JSON), protected by Row Level
Security so each user can only touch their own row.

## What's here

```
supabase/
  migrations/0001_profiles.sql   -- profiles table + RLS + email_codes
  functions/auth/index.ts        -- signup / login / verify Edge Function
```

## One-time setup

1. **Create the tables.** Dashboard → **SQL Editor** → paste
   `migrations/0001_profiles.sql` → **Run**.

2. **Install the CLI & link the project** (once):
   ```bash
   npm i -g supabase
   supabase login
   supabase link --project-ref <YOUR-PROJECT-REF>   # the xxxx in xxxx.supabase.co
   ```

3. **Set the service-role secret** the function needs:
   ```bash
   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<your service_role key>
   # optional — only if you want real verification emails sent:
   supabase secrets set RESEND_API_KEY=<your resend key>
   ```
   > `SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected automatically — don't set them.
   > The **service_role** key is a secret: it goes in function secrets only, never in the client.

4. **Deploy the function:**
   ```bash
   supabase functions deploy auth --no-verify-jwt
   ```
   Its URL will be `https://<project-ref>.functions.supabase.co/auth`.

5. **Auth settings.** Dashboard → Authentication → Providers → Email: leave
   "Confirm email" **off** (username accounts are auto-confirmed; the optional
   real-email check is handled separately by the `verify` action).

## The client only needs two public values

In the game's config block, paste:

- **Project URL** — `https://<project-ref>.supabase.co`
- **anon public key** — Dashboard → Project Settings → API → `anon` `public`

Both are safe to ship in client code. Never put the `service_role` key there.

## API (POST JSON to the function URL)

| action   | body                                   | returns                                   |
|----------|----------------------------------------|-------------------------------------------|
| `signup` | `{username, password, email?}`         | `{ok, username, session:{access_token, refresh_token}}` |
| `login`  | `{username, password}`                 | `{ok, session:{...}}`                      |
| `verify` | `{access_token, code}`                 | `{ok, email_verified:true}`               |

Errors come back as `{error: "<code>"}` with an HTTP status (e.g.
`username_taken` 409, `bad_credentials` 401).
