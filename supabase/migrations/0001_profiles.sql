-- Georama accounts: username + password (backed by Supabase Auth via a per-user
-- synthetic email), with an OPTIONAL real email for verification / recovery.
--
-- Run this once in your project: Supabase Dashboard -> SQL Editor -> paste -> Run
-- (or `supabase db push` if you use the CLI with these migrations).

create extension if not exists "pgcrypto";

-- ---------- profiles: one row per account, keyed to the auth user ----------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  username       text not null,
  username_lower text not null,
  auth_email     text not null,              -- the synthetic email used for password auth
  email          text,                       -- optional real email (verification / recovery)
  email_verified boolean not null default false,
  stats          jsonb   not null default '{}'::jsonb,   -- the whole game profile lives here
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create unique index if not exists profiles_username_lower_key on public.profiles (username_lower);

alter table public.profiles enable row level security;

-- A signed-in user may read and update ONLY their own row.
drop policy if exists "read own profile"   on public.profiles;
create policy "read own profile"   on public.profiles for select using (auth.uid() = id);

drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- Column privileges: the client can only ever WRITE the `stats` column.
-- username / email / email_verified are changed server-side (Edge Function, service role).
revoke all on public.profiles from anon, authenticated;
grant select (id, username, email, email_verified, stats, created_at, updated_at) on public.profiles to authenticated;
grant update (stats) on public.profiles to authenticated;

-- keep updated_at fresh on every write
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------- optional email verification codes (server-only) ----------
create table if not exists public.email_codes (
  id         uuid primary key references auth.users(id) on delete cascade,
  code_hash  text not null,
  expires_at timestamptz not null
);
alter table public.email_codes enable row level security;  -- no client policies: service role only
