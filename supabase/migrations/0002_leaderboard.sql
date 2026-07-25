-- Public top-N leaderboard by ranked ELO — one indexed query, no data
-- duplication. A SECURITY DEFINER function reads profiles (bypassing RLS) but
-- only ever returns public-safe columns (username, elo, level, games).
--
-- Run once: Dashboard -> SQL Editor -> paste -> Run.

-- functional index so the ordering stays cheap as the table grows
create index if not exists profiles_elo_idx
  on public.profiles ((((stats->>'elo'))::numeric) desc);

create or replace function public.leaderboard_top(lim int default 50)
  returns table(rank int, username text, elo int, level int, games int)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select (row_number() over (order by (p.stats->>'elo')::numeric desc nulls last))::int as rank,
         p.username,
         coalesce((p.stats->>'elo')::numeric, 1000)::int as elo,
         floor(sqrt(coalesce((p.stats->>'xp')::numeric, 0) / 50))::int as level,
         coalesce((p.stats->>'games')::numeric, 0)::int as games
  from public.profiles p
  where coalesce((p.stats->>'placed')::boolean, false) = true
  order by (p.stats->>'elo')::numeric desc nulls last
  limit least(greatest(coalesce(lim, 50), 1), 100);
$$;

-- anyone (even logged-out) can read the leaderboard
grant execute on function public.leaderboard_top(int) to anon, authenticated;
