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
  migrations/0002_leaderboard.sql-- public leaderboard_top RPC
  migrations/0003_admin.sql      -- moderation console (admin flag, ban, wipe, edit score)
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

3. **Deploy the function:**
   ```bash
   supabase functions deploy auth --no-verify-jwt
   ```
   `SUPABASE_URL`, `SUPABASE_ANON_KEY` **and `SUPABASE_SERVICE_ROLE_KEY` are
   injected into every Edge Function automatically** — you do NOT need to set
   them. Its URL is `https://<project-ref>.supabase.co/functions/v1/auth`.

### Optional: verification emails

Edge Functions can't send email on their own — you must connect a provider.
The function uses [Resend](https://resend.com) (free tier) when a key is set:

```bash
supabase secrets set RESEND_API_KEY=<your resend key>
# to send from your own domain (see the caveat below):
supabase secrets set MAIL_FROM="Georama <no-reply@yourdomain.com>"
```

Secrets are read at runtime, so **no redeploy is needed** after setting them.

**Delivery caveat:** with the default sender `onboarding@resend.dev`, Resend
only delivers to the email you signed up to Resend with (test mode). To email
*any* user, verify a domain in Resend and set `MAIL_FROM` to an address on it.

Until a provider is configured, the optional email field is stored but no code
is sent — the app now says so clearly, and accounts work fully by
username/password regardless.

The function actions are: `signup`, `login`, `verify`, `resend`.

5. **Auth settings.** Dashboard → Authentication → Providers → Email: leave
   "Confirm email" **off** (username accounts are auto-confirmed; the optional
   real-email check is handled separately by the `verify` action).

## Admin / moderation console

`migrations/0003_admin.sql` adds a **secure moderation console** — reachable
from the full leaderboard page (a 🛡️ button that only appears for admins). From
it you can search players, view anyone's recent matches, **ban / unban**, **wipe
a player's stats**, and **edit their ELO**.

There is no separate "admin login" — you just flag one of your normal accounts.
The security model never trusts the client: every action is a Postgres
`SECURITY DEFINER` function that first checks `is_admin()`, and normal accounts
are only granted write access to their own `stats` column, so nobody can PATCH
`is_admin = true` onto their own row.

**Set up your admin account (one time):**

1. **Sign up in the app** with the username + password you want to be the
   admin (nothing special about the name — any account can be promoted).
2. Dashboard → **SQL Editor** → paste `migrations/0003_admin.sql` → **Run**.
3. Promote that account by running the last line of the file with your name:
   ```sql
   update public.profiles set is_admin = true where username = 'YOUR_ADMIN_NAME';
   ```
4. Log in as that account in the app, open the **full leaderboard page**, and
   the **🛡️ 관리자 콘솔 열기 / Open admin console** button appears.

Banned players are hidden from the public leaderboard and blocked from entering
ranked. To add more admins later, just re-run step 3 with another username.

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
