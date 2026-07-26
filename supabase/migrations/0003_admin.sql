-- 0003_admin.sql — moderation console: admin flag, ban, wipe, modify score, recent matches.
-- Run once: Dashboard → SQL Editor → paste → Run. Then flag your account (very bottom).
--
-- Security model: players are NEVER trusted to moderate. Every admin action runs
-- through a SECURITY DEFINER function that first checks the caller is an admin, so
-- the powerful queries can bypass RLS while the *authorization* stays server-side.

-- 1) moderation columns
alter table public.profiles add column if not exists is_admin boolean not null default false;
alter table public.profiles add column if not exists banned   boolean not null default false;

-- 2) lock down what a normal player may write from the client (only their own `stats`).
--    This is what stops anyone from PATCHing is_admin=true on their own row.
revoke update on public.profiles from authenticated;
grant  update (stats) on public.profiles to authenticated;

-- 3) is the current caller an admin?
create or replace function public.is_admin()
  returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- 4) admin: list players (full stats — recent matches live in stats.recent)
create or replace function public.admin_list_players(lim int default 120, q text default null)
  returns table(id uuid, username text, banned boolean, is_admin boolean, email text, stats jsonb, created_at timestamptz)
  language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  return query
    select p.id, p.username, p.banned, p.is_admin, p.email, p.stats, p.created_at
    from public.profiles p
    where q is null or q = '' or p.username ilike '%' || q || '%'
    order by (p.stats->>'elo')::numeric desc nulls last
    limit least(greatest(coalesce(lim, 120), 1), 500);
end; $$;

-- 5) admin actions (each re-checks authorization)
create or replace function public.admin_set_banned(target uuid, val boolean)
  returns void language plpgsql security definer set search_path = '' as $$
begin if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.profiles set banned = val where id = target; end; $$;

create or replace function public.admin_wipe(target uuid)
  returns void language plpgsql security definer set search_path = '' as $$
begin if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.profiles set stats = '{}'::jsonb where id = target; end; $$;

create or replace function public.admin_set_stat(target uuid, skey text, val numeric)
  returns void language plpgsql security definer set search_path = '' as $$
begin if not public.is_admin() then raise exception 'not authorized'; end if;
  update public.profiles
     set stats = jsonb_set(coalesce(stats, '{}'::jsonb), array[skey], to_jsonb(val), true)
   where id = target; end; $$;

grant execute on function public.is_admin() to authenticated;
grant execute on function public.admin_list_players(int, text) to authenticated;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;
grant execute on function public.admin_wipe(uuid) to authenticated;
grant execute on function public.admin_set_stat(uuid, text, numeric) to authenticated;

-- 6) public leaderboard — now also hides banned players (supersedes 0002)
create index if not exists profiles_elo_idx on public.profiles ((((stats->>'elo'))::numeric) desc);
drop function if exists public.leaderboard_top(int);
create function public.leaderboard_top(lim int default 50)
  returns table(rank int, username text, elo int, level int, games int, modes jsonb)
  language sql stable security definer set search_path = '' as $$
  select (row_number() over (order by (p.stats->>'elo')::numeric desc nulls last))::int,
         p.username,
         coalesce((p.stats->>'elo')::numeric, 1000)::int,
         floor(sqrt(coalesce((p.stats->>'xp')::numeric, 0) / 50))::int,
         coalesce((p.stats->>'games')::numeric, 0)::int,
         coalesce(p.stats->'rankElo', '{}'::jsonb)
  from public.profiles p
  where coalesce((p.stats->>'placed')::boolean, false) = true
    and coalesce(p.banned, false) = false
  order by (p.stats->>'elo')::numeric desc nulls last
  limit least(greatest(coalesce(lim, 50), 1), 100);
$$;
grant execute on function public.leaderboard_top(int) to anon, authenticated;

-- 7) ===== MAKE YOURSELF ADMIN =====
-- First sign up IN THE APP with your admin username + password, then run this once
-- with that username (this is the only step that grants moderation powers):
--
--   update public.profiles set is_admin = true where username = 'YOUR_ADMIN_NAME';
