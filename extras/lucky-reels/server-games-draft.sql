-- DRAFT, DO NOT RUN YET: the server-side games, still being built and tested. The page does not use it yet.
-- Once it is finished it moves into supabase-setup.sql as a "run this part once" section.


-- ---------------------------------------------------------------------------
-- Games on the server: run this part once (after all parts above). Until now the page itself drew the
-- results of slots, blackjack, Plinko, Chicken, coin flip, solo poker, the gamble and Lucky Burger and then
-- saved the new balance, so a player who changed the page could give himself wins. From now on the database
-- draws every result, pays it and keeps credits, level, XP, goodies, missions, achievements and the burger
-- career; a page can no longer change any of them, it only shows what the database says. Pages from before
-- this update keep working for everything else, but their winnings no longer count: reload them.
-- The blackjack shoe, the dealer's hidden card and the poker deck stay in a table no page can read.
create table if not exists public.lr_secret (
  player uuid primary key references public.players (id) on delete cascade,
  shoe integer[] not null default '{}',
  hole integer,
  pk jsonb
);
alter table public.lr_secret enable row level security;
revoke all on public.lr_secret from anon, authenticated;

-- settled live-game bets whose goodie and event extras (and XP) were paid
alter table public.horse_bets add column if not exists bonused boolean not null default false;
alter table public.roulette_bets add column if not exists bonused boolean not null default false;
alter table public.rocket_bets add column if not exists bonused boolean not null default false;
alter table public.lotto_tickets add column if not exists bonused boolean not null default false;
update public.horse_bets set bonused = true where not bonused and (payout is not null or claimed);
update public.roulette_bets set bonused = true where not bonused and (payout is not null or claimed);
update public.rocket_bets set bonused = true where not bonused and (payout is not null or claimed);
update public.lotto_tickets set bonused = true where not bonused;
create index if not exists horse_bets_bonus on public.horse_bets (player) where not bonused;
create index if not exists roulette_bets_bonus on public.roulette_bets (player) where not bonused;
create index if not exists rocket_bets_bonus on public.rocket_bets (player) where not bonused;
create index if not exists lotto_tickets_bonus on public.lotto_tickets (player) where not bonused;

-- The parts of the saved game only the database may change.
create or replace function public.lr_protect(n jsonb, o jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  k text;
  p text[];
begin
  if n is null or jsonb_typeof(n) <> 'object' then n := '{}'::jsonb; end if;
  if o is null or jsonb_typeof(o) <> 'object' then o := '{}'::jsonb; end if;
  foreach k in array array['credits', 'level', 'prestige', 'spins', 'jackpots', 'best', 'lastWin', 'owned', 'xp', 'streak', 'stars', 'starBank',
    'freeSpins', 'freeBet', 'freeTotal', 'nudges', 'missions', 'missionsDone', 'ach', 'sl', 'job', 'jobReset', 'rrAt', 'srv', 'evGifts'] loop
    if o ? k then n := jsonb_set(n, array[k], o -> k); else n := n - k; end if;
  end loop;
  foreach p slice 1 in array array[['bj', 'round'], ['bj', 'hands'], ['bj', 'lastBet'], ['bj', 'shoe'], ['pl', 'drops'], ['pl', 'pending'],
    ['ck', 'round'], ['ck', 'games'], ['cf', 'round'], ['cf', 'flips'], ['pk', 'solo'], ['pk', 'hands']] loop
    if jsonb_typeof(n -> p[1]) is distinct from 'object' then n := jsonb_set(n, array[p[1]], '{}'::jsonb); end if;
    if o #> p is not null then n := jsonb_set(n, p, o #> p); else n := n #- p; end if;
  end loop;
  return n;
end;
$$;

-- A page saves only what is its own (bets it typed, sounds, the game it has open, cosmetics switched on);
-- the rest stays as the database has it. Names styles and trophies need the goodie.
create or replace function public.players_0_lock()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  o jsonb;
  n jsonb;
begin
  if current_user <> 'authenticated' then return new; end if;
  new.credits := old.credits; new.level := old.level; new.prestige := old.prestige;
  new.spins := old.spins; new.jackpots := old.jackpots; new.best := old.best;
  if new.game is distinct from old.game then
    begin o := old.game::jsonb; exception when others then o := '{}'::jsonb; end;
    begin n := new.game::jsonb; exception when others then n := o; end;
    new.game := public.lr_protect(n, o)::text;
  end if;
  begin
    if o is null then o := coalesce(old.game::jsonb, '{}'::jsonb); end if;
    begin
      if new.flair is not null and new.flair <> 'admin' and coalesce((o -> 'owned' ->> (case new.flair when 'neon' then 'neon' when 'gold' then 'goldName'
        when 'fire' then 'fireName' when 'ice' then 'iceName' when 'galaxy' then 'galaxyName' else '-' end))::boolean, false) is not true then new.flair := null; end if;
      if coalesce(array_length(new.trophies, 1), 0) > 0 then
        new.trophies := array(select t from unnest(new.trophies) with ordinality u(t, i)
          where (i = 1 and t = '') or coalesce((o -> 'owned' ->> t)::boolean, false) order by i);
      end if;
    end;
  exception when others then null;
  end;
  return new;
end;
$$;
drop trigger if exists players_0_lock on public.players;
create trigger players_0_lock before update on public.players for each row execute function public.players_0_lock();
-- these checked what pages saved; with the lock there is nothing left for them to check
drop trigger if exists players_guard on public.players;
drop trigger if exists players_watch on public.players;
drop trigger if exists players_keep_job on public.players;

-- Settings the games use, cleaned like the page does it, and the events running right now.
create or replace function public.lr_num(v jsonb, def numeric, lo numeric, hi numeric)
returns numeric
language plpgsql
immutable
as $$
declare
  x numeric;
begin
  if v is null or jsonb_typeof(v) not in ('number', 'string') then return def; end if;
  begin x := (v #>> '{}')::numeric; exception when others then return def; end;
  if x is null or x = 'NaN'::numeric then return def; end if;
  return least(hi, greatest(lo, x));
end;
$$;

create or replace function public.lr_cfg()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d jsonb;
  econ boolean;
  t numeric := floor(extract(epoch from now()) * 1000);
begin
  select coalesce(data, '{}'::jsonb) into d from public.settings where id = 1;
  d := coalesce(d, '{}'::jsonb);
  econ := public.lr_num(d -> 'econ', 0, 0, 100) = 3;
  return jsonb_build_object(
    'winMultiplier', public.lr_num(d -> 'winMultiplier', 1, 0.1, 100),
    'jackpotPay', case when econ then round(public.lr_num(d -> 'jackpotPay', 150, 1, 100000)) else 150 end,
    'starGoal', case when econ then round(public.lr_num(d -> 'starGoal', 15, 3, 50)) else 15 end,
    'freeSpins', case when econ then round(public.lr_num(d -> 'freeSpins', 8, 1, 50)) else 8 end,
    'freeMult', case when econ then round(public.lr_num(d -> 'freeMult', 2, 1, 20)) else 2 end,
    'nudgeChance', case when econ then round(public.lr_num(d -> 'nudgeChance', 12, 0, 100)) else 12 end,
    'holdChance', case when econ then round(public.lr_num(d -> 'holdChance', 15, 0, 100)) else 15 end,
    'maxBet', round(public.lr_num(d -> 'maxBet', 0, 0, 9007199254740991)),
    'startCredits', round(public.lr_num(d -> 'startCredits', 500, 0, 1e12)),
    'maintenance', coalesce(d -> 'maintenance' = 'true'::jsonb or d -> 'maintenance' = '"true"'::jsonb, false),
    'evs', coalesce((select jsonb_agg(e) from jsonb_array_elements(case when jsonb_typeof(d -> 'events') = 'array' then d -> 'events' else '[]'::jsonb end) e
      where jsonb_typeof(e) = 'object' and coalesce(e ->> 'id', '') <> '' and public.lr_num(e -> 'start', 0, 0, 1e16) > 0
        and public.lr_num(e -> 'end', 0, 0, 1e16) > public.lr_num(e -> 'start', 0, 0, 1e16)
        and t >= public.lr_num(e -> 'start', 0, 0, 1e16) and t < public.lr_num(e -> 'end', 0, 0, 1e16)), '[]'::jsonb));
end;
$$;

-- an event's boost for one game (they stack), a factor like XP or wages, the shop discount
create or replace function public.lr_evm(c jsonb, game text) returns numeric language plpgsql immutable as $$
declare
  m numeric := 1;
  e jsonb;
begin
  for e in select * from jsonb_array_elements(c -> 'evs') loop
    m := m * public.lr_num(case when coalesce(e -> 'fx' -> 'mult' ->> 'all', '0') in ('0', '') then '1'::jsonb else e -> 'fx' -> 'mult' -> 'all' end, 1, 1, 10)
      * public.lr_num(case when coalesce(e -> 'fx' -> 'mult' ->> game, '0') in ('0', '') then '1'::jsonb else e -> 'fx' -> 'mult' -> game end, 1, 1, 10);
  end loop;
  return least(20, m);
end;
$$;
create or replace function public.lr_evf(c jsonb, k text) returns numeric language plpgsql immutable as $$
declare
  m numeric := 1;
  e jsonb;
begin
  for e in select * from jsonb_array_elements(c -> 'evs') loop
    m := m * public.lr_num(case when coalesce(e -> 'fx' ->> k, '0') in ('0', '') then '1'::jsonb else e -> 'fx' -> k end, 1, 1, 10);
  end loop;
  return least(10, m);
end;
$$;
create or replace function public.lr_evd(c jsonb) returns numeric language sql immutable as $$
  select coalesce(max(public.lr_num(e -> 'fx' -> 'discount', 0, 0, 90)), 0) / 100 from jsonb_array_elements(c -> 'evs') e
$$;
-- the admin's happy hour times the events
create or replace function public.lr_wm(c jsonb, game text) returns numeric language sql immutable as $$
  select (c ->> 'winMultiplier')::numeric * public.lr_evm(c, game)
$$;
create or replace function public.lr_lim(c jsonb, lv integer) returns numeric language sql immutable as $$
  select least(public.lr_bet_limit(lv, 0), case when (c ->> 'maxBet')::numeric > 0 then (c ->> 'maxBet')::numeric else 9007199254740991 end)
$$;
create or replace function public.lr_rand(n integer) returns integer language sql volatile as $$
  select least(n - 1, floor(random() * n)::integer)
$$;
create or replace function public.lr_xp_need(lv integer) returns numeric language sql immutable as $$
  select floor(120 * power(lv::numeric, 1.4))
$$;
create or replace function public.lr_n(g jsonb, k text) returns numeric language sql immutable as $$
  select coalesce(case when jsonb_typeof(g -> k) = 'number' then (g ->> k)::numeric end, 0)
$$;
create or replace function public.lr_has(g jsonb, k text) returns boolean language sql immutable as $$
  select coalesce(case jsonb_typeof(g -> 'owned' -> k) when 'boolean' then (g -> 'owned' ->> k)::boolean when 'number' then (g -> 'owned' ->> k)::numeric > 0 else false end, false)
$$;
-- what the page is told besides the game: level-ups, achievements, missions, goodie extras
create or replace function public.lr_out(g jsonb, k text, v jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(g, array['_out'], coalesce(g -> '_out', '{}'::jsonb) || jsonb_build_object(k, coalesce(g -> '_out' -> k, '[]'::jsonb) || jsonb_build_array(v)))
$$;
create or replace function public.lr_add(g jsonb, k text, v numeric) returns jsonb language sql immutable as $$
  select g || jsonb_build_object(k, public.lr_n(g, k) + v)
$$;

-- The player who calls, locked for this call.
create or replace function public.lr_me()
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select * into p from public.players where id = auth.uid() for update;
  if p.id is null or p.is_banned then raise exception 'not allowed'; end if;
  return p;
end;
$$;

create or replace function public.lr_new_mission(ex text[], lv integer)
returns jsonb
language plpgsql
volatile
as $$
declare
  types text[] := array(select t from unnest(array['spins', 'wins', 'earn', 'stars', 'three', 'streak', 'wilds', 'nudge', 'gamble', 'hold']) t where not t = any(coalesce(ex, '{}')));
  t text;
  tier integer := public.lr_rand(3);
begin
  t := types[1 + public.lr_rand(array_length(types, 1))];
  return jsonb_build_object('t', t, 'goal', public.lr_goal(t, tier), 'prog', 0, 'reward', 150 * greatest(1, lv) * (tier + 1));
end;
$$;
create or replace function public.lr_goal(t text, tier integer) returns integer language sql immutable as $$
  select (case t when 'spins' then array[15, 25, 40] when 'wins' then array[5, 8, 12] when 'earn' then array[20, 40, 80] when 'stars' then array[3, 5, 8]
    when 'three' then array[1, 2, 3] when 'streak' then array[3, 4, 5] when 'wilds' then array[2, 4, 6] when 'nudge' then array[1, 2, 3]
    when 'gamble' then array[2, 3, 5] when 'hold' then array[1, 2, 3] end)[tier + 1]
$$;
-- three missions, each of another kind
create or replace function public.lr_fill(g jsonb)
returns jsonb
language plpgsql
volatile
as $$
declare
  ms jsonb := '[]'::jsonb;
  m jsonb;
  ex text[] := '{}';
begin
  for m in select * from jsonb_array_elements(case when jsonb_typeof(g -> 'missions') = 'array' then g -> 'missions' else '[]'::jsonb end) loop
    if jsonb_typeof(m) = 'object' and m ->> 't' in ('spins', 'wins', 'earn', 'stars', 'three', 'streak', 'wilds', 'nudge', 'gamble', 'hold')
       and not (m ->> 't') = any(ex) and jsonb_array_length(ms) < 3 and jsonb_typeof(m -> 'goal') = 'number' and jsonb_typeof(m -> 'reward') = 'number' then
      ms := ms || jsonb_build_array(jsonb_build_object('t', m ->> 't', 'goal', least(80, greatest(1, (m ->> 'goal')::numeric)),
        'prog', public.lr_num(m -> 'prog', 0, 0, 1e9), 'reward', least(150 * 20 * 3, greatest(0, (m ->> 'reward')::numeric))));
      ex := ex || (m ->> 't');
    end if;
  end loop;
  while jsonb_array_length(ms) < 3 loop
    m := public.lr_new_mission(ex, public.lr_n(g, 'level')::integer);
    ms := ms || jsonb_build_array(m);
    ex := ex || (m ->> 't');
  end loop;
  return g || jsonb_build_object('missions', ms);
end;
$$;

-- The saved game as the database keeps it. The first time a player comes with this update, rounds an old
-- page left open give their stake back (they can't be finished the new way) and the numbers are checked.
create or replace function public.lr_g(p public.players)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  g jsonb;
  back numeric := 0;
  lim numeric := public.lr_bet_limit(p.level, 0);
  k text;
begin
  begin g := p.game::jsonb; exception when others then g := null; end;
  if g is null or jsonb_typeof(g) <> 'object' then g := '{}'::jsonb; end if;
  if not g ? 'srv' then
    begin
      if g #>> '{bj,round,phase}' in ('player', 'dealer') then
        select least(lim * 4, coalesce(sum(public.lr_num(h -> 'bet', 0, 0, lim * 2)), 0)) into back
          from jsonb_array_elements(case when jsonb_typeof(g #> '{bj,round,hands}') = 'array' then g #> '{bj,round,hands}' else '[]'::jsonb end) h;
      end if;
      if jsonb_typeof(g #> '{ck,round}') = 'object' then back := back + public.lr_num(g #> '{ck,round,bet}', 0, 0, lim); end if;
      if jsonb_typeof(g #> '{cf,round}') = 'object' then back := back + public.lr_num(g #> '{cf,round,bet}', 0, 0, lim); end if;
      if jsonb_typeof(g #> '{pk,solo,seats}') = 'array' then
        back := back + coalesce((select least(greatest(lim * 200, 200000), public.lr_num(s -> 'stack', 0, 0, 1e15))
          from jsonb_array_elements(g #> '{pk,solo,seats}') s where jsonb_typeof(s) = 'object' and s ->> 'pid' = p.id::text limit 1), 0);
      end if;
    exception when others then null;
    end;
    foreach k in array array['xp', 'streak', 'stars', 'starBank', 'freeSpins', 'freeBet', 'freeTotal', 'nudges', 'missionsDone', 'lastWin', 'jobReset', 'rrAt'] loop
      g := g || jsonb_build_object(k, floor(public.lr_num(g -> k, 0, 0, 1e15)));
    end loop;
    g := g || jsonb_build_object('freeSpins', least(200, public.lr_n(g, 'freeSpins')), 'stars', least(49, public.lr_n(g, 'stars')), 'nudges', 0,
      'owned', case when jsonb_typeof(g -> 'owned') = 'object' then g -> 'owned' else '{}'::jsonb end,
      'ach', case when jsonb_typeof(g -> 'ach') = 'object' then g -> 'ach' else '{}'::jsonb end,
      'job', case when jsonb_typeof(g -> 'job') = 'object' then jsonb_build_object('worked', public.lr_num(g #> '{job,worked}', 0, 0, 1e9),
        'earned', floor(public.lr_num(g #> '{job,earned}', 0, 0, 1e15)), 'shifts', floor(public.lr_num(g #> '{job,shifts}', 0, 0, 1e9)),
        'pos', floor(public.lr_num(g #> '{job,pos}', 0, 0, 7))) else jsonb_build_object('worked', 0, 'earned', 0, 'shifts', 0, 'pos', 0) end,
      'sl', '{}'::jsonb, 'srv', 1, 'credits', least(9007199254740991, p.credits + floor(back)));
    if public.lr_n(g, 'freeSpins') > 0 and public.lr_n(g, 'freeBet') < 1 then g := g || jsonb_build_object('freeBet', 1); end if;
    g := g || jsonb_build_object('freeBet', least(public.lr_n(g, 'freeBet'), lim));
    foreach k in array array['bj', 'pl', 'ck', 'cf', 'pk'] loop
      if jsonb_typeof(g -> k) is distinct from 'object' then g := jsonb_set(g, array[k], '{}'::jsonb); end if;
    end loop;
    g := jsonb_set(g, '{bj,round}', 'null'::jsonb);
    g := jsonb_set(g, '{bj,shoe}', '[]'::jsonb);
    g := jsonb_set(g, '{ck,round}', 'null'::jsonb);
    g := jsonb_set(g, '{cf,round}', 'null'::jsonb);
    g := jsonb_set(g, '{pk,solo}', 'null'::jsonb);
    g := jsonb_set(g, '{pl,pending}', '[]'::jsonb);
    foreach k in array array['bj,hands', 'bj,lastBet', 'pl,drops', 'ck,games', 'cf,flips', 'pk,hands'] loop
      g := jsonb_set(g, string_to_array(k, ','), to_jsonb(floor(public.lr_num(g #> string_to_array(k, ','), 0, 0, 1e12))));
    end loop;
    g := public.lr_fill(g || jsonb_build_object('level', p.level));
    delete from public.lr_secret where player = p.id;
    p.credits := (g ->> 'credits')::bigint;
  end if;
  -- an admin set the level: XP starts over on it
  if public.lr_n(g, 'level') <> p.level then g := g || jsonb_build_object('xp', case when p.level >= 20 then public.lr_xp_need(20) else 0 end); end if;
  return g || jsonb_build_object('credits', p.credits, 'level', p.level, 'prestige', p.prestige, 'spins', p.spins, 'jackpots', p.jackpots, 'best', p.best);
end;
$$;

-- What a page gets back: everything of the game the database keeps (nothing secret is in it).
create or replace function public.lr_view(g jsonb)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('credits', g -> 'credits', 'level', g -> 'level', 'prestige', g -> 'prestige', 'spins', g -> 'spins', 'jackpots', g -> 'jackpots',
    'best', g -> 'best', 'lastWin', g -> 'lastWin', 'owned', g -> 'owned', 'xp', g -> 'xp', 'streak', g -> 'streak', 'stars', g -> 'stars',
    'starBank', g -> 'starBank', 'freeSpins', g -> 'freeSpins', 'freeBet', g -> 'freeBet', 'freeTotal', g -> 'freeTotal', 'nudges', g -> 'nudges',
    'missions', g -> 'missions', 'missionsDone', g -> 'missionsDone', 'ach', g -> 'ach', 'sl', g -> 'sl', 'job', g -> 'job', 'jobReset', g -> 'jobReset',
    'rrAt', g -> 'rrAt', 'evGifts', g -> 'evGifts',
    'bj', jsonb_build_object('round', g #> '{bj,round}', 'hands', g #> '{bj,hands}', 'lastBet', g #> '{bj,lastBet}', 'shoeLeft', g #> '{bj,shoeLeft}'),
    'pl', jsonb_build_object('drops', g #> '{pl,drops}'), 'ck', jsonb_build_object('round', g #> '{ck,round}', 'games', g #> '{ck,games}'),
    'cf', jsonb_build_object('round', g #> '{cf,round}', 'flips', g #> '{cf,flips}'), 'pk', jsonb_build_object('solo', g #> '{pk,solo}', 'hands', g #> '{pk,hands}'))
$$;

-- Write the game back; the page gets the new state and what happened on the way.
create or replace function public.lr_put(uid uuid, g jsonb, r jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  o jsonb := coalesce(g -> '_out', '{}'::jsonb);
begin
  g := g - '_out';
  g := g || jsonb_build_object('credits', least(9007199254740991, greatest(0, floor(public.lr_n(g, 'credits')))),
    'best', least(9007199254740991, greatest(0, floor(public.lr_n(g, 'best')))));
  update public.players set credits = (g ->> 'credits')::bigint, level = (g ->> 'level')::integer, prestige = (g ->> 'prestige')::smallint,
    spins = least(2147483647, public.lr_n(g, 'spins'))::integer, jackpots = least(2147483647, public.lr_n(g, 'jackpots'))::integer,
    best = (g ->> 'best')::bigint, game = g::text, updated_at = now()
  where id = uid;
  return jsonb_build_object('g', public.lr_view(g), 'out', o, 'r', r);
end;
$$;

-- XP; every new level pays 250 x the level
create or replace function public.lr_xp(g jsonb, c jsonb, n numeric)
returns jsonb
language plpgsql
immutable
as $$
declare
  lv integer := public.lr_n(g, 'level')::integer;
  xp numeric := public.lr_n(g, 'xp');
  f numeric;
  cr numeric := public.lr_n(g, 'credits');
begin
  if lv >= 20 then return g || jsonb_build_object('xp', public.lr_xp_need(20)); end if;
  f := least(5, public.lr_evf(c, 'xp'));
  xp := xp + case when f > 1 then round(n * f) else n end;
  while lv < 20 and xp >= public.lr_xp_need(lv) loop
    xp := xp - public.lr_xp_need(lv);
    lv := lv + 1;
    cr := cr + 250 * lv;
    g := public.lr_out(g, 'levels', to_jsonb(lv));
  end loop;
  if lv >= 20 then xp := public.lr_xp_need(20); end if;
  return g || jsonb_build_object('xp', xp, 'level', lv, 'credits', cr);
end;
$$;

-- Achievements: each pays once. ctx says what just happened.
create or replace function public.lr_ach(g jsonb, ctx jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  a record;
  ok boolean;
  ach jsonb := case when jsonb_typeof(g -> 'ach') = 'object' then g -> 'ach' else '{}'::jsonb end;
  cr numeric := public.lr_n(g, 'credits');
  cn numeric;
  cb boolean;
begin
  for a in select * from (values ('first', 100), ('win', 100), ('three', 250), ('streak3', 300), ('streak6', 1500), ('bonus', 500), ('big', 500), ('mega', 2000),
    ('jackpot', 2500), ('level5', 1000), ('level10', 5000), ('allin', 1000), ('marathon', 1000), ('million', 10000), ('wild', 300), ('nudger', 300),
    ('gambler', 2000), ('tasks', 3000), ('shark', 300), ('royalty', 2000), ('chicken', 600), ('skyhigh', 800), ('moon', 5000), ('horses', 300),
    ('longshot', 2000), ('plinko', 800), ('prestige', 2500), ('miner', 100), ('coinStreak', 1500), ('coinEdge', 10000), ('jobBoss', 5000),
    ('bullseye', 500), ('natural', 300), ('splitter', 500), ('collector', 5000)) v(id, reward) loop
    if ach ? a.id then continue; end if;
    cn := coalesce(case a.id when 'win' then (ctx ->> 'win')::numeric when 'big' then (ctx ->> 'ratio')::numeric when 'mega' then (ctx ->> 'ratio')::numeric
      when 'allin' then (ctx ->> 'bet')::numeric when 'skyhigh' then (ctx ->> 'rocketMult')::numeric when 'moon' then (ctx ->> 'rocketMult')::numeric
      when 'longshot' then (ctx ->> 'horseOdds')::numeric when 'plinko' then (ctx ->> 'plinkoMult')::numeric when 'prestige' then (ctx ->> 'prestige')::numeric
      when 'coinStreak' then (ctx ->> 'coinStreak')::numeric when 'jobBoss' then (ctx ->> 'jobPos')::numeric end, 0);
    cb := coalesce((ctx ->> (case a.id when 'three' then 'three' when 'bonus' then 'triggered' when 'jackpot' then 'jackpot' when 'wild' then 'wildLine'
      when 'nudger' then 'nudgeWin' when 'gambler' then 'gambleFull' when 'shark' then 'pokerWin' when 'royalty' then 'pokerSF' when 'chicken' then 'chickenCrossed'
      when 'horses' then 'horseWin' when 'miner' then 'jobPaid' when 'coinEdge' then 'coinEdge' when 'bullseye' then 'bullseye' when 'natural' then 'natural'
      when 'splitter' then 'splitBoth' else '-' end))::boolean, false);
    ok := case a.id
      when 'first' then public.lr_n(g, 'spins') >= 1
      when 'win' then cn > 0
      when 'streak3' then public.lr_n(g, 'streak') >= 3
      when 'streak6' then public.lr_n(g, 'streak') >= 6
      when 'big' then cn >= 25
      when 'mega' then cn >= 75
      when 'level5' then public.lr_n(g, 'level') >= 5
      when 'level10' then public.lr_n(g, 'level') >= 10
      when 'allin' then cn >= 10000
      when 'marathon' then public.lr_n(g, 'spins') >= 100
      when 'million' then cr >= 1000000
      when 'tasks' then public.lr_n(g, 'missionsDone') >= 10
      when 'skyhigh' then cn >= 10
      when 'moon' then cn >= 200
      when 'longshot' then cn >= 10
      when 'plinko' then cn >= 25
      when 'prestige' then cn >= 1
      when 'coinStreak' then cn >= 5
      when 'jobBoss' then cn >= 7
      when 'collector' then public.lr_n(g -> 'owned', 'horseshoe') >= 3 and public.lr_has(g, 'goldCherry') and public.lr_has(g, 'piggy')
        and public.lr_has(g, 'autospin') and public.lr_has(g, 'gold')
      else cb end;
    if ok then
      ach := ach || jsonb_build_object(a.id, true);
      cr := cr + a.reward;
      g := public.lr_out(g, 'ach', jsonb_build_object('id', a.id, 'reward', a.reward));
    end if;
  end loop;
  return g || jsonb_build_object('ach', ach, 'credits', cr);
end;
$$;

-- Mission progress; a finished one pays and makes room for a new one.
create or replace function public.lr_mission(g jsonb, t text, amount numeric default 1)
returns jsonb
language plpgsql
volatile
as $$
declare
  ms jsonb := coalesce(g -> 'missions', '[]'::jsonb);
  m jsonb;
  pr numeric;
  done boolean := false;
begin
  for i in 0 .. jsonb_array_length(ms) - 1 loop
    m := ms -> i;
    if m ->> 't' is distinct from t then continue; end if;
    pr := case when t = 'streak' then greatest(public.lr_n(m, 'prog'), amount) else public.lr_n(m, 'prog') + amount end;
    if pr < public.lr_n(m, 'goal') then ms := jsonb_set(ms, array[i::text, 'prog'], to_jsonb(pr)); continue; end if;
    g := public.lr_add(public.lr_add(g, 'credits', public.lr_n(m, 'reward')), 'missionsDone', 1);
    g := public.lr_out(g, 'missions', jsonb_build_object('t', t, 'goal', m -> 'goal', 'reward', m -> 'reward'));
    ms := jsonb_set(ms, array[i::text], public.lr_new_mission(array(select x ->> 't' from jsonb_array_elements(ms) x), public.lr_n(g, 'level')::integer));
    done := true;
  end loop;
  g := g || jsonb_build_object('missions', ms);
  if done then g := public.lr_ach(g); end if;
  return g;
end;
$$;

-- The game as it is now (the page asks for it when it loads, and to see whether this part is installed).
create or replace function public.game_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  g jsonb := public.lr_g(p);
begin
  return public.lr_put(p.id, g);
end;
$$;

-- ----- Slots -----
-- The 27 stops of each reel, in the same order as on the page.
create or replace function public.lr_strip() returns text[] language sql immutable as $$
  select array['star', 'star', 'wild', 'cherry', 'cherry', 'cherry', 'cherry', 'cherry', 'cherry', 'cherry', 'lemon', 'lemon', 'lemon', 'lemon', 'lemon',
    'lemon', 'plum', 'plum', 'plum', 'plum', 'plum', 'bell', 'bell', 'bell', 'bar', 'bar', 'seven']
$$;
-- The symbol a line counts as: wilds stand in for anything except stars, which need three of their own.
create or replace function public.lr_line(a text, b text, c text) returns text language sql immutable as $$
  select case
    when n = 0 then 'wild'
    when cnt = 1 and (s <> 'star' or n = 3) then s
  end
  from (select count(*) filter (where x <> 'wild') n, count(distinct x) filter (where x <> 'wild') cnt, max(x) filter (where x <> 'wild') s
    from unnest(array[a, b, c]) x) q
$$;
create or replace function public.lr_payout(g jsonb, c jsonb, a text, b text, cc text) returns numeric language plpgsql immutable as $$
declare
  line text := public.lr_line(a, b, cc);
  cherries integer := (a = 'cherry')::integer + (b = 'cherry')::integer + (cc = 'cherry')::integer;
begin
  if line = 'seven' then return (c ->> 'jackpotPay')::numeric + 8 * public.lr_n(g -> 'owned', 'horseshoe'); end if;
  if line = 'cherry' and public.lr_has(g, 'goldCherry') then return 3.5; end if;
  if line is not null then return case line when 'wild' then 80 when 'star' then 40 when 'bar' then 20 when 'bell' then 10 when 'plum' then 6 when 'lemon' then 4 else 3 end; end if;
  if cherries = 2 then return 1.5; end if;
  if a = 'cherry' then return 0.5; end if;
  return 0;
end;
$$;
-- stars on the line fill the bonus meter; a full meter starts free spins
create or replace function public.lr_stars(g jsonb, c jsonb, n integer, bet numeric) returns jsonb language plpgsql immutable as $$
declare
  st numeric := public.lr_n(g, 'stars') + n;
  bank numeric := public.lr_n(g, 'starBank') + bet * n;
  avg numeric;
  goal numeric := (c ->> 'starGoal')::numeric;
  fs numeric := (c ->> 'freeSpins')::numeric + case when public.lr_has(g, 'starPlus') then 1 else 0 end;
begin
  if n < 1 then return g; end if;
  if st >= goal then
    avg := greatest(1, floor(bank / st));
    st := st - goal;
    bank := avg * st;
    if public.lr_n(g, 'freeSpins') = 0 and not coalesce((g #>> '{sl,inBonus}')::boolean, false) then g := g || jsonb_build_object('freeBet', avg); end if;
    g := public.lr_add(g, 'freeSpins', fs) || jsonb_build_object('_trig', true);
  end if;
  return g || jsonb_build_object('stars', st, 'starBank', bank);
end;
$$;

-- One spin. With free spins waiting it is a free one. holds: reels kept from the last spin (only when it offered that).
create or replace function public.game_spin(p_bet numeric, p_holds boolean[] default null, p_auto boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  sl jsonb;
  strip text[] := public.lr_strip();
  pos integer[];
  tg integer[];
  holds boolean[] := array[false, false, false];
  free boolean;
  bet numeric;
  raised boolean;
  syms text[];
  line text;
  base numeric;
  smult numeric;
  mult numeric;
  bolt integer := 0;
  roll integer;
  win numeric;
  refund numeric := 0;
  sc integer := 0;
  wc integer := 0;
  trig boolean := false;
  nadd integer := 0;
  free7 integer;
  lim numeric := public.lr_lim(c, p.level);
  over boolean := false;
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  sl := coalesce(g -> 'sl', '{}'::jsonb);
  if sl ? 'gm' then raise exception 'gamble open'; end if;
  pos := coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x), '{}');
  if coalesce(array_length(pos, 1), 0) <> 3 then pos := array[public.lr_rand(27), public.lr_rand(27), public.lr_rand(27)]; end if;
  free := public.lr_n(g, 'freeSpins') > 0;
  if free then
    bet := greatest(1, public.lr_n(g, 'freeBet'));
    g := public.lr_add(g, 'freeSpins', -1);
    if not coalesce((sl ->> 'inBonus')::boolean, false) then g := g || jsonb_build_object('freeTotal', 0); sl := sl || '{"inBonus": true}'; end if;
  else
    bet := least(floor(coalesce(p_bet, 0)), lim);
    if bet < 1 then raise exception 'bet'; end if;
    if public.lr_n(g, 'credits') < bet then raise exception 'credits'; end if;
    raised := coalesce(true = any(p_holds), false) and bet > public.lr_n(sl, 'lastBet');
    if coalesce((sl ->> 'holdOffer')::boolean, false) and not raised and coalesce(array_length(p_holds, 1), 0) = 3
       and (p_holds[1]::integer + p_holds[2]::integer + p_holds[3]::integer) <= 2 then holds := p_holds; end if;
    g := public.lr_add(g, 'credits', -bet);
  end if;
  g := public.lr_add(g, 'spins', 1) || jsonb_build_object('nudges', 0);
  sl := sl || jsonb_build_object('holdOffer', false, 'nudgeOpen', false, 'gamble', 0);
  tg := array(select case when holds[i] then pos[i] else public.lr_rand(27) end from generate_series(1, 3) i);
  -- three sevens are a bit rarer than the reels alone make them: a quarter of them get the last free reel drawn again
  free7 := (select i from unnest(array[3, 2, 1]) i where not holds[i] limit 1);
  if free7 is not null and public.lr_line(strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]) = 'seven' and public.lr_rand(100) < 25 then
    tg[free7] := public.lr_rand(27);
  end if;
  syms := array[strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]];
  line := public.lr_line(syms[1], syms[2], syms[3]);
  base := public.lr_payout(g, c, syms[1], syms[2], syms[3]);
  smult := case when base > 0 then 1 + 0.1 * least(public.lr_n(g, 'streak'), 5) else 1 end;
  mult := base * (case when free then (c ->> 'freeMult')::numeric else 1 end) * smult * public.lr_wm(c, 'slots');
  if public.lr_has(g, 'lightning') and base > 0 and public.lr_rand(1000) < 10 then
    roll := public.lr_rand(100);
    bolt := case when roll < 70 then 2 when roll < 90 then 3 when roll < 98 then 5 else 10 end;
  end if;
  win := floor(mult * bet * greatest(bolt, 1));
  if base = 0 and public.lr_has(g, 'piggy') then refund := floor(bet * 0.02); end if;
  g := public.lr_add(g, 'credits', win + refund) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win),
    'streak', case when base > 0 then public.lr_n(g, 'streak') + 1 else 0 end);
  if free then g := public.lr_add(g, 'freeTotal', win); end if;
  -- held reels don't count their star or wild again
  sc := (select count(*) from generate_series(1, 3) i where not holds[i] and syms[i] = 'star');
  wc := (select count(*) from generate_series(1, 3) i where not holds[i] and syms[i] = 'wild');
  g := public.lr_stars(g || jsonb_build_object('sl', sl), c, sc, bet);
  trig := coalesce((g ->> '_trig')::boolean, false);
  g := g - '_trig';
  sl := g -> 'sl';
  g := public.lr_xp(g, c, 10 + floor(log(bet) * 8) + case when base > 0 then 8 else 0 end + case when line is not null then 30 else 0 end);
  g := public.lr_mission(g, 'spins');
  if win > 0 then g := public.lr_mission(public.lr_mission(g, 'wins'), 'earn', win / bet); end if;
  if line is not null then g := public.lr_mission(g, 'three'); end if;
  if sc > 0 then g := public.lr_mission(g, 'stars', sc); end if;
  if wc > 0 then g := public.lr_mission(g, 'wilds', wc); end if;
  g := public.lr_mission(g, 'streak', public.lr_n(g, 'streak'));
  if win > 0 and true = any(holds) then g := public.lr_mission(g, 'hold'); end if;
  -- after a paid spin: gamble a win, or nudges and holds after a loss
  if not free and not coalesce(p_auto, false) then
    if win > 0 then sl := sl || jsonb_build_object('gamble', win);
    else
      if public.lr_rand(100) < (c ->> 'nudgeChance')::numeric then
        nadd := case when public.lr_rand(5) = 0 then 2 else 1 end;
        g := public.lr_add(g, 'nudges', nadd);
      end if;
      sl := sl || jsonb_build_object('nudgeOpen', public.lr_n(g, 'nudges') > 0, 'holdOffer', public.lr_rand(100) < (c ->> 'holdChance')::numeric);
    end if;
  end if;
  if line = 'seven' then g := public.lr_add(g, 'jackpots', 1); end if;
  if free and public.lr_n(g, 'freeSpins') = 0 then sl := sl || '{"inBonus": false}'; over := true; end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(tg), 'lastBet', bet);
  g := public.lr_ach(g || jsonb_build_object('sl', sl), jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet, 'jackpot', coalesce(line = 'seven', false),
    'triggered', trig, 'bet', bet, 'wildLine', line is not null and 'wild' = any(syms)));
  return public.lr_put(p.id, g, jsonb_build_object('targets', to_jsonb(tg), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'smult', smult,
    'mult', round(mult * greatest(bolt, 1), 2), 'bolt', bolt, 'win', win, 'refund', refund, 'bet', bet, 'free', free, 'stars', sc, 'wilds', wc,
    'triggered', trig, 'nudgesAdded', nadd, 'jackpot', coalesce(line = 'seven', false), 'bonusOver', over, 'held', to_jsonb(holds)));
end;
$$;

-- A nudge moves one reel down a stop.
create or replace function public.game_nudge(p_reel integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  sl jsonb := coalesce(g -> 'sl', '{}'::jsonb);
  strip text[] := public.lr_strip();
  pos integer[];
  syms text[];
  line text;
  base numeric;
  bet numeric;
  smult numeric;
  win numeric := 0;
  star boolean;
  trig boolean := false;
begin
  if not coalesce((sl ->> 'nudgeOpen')::boolean, false) or public.lr_n(g, 'nudges') < 1 or p_reel not between 0 and 2 then raise exception 'no nudge'; end if;
  pos := array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x);
  bet := greatest(1, public.lr_n(sl, 'lastBet'));
  g := public.lr_add(g, 'nudges', -1);
  sl := sl || '{"holdOffer": false}';
  pos[p_reel + 1] := (pos[p_reel + 1] + 26) % 27;
  star := strip[pos[p_reel + 1] + 1] = 'star';
  -- a star nudged onto the line counts like a landed one
  if star then
    g := public.lr_stars(g || jsonb_build_object('sl', sl), c, 1, bet);
    trig := coalesce((g ->> '_trig')::boolean, false);
    g := public.lr_mission(g - '_trig', 'stars', 1);
    sl := g -> 'sl';
  end if;
  syms := array[strip[pos[1] + 1], strip[pos[2] + 1], strip[pos[3] + 1]];
  line := public.lr_line(syms[1], syms[2], syms[3]);
  base := public.lr_payout(g, c, syms[1], syms[2], syms[3]);
  if base > 0 then
    smult := 1 + 0.1 * least(public.lr_n(g, 'streak'), 5);
    win := floor(base * bet * smult * public.lr_wm(c, 'slots'));
    g := public.lr_add(g, 'credits', win) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win), 'streak', public.lr_n(g, 'streak') + 1);
    sl := sl || jsonb_build_object('nudgeOpen', false, 'gamble', win);
    g := public.lr_mission(public.lr_mission(public.lr_mission(public.lr_mission(g, 'nudge'), 'wins'), 'earn', win / bet), 'streak', public.lr_n(g, 'streak'));
    if line is not null then g := public.lr_mission(g, 'three'); end if;
    g := public.lr_xp(g, c, 8 + case when line is not null then 30 else 0 end);
    if line = 'seven' then g := public.lr_add(g, 'jackpots', 1); end if;
  else
    sl := sl || jsonb_build_object('nudgeOpen', public.lr_n(g, 'nudges') > 0);
  end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(pos));
  g := public.lr_ach(g || jsonb_build_object('sl', sl), case when base > 0 then jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet,
    'jackpot', coalesce(line = 'seven', false), 'bet', bet, 'nudgeWin', true, 'wildLine', line is not null and 'wild' = any(syms), 'triggered', trig) else jsonb_build_object('triggered', trig) end);
  return public.lr_put(p.id, g, jsonb_build_object('reel', p_reel, 'pos', to_jsonb(pos), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'win', win,
    'smult', coalesce(smult, 1), 'star', star, 'triggered', trig, 'jackpot', coalesce(line = 'seven', false), 'bet', bet));
end;
$$;

-- The gamble after a slot win: higher or lower, up to five rounds; ties keep the stake.
create or replace function public.lr_gf(rank integer, higher boolean) returns numeric language sql immutable as $$
  select case when k = 12 then 1 when k = 0 then 0 else (floor(0.95::float8 * 12 / k * 100 + 1e-9) / 100)::numeric end
  from (select case when higher then 12 - rank else rank end k) q
$$;
create or replace function public.game_gamble(p_act text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  sl jsonb := coalesce(g -> 'sl', '{}'::jsonb);
  gm jsonb := sl -> 'gm';
  stake numeric;
  rank integer;
  nr integer;
  ns integer;
  f numeric;
  res text;
begin
  if p_act = 'open' then
    if gm is not null or public.lr_n(sl, 'gamble') <= 0 then raise exception 'no gamble'; end if;
    stake := public.lr_n(sl, 'gamble');
    gm := jsonb_build_object('stake', stake, 'rank', public.lr_rand(13), 'suit', public.lr_rand(4), 'rounds', 0);
    g := public.lr_add(g, 'credits', -stake) || jsonb_build_object('sl', sl || jsonb_build_object('gamble', 0, 'gm', gm));
    return public.lr_put(p.id, g, jsonb_build_object('gm', gm));
  end if;
  if gm is null then raise exception 'no gamble'; end if;
  stake := public.lr_n(gm, 'stake');
  rank := public.lr_n(gm, 'rank')::integer;
  if p_act in ('hi', 'lo') then
    f := public.lr_gf(rank, p_act = 'hi');
    if f = 0 or public.lr_n(gm, 'rounds') >= 5 then raise exception 'no guess'; end if;
    nr := public.lr_rand(13); ns := public.lr_rand(4);
    if nr = rank then res := 'same';
    elsif (nr > rank) = (p_act = 'hi') then
      res := 'win';
      stake := floor(stake * f);
      gm := gm || jsonb_build_object('rounds', public.lr_n(gm, 'rounds') + 1);
      g := public.lr_mission(g, 'gamble');
      if public.lr_n(gm, 'rounds') >= 5 then g := public.lr_ach(g, '{"gambleFull": true}'); end if;
    else res := 'lose'; stake := 0;
    end if;
    gm := gm || jsonb_build_object('stake', stake, 'rank', nr, 'suit', ns);
    sl := coalesce(g -> 'sl', sl);
    g := g || jsonb_build_object('sl', case when stake > 0 then sl || jsonb_build_object('gm', gm) else sl - 'gm' end);
    return public.lr_put(p.id, g, jsonb_build_object('next', jsonb_build_object('rank', nr, 'suit', ns), 'res', res, 'stake', stake, 'rounds', gm -> 'rounds'));
  end if;
  if p_act = 'collect' then
    g := public.lr_add(g, 'credits', stake) || jsonb_build_object('lastWin', stake, 'best', greatest(public.lr_n(g, 'best'), stake), 'sl', sl - 'gm');
    g := public.lr_ach(g);
    return public.lr_put(p.id, g, jsonb_build_object('stake', stake));
  end if;
  raise exception 'unknown';
end;
$$;

-- ----- Blackjack: six decks, the dealer stands on soft 17 -----
create or replace function public.lr_bj_value(c integer) returns integer language sql immutable as $$
  select case when (c / 4) % 13 = 0 then 11 else least(10, (c / 4) % 13 + 1) end
$$;
create or replace function public.lr_bj_total(cards jsonb) returns integer language plpgsql immutable as $$
declare
  t integer := 0;
  aces integer := 0;
  x jsonb;
begin
  for x in select * from jsonb_array_elements(coalesce(cards, '[]'::jsonb)) loop
    t := t + public.lr_bj_value((x #>> '{}')::integer);
    if (((x #>> '{}')::integer) / 4) % 13 = 0 then aces := aces + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end;
$$;
create or replace function public.lr_bj_natural(h jsonb) returns boolean language sql immutable as $$
  select jsonb_array_length(h -> 'cards') = 2 and not coalesce((h ->> 'split')::boolean, false) and public.lr_bj_total(h -> 'cards') = 21
$$;
-- the next card off the shoe (a fresh shuffled shoe when it is empty)
create or replace function public.lr_bj_draw(uid uuid) returns integer language plpgsql volatile set search_path = public as $$
declare
  s integer[];
  c integer;
begin
  select shoe into s from public.lr_secret where player = uid;
  if coalesce(array_length(s, 1), 0) = 0 then
    s := array(select x from generate_series(0, 51) x, generate_series(1, 6) d order by random());
  end if;
  c := s[array_length(s, 1)];
  update public.lr_secret set shoe = s[1:array_length(s, 1) - 1] where player = uid;
  return c;
end;
$$;

-- The hand that plays now is done; on to the next one, or the dealer plays.
create or replace function public.lr_bj_play(uid uuid, g jsonb, c jsonb)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  r jsonb := g #> '{bj,round}';
  nxt integer;
  hole integer;
  dealer jsonb;
  dbj boolean;
  stands boolean;
  d integer;
  back numeric := 0;
  staked numeric := 0;
  wins integer := 0;
  h jsonb;
  hs jsonb := '[]'::jsonb;
  t integer;
  res text;
  w numeric;
  extra numeric;
  net numeric;
  nat boolean := false;
begin
  loop
    if r ->> 'phase' <> 'player' then exit; end if;
    nxt := (select (i - 1)::integer from jsonb_array_elements(r -> 'hands') with ordinality x(hh, i) where not coalesce((hh ->> 'done')::boolean, false) order by i limit 1);
    if nxt is null then exit; end if;
    -- a hand of 21 plays itself
    if public.lr_bj_total(r -> 'hands' -> nxt -> 'cards') = 21 or (r -> 'hands' -> nxt ->> 'result') = 'bust' then
      r := jsonb_set(r, array['hands', nxt::text, 'done'], 'true');
      continue;
    end if;
    r := r || jsonb_build_object('active', nxt);
    return jsonb_set(g, '{bj,round}', r);
  end loop;
  -- the dealer turns the hidden card and draws to 17
  select s.hole into hole from public.lr_secret s where s.player = uid;
  dealer := jsonb_build_array(r -> 'dealer' -> 0, hole);
  dbj := public.lr_bj_total(dealer) = 21;
  stands := exists (select 1 from jsonb_array_elements(r -> 'hands') hh where hh ->> 'result' is distinct from 'bust' and not public.lr_bj_natural(hh));
  if stands and not dbj then
    while public.lr_bj_total(dealer) < 17 loop dealer := dealer || to_jsonb(public.lr_bj_draw(uid)); end loop;
  end if;
  d := public.lr_bj_total(dealer);
  for h in select * from jsonb_array_elements(r -> 'hands') loop
    staked := staked + public.lr_n(h, 'bet');
    t := public.lr_bj_total(h -> 'cards');
    if h ->> 'result' = 'bust' then res := 'bust'; w := 0;
    elsif public.lr_bj_natural(h) and not dbj then res := 'blackjack'; w := public.lr_n(h, 'bet') * case when public.lr_has(g, 'bjChip') then 2.55 else 2.5 end;
    elsif dbj and not public.lr_bj_natural(h) then res := 'lose'; w := 0;
    elsif d > 21 or t > d then res := 'win'; w := public.lr_n(h, 'bet') * 2;
    elsif t = d then res := 'push'; w := public.lr_n(h, 'bet');
    else res := 'lose'; w := 0;
    end if;
    -- happy hour and events multiply the winnings, not the returned stake
    if w > public.lr_n(h, 'bet') then w := public.lr_n(h, 'bet') + (w - public.lr_n(h, 'bet')) * public.lr_wm(c, 'bj'); end if;
    w := floor(w);
    back := back + w;
    if res in ('win', 'blackjack') then wins := wins + 1; end if;
    if res = 'blackjack' then nat := true; end if;
    hs := hs || jsonb_build_array(h || jsonb_build_object('result', res, 'win', w, 'done', true));
  end loop;
  g := public.lr_add(g, 'credits', back);
  -- Dealer's Peek: against a dealer blackjack only the first bet is lost; doubles and splits come back
  if dbj and public.lr_has(g, 'bjPeek') and staked > public.lr_n(g -> 'bj', 'lastBet') then
    extra := staked - public.lr_n(g -> 'bj', 'lastBet');
    back := back + extra;
    g := public.lr_out(public.lr_add(g, 'credits', extra), 'bonus', jsonb_build_object('id', 'bjPeek', 'amount', extra));
  end if;
  net := back - staked;
  r := r || jsonb_build_object('hands', hs, 'dealer', dealer, 'phase', 'done', 'hole', false, 'net', net, 'dealerBJ', dbj);
  g := jsonb_set(g, '{bj,round}', r);
  g := jsonb_set(g, '{bj,hands}', to_jsonb(public.lr_n(g -> 'bj', 'hands') + 1));
  g := g || jsonb_build_object('lastWin', greatest(0, net), 'best', greatest(public.lr_n(g, 'best'), net));
  g := public.lr_xp(g, c, 8 + wins * 6);
  g := public.lr_ach(g, jsonb_build_object('natural', nat, 'splitBoth', jsonb_array_length(hs) = 2 and wins = 2, 'win', greatest(0, net), 'bet', staked));
  return g;
end;
$$;

-- deal (with a bet), hit, stand, double, split
create or replace function public.game_bj(p_act text, p_bet numeric default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  r jsonb := g #> '{bj,round}';
  bet numeric;
  i integer;
  h jsonb;
  card integer;
  a integer;
  b integer;
  t integer;
  shuffled boolean := false;
  left_ integer;
begin
  insert into public.lr_secret (player) values (p.id) on conflict do nothing;
  if p_act = 'deal' then
    if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
    if r is not null and jsonb_typeof(r) = 'object' and r ->> 'phase' <> 'done' then raise exception 'round open'; end if;
    bet := least(floor(coalesce(p_bet, 0)), public.lr_lim(c, p.level));
    if bet < 1 then raise exception 'bet'; end if;
    if public.lr_n(g, 'credits') < bet then raise exception 'credits'; end if;
    if (select coalesce(array_length(shoe, 1), 0) from public.lr_secret where player = p.id) < 78 then
      update public.lr_secret set shoe = array(select x from generate_series(0, 51) x, generate_series(1, 6) d order by random()) where player = p.id;
      shuffled := true;
    end if;
    g := public.lr_add(g, 'credits', -bet);
    g := jsonb_set(g, '{bj,lastBet}', to_jsonb(bet));
    a := public.lr_bj_draw(p.id);
    card := public.lr_bj_draw(p.id);
    b := public.lr_bj_draw(p.id);
    t := public.lr_bj_draw(p.id);
    update public.lr_secret set hole = t where player = p.id;
    r := jsonb_build_object('hands', jsonb_build_array(jsonb_build_object('cards', jsonb_build_array(a, b), 'bet', bet, 'split', false, 'result', null, 'win', 0, 'done', false)),
      'dealer', jsonb_build_array(card, -1), 'active', 0, 'phase', 'player', 'hole', true);
    g := jsonb_set(g, '{bj,round}', r);
    -- the dealer checks for blackjack straight away; a player blackjack ends the hand too
    if public.lr_bj_natural(r -> 'hands' -> 0) or public.lr_bj_total(jsonb_build_array(card, (select hole from public.lr_secret where player = p.id))) = 21 then
      g := jsonb_set(g, '{bj,round,hands,0,done}', 'true');
      g := public.lr_bj_play(p.id, g, c);
    end if;
  else
    if r is null or jsonb_typeof(r) <> 'object' or r ->> 'phase' <> 'player' then raise exception 'no round'; end if;
    i := public.lr_n(r, 'active')::integer;
    h := r -> 'hands' -> i;
    if p_act in ('hit', 'double') then
      if p_act = 'double' then
        if jsonb_array_length(h -> 'cards') <> 2 or public.lr_n(g, 'credits') < public.lr_n(h, 'bet') then raise exception 'no double'; end if;
        g := public.lr_add(g, 'credits', -public.lr_n(h, 'bet'));
        h := h || jsonb_build_object('bet', public.lr_n(h, 'bet') * 2);
      end if;
      h := h || jsonb_build_object('cards', (h -> 'cards') || to_jsonb(public.lr_bj_draw(p.id)));
      t := public.lr_bj_total(h -> 'cards');
      if t > 21 then h := h || '{"result": "bust", "done": true}';
      elsif t = 21 or p_act = 'double' then h := h || '{"done": true}';
      end if;
      g := jsonb_set(g, array['bj', 'round', 'hands', i::text], h);
    elsif p_act = 'stand' then
      g := jsonb_set(g, array['bj', 'round', 'hands', i::text, 'done'], 'true');
    elsif p_act = 'split' then
      if jsonb_array_length(r -> 'hands') > 1 or jsonb_array_length(h -> 'cards') <> 2
         or public.lr_bj_value((h #>> '{cards,0}')::integer) <> public.lr_bj_value((h #>> '{cards,1}')::integer)
         or public.lr_n(g, 'credits') < public.lr_n(h, 'bet') then raise exception 'no split'; end if;
      g := public.lr_add(g, 'credits', -public.lr_n(h, 'bet'));
      a := (h #>> '{cards,0}')::integer; b := (h #>> '{cards,1}')::integer;
      r := r || jsonb_build_object('hands', jsonb_build_array(
        jsonb_build_object('cards', jsonb_build_array(a, public.lr_bj_draw(p.id)), 'bet', h -> 'bet', 'split', true, 'result', null, 'win', 0, 'done', (a / 4) % 13 = 0),
        jsonb_build_object('cards', jsonb_build_array(b, public.lr_bj_draw(p.id)), 'bet', h -> 'bet', 'split', true, 'result', null, 'win', 0, 'done', (a / 4) % 13 = 0)));
      g := jsonb_set(g, '{bj,round}', r);
    else raise exception 'unknown';
    end if;
    g := public.lr_bj_play(p.id, g, c);
  end if;
  select coalesce(array_length(shoe, 1), 0) into left_ from public.lr_secret where player = p.id;
  g := jsonb_set(g, '{bj,shoeLeft}', to_jsonb(left_));
  return public.lr_put(p.id, g, jsonb_build_object('shuffled', shuffled));
end;
$$;

-- ----- Plinko: up to 10 balls per call, each falls by coin flips at every row -----
create or replace function public.game_plinko(p_bet numeric, p_rows integer, p_risk text, p_count integer default 1)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  tab jsonb := '{"8": {"low": [5.2, 1.9, 1.1, 0.92, 0.46, 0.92, 1.1, 1.9, 5.2], "medium": [12, 2.8, 1.2, 0.64, 0.36, 0.64, 1.2, 2.8, 12], "high": [25, 3.7, 1.4, 0.28, 0.18, 0.28, 1.4, 3.7, 25]},
    "12": {"low": [9.2, 2.8, 1.4, 1.2, 1.1, 0.92, 0.46, 0.92, 1.1, 1.2, 1.4, 2.8, 9.2], "medium": [31, 11, 3.6, 1.8, 1.1, 0.55, 0.28, 0.55, 1.1, 1.8, 3.6, 11, 31], "high": [165, 22, 7.6, 1.8, 0.65, 0.18, 0.18, 0.18, 0.65, 1.8, 7.6, 22, 165]},
    "16": {"low": [14, 8.3, 1.8, 1.2, 1.2, 1.2, 1.1, 0.92, 0.46, 0.92, 1.1, 1.2, 1.2, 1.2, 1.8, 8.3, 14], "medium": [105, 38, 9.3, 4.6, 2.8, 1.4, 0.93, 0.46, 0.28, 0.46, 0.93, 1.4, 2.8, 4.6, 9.3, 38, 105], "high": [940, 125, 24, 8.4, 3.7, 1.8, 0.19, 0.19, 0.19, 0.19, 0.19, 1.8, 3.7, 8.4, 24, 125, 940]}}';
  bet numeric := least(floor(coalesce(p_bet, 0)), public.lr_lim(c, p.level));
  balls jsonb := '[]'::jsonb;
  path integer[];
  slot integer;
  mult numeric;
  gold boolean;
  eff numeric;
  boost numeric;
  w numeric := public.lr_wm(c, 'pl');
  pay numeric;
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  if p_rows not in (8, 12, 16) or p_risk not in ('low', 'medium', 'high') then raise exception 'board'; end if;
  if bet < 1 then raise exception 'bet'; end if;
  for k in 1 .. least(10, greatest(1, coalesce(p_count, 1))) loop
    if public.lr_n(g, 'credits') < bet then exit; end if;
    path := array(select public.lr_rand(2) from generate_series(1, p_rows));
    slot := (select sum(x) from unnest(path) x);
    mult := (tab -> p_rows::text -> p_risk ->> slot)::numeric;
    -- goodies: one ball in 60 is golden and pays double; slots under 1x pay 3% more; the outermost slots 5% more
    gold := public.lr_has(g, 'plGold') and public.lr_rand(60) = 0;
    eff := (case when mult < 1 and public.lr_has(g, 'plSoft') then mult * 1.03 else mult end)
      * (case when (slot = 0 or slot = p_rows) and public.lr_has(g, 'plBump') then 1.05 else 1 end) * (case when gold then 2 else 1 end);
    -- events and the happy hour raise hits up to 5x by at most 15%; a happy hour below 1 counts fully
    boost := case when w < 1 then w when mult <= 5 then least(1.15, 1 + 0.15 * (w - 1)) else 1 end;
    pay := floor(case when eff > 1 then bet + bet * (eff - 1) * boost else bet * eff end);
    g := public.lr_add(g, 'credits', pay - bet) || jsonb_build_object('lastWin', pay, 'best', greatest(public.lr_n(g, 'best'), pay - bet));
    g := jsonb_set(g, '{pl,drops}', to_jsonb(public.lr_n(g -> 'pl', 'drops') + 1));
    g := public.lr_xp(g, c, 3 + case when mult >= 2 then 4 else 0 end);
    g := public.lr_ach(g, jsonb_build_object('win', greatest(0, pay - bet), 'bet', bet, 'plinkoMult', mult));
    balls := balls || jsonb_build_array(jsonb_build_object('path', to_jsonb(path), 'slot', slot, 'mult', mult, 'gold', gold, 'pay', pay, 'bet', bet));
  end loop;
  if jsonb_array_length(balls) = 0 then raise exception 'credits'; end if;
  return public.lr_put(p.id, g, jsonb_build_object('balls', balls));
end;
$$;

-- ----- Chicken: hop lane by lane, cash out any time -----
create or replace function public.lr_ck_mult(k integer, diff text) returns numeric language sql immutable as $$
  -- in floating point like the page, so both show the same numbers
  select case when k = 0 then 1 else (floor(0.95::float8 / power(case diff when 'easy' then 0.92::float8 when 'hard' then 0.75::float8 else 0.84::float8 end, k) * 100) / 100)::numeric end
$$;
create or replace function public.game_chicken(p_act text, p_bet numeric default 0, p_diff text default 'medium')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  r jsonb := g #> '{ck,round}';
  bet numeric;
  nxt integer;
  hit boolean := false;
  m numeric;
  pay numeric := 0;
  extra numeric := 0;
  crossed boolean := false;
  surv numeric;
begin
  if p_act = 'go' then
    if r is null or jsonb_typeof(r) <> 'object' then
      if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
      bet := least(floor(coalesce(p_bet, 0)), public.lr_lim(c, p.level));
      if bet < 1 then raise exception 'bet'; end if;
      if public.lr_n(g, 'credits') < bet then raise exception 'credits'; end if;
      if p_diff not in ('easy', 'medium', 'hard') then raise exception 'diff'; end if;
      g := public.lr_add(g, 'credits', -bet);
      r := jsonb_build_object('bet', bet, 'diff', p_diff, 'lane', 0);
    end if;
    surv := case r ->> 'diff' when 'easy' then 0.92 when 'hard' then 0.75 else 0.84 end;
    nxt := public.lr_n(r, 'lane')::integer + 1;
    hit := public.lr_rand(10000) >= surv * 10000;
    r := r || jsonb_build_object('lane', nxt);
    if hit then
      g := jsonb_set(g, '{ck,round}', 'null'::jsonb);
      g := jsonb_set(g, '{ck,games}', to_jsonb(public.lr_n(g -> 'ck', 'games') + 1)) || '{"lastWin": 0}';
      if public.lr_has(g, 'ckHelmet') then
        extra := floor(public.lr_n(r, 'bet') * 0.02);
        if extra > 0 then g := public.lr_out(public.lr_add(g, 'credits', extra), 'bonus', jsonb_build_object('id', 'ckHelmet', 'amount', extra)); end if;
      end if;
      g := public.lr_xp(g, c, 3 + nxt);
      return public.lr_put(p.id, g, jsonb_build_object('hit', true, 'lane', nxt, 'bet', r -> 'bet', 'diff', r -> 'diff'));
    end if;
    g := jsonb_set(g, '{ck,round}', r);
    if nxt < 10 then return public.lr_put(p.id, g, jsonb_build_object('hit', false, 'lane', nxt, 'bet', r -> 'bet', 'diff', r -> 'diff')); end if;
    crossed := true;
  elsif p_act <> 'cash' then raise exception 'unknown';
  end if;
  if r is null or jsonb_typeof(r) <> 'object' or public.lr_n(r, 'lane') < 1 then raise exception 'no round'; end if;
  -- events and the happy hour don't raise Chicken wins (a happy hour below 1 still counts)
  m := public.lr_ck_mult(public.lr_n(r, 'lane')::integer, r ->> 'diff');
  bet := public.lr_n(r, 'bet');
  pay := floor(case when m > 1 then bet::float8 + bet::float8 * (m::float8 - 1) * least(1, (c ->> 'winMultiplier')::float8) else bet::float8 * m::float8 end);
  g := public.lr_add(g, 'credits', pay);
  if public.lr_has(g, 'ckFeather') then
    extra := floor(pay * 0.02);
    if extra > 0 then g := public.lr_out(public.lr_add(g, 'credits', extra), 'bonus', jsonb_build_object('id', 'ckFeather', 'amount', extra)); end if;
  end if;
  g := g || jsonb_build_object('lastWin', pay, 'best', greatest(public.lr_n(g, 'best'), pay - bet));
  g := jsonb_set(g, '{ck,round}', 'null'::jsonb);
  g := jsonb_set(g, '{ck,games}', to_jsonb(public.lr_n(g -> 'ck', 'games') + 1));
  g := public.lr_xp(g, c, 4 + public.lr_n(r, 'lane') * 2);
  g := public.lr_ach(g, jsonb_build_object('win', pay - bet, 'bet', bet, 'chickenCrossed', crossed));
  return public.lr_put(p.id, g, jsonb_build_object('hit', false, 'lane', r -> 'lane', 'bet', bet, 'diff', r -> 'diff', 'cashed', true, 'crossed', crossed, 'mult', m, 'pay', pay));
end;
$$;

-- ----- Coin flip: a win can ride and doubles; one flip in 10,000 lands on the edge and pays 10x -----
create or replace function public.game_coin(p_act text, p_bet numeric default 0, p_side text default 'heads')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  r jsonb := g #> '{cf,round}';
  bet numeric;
  edge boolean;
  res text;
  won boolean;
  mult numeric;
  pay numeric;
  auto boolean := false;
begin
  if p_act = 'flip' then
    if p_side not in ('heads', 'tails') then raise exception 'side'; end if;
    if r is null or jsonb_typeof(r) <> 'object' then
      if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
      bet := least(floor(coalesce(p_bet, 0)), public.lr_lim(c, p.level));
      if bet < 1 then raise exception 'bet'; end if;
      if public.lr_n(g, 'credits') < bet then raise exception 'credits'; end if;
      g := public.lr_add(g, 'credits', -bet);
      r := jsonb_build_object('bet', bet, 'mult', 1, 'wins', 0);
    end if;
    edge := public.lr_rand(case when public.lr_has(g, 'cfThumb') then 5000 else 10000 end) = 0;
    res := case when edge then 'edge' when public.lr_rand(2) = 1 then 'heads' else 'tails' end;
    won := edge or res = p_side;
    mult := public.lr_n(r, 'mult') * case when edge then 10 else 2 end;
    g := jsonb_set(g, '{cf,flips}', to_jsonb(public.lr_n(g -> 'cf', 'flips') + 1));
    g := public.lr_xp(g, c, 3);
    if edge then g := public.lr_ach(g, '{"coinEdge": true}'); end if;
    if not won then
      g := jsonb_set(g, '{cf,round}', 'null'::jsonb) || '{"lastWin": 0}';
      return public.lr_put(p.id, g, jsonb_build_object('res', res, 'won', false, 'bet', r -> 'bet', 'mult', mult, 'wins', r -> 'wins'));
    end if;
    r := r || jsonb_build_object('mult', mult, 'wins', public.lr_n(r, 'wins') + 1);
    g := jsonb_set(g, '{cf,round}', r);
    -- ten wins in a row is the most a coin can carry: it pays out by itself
    if public.lr_n(r, 'wins') < 10 then
      return public.lr_put(p.id, g, jsonb_build_object('res', res, 'won', true, 'bet', r -> 'bet', 'mult', mult, 'wins', r -> 'wins'));
    end if;
    auto := true;
  elsif p_act <> 'cash' then raise exception 'unknown';
  end if;
  if r is null or jsonb_typeof(r) <> 'object' then raise exception 'no round'; end if;
  bet := public.lr_n(r, 'bet');
  mult := public.lr_n(r, 'mult');
  -- events and the happy hour don't raise coin flip wins (a happy hour below 1 still counts)
  pay := floor(case when mult > 1 then bet::float8 + bet::float8 * (mult::float8 - 1) * least(1, (c ->> 'winMultiplier')::float8) else bet::float8 * mult::float8 end);
  g := public.lr_add(g, 'credits', pay) || jsonb_build_object('lastWin', pay, 'best', greatest(public.lr_n(g, 'best'), pay - bet));
  g := jsonb_set(g, '{cf,round}', 'null'::jsonb);
  g := public.lr_ach(g, jsonb_build_object('win', pay - bet, 'bet', bet, 'coinStreak', r -> 'wins'));
  return public.lr_put(p.id, g, jsonb_build_object('res', res, 'won', true, 'bet', bet, 'mult', mult, 'wins', r -> 'wins', 'cashed', true, 'auto', auto, 'pay', pay));
end;
$$;

-- ----- Solo poker against five bots (the same rules as the online table) -----
create or replace function public.lr_pk_seat(pid text, name text, stack numeric, bot text) returns jsonb language sql immutable as $$
  select jsonb_build_object('pid', pid, 'name', name, 'stack', stack, 'bet', 0, 'committed', 0, 'in_hand', false, 'folded', false, 'allin', false, 'acted', false,
    'last', null, 'leaving', false, 'won', 0, 'hand_name', null, 'cards', '[]'::jsonb, 'revealed', false, 'bot', bot)
$$;
create or replace function public.lr_pk_ok(st jsonb, s jsonb, test text) returns boolean language sql immutable as $$
  select jsonb_typeof(s) = 'object' and case test
    when 'stack' then (s ->> 'stack')::numeric > 0
    when 'hand' then (s ->> 'in_hand')::boolean
    when 'act' then (s ->> 'in_hand')::boolean and not (s ->> 'folded')::boolean and not (s ->> 'allin')::boolean
    when 'needs' then (s ->> 'in_hand')::boolean and not (s ->> 'folded')::boolean and not (s ->> 'allin')::boolean
      and (not (s ->> 'acted')::boolean or (s ->> 'bet')::numeric < (st ->> 'current_bet')::numeric)
    else false end
$$;
create or replace function public.lr_pk_next(st jsonb, from_ integer, test text) returns integer language plpgsql immutable as $$
declare
  i integer;
begin
  for k in 1 .. 8 loop
    i := (((from_ + k) % 8) + 8) % 8;
    if public.lr_pk_ok(st, st -> 'seats' -> i, test) then return i; end if;
  end loop;
  return -1;
end;
$$;
create or replace function public.lr_pk_put(st jsonb, i integer, amt numeric) returns jsonb language plpgsql immutable as $$
declare
  s jsonb := st -> 'seats' -> i;
begin
  amt := greatest(0, least(amt, (s ->> 'stack')::numeric));
  s := s || jsonb_build_object('stack', (s ->> 'stack')::numeric - amt, 'bet', (s ->> 'bet')::numeric + amt, 'committed', (s ->> 'committed')::numeric + amt);
  if (s ->> 'stack')::numeric = 0 and (s ->> 'in_hand')::boolean then s := s || '{"allin": true}'; end if;
  return jsonb_set(st, array['seats', i::text], s);
end;
$$;
-- the best five of up to seven cards, and which five
create or replace function public.lr_pk_best(cs integer[], out score bigint, out five integer[]) language plpgsql immutable set search_path = public as $$
declare
  n integer := coalesce(array_length(cs, 1), 0);
  sc bigint;
begin
  score := -1;
  for a in 1 .. n loop for b in a + 1 .. n loop for c in b + 1 .. n loop for d in c + 1 .. n loop for e in d + 1 .. n loop
    sc := public.poker_score5(array[cs[a], cs[b], cs[c], cs[d], cs[e]]);
    if sc > score then score := sc; five := array[cs[a], cs[b], cs[c], cs[d], cs[e]]; end if;
  end loop; end loop; end loop; end loop; end loop;
end;
$$;
create or replace function public.lr_ints(j jsonb) returns integer[] language sql immutable as $$
  select coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(coalesce(j, '[]'::jsonb)) x), '{}')
$$;

create or replace function public.lr_pk_finish(st jsonb, showdown boolean) returns jsonb language plpgsql immutable set search_path = public as $$
declare
  cont integer[] := array(select gs from generate_series(0, 7) gs where jsonb_typeof(st -> 'seats' -> gs) = 'object'
    and (st -> 'seats' -> gs ->> 'in_hand')::boolean and not (st -> 'seats' -> gs ->> 'folded')::boolean);
  pot numeric := (select coalesce(sum((s ->> 'committed')::numeric), 0) from jsonb_array_elements(st -> 'seats') s where jsonb_typeof(s) = 'object');
  w integer;
  sc bigint[] := array_fill(-1::bigint, array[8]);
  b record;
  lvl numeric;
  prev numeric := 0;
  paid numeric := 0;
  part numeric;
  elig integer[];
  top bigint;
  winners integer[];
  last_w integer[] := '{}';
  share numeric;
  odd numeric;
  f integer;
  i integer;
  tops integer[];
begin
  if not showdown then
    w := cont[1];
    st := jsonb_set(st, array['seats', w::text], (st -> 'seats' -> w) || jsonb_build_object('stack', (st -> 'seats' -> w ->> 'stack')::numeric + pot, 'won', pot));
    st := st || jsonb_build_object('winners', jsonb_build_array(w), 'result', (st -> 'seats' -> w ->> 'name') || ' wins ' || pot);
  else
    foreach i in array cont loop
      b := public.lr_pk_best(public.lr_ints(st -> 'seats' -> i -> 'cards') || public.lr_ints(st -> 'board'));
      sc[i + 1] := b.score;
      st := jsonb_set(st, array['seats', i::text], (st -> 'seats' -> i) || jsonb_build_object('hand_name', public.poker_hand_name(b.score), 'revealed', true, 'best', to_jsonb(b.five)));
    end loop;
    -- side pots: every level of chips put in is won by the best hand that put in that much
    for lvl in select distinct (st -> 'seats' -> x ->> 'committed')::numeric v from unnest(cont) x order by v loop
      part := (select coalesce(sum(least((s ->> 'committed')::numeric, lvl) - least((s ->> 'committed')::numeric, prev)), 0) from jsonb_array_elements(st -> 'seats') s where jsonb_typeof(s) = 'object');
      elig := array(select x from unnest(cont) x where (st -> 'seats' -> x ->> 'committed')::numeric >= lvl);
      top := (select max(sc[x + 1]) from unnest(elig) x);
      winners := array(select x from unnest(elig) x where sc[x + 1] = top order by x);
      share := floor(part / array_length(winners, 1));
      foreach i in array winners loop
        st := jsonb_set(st, array['seats', i::text], (st -> 'seats' -> i) || jsonb_build_object('stack', (st -> 'seats' -> i ->> 'stack')::numeric + share, 'won', (st -> 'seats' -> i ->> 'won')::numeric + share));
      end loop;
      odd := part - share * array_length(winners, 1);
      if odd > 0 then
        f := -1;
        for k in 1 .. 8 loop
          if ((((st ->> 'button')::integer + k) % 8) + 8) % 8 = any(winners) then f := ((((st ->> 'button')::integer + k) % 8) + 8) % 8; exit; end if;
        end loop;
        if f < 0 then f := winners[1]; end if;
        st := jsonb_set(st, array['seats', f::text], (st -> 'seats' -> f) || jsonb_build_object('stack', (st -> 'seats' -> f ->> 'stack')::numeric + odd, 'won', (st -> 'seats' -> f ->> 'won')::numeric + odd));
      end if;
      paid := paid + part; prev := lvl; last_w := winners;
    end loop;
    if pot > paid and coalesce(array_length(last_w, 1), 0) > 0 then
      f := last_w[1];
      st := jsonb_set(st, array['seats', f::text], (st -> 'seats' -> f) || jsonb_build_object('stack', (st -> 'seats' -> f ->> 'stack')::numeric + pot - paid, 'won', (st -> 'seats' -> f ->> 'won')::numeric + pot - paid));
    end if;
    tops := array(select x from unnest(cont) x where (st -> 'seats' -> x ->> 'won')::numeric > 0 order by (st -> 'seats' -> x ->> 'won')::numeric desc, x);
    st := st || jsonb_build_object('winners', to_jsonb(array(select x from unnest(cont) x where (st -> 'seats' -> x ->> 'won')::numeric > 0)),
      'result', case when array_length(tops, 1) > 1
        then 'Split pot: ' || (select string_agg(st -> 'seats' -> x ->> 'name', ' & ' order by o) from unnest(tops) with ordinality u(x, o)) || ' · ' || (st -> 'seats' -> tops[1] ->> 'hand_name')
        else (st -> 'seats' -> tops[1] ->> 'name') || ' wins ' || (st -> 'seats' -> tops[1] ->> 'won') || ' with ' || lower(st -> 'seats' -> tops[1] ->> 'hand_name') end);
  end if;
  return st || jsonb_build_object('phase', 'showdown', 'to_act', -1, 'pause', case when showdown then 5200 else 3200 end);
end;
$$;

-- after a move: the next player, the next street, or the showdown
create or replace function public.lr_pk_advance(st jsonb) returns jsonb language plpgsql immutable set search_path = public as $$
declare
  alive integer := (select count(*) from jsonb_array_elements(st -> 'seats') s where jsonb_typeof(s) = 'object' and (s ->> 'in_hand')::boolean and not (s ->> 'folded')::boolean);
  can_act integer := (select count(*) from jsonb_array_elements(st -> 'seats') s where public.lr_pk_ok(st, s, 'act'));
  facing boolean := exists (select 1 from jsonb_array_elements(st -> 'seats') s where public.lr_pk_ok(st, s, 'act') and (s ->> 'bet')::numeric < (st ->> 'current_bet')::numeric);
  nxt integer;
  deck jsonb;
  n integer;
begin
  if alive = 1 then return public.lr_pk_finish(st, false); end if;
  if can_act >= 2 or facing then
    nxt := public.lr_pk_next(st, case when (st ->> 'to_act')::integer >= 0 then (st ->> 'to_act')::integer else (st ->> 'button')::integer end, 'needs');
    if nxt >= 0 then return st || jsonb_build_object('to_act', nxt, 'pause', 0); end if;
  end if;
  for i in 0 .. 7 loop
    if jsonb_typeof(st -> 'seats' -> i) = 'object' then
      st := jsonb_set(st, array['seats', i::text], (st -> 'seats' -> i) || jsonb_build_object('bet', 0, 'acted', false)
        || case when public.lr_pk_ok(st, st -> 'seats' -> i, 'act') then '{"last": null}'::jsonb else '{}'::jsonb end);
    end if;
  end loop;
  st := st || jsonb_build_object('current_bet', 0, 'min_raise', st -> 'bb');
  if st ->> 'phase' = 'river' then return public.lr_pk_finish(st, true); end if;
  n := case when st ->> 'phase' = 'preflop' then 3 else 1 end;
  deck := st -> 'deck';
  st := st || jsonb_build_object('board', (st -> 'board') || (select coalesce(jsonb_agg(deck -> (jsonb_array_length(deck) - k) order by k), '[]'::jsonb) from generate_series(1, n) k),
    'deck', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(deck) with ordinality u(x, o) where o <= jsonb_array_length(deck) - n),
    'phase', case st ->> 'phase' when 'preflop' then 'flop' when 'flop' then 'turn' else 'river' end);
  if can_act < 2 then return st || jsonb_build_object('to_act', -1, 'pause', 1300); end if;
  return st || jsonb_build_object('to_act', public.lr_pk_next(st, (st ->> 'button')::integer, 'act'), 'pause', 0);
end;
$$;

create or replace function public.lr_pk_start(st jsonb) returns jsonb language plpgsql volatile set search_path = public as $$
declare
  s jsonb;
  live integer[];
  deck integer[];
  i integer;
  sb integer;
  bb integer;
  k integer;
begin
  for k in 0 .. 7 loop
    s := st -> 'seats' -> k;
    if jsonb_typeof(s) <> 'object' then continue; end if;
    if s ->> 'bot' is not null and (s ->> 'stack')::numeric <= 0 then
      st := jsonb_set(st, array['seats', k::text], public.lr_pk_seat('bot:' || (s ->> 'bot') || (st ->> 'hand'), s ->> 'bot', 2000, s ->> 'bot'));
    elsif s ->> 'bot' is null and ((s ->> 'stack')::numeric <= 0 or (s ->> 'leaving')::boolean) then
      st := jsonb_set(st, array['seats', k::text], 'null'::jsonb);
    end if;
    if jsonb_typeof(st -> 'seats' -> k) = 'object' then
      st := jsonb_set(st, array['seats', k::text], (st -> 'seats' -> k) || '{"in_hand": false, "folded": false, "allin": false, "acted": false, "bet": 0, "committed": 0, "cards": [], "last": null, "won": 0, "hand_name": null, "revealed": false, "best": null}');
    end if;
  end loop;
  live := array(select gs from generate_series(0, 7) gs where jsonb_typeof(st -> 'seats' -> gs) = 'object' and (st -> 'seats' -> gs ->> 'stack')::numeric > 0);
  st := st || '{"board": [], "result": null, "winners": [], "counted": false, "rake": 0}';
  if coalesce(array_length(live, 1), 0) < 2 or not exists (select 1 from jsonb_array_elements(st -> 'seats') x where jsonb_typeof(x) = 'object' and x ->> 'bot' is null) then
    return st || '{"phase": "waiting", "to_act": -1, "pause": 0}';
  end if;
  st := st || jsonb_build_object('button', public.lr_pk_next(st, (st ->> 'button')::integer, 'stack'));
  deck := array(select x from generate_series(0, 51) x order by random());
  foreach k in array live loop st := jsonb_set(st, array['seats', k::text, 'in_hand'], 'true'); end loop;
  for r in 1 .. 2 loop
    i := (st ->> 'button')::integer;
    for k in 1 .. array_length(live, 1) loop
      i := public.lr_pk_next(st, i, 'hand');
      st := jsonb_set(st, array['seats', i::text, 'cards'], (st -> 'seats' -> i -> 'cards') || to_jsonb(deck[array_length(deck, 1)]));
      deck := deck[1:array_length(deck, 1) - 1];
    end loop;
  end loop;
  st := st || jsonb_build_object('deck', to_jsonb(deck));
  sb := case when array_length(live, 1) = 2 then (st ->> 'button')::integer else public.lr_pk_next(st, (st ->> 'button')::integer, 'hand') end;
  bb := public.lr_pk_next(st, sb, 'hand');
  st := public.lr_pk_put(st, sb, (st ->> 'sb')::numeric);
  st := jsonb_set(st, array['seats', sb::text, 'last'], '"Small blind"');
  st := public.lr_pk_put(st, bb, (st ->> 'bb')::numeric);
  st := jsonb_set(st, array['seats', bb::text, 'last'], '"Big blind"');
  st := st || jsonb_build_object('current_bet', st -> 'bb', 'min_raise', st -> 'bb', 'phase', 'preflop', 'hand', (st ->> 'hand')::integer + 1, 'pause', 0);
  st := st || jsonb_build_object('to_act', public.lr_pk_next(st, bb, 'act'));
  if (st ->> 'to_act')::integer < 0 then st := public.lr_pk_advance(st); end if;
  return st;
end;
$$;

create or replace function public.lr_pk_act(st jsonb, i integer, act text, amount numeric default 0) returns jsonb language plpgsql immutable set search_path = public as $$
declare
  s jsonb := st -> 'seats' -> i;
  need numeric;
  cap numeric;
  target numeric;
  was numeric;
  by_ numeric;
begin
  if jsonb_typeof(s) <> 'object' or (st ->> 'to_act')::integer <> i or st ->> 'phase' not in ('preflop', 'flop', 'turn', 'river') then return st || '{"err": "Not your turn."}'; end if;
  need := (st ->> 'current_bet')::numeric - (s ->> 'bet')::numeric;
  if act = 'fold' then st := jsonb_set(st, array['seats', i::text], s || '{"folded": true, "last": "Fold"}');
  elsif act = 'check' then
    if need > 0 then return st || '{"err": "You cannot check."}'; end if;
    st := jsonb_set(st, array['seats', i::text, 'last'], '"Check"');
  elsif act = 'call' then
    st := public.lr_pk_put(st, i, need);
    st := jsonb_set(st, array['seats', i::text, 'last'], to_jsonb(case when (st -> 'seats' -> i ->> 'allin')::boolean then 'All-in' when need > 0 then 'Call' else 'Check' end));
  elsif act = 'raise' then
    cap := (s ->> 'bet')::numeric + (s ->> 'stack')::numeric;
    target := least(floor(coalesce(amount, 0)), cap);
    if target <= (st ->> 'current_bet')::numeric then return st || '{"err": "Raise more than the current bet."}'; end if;
    if target - (st ->> 'current_bet')::numeric < (st ->> 'min_raise')::numeric and target < cap then return st || '{"err": "That raise is too small."}'; end if;
    by_ := target - (st ->> 'current_bet')::numeric;
    was := (st ->> 'current_bet')::numeric;
    st := public.lr_pk_put(st, i, target - (s ->> 'bet')::numeric);
    if by_ >= (st ->> 'min_raise')::numeric then
      st := st || jsonb_build_object('min_raise', by_);
      for j in 0 .. 7 loop
        if j <> i and public.lr_pk_ok(st, st -> 'seats' -> j, 'act') then st := jsonb_set(st, array['seats', j::text, 'acted'], 'false'); end if;
      end loop;
    end if;
    st := st || jsonb_build_object('current_bet', target);
    st := jsonb_set(st, array['seats', i::text, 'last'], to_jsonb(case when (st -> 'seats' -> i ->> 'allin')::boolean then 'All-in' when was > 0 then 'Raise ' || target else 'Bet ' || target end));
  else return st || '{"err": "Unknown move."}';
  end if;
  st := jsonb_set(st, array['seats', i::text, 'acted'], 'true');
  return public.lr_pk_advance(st - 'err');
end;
$$;

-- how good a bot thinks its hand is (0 to 1)
create or replace function public.lr_pk_strength(hole integer[], board integer[]) returns numeric language plpgsql immutable set search_path = public as $$
declare
  a integer;
  b integer;
  v numeric;
  sc bigint;
  cat integer;
  pr integer;
begin
  if coalesce(array_length(board, 1), 0) = 0 then
    a := greatest(hole[1] / 4, hole[2] / 4); b := least(hole[1] / 4, hole[2] / 4);
    v := (a + b)::numeric / 24 * 0.55;
    if a = b then v := 0.5 + a::numeric / 24; end if;
    if hole[1] % 4 = hole[2] % 4 then v := v + 0.06; end if;
    if a - b = 1 then v := v + 0.04; end if;
    if a >= 10 then v := v + 0.05; end if;
    return least(1, v);
  end if;
  sc := (public.lr_pk_best(hole || board)).score;
  cat := (sc / 371293)::integer;
  v := (array[0.12, 0.42, 0.66, 0.78, 0.84, 0.88, 0.93, 0.98, 1])[cat + 1];
  if cat = 0 then v := v + (select max(x / 4) from unnest(hole) x)::numeric / 60; end if;
  if cat = 1 then
    pr := ((sc / 28561) % 13)::integer;
    if not pr = any(array[hole[1] / 4, hole[2] / 4]) then v := 0.2;
    elsif pr >= (select max(x / 4) from unnest(board) x) then v := v + 0.12;
    end if;
  end if;
  if array_length(board, 1) < 5 and (select max(n) from (select count(*) n from unnest(hole || board) x group by x % 4) q) = 4 then v := v + 0.12; end if;
  return least(1, v);
end;
$$;
create or replace function public.lr_pk_bot(st jsonb, i integer, out act text, out amt numeric) language plpgsql volatile set search_path = public as $$
declare
  s jsonb := st -> 'seats' -> i;
  tight numeric;
  aggr numeric;
  bluff numeric;
  need numeric := (st ->> 'current_bet')::numeric - (s ->> 'bet')::numeric;
  pot numeric := (select coalesce(sum((x ->> 'committed')::numeric), 0) from jsonb_array_elements(st -> 'seats') x where jsonb_typeof(x) = 'object');
  str numeric := public.lr_pk_strength(public.lr_ints(s -> 'cards'), public.lr_ints(st -> 'board'));
  r numeric := random();
  bb numeric := (st ->> 'bb')::numeric;
  cb numeric := (st ->> 'current_bet')::numeric;
  odds numeric;
begin
  select t, a, b into tight, aggr, bluff from (values ('Ace Bot', 0.6, 0.5, 0.05), ('Bluffy', 0.3, 0.7, 0.14), ('Duchess', 0.7, 0.4, 0.04), ('Rusty', 0.45, 0.3, 0.06),
    ('Lucky Lou', 0.4, 0.55, 0.09)) v(n, t, a, b) where n = s ->> 'bot';
  tight := coalesce(tight, 0.6); aggr := coalesce(aggr, 0.5); bluff := coalesce(bluff, 0.05);
  amt := 0;
  if need = 0 then
    if str > 0.6 + tight * 0.2 and r < 0.35 + aggr * 0.5 then act := 'raise'; amt := 0.45 + random() * 0.5;
    elsif r < bluff then act := 'raise'; amt := 0.5;
    else act := 'check'; return;
    end if;
  else
    odds := need / (pot + need);
    if str > 0.8 and r < 0.25 + aggr * 0.5 then act := 'raise'; amt := 0.6 + random() * 0.6;
    elsif str >= odds + 0.1 * tight or (need <= bb and str > 0.25) then act := 'call'; return;
    elsif r < bluff * 0.5 then act := 'raise'; amt := 0.7;
    else act := 'fold'; return;
    end if;
  end if;
  -- a raise of a share of the pot, in big blinds
  amt := least((s ->> 'bet')::numeric + (s ->> 'stack')::numeric, greatest(cb + (st ->> 'min_raise')::numeric, cb + round(((pot + need) * amt) / bb) * bb));
end;
$$;

-- what the page sees: the bots' cards only once they are shown, no deck
create or replace function public.lr_pk_view(st jsonb) returns jsonb language plpgsql immutable as $$
begin
  if st is null or jsonb_typeof(st) <> 'object' then return null; end if;
  for i in 0 .. 7 loop
    if jsonb_typeof(st -> 'seats' -> i) = 'object' and st -> 'seats' -> i ->> 'bot' is not null and not (st -> 'seats' -> i ->> 'revealed')::boolean then
      st := jsonb_set(st, array['seats', i::text, 'cards'], case when jsonb_array_length(st -> 'seats' -> i -> 'cards') > 0 then '[-1, -1]'::jsonb else '[]'::jsonb end);
    end if;
  end loop;
  return st - 'deck';
end;
$$;

-- sit (with a buy-in), act (fold, check, call, raise), next (the next hand or street), leave
create or replace function public.game_poker(p_act text, p_amount numeric default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  st jsonb;
  frames jsonb := '[]'::jsonb;
  me integer := 0;
  b record;
  rake numeric;
  won boolean;
  hn text;
  steps integer := 0;
  busted boolean := false;
begin
  insert into public.lr_secret (player) values (p.id) on conflict do nothing;
  select pk into st from public.lr_secret where player = p.id;
  if p_act = 'sit' then
    if st is not null then raise exception 'already seated'; end if;
    if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
    p_amount := floor(coalesce(p_amount, 0));
    if p_amount < 200 then raise exception 'buy-in'; end if;
    if public.lr_n(g, 'credits') < p_amount then raise exception 'credits'; end if;
    g := public.lr_add(g, 'credits', -p_amount);
    st := jsonb_build_object('solo', true, 'phase', 'waiting', 'hand', 0, 'button', -1, 'sb', 10, 'bb', 20, 'board', '[]'::jsonb, 'deck', '[]'::jsonb,
      'current_bet', 0, 'min_raise', 20, 'to_act', -1, 'result', null, 'winners', '[]'::jsonb, 'seats', jsonb_build_array(
        public.lr_pk_seat(p.id::text, p.name, p_amount, null), public.lr_pk_seat('bot:Ace Bot', 'Ace Bot', 2000, 'Ace Bot'), null,
        public.lr_pk_seat('bot:Bluffy', 'Bluffy', 2000, 'Bluffy'), public.lr_pk_seat('bot:Duchess', 'Duchess', 2000, 'Duchess'),
        public.lr_pk_seat('bot:Rusty', 'Rusty', 2000, 'Rusty'), null, public.lr_pk_seat('bot:Lucky Lou', 'Lucky Lou', 2000, 'Lucky Lou')));
    st := public.lr_pk_start(st);
  elsif st is null then raise exception 'not seated';
  elsif p_act = 'leave' then
    -- chips in the current pot stay there; the rest goes back to the credits
    g := public.lr_add(g, 'credits', public.lr_n(st -> 'seats' -> 0, 'stack'));
    update public.lr_secret set pk = null where player = p.id;
    g := jsonb_set(g, '{pk,solo}', 'null'::jsonb);
    return public.lr_put(p.id, g, jsonb_build_object('frames', '[]'::jsonb, 'left', public.lr_n(st -> 'seats' -> 0, 'stack')));
  elsif p_act = 'next' then
    if st ->> 'phase' = 'showdown' then
      if public.lr_n(st -> 'seats' -> 0, 'stack') <= 0 then busted := true;
      else st := public.lr_pk_start(st);
      end if;
    elsif (st ->> 'to_act')::integer < 0 and st ->> 'phase' in ('preflop', 'flop', 'turn', 'river') then st := public.lr_pk_advance(st);
    elsif st ->> 'phase' = 'waiting' then st := public.lr_pk_start(st);
    end if;
  else
    st := public.lr_pk_act(st, me, p_act, p_amount);
    if st ? 'err' then raise exception '%', st ->> 'err'; end if;
  end if;
  -- the bots play until it is the player's turn again or the hand is over
  loop
    steps := steps + 1;
    exit when busted or steps > 200;
    if st ->> 'phase' = 'showdown' then
      if not coalesce((st ->> 'counted')::boolean, false) then
        st := st || '{"counted": true}';
        if (st -> 'seats' -> me ->> 'in_hand')::boolean then
          won := (st -> 'seats' -> me ->> 'won')::numeric > 0;
          g := jsonb_set(g, '{pk,hands}', to_jsonb(public.lr_n(g -> 'pk', 'hands') + 1));
          -- the house takes a rake from pots won against the bots: 5% (2.5% with the Chip Magnet), at most 20 big blinds
          if won then
            rake := least(20 * case when public.lr_has(g, 'pkMagnet') then 10 else 20 end, floor((st -> 'seats' -> me ->> 'won')::numeric * case when public.lr_has(g, 'pkMagnet') then 0.025 else 0.05 end));
            if rake > 0 then st := jsonb_set(st, array['seats', me::text, 'stack'], to_jsonb((st -> 'seats' -> me ->> 'stack')::numeric - rake)) || jsonb_build_object('rake', rake); end if;
          end if;
          hn := st -> 'seats' -> me ->> 'hand_name';
          g := public.lr_xp(g, c, 6 + case when won then 8 else 0 end);
          g := public.lr_ach(g, jsonb_build_object('pokerWin', won, 'pokerSF', won and coalesce(hn ~* 'straight flush|royal', false)));
        end if;
      end if;
      frames := frames || jsonb_build_array(public.lr_pk_view(st));
      exit;
    end if;
    if st ->> 'phase' = 'waiting' then frames := frames || jsonb_build_array(public.lr_pk_view(st)); exit; end if;
    frames := frames || jsonb_build_array(public.lr_pk_view(st));
    if (st ->> 'to_act')::integer < 0 then st := public.lr_pk_advance(st); continue; end if;
    exit when (st ->> 'to_act')::integer = me;
    b := public.lr_pk_bot(st, (st ->> 'to_act')::integer);
    st := public.lr_pk_act(st, (st ->> 'to_act')::integer, b.act, b.amt);
    if st ? 'err' then
      st := st - 'err';
      st := public.lr_pk_act(st, (st ->> 'to_act')::integer, case when (st ->> 'current_bet')::numeric > (st -> 'seats' -> (st ->> 'to_act')::integer ->> 'bet')::numeric then 'call' else 'check' end, 0);
      st := st - 'err';
    end if;
  end loop;
  if busted then
    update public.lr_secret set pk = null where player = p.id;
    g := jsonb_set(g, '{pk,solo}', 'null'::jsonb);
  else
    update public.lr_secret set pk = st where player = p.id;
    g := jsonb_set(g, '{pk,solo}', public.lr_pk_view(st));
  end if;
  return public.lr_put(p.id, g, jsonb_build_object('frames', frames, 'busted', busted));
end;
$$;

-- ----- Lucky Burger: one paycheck per 10 seconds of a shift at most -----
create or replace function public.lr_jb_pos(worked numeric) returns integer language sql immutable as $$
  select coalesce(max(i) - 1, 0)::integer from unnest(array[0, 225, 675, 1350, 2250, 3600, 5400, 8100]) with ordinality u(at, i) where worked >= at
$$;
create or replace function public.game_job(p_act text, p_mood numeric default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  j jsonb := coalesce(g -> 'job', '{}'::jsonb);
  t numeric := floor(extract(epoch from clock_timestamp()) * 1000);
  pay numeric := 0;
  pos integer;
  now_pos integer;
  promo boolean := false;
begin
  if p_act = 'start' then
    j := j || jsonb_build_object('shifts', public.lr_n(j, 'shifts') + 1, 'paidAt', t);
  elsif p_act = 'pay' then
    -- the page pays every 10 seconds of good work; faster than that is not possible
    if public.lr_n(j, 'paidAt') = 0 or t - public.lr_n(j, 'paidAt') < 9500 then
      return public.lr_put(p.id, g, jsonb_build_object('pay', 0, 'early', true));
    end if;
    pos := public.lr_jb_pos(public.lr_n(j, 'worked'));
    -- the happier the boss, the bigger the paycheck (80% to 120% of the wage), +10% with the badge
    pay := round((array[14, 22, 34, 50, 72, 105, 160, 250])[pos + 1] * (0.8 + 0.4 * least(100, greatest(30, coalesce(p_mood, 0))) / 100)
      * case when public.lr_has(g, 'jbBadge') then 1.1 else 1 end * public.lr_evf(c, 'wage'));
    j := j || jsonb_build_object('worked', public.lr_n(j, 'worked') + 10 * case when public.lr_has(g, 'jbSchool') then 1.25 else 1 end,
      'earned', public.lr_n(j, 'earned') + pay, 'paidAt', t);
    now_pos := public.lr_jb_pos(public.lr_n(j, 'worked'));
    if now_pos > public.lr_n(j, 'pos') then j := j || jsonb_build_object('pos', now_pos); promo := true; end if;
    g := public.lr_add(g, 'credits', pay) || jsonb_build_object('job', j);
    g := public.lr_ach(g, jsonb_build_object('jobPaid', true, 'jobPos', now_pos));
    return public.lr_put(p.id, g, jsonb_build_object('pay', pay, 'pos', now_pos, 'promoted', promo));
  elsif p_act = 'stop' then
    j := j - 'paidAt';
  else raise exception 'unknown';
  end if;
  return public.lr_put(p.id, g || jsonb_build_object('job', j), '{}'::jsonb);
end;
$$;

-- ----- Shop -----
create or replace function public.lr_price(id text, g jsonb) returns numeric language sql immutable as $$
  select case id
    when 'horseshoe' then 2000 * power(3, public.lr_n(g -> 'owned', 'horseshoe'))
    when 'goldCherry' then 1500 when 'piggy' then 3000 when 'starPlus' then 30000 when 'autospin' then 1000
    when 'gold' then 25000 when 'midnight' then 30000 when 'ruby' then 20000 when 'emerald' then 20000 when 'bubblegum' then 18000 when 'carbon' then 35000
    when 'neon' then 40000 when 'goldName' then 15000 when 'fireName' then 22000 when 'iceName' then 22000 when 'galaxyName' then 50000 when 'adminName' then 0
    when 'bronzeCup' then 5000 when 'silverCup' then 25000 when 'goldCup' then 100000 when 'diamondTrophy' then 500000 when 'crownTrophy' then 2000000
    when 'nightMode' then 5000 when 'disco' then 8000 when 'royalFelt' then 15000 when 'goldBacks' then 12000 when 'fireworks' then 20000
    when 'bjChip' then 15000 when 'bjShoe' then 8000 when 'bjPeek' then 20000 when 'rlStraight' then 12000 when 'rlOutside' then 20000 when 'rlZero' then 25000
    when 'pkMagnet' then 15000 when 'pkCoach' then 10000 when 'plGold' then 20000 when 'plSoft' then 10000 when 'plBump' then 15000
    when 'ckFeather' then 12000 when 'ckHelmet' then 12000 when 'ckGold' then 20000 when 'hrCrop' then 15000 when 'hrBino' then 15000 when 'hrSaddle' then 15000
    when 'rkTurbo' then 25000 when 'rkChute' then 15000 when 'rkPilot' then 15000 when 'cfThumb' then 30000
    when 'jbShoes' then 3000 when 'jbTimer' then 8000 when 'jbBadge' then 25000 when 'jbSchool' then 60000 when 'lightning' then 250000
  end
$$;
create or replace function public.game_buy(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  price numeric := public.lr_price(p_id, g);
  d numeric := public.lr_evd(c);
begin
  if price is null then raise exception 'unknown goodie'; end if;
  if p_id = 'adminName' and not p.is_admin then raise exception 'not allowed'; end if;
  if d > 0 then price := greatest(1, floor(price * (1 - d))); end if;
  if public.lr_n(g, 'credits') < price then raise exception 'credits'; end if;
  if p_id = 'horseshoe' then
    if public.lr_n(g -> 'owned', 'horseshoe') >= 3 then raise exception 'maxed'; end if;
    g := jsonb_set(g, '{owned,horseshoe}', to_jsonb(public.lr_n(g -> 'owned', 'horseshoe') + 1));
  else
    if public.lr_has(g, p_id) then raise exception 'owned'; end if;
    g := jsonb_set(g, array['owned', p_id], 'true');
  end if;
  g := public.lr_ach(public.lr_add(g, 'credits', -price));
  return public.lr_put(p.id, g, jsonb_build_object('id', p_id, 'price', price));
end;
$$;

-- a new mission instead of one, for 25 x the level
create or replace function public.game_swap(p_i integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  g jsonb := public.lr_fill(public.lr_g(p));
  cost numeric := 25 * p.level;
begin
  if p_i not between 0 and 2 then raise exception 'mission'; end if;
  if public.lr_n(g, 'credits') < cost then raise exception 'credits'; end if;
  g := public.lr_add(g, 'credits', -cost);
  g := jsonb_set(g, array['missions', p_i::text], public.lr_new_mission(array(select x ->> 't' from jsonb_array_elements(g -> 'missions') x), p.level));
  return public.lr_put(p.id, g, jsonb_build_object('cost', cost));
end;
$$;

create or replace function public.game_prestige()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  g jsonb := public.lr_g(p);
begin
  if p.level < 20 then raise exception 'level'; end if;
  if p.prestige >= 99 then raise exception 'max'; end if;
  g := g || jsonb_build_object('prestige', p.prestige + 1, 'level', 1, 'xp', 0);
  g := public.lr_ach(g, jsonb_build_object('prestige', p.prestige + 1));
  return public.lr_put(p.id, g, jsonb_build_object('prestige', p.prestige + 1));
end;
$$;

-- Start over: the start credits at level 1, everything else gone (the prestige stays)
create or replace function public.game_restart()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
begin
  delete from public.lr_secret where player = p.id;
  g := g || jsonb_build_object('credits', (c ->> 'startCredits')::numeric, 'level', 1, 'xp', 0, 'spins', 0, 'jackpots', 0, 'best', 0, 'lastWin', 0,
    'owned', '{}'::jsonb, 'ach', '{}'::jsonb, 'missions', '[]'::jsonb, 'missionsDone', 0, 'streak', 0, 'stars', 0, 'starBank', 0, 'freeSpins', 0,
    'freeBet', 0, 'freeTotal', 0, 'nudges', 0, 'sl', '{}'::jsonb, 'job', jsonb_build_object('worked', 0, 'earned', 0, 'shifts', 0, 'pos', 0),
    'jobReset', floor(extract(epoch from now()) * 1000));
  g := g || jsonb_build_object('bj', coalesce(g -> 'bj', '{}'::jsonb) || '{"round": null, "hands": 0, "lastBet": 0, "shoe": []}',
    'pl', coalesce(g -> 'pl', '{}'::jsonb) || '{"drops": 0, "pending": []}', 'ck', coalesce(g -> 'ck', '{}'::jsonb) || '{"round": null, "games": 0}',
    'cf', coalesce(g -> 'cf', '{}'::jsonb) || '{"round": null, "flips": 0}', 'pk', coalesce(g -> 'pk', '{}'::jsonb) || '{"solo": null, "hands": 0}');
  return public.lr_put(p.id, public.lr_fill(g), '{}'::jsonb);
end;
$$;

-- An event's gift, once per player and event.
create or replace function public.game_gifts()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  e jsonb;
  got jsonb := '[]'::jsonb;
  seen jsonb := case when jsonb_typeof(g -> 'evGifts') = 'array' then g -> 'evGifts' else '[]'::jsonb end;
  n numeric;
begin
  for e in select * from jsonb_array_elements(c -> 'evs') loop
    n := floor(public.lr_num(e -> 'fx' -> 'gift', 0, 0, 1000000));
    if n > 0 and not seen @> jsonb_build_array(e ->> 'id') then
      g := public.lr_add(g, 'credits', n);
      seen := seen || jsonb_build_array(e ->> 'id');
      got := got || jsonb_build_array(jsonb_build_object('id', e ->> 'id', 'title', e ->> 'title', 'icon', e ->> 'icon', 'gift', n));
    end if;
  end loop;
  if jsonb_array_length(got) = 0 then return jsonb_build_object('r', jsonb_build_object('gifts', got)); end if;
  seen := (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(seen) with ordinality u(x, o) where o > jsonb_array_length(seen) - 50);
  return public.lr_put(p.id, g || jsonb_build_object('evGifts', seen), jsonb_build_object('gifts', got));
end;
$$;

-- ----- Live games (roulette, horses, rocket, lotto): their goodie and event extras, XP and achievements -----
create or replace function public.game_live()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  c jsonb := public.lr_cfg();
  g jsonb := public.lr_g(p);
  b record;
  k text;
  v numeric;
  at integer;
  ord integer[] := array[0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26];
  bon jsonb := '{}'::jsonb;
  xp numeric := 0;
  ev numeric;
  any_ boolean := false;
  t numeric;
begin
  -- roulette: a quarter back for a single number right next to the ball, outside wins 2% more, half of the even-money bets back on zero
  for b in select rb.id, rb.bets, rb.total, rb.payout, rr.result from public.roulette_bets rb join public.roulette_rounds rr on rr.id = rb.round_id
           where rb.player = p.id and not rb.bonused and rb.payout is not null and rr.result is not null loop
    any_ := true;
    at := array_position(ord, b.result::integer) - 1;
    for k, v in select key, value::numeric from jsonb_each_text(b.bets) loop
      if left(k, 1) = 'n' and public.lr_has(g, 'rlStraight') and substr(k, 2)::integer <> b.result
         and substr(k, 2)::integer in (ord[(at + 1) % 37 + 1], ord[(at + 36) % 37 + 1]) then bon := bon || jsonb_build_object('rlStraight', public.lr_n(bon, 'rlStraight') + v * 0.25); end if;
      if b.result = 0 and public.lr_has(g, 'rlZero') and k in ('red', 'black', 'odd', 'even', 'low', 'high') then bon := bon || jsonb_build_object('rlZero', public.lr_n(bon, 'rlZero') + v * 0.5); end if;
      if left(k, 1) <> 'n' and public.roulette_hit(k, b.result::integer) and public.lr_has(g, 'rlOutside') then
        bon := bon || jsonb_build_object('rlOutside', public.lr_n(bon, 'rlOutside') + v * public.roulette_pays(k) * 0.02);
      end if;
    end loop;
    ev := greatest(0, b.payout - b.total) * (public.lr_evm(c, 'rl') - 1);
    if ev > 0 then bon := bon || jsonb_build_object('event', public.lr_n(bon, 'event') + ev); end if;
    xp := xp + 8;
    g := public.lr_ach(g, jsonb_build_object('bullseye', exists (select 1 from jsonb_each_text(b.bets) x where left(x.key, 1) = 'n' and substr(x.key, 2)::integer = b.result),
      'win', greatest(0, b.payout - b.total), 'bet', b.total));
    update public.roulette_bets set bonused = true where id = b.id;
  end loop;
  -- horses: winning Win or Place bets 6% more, 2% of losing bets back
  for b in select * from public.horse_bets where player = p.id and not bonused and payout is not null loop
    any_ := true;
    if b.payout = 0 and public.lr_has(g, 'hrSaddle') then bon := bon || jsonb_build_object('hrSaddle', public.lr_n(bon, 'hrSaddle') + b.amount * 0.02); end if;
    if b.payout > 0 and b.kind = 'win' and public.lr_has(g, 'hrCrop') then bon := bon || jsonb_build_object('hrCrop', public.lr_n(bon, 'hrCrop') + b.payout * 0.06); end if;
    if b.payout > 0 and b.kind = 'place' and public.lr_has(g, 'hrBino') then bon := bon || jsonb_build_object('hrBino', public.lr_n(bon, 'hrBino') + b.payout * 0.06); end if;
    ev := greatest(0, b.payout - b.amount) * (public.lr_evm(c, 'hr') - 1);
    if ev > 0 then bon := bon || jsonb_build_object('event', public.lr_n(bon, 'event') + ev); end if;
    xp := xp + 3 + case when b.payout > 0 then 6 else 0 end;
    if b.payout > 0 then g := public.lr_ach(g, jsonb_build_object('horseWin', true, 'horseOdds', b.odds, 'win', b.payout)); end if;
    update public.horse_bets set bonused = true where id = b.id;
  end loop;
  -- rocket: every cash-out 2% more, 2% back after an explosion
  for b in select * from public.rocket_bets where player = p.id and not bonused and payout is not null loop
    any_ := true;
    if b.payout > 0 and public.lr_has(g, 'rkTurbo') then bon := bon || jsonb_build_object('rkTurbo', public.lr_n(bon, 'rkTurbo') + b.payout * 0.02); end if;
    if b.payout = 0 and public.lr_has(g, 'rkChute') then bon := bon || jsonb_build_object('rkChute', public.lr_n(bon, 'rkChute') + b.amount * 0.02); end if;
    ev := greatest(0, b.payout - b.amount) * (public.lr_evm(c, 'rk') - 1);
    if ev > 0 then bon := bon || jsonb_build_object('event', public.lr_n(bon, 'event') + ev); end if;
    xp := xp + 3 + case when b.payout > 0 then 6 else 0 end;
    if b.payout > 0 then g := public.lr_ach(g, jsonb_build_object('rocketMult', b.cashed, 'win', b.payout - b.amount, 'bet', b.amount)); end if;
    update public.rocket_bets set bonused = true where id = b.id;
  end loop;
  -- lotto tickets: XP
  select count(*) into t from public.lotto_tickets where player = p.id and not bonused;
  if t > 0 then
    any_ := true;
    xp := xp + 5 * t;
    update public.lotto_tickets set bonused = true where player = p.id and not bonused;
  end if;
  if not any_ then return jsonb_build_object('r', jsonb_build_object('none', true)); end if;
  for k, v in select key, floor(value::numeric) from jsonb_each_text(bon) loop
    if v > 0 then g := public.lr_out(public.lr_add(g, 'credits', v), 'bonus', jsonb_build_object('id', k, 'amount', v)); end if;
  end loop;
  if xp > 0 then g := public.lr_xp(g, c, xp); end if;
  g := public.lr_ach(g);
  return public.lr_put(p.id, g, '{}'::jsonb);
end;
$$;

do $$
declare
  f text;
begin
  foreach f in array array['game_state()', 'game_spin(numeric, boolean[], boolean)', 'game_nudge(integer)', 'game_gamble(text)', 'game_bj(text, numeric)',
    'game_plinko(numeric, integer, text, integer)', 'game_chicken(text, numeric, text)', 'game_coin(text, numeric, text)', 'game_poker(text, numeric)',
    'game_job(text, numeric)', 'game_buy(text)', 'game_swap(integer)', 'game_prestige()', 'game_restart()', 'game_gifts()', 'game_live()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['lr_me()', 'lr_cfg()', 'lr_g(public.players)', 'lr_put(uuid, jsonb, jsonb)', 'lr_bj_draw(uuid)', 'lr_bj_play(uuid, jsonb, jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
end;
$$;
