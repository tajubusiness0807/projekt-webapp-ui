-- Lucky Reels: database setup for the public site.
-- Run this once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.

create table if not exists public.players (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  credits bigint not null default 500,
  best bigint not null default 0,
  level integer not null default 1,
  spins integer not null default 0,
  game text,
  updated_at timestamptz not null default now()
);

alter table public.players enable row level security;

-- Everyone, signed in or not, can read the highscores.
drop policy if exists "Highscores are public" on public.players;
create policy "Highscores are public" on public.players
  for select using (true);

-- A signed-in player can change only their own row. Nobody can add or delete rows from the site.
drop policy if exists "Players save their own game" on public.players;
create policy "Players save their own game" on public.players
  for update to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Live highscore updates.
do $$
begin
  alter publication supabase_realtime add table public.players;
exception when duplicate_object then null;
end $$;

-- Run this part AFTER creating the two users under Authentication -> Users
-- (emails lukas@lucky-reels.app and julius@lucky-reels.app, "Auto Confirm User" ticked).
insert into public.players (id, name, credits)
select id, 'Lukas', 1000 from auth.users where email = 'lukas@lucky-reels.app'
on conflict (id) do nothing;

insert into public.players (id, name, credits)
select id, 'Julius', 750 from auth.users where email = 'julius@lucky-reels.app'
on conflict (id) do nothing;

insert into public.players (id, name, credits)
select id, 'Finley', 500 from auth.users where email = 'finley@lucky-reels.app'
on conflict (id) do nothing;

-- Check: this should list every player.
select name, credits from public.players order by name;

-- ---------------------------------------------------------------------------
-- Self sign-up: run this part once to let players create their own accounts
-- on the login screen. Also switch off "Confirm email" under
-- Authentication -> Sign In / Providers -> Email, because the made-up
-- @lucky-reels.app addresses can't receive mail.

create or replace function public.create_player_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  display text := trim(coalesce(new.raw_user_meta_data ->> 'name', ''));
begin
  if display !~ '^[A-Za-z0-9_-]{3,20}$' then
    display := split_part(new.email, '@', 1);
  end if;
  insert into public.players (id, name, credits)
  values (new.id, display, 500)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.create_player_for_new_user();

-- Give a game row to any login that was created before the trigger existed.
insert into public.players (id, name, credits)
select u.id, split_part(u.email, '@', 1), 500
from auth.users u
where not exists (select 1 from public.players p where p.id = u.id);

-- ---------------------------------------------------------------------------
-- Chat and jackpot alerts: run this part once.

-- Counts jackpots per player so the highscores can light up when someone hits one.
alter table public.players add column if not exists jackpots integer not null default 0;

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.players (id) on delete cascade,
  name text not null default '',
  body text not null check (char_length(trim(body)) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists messages_created_at on public.messages (created_at desc);

alter table public.messages enable row level security;

drop policy if exists "Chat is readable" on public.messages;
create policy "Chat is readable" on public.messages
  for select using (true);

drop policy if exists "Players post as themselves" on public.messages;
create policy "Players post as themselves" on public.messages
  for insert to authenticated
  with check (user_id = auth.uid());

-- The sender's name and time come from the server, so nobody can post as someone else.
create or replace function public.stamp_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select name into new.name from public.players where id = new.user_id;
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists stamp_message on public.messages;
create trigger stamp_message
  before insert on public.messages
  for each row execute function public.stamp_message();

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- Admin menu: run this part once, then make yourself an admin with the
-- last line (put in your own username).

alter table public.players add column if not exists is_admin boolean not null default false;
alter table public.players add column if not exists is_banned boolean not null default false;
alter table public.players add column if not exists admin_rev integer not null default 0;

-- Players may only save their game fields, never their admin or blocked flags.
revoke update on public.players from anon, authenticated;
grant update (credits, best, level, spins, game, jackpots, updated_at) on public.players to authenticated;

drop policy if exists "Players save their own game" on public.players;
create policy "Players save their own game" on public.players
  for update to authenticated
  using (auth.uid() = id and not is_banned)
  with check (auth.uid() = id);

-- Game-wide settings, one row, readable by everyone, changed only through admin_save_settings.
create table if not exists public.settings (
  id integer primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb
);
insert into public.settings (id) values (1) on conflict (id) do nothing;
alter table public.settings enable row level security;
drop policy if exists "Settings are public" on public.settings;
create policy "Settings are public" on public.settings for select using (true);
do $$
begin
  alter publication supabase_realtime add table public.settings;
exception when duplicate_object then null;
end $$;

-- Blocked players and a switched-off chat stop new messages.
drop policy if exists "Players post as themselves" on public.messages;
create policy "Players post as themselves" on public.messages
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.players p where p.id = auth.uid() and not p.is_banned)
    and (
      coalesce((select (data ->> 'chatEnabled')::boolean from public.settings where id = 1), true)
      or exists (select 1 from public.players p where p.id = auth.uid() and p.is_admin)
    )
  );

-- New accounts use the admin's start credits and respect "New accounts allowed".
create or replace function public.create_player_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  display text := trim(coalesce(new.raw_user_meta_data ->> 'name', ''));
  start_credits bigint;
  open boolean;
begin
  select (data ->> 'startCredits')::bigint, (data ->> 'signupsOpen')::boolean
    into start_credits, open
    from public.settings where id = 1;
  -- Accounts made on the sign-in screen carry a name; ones made in the dashboard don't.
  if open is false and new.raw_user_meta_data ? 'name' then
    raise exception 'Sign-ups are closed';
  end if;
  if display !~ '^[A-Za-z0-9_-]{3,20}$' then
    display := split_part(new.email, '@', 1);
  end if;
  insert into public.players (id, name, credits)
  values (new.id, display, coalesce(start_credits, 500))
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_admin from public.players where id = auth.uid()), false);
$$;

create or replace function public.admin_update_player(
  target uuid,
  new_credits bigint default null,
  reset boolean default false,
  set_admin boolean default null,
  set_banned boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if new_credits is not null and new_credits < 0 then raise exception 'credits must be 0 or more'; end if;
  update public.players set
    credits = case when reset then coalesce(new_credits, start_credits) else coalesce(new_credits, credits) end,
    best = case when reset then 0 else best end,
    level = case when reset then 1 else level end,
    spins = case when reset then 0 else spins end,
    jackpots = case when reset then 0 else jackpots end,
    game = case when reset then null else game end,
    is_admin = coalesce(set_admin, is_admin),
    is_banned = coalesce(set_banned, is_banned),
    admin_rev = admin_rev + case when reset or new_credits is not null then 1 else 0 end,
    updated_at = now()
  where id = target;
end;
$$;

create or replace function public.admin_give_all(amount bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.players
    set credits = greatest(0, credits + amount), admin_rev = admin_rev + 1, updated_at = now()
    where not is_banned;
end;
$$;

create or replace function public.admin_delete_message(msg bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  delete from public.messages where id = msg;
end;
$$;

create or replace function public.admin_clear_chat()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  delete from public.messages where true;
end;
$$;

create or replace function public.admin_save_settings(patch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.settings set data = data || patch where id = 1;
end;
$$;

revoke execute on function public.admin_update_player(uuid, bigint, boolean, boolean, boolean) from public, anon;
revoke execute on function public.admin_give_all(bigint) from public, anon;
revoke execute on function public.admin_delete_message(bigint) from public, anon;
revoke execute on function public.admin_clear_chat() from public, anon;
revoke execute on function public.admin_save_settings(jsonb) from public, anon;
grant execute on function public.admin_update_player(uuid, bigint, boolean, boolean, boolean) to authenticated;
grant execute on function public.admin_give_all(bigint) to authenticated;
grant execute on function public.admin_delete_message(bigint) to authenticated;
grant execute on function public.admin_clear_chat() to authenticated;
grant execute on function public.admin_save_settings(jsonb) to authenticated;

-- Make yourself an admin (use your own username):
update public.players set is_admin = true where name = 'DEIN_NAME';

-- ---------------------------------------------------------------------------
-- Private chats: run this part once (after the admin part above).
-- Who is online needs no table: it uses Supabase Realtime presence.

create table if not exists public.direct_messages (
  id bigint generated always as identity primary key,
  sender uuid not null default auth.uid() references public.players (id) on delete cascade,
  recipient uuid not null references public.players (id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 300),
  created_at timestamptz not null default now(),
  check (sender <> recipient)
);
create index if not exists direct_messages_sender on public.direct_messages (sender, created_at desc);
create index if not exists direct_messages_recipient on public.direct_messages (recipient, created_at desc);

alter table public.direct_messages enable row level security;

-- Only the two people in a private chat can read it; admins can't either.
drop policy if exists "Only the two people read a private chat" on public.direct_messages;
create policy "Only the two people read a private chat" on public.direct_messages
  for select to authenticated
  using (auth.uid() = sender or auth.uid() = recipient);

drop policy if exists "Players send private messages as themselves" on public.direct_messages;
create policy "Players send private messages as themselves" on public.direct_messages
  for insert to authenticated
  with check (
    sender = auth.uid()
    and exists (select 1 from public.players p where p.id = auth.uid() and not p.is_banned)
    and (
      coalesce((select (data ->> 'chatEnabled')::boolean from public.settings where id = 1), true)
      or exists (select 1 from public.players p where p.id = auth.uid() and p.is_admin)
    )
  );

create or replace function public.stamp_direct_message()
returns trigger
language plpgsql
as $$
begin
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists stamp_direct_message on public.direct_messages;
create trigger stamp_direct_message
  before insert on public.direct_messages
  for each row execute function public.stamp_direct_message();

do $$
begin
  alter publication supabase_realtime add table public.direct_messages;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- Admin security: run this part once (after the admin part above), then set
-- your admin password with the last statement.
--
-- Admins now need a separate admin password, checked here on the server.
-- A correct password opens a 15-minute admin session (extended by every admin
-- action); every admin function needs that session. Five wrong passwords in
-- 15 minutes block further tries. None of these tables can be read through
-- the website, not even by admins.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.admin_keys (
  player_id uuid primary key references public.players (id) on delete cascade,
  hash text not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.admin_sessions (
  token uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players (id) on delete cascade,
  expires_at timestamptz not null
);
create table if not exists public.admin_attempts (
  id bigint generated always as identity primary key,
  player_id uuid not null,
  ok boolean not null,
  at timestamptz not null default now()
);
alter table public.admin_keys enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.admin_attempts enable row level security;
revoke all on public.admin_keys, public.admin_sessions, public.admin_attempts from anon, authenticated;

-- The old admin functions worked without an admin session; remove them.
drop function if exists public.admin_update_player(uuid, bigint, boolean, boolean, boolean);
drop function if exists public.admin_give_all(bigint);
drop function if exists public.admin_delete_message(bigint);
drop function if exists public.admin_clear_chat();
drop function if exists public.admin_save_settings(jsonb);

create or replace function public.admin_unlock(pw text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  me uuid := auth.uid();
  stored text;
  fails integer;
  tok uuid;
begin
  if me is null or not public.is_admin() then return 'notadmin'; end if;
  select count(*) into fails from public.admin_attempts
    where player_id = me and not ok and at > now() - interval '15 minutes';
  if fails >= 5 then return 'locked'; end if;
  select hash into stored from public.admin_keys where player_id = me;
  if stored is null then return 'nokey'; end if;
  if crypt(pw, stored) <> stored then
    insert into public.admin_attempts (player_id, ok) values (me, false);
    return 'wrong';
  end if;
  insert into public.admin_attempts (player_id, ok) values (me, true);
  delete from public.admin_attempts where at < now() - interval '1 day';
  delete from public.admin_sessions where player_id = me or expires_at < now();
  insert into public.admin_sessions (player_id, expires_at)
    values (me, now() + interval '15 minutes') returning token into tok;
  return 'ok:' || tok;
end;
$$;

-- Every admin function starts with this: an admin, with a live session, which it extends.
create or replace function public.admin_check(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.admin_sessions set expires_at = now() + interval '15 minutes'
    where token = tok and player_id = auth.uid() and expires_at > now();
  if not found then raise exception 'admin session expired'; end if;
end;
$$;

create or replace function public.admin_lock(tok uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.admin_sessions where token = tok and player_id = auth.uid();
$$;

create or replace function public.admin_update_player(
  tok uuid,
  target uuid,
  new_credits bigint default null,
  reset boolean default false,
  set_banned boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform public.admin_check(tok);
  if new_credits is not null and new_credits < 0 then raise exception 'credits must be 0 or more'; end if;
  if set_banned and target = auth.uid() then raise exception 'cannot block yourself'; end if;
  update public.players set
    credits = case when reset then coalesce(new_credits, start_credits) else coalesce(new_credits, credits) end,
    best = case when reset then 0 else best end,
    level = case when reset then 1 else level end,
    spins = case when reset then 0 else spins end,
    jackpots = case when reset then 0 else jackpots end,
    game = case when reset then null else game end,
    is_banned = coalesce(set_banned, is_banned),
    admin_rev = admin_rev + case when reset or new_credits is not null then 1 else 0 end,
    updated_at = now()
  where id = target;
end;
$$;

create or replace function public.admin_set_admin(tok uuid, target uuid, make boolean, new_pw text default null)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.admin_check(tok);
  if make then
    if new_pw is null or length(new_pw) < 8 then raise exception 'admin password too short'; end if;
    update public.players set is_admin = true where id = target;
    insert into public.admin_keys (player_id, hash) values (target, crypt(new_pw, gen_salt('bf')))
      on conflict (player_id) do update set hash = excluded.hash, updated_at = now();
  else
    if target = auth.uid() then raise exception 'cannot remove yourself'; end if;
    update public.players set is_admin = false where id = target;
    delete from public.admin_keys where player_id = target;
    delete from public.admin_sessions where player_id = target;
  end if;
end;
$$;

create or replace function public.admin_change_password(tok uuid, new_pw text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.admin_check(tok);
  if new_pw is null or length(new_pw) < 8 then raise exception 'admin password too short'; end if;
  update public.admin_keys set hash = crypt(new_pw, gen_salt('bf')), updated_at = now() where player_id = auth.uid();
end;
$$;

create or replace function public.admin_give_all(tok uuid, amount bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  update public.players
    set credits = greatest(0, credits + amount), admin_rev = admin_rev + 1, updated_at = now()
    where not is_banned;
end;
$$;

create or replace function public.admin_delete_message(tok uuid, msg bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  delete from public.messages where id = msg;
end;
$$;

create or replace function public.admin_clear_chat(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  delete from public.messages where true;
end;
$$;

create or replace function public.admin_save_settings(tok uuid, patch jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  update public.settings set data = data || patch where id = 1;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_unlock(text)', 'admin_check(uuid)', 'admin_lock(uuid)',
    'admin_update_player(uuid, uuid, bigint, boolean, boolean)', 'admin_set_admin(uuid, uuid, boolean, text)',
    'admin_change_password(uuid, text)', 'admin_give_all(uuid, bigint)', 'admin_delete_message(uuid, bigint)',
    'admin_clear_chat(uuid)', 'admin_save_settings(uuid, jsonb)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- Set your admin password (at least 8 characters, different from your login
-- password). Put in your username and run this again any time to reset it.
insert into public.admin_keys (player_id, hash)
select id, extensions.crypt('NEUES-ADMIN-PASSWORT', extensions.gen_salt('bf'))
from public.players where name = 'DEIN_NAME' and is_admin
on conflict (player_id) do update set hash = excluded.hash, updated_at = now();

-- ---------------------------------------------------------------------------
-- Deleting players: run this part once (after "Admin security").
-- Deletes the login itself; the game row, chat messages, private messages and
-- any admin password go with it.

create or replace function public.admin_delete_player(tok uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if target = auth.uid() then raise exception 'cannot delete yourself'; end if;
  if exists (select 1 from public.players where id = target and is_admin) then
    raise exception 'remove admin rights first';
  end if;
  delete from auth.users where id = target;
end;
$$;

revoke execute on function public.admin_delete_player(uuid, uuid) from public, anon;
grant execute on function public.admin_delete_player(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Neon Name goodie: run this part once so other players can see it.

alter table public.players add column if not exists flair text check (flair is null or flair in ('neon'));
grant update (flair) on public.players to authenticated;

-- ---------------------------------------------------------------------------
-- Online poker: run this part once (after "Admin menu").
-- One Texas Hold'em table for up to 8 players. The database is the dealer: it
-- shuffles, deals, checks every move and pays the pots, so nobody can peek at
-- other hands or change the chips from the browser. The table and the seats
-- (with the cards) can't be read through the website at all; poker_state()
-- hands each player only their own cards. poker_pulse is a public counter the
-- page listens to, so everyone sees each move right away.

create table if not exists public.poker_tables (
  id integer primary key default 1 check (id = 1),
  phase text not null default 'waiting',
  hand integer not null default 0,
  button integer not null default -1,
  sb bigint not null default 10,
  bb bigint not null default 20,
  board integer[] not null default '{}',
  deck integer[] not null default '{}',
  current_bet bigint not null default 0,
  min_raise bigint not null default 20,
  to_act integer not null default -1,
  deadline timestamptz,
  result text
);
insert into public.poker_tables (id) values (1) on conflict do nothing;

create table if not exists public.poker_seats (
  seat integer primary key check (seat between 0 and 7),
  player_id uuid unique references public.players (id) on delete cascade,
  name text not null,
  stack bigint not null default 0,
  bet bigint not null default 0,
  committed bigint not null default 0,
  in_hand boolean not null default false,
  folded boolean not null default false,
  allin boolean not null default false,
  acted boolean not null default false,
  last text,
  won bigint not null default 0,
  hand_name text,
  cards integer[] not null default '{}',
  revealed boolean not null default false,
  misses integer not null default 0
);

create table if not exists public.poker_pulse (
  id integer primary key default 1 check (id = 1),
  rev bigint not null default 0,
  at timestamptz not null default now()
);
insert into public.poker_pulse (id) values (1) on conflict do nothing;

alter table public.poker_tables enable row level security;
alter table public.poker_seats enable row level security;
alter table public.poker_pulse enable row level security;
revoke all on public.poker_tables, public.poker_seats, public.poker_pulse from anon, authenticated;
grant select on public.poker_pulse to anon, authenticated;
drop policy if exists "Poker pulse is public" on public.poker_pulse;
create policy "Poker pulse is public" on public.poker_pulse for select using (true);
do $$
begin
  alter publication supabase_realtime add table public.poker_pulse;
exception when duplicate_object then null;
end $$;

-- Cards are 0-51: rank = card / 4 (0 = two ... 12 = ace), suit = card % 4.
-- A five-card hand as one number; bigger wins. Same scoring as the page's solo table.
create or replace function public.poker_score5(cs integer[])
returns bigint
language plpgsql
immutable
set search_path = public
as $$
declare
  r integer[];
  g integer[];
  cnt integer[];
  flush boolean;
  high integer := -1;
  cat integer;
  kick integer[];
  sc bigint;
begin
  select array_agg(c / 4 order by c / 4 desc) into r from unnest(cs) c;
  flush := (select count(distinct c % 4) from unnest(cs) c) = 1;
  if (select count(distinct x) from unnest(r) x) = 5 then
    if r[1] - r[5] = 4 then high := r[1];
    elsif r[1] = 12 and r[2] = 3 then high := 3;
    end if;
  end if;
  select array_agg(x order by n desc, x desc), array_agg(n order by n desc, x desc) into g, cnt
    from (select x, count(*)::integer n from unnest(r) x group by x) q;
  if high >= 0 and flush then cat := 8; kick := array[high];
  elsif cnt[1] = 4 then cat := 7; kick := g;
  elsif cnt[1] = 3 and cnt[2] = 2 then cat := 6; kick := g;
  elsif flush then cat := 5; kick := r;
  elsif high >= 0 then cat := 4; kick := array[high];
  elsif cnt[1] = 3 then cat := 3; kick := g;
  elsif cnt[1] = 2 and cnt[2] = 2 then cat := 2; kick := g;
  elsif cnt[1] = 2 then cat := 1; kick := g;
  else cat := 0; kick := r;
  end if;
  sc := cat;
  for i in 1..5 loop sc := sc * 13 + coalesce(kick[i], 0); end loop;
  return sc;
end;
$$;

-- The best five of up to seven cards.
create or replace function public.poker_best(cs integer[])
returns bigint
language plpgsql
immutable
set search_path = public
as $$
declare
  n integer := coalesce(array_length(cs, 1), 0);
  best bigint := -1;
  sc bigint;
begin
  for a in 1..n loop for b in a + 1..n loop for c in b + 1..n loop for d in c + 1..n loop for e in d + 1..n loop
    sc := public.poker_score5(array[cs[a], cs[b], cs[c], cs[d], cs[e]]);
    if sc > best then best := sc; end if;
  end loop; end loop; end loop; end loop; end loop;
  return best;
end;
$$;

create or replace function public.poker_hand_name(sc bigint)
returns text
language sql
immutable
as $$
  select case
    when sc / 371293 = 8 and (sc / 28561) % 13 = 12 then 'Royal flush'
    else (array['High card', 'Pair', 'Two pair', 'Three of a kind', 'Straight', 'Flush', 'Full house', 'Four of a kind', 'Straight flush'])[(sc / 371293)::integer + 1]
  end;
$$;

-- The next seat after "from" (clockwise, "from" itself last) that fits the test:
-- 'stack' has chips, 'hand' is dealt in, 'act' can still act, 'needs' still has to act this round.
create or replace function public._pk_next(from_seat integer, test text)
returns integer
language sql
stable
set search_path = public
as $$
  select s.seat from public.poker_seats s, public.poker_tables t
  where t.id = 1 and case test
    when 'stack' then s.stack > 0 and s.player_id is not null
    when 'hand' then s.in_hand
    when 'act' then s.in_hand and not s.folded and not s.allin
    else s.in_hand and not s.folded and not s.allin and (not s.acted or s.bet < t.current_bet)
  end
  order by (s.seat - from_seat - 1 + 16) % 8
  limit 1;
$$;

create or replace function public._pk_put(p_seat integer, amt bigint)
returns void
language sql
set search_path = public
as $$
  update public.poker_seats set
    stack = stack - greatest(0, least(amt, stack)),
    bet = bet + greatest(0, least(amt, stack)),
    committed = committed + greatest(0, least(amt, stack)),
    allin = allin or (in_hand and stack - greatest(0, least(amt, stack)) = 0)
  where seat = p_seat;
$$;

create or replace function public._pk_pulse()
returns void
language sql
set search_path = public
as $$
  update public.poker_pulse set rev = rev + 1, at = now() where id = 1;
$$;

create or replace function public._pk_finish(showdown boolean)
returns void
language plpgsql
set search_path = public
as $$
declare
  t public.poker_tables;
  pot bigint;
  lvl bigint;
  prev bigint := 0;
  part bigint;
  top bigint;
  nwin integer;
  share bigint;
  odd_seat integer;
  w record;
  paid bigint := 0;
  last_top bigint;
begin
  select * into t from public.poker_tables where id = 1;
  select coalesce(sum(committed), 0) into pot from public.poker_seats;
  if not showdown then
    update public.poker_seats set stack = stack + pot, won = pot
      where in_hand and not folded returning * into w;
    update public.poker_tables set result = w.name || ' wins ' || pot where id = 1;
  else
    update public.poker_seats set
      hand_name = public.poker_hand_name(public.poker_best(cards || t.board)),
      revealed = true
      where in_hand and not folded;
    for lvl in select distinct committed from public.poker_seats where in_hand and not folded order by 1 loop
      select coalesce(sum(least(committed, lvl) - least(committed, prev)), 0) into part from public.poker_seats;
      select max(public.poker_best(cards || t.board)) into top
        from public.poker_seats where in_hand and not folded and committed >= lvl;
      select count(*) into nwin from public.poker_seats
        where in_hand and not folded and committed >= lvl and public.poker_best(cards || t.board) = top;
      share := part / nwin;
      update public.poker_seats set stack = stack + share, won = won + share
        where in_hand and not folded and committed >= lvl and public.poker_best(cards || t.board) = top;
      if part - share * nwin > 0 then
        select seat into odd_seat from public.poker_seats
          where in_hand and not folded and committed >= lvl and public.poker_best(cards || t.board) = top
          order by (seat - t.button - 1 + 16) % 8 limit 1;
        update public.poker_seats set stack = stack + (part - share * nwin), won = won + (part - share * nwin) where seat = odd_seat;
      end if;
      paid := paid + part; prev := lvl; last_top := top;
    end loop;
    -- Chips above the highest contender (from players who folded after betting more) go to the last winner.
    if pot > paid then
      update public.poker_seats set stack = stack + (pot - paid), won = won + (pot - paid)
        where seat = (select seat from public.poker_seats where in_hand and not folded and public.poker_best(cards || t.board) = last_top
                      order by committed desc, (seat - t.button - 1 + 16) % 8 limit 1);
    end if;
    update public.poker_tables set result = (
      select case when count(*) > 1
        then 'Split pot: ' || string_agg(name, ' & ' order by won desc) || ' · ' || min(hand_name)
        else min(name) || ' wins ' || max(won) || ' with ' || lower(min(hand_name)) end
      from public.poker_seats where won > 0
    ) where id = 1;
  end if;
  update public.poker_tables set phase = 'showdown', to_act = -1,
    deadline = now() + case when showdown then interval '6 seconds' else interval '3.5 seconds' end
    where id = 1;
end;
$$;

-- Move the hand on after a move: next player, next street, or the showdown.
create or replace function public._pk_advance()
returns void
language plpgsql
set search_path = public
as $$
declare
  t public.poker_tables;
  alive integer;
  can_act integer;
  facing boolean;
  nxt integer;
  n integer;
begin
  select * into t from public.poker_tables where id = 1;
  select count(*) filter (where in_hand and not folded),
         count(*) filter (where in_hand and not folded and not allin),
         coalesce(bool_or(in_hand and not folded and not allin and bet < t.current_bet), false)
    into alive, can_act, facing from public.poker_seats;
  if alive <= 1 then perform public._pk_finish(false); return; end if;
  if can_act >= 2 or facing then
    nxt := public._pk_next(case when t.to_act >= 0 then t.to_act else t.button end, 'needs');
    if nxt is not null then
      update public.poker_tables set to_act = nxt, deadline = now() + interval '25 seconds' where id = 1;
      return;
    end if;
  end if;
  update public.poker_seats set bet = 0, acted = false,
    last = case when in_hand and not folded and not allin then null else last end
    where true;
  if t.phase = 'river' then
    update public.poker_tables set current_bet = 0, min_raise = bb where id = 1;
    perform public._pk_finish(true);
    return;
  end if;
  n := case when t.phase = 'preflop' then 3 else 1 end;
  update public.poker_tables set
    board = board || deck[1:n], deck = deck[n + 1:],
    phase = case phase when 'preflop' then 'flop' when 'flop' then 'turn' else 'river' end,
    current_bet = 0, min_raise = bb
    where id = 1;
  if can_act < 2 then
    update public.poker_tables set to_act = -1, deadline = now() + interval '1.3 seconds' where id = 1;
  else
    update public.poker_tables set to_act = public._pk_next(t.button, 'act'), deadline = now() + interval '25 seconds' where id = 1;
  end if;
end;
$$;

create or replace function public._pk_start()
returns void
language plpgsql
set search_path = public
as $$
declare
  t public.poker_tables;
  live integer;
  btn integer;
  sb_seat integer;
  bb_seat integer;
  v_deck integer[];
  i integer;
begin
  delete from public.poker_seats where player_id is null or stack <= 0;
  update public.poker_seats set in_hand = false, folded = false, allin = false, acted = false, bet = 0, committed = 0,
    cards = '{}', last = null, won = 0, hand_name = null, revealed = false
    where true;
  update public.poker_tables set board = '{}', result = null where id = 1;
  select count(*) into live from public.poker_seats where stack > 0;
  if live < 2 then
    update public.poker_tables set phase = 'waiting', to_act = -1, deadline = null where id = 1;
    return;
  end if;
  select * into t from public.poker_tables where id = 1;
  btn := public._pk_next(t.button, 'stack');
  update public.poker_seats set in_hand = true where stack > 0;
  select array_agg(g order by gen_random_uuid()) into v_deck from generate_series(0, 51) g;
  for r in 1..2 loop
    i := btn;
    for k in 1..live loop
      i := public._pk_next(i, 'hand');
      update public.poker_seats set cards = cards || v_deck[1] where seat = i;
      v_deck := v_deck[2:];
    end loop;
  end loop;
  update public.poker_tables set button = btn, deck = v_deck, phase = 'preflop', hand = hand + 1,
    current_bet = bb, min_raise = bb where id = 1;
  sb_seat := case when live = 2 then btn else public._pk_next(btn, 'hand') end;
  bb_seat := public._pk_next(sb_seat, 'hand');
  perform public._pk_put(sb_seat, t.sb);
  update public.poker_seats set last = 'Small blind' where seat = sb_seat;
  perform public._pk_put(bb_seat, t.bb);
  update public.poker_seats set last = 'Big blind' where seat = bb_seat;
  i := public._pk_next(bb_seat, 'act');
  if i is null then
    update public.poker_tables set to_act = -1 where id = 1;
    perform public._pk_advance();
  else
    update public.poker_tables set to_act = i, deadline = now() + interval '25 seconds' where id = 1;
  end if;
end;
$$;

-- One move by the player in p_seat. Returns an error text, or null when the move counted.
create or replace function public._pk_act(p_seat integer, act text, amount bigint)
returns text
language plpgsql
set search_path = public
as $$
declare
  t public.poker_tables;
  s public.poker_seats;
  need bigint;
  cap bigint;
  target bigint;
  was bigint;
begin
  select * into t from public.poker_tables where id = 1;
  select * into s from public.poker_seats where seat = p_seat;
  if s is null or t.to_act <> p_seat or t.phase not in ('preflop', 'flop', 'turn', 'river') then return 'Not your turn.'; end if;
  need := t.current_bet - s.bet;
  if act = 'fold' then
    update public.poker_seats set folded = true, last = 'Fold' where seat = p_seat;
  elsif act = 'check' then
    if need > 0 then return 'You cannot check.'; end if;
    update public.poker_seats set last = 'Check' where seat = p_seat;
  elsif act = 'call' then
    perform public._pk_put(p_seat, need);
    update public.poker_seats set last = case when allin then 'All-in' when need > 0 then 'Call' else 'Check' end where seat = p_seat;
  elsif act = 'raise' then
    cap := s.bet + s.stack;
    target := least(amount, cap);
    if target <= t.current_bet then return 'Raise more than the current bet.'; end if;
    if target - t.current_bet < t.min_raise and target < cap then
      return 'The smallest raise is to ' || (t.current_bet + t.min_raise) || '.';
    end if;
    was := t.current_bet;
    perform public._pk_put(p_seat, target - s.bet);
    if target - t.current_bet >= t.min_raise then
      update public.poker_tables set min_raise = target - t.current_bet where id = 1;
      update public.poker_seats set acted = false where seat <> p_seat and in_hand and not folded and not allin;
    end if;
    update public.poker_tables set current_bet = target where id = 1;
    update public.poker_seats set last = case when allin then 'All-in' when was > 0 then 'Raise ' || target else 'Bet ' || target end
      where seat = p_seat;
  else
    return 'Unknown move.';
  end if;
  update public.poker_seats set acted = true where seat = p_seat;
  perform public._pk_advance();
  return null;
end;
$$;

-- Leaving: chips not in the pot go back to the player's credits. A seat in a
-- running hand stays as an empty "left" seat until that hand ends.
create or replace function public._pk_cash_out(p_seat integer)
returns void
language plpgsql
set search_path = public
as $$
declare
  t public.poker_tables;
  s public.poker_seats;
begin
  select * into t from public.poker_tables where id = 1;
  select * into s from public.poker_seats where seat = p_seat;
  if s is null or s.player_id is null then return; end if;
  if s.in_hand and not s.folded and t.phase in ('preflop', 'flop', 'turn', 'river') then
    if t.to_act = p_seat then perform public._pk_act(p_seat, 'fold', 0);
    else update public.poker_seats set folded = true, last = 'Fold' where seat = p_seat;
    end if;
  end if;
  select * into s from public.poker_seats where seat = p_seat;
  update public.players set credits = credits + s.stack, admin_rev = admin_rev + 1 where id = s.player_id;
  if s.committed > 0 and t.phase <> 'waiting' then
    update public.poker_seats set player_id = null, stack = 0, last = 'Left' where seat = p_seat;
  else
    delete from public.poker_seats where seat = p_seat;
  end if;
  -- A fold out of turn can leave a single player in the hand.
  select * into t from public.poker_tables where id = 1;
  if t.phase in ('preflop', 'flop', 'turn', 'river')
     and (select count(*) from public.poker_seats where in_hand and not folded) <= 1 then
    perform public._pk_finish(false);
  end if;
end;
$$;

drop function if exists public.poker_sit(bigint);
-- seat_no picks a free seat (0-7); null takes the first free one.
create or replace function public.poker_sit(buy_in bigint, seat_no integer default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.players;
  t public.poker_tables;
  free integer;
begin
  select * into t from public.poker_tables where id = 1 for update;
  select * into me from public.players where id = auth.uid() for update;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if exists (select 1 from public.poker_seats where player_id = me.id) then raise exception 'already seated'; end if;
  if buy_in is null or buy_in < 200 then raise exception 'buy-in too small'; end if;
  if me.credits < buy_in then raise exception 'not enough credits'; end if;
  select g into free from generate_series(0, 7) g
    where g not in (select seat from public.poker_seats) order by g limit 1;
  if free is null then raise exception 'table full'; end if;
  if seat_no is not null then
    if seat_no not between 0 and 7 or exists (select 1 from public.poker_seats where seat = seat_no) then
      raise exception 'seat taken';
    end if;
    free := seat_no;
  end if;
  update public.players set credits = credits - buy_in, admin_rev = admin_rev + 1 where id = me.id;
  insert into public.poker_seats (seat, player_id, name, stack) values (free, me.id, me.name, buy_in);
  if t.phase = 'waiting' and (select count(*) from public.poker_seats where stack > 0) >= 2 then
    update public.poker_tables set deadline = now() + interval '1.5 seconds' where id = 1;
  end if;
  perform public._pk_pulse();
end;
$$;

create or replace function public.poker_leave()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_seat integer;
begin
  perform 1 from public.poker_tables where id = 1 for update;
  select seat into my_seat from public.poker_seats where player_id = auth.uid();
  if my_seat is null then return; end if;
  perform public._pk_cash_out(my_seat);
  perform public._pk_pulse();
end;
$$;

create or replace function public.poker_act(act text, amount bigint default 0)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_seat integer;
  err text;
begin
  perform 1 from public.poker_tables where id = 1 for update;
  select seat into my_seat from public.poker_seats where player_id = auth.uid();
  if my_seat is null then raise exception 'Not your turn.'; end if;
  err := public._pk_act(my_seat, act, amount);
  if err is not null then raise exception '%', err; end if;
  update public.poker_seats set misses = 0 where seat = my_seat;
  perform public._pk_pulse();
end;
$$;

-- Anyone at the table calls this when a deadline has passed: a player who ran
-- out of time checks (or folds); two missed turns in a row sit them out. It
-- also deals the next card during an all-in run-out and starts the next hand.
create or replace function public.poker_tick()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.poker_tables;
  s public.poker_seats;
begin
  select * into t from public.poker_tables where id = 1 for update;
  if t.phase = 'waiting' then
    if (select count(*) from public.poker_seats where stack > 0 and player_id is not null) < 2
       or (t.deadline is not null and t.deadline > now()) then return; end if;
    perform public._pk_start();
  elsif t.deadline is null or t.deadline > now() then
    return;
  elsif t.phase = 'showdown' then
    perform public._pk_start();
  elsif t.to_act < 0 then
    perform public._pk_advance();
  else
    select * into s from public.poker_seats where seat = t.to_act;
    update public.poker_seats set misses = misses + 1 where seat = t.to_act;
    if s.misses + 1 >= 2 then
      perform public._pk_cash_out(t.to_act);
    else
      perform public._pk_act(t.to_act, case when t.current_bet > s.bet then 'fold' else 'check' end, 0);
    end if;
  end if;
  perform public._pk_pulse();
end;
$$;

-- The table as one player sees it: their own cards, and other cards only once shown.
create or replace function public.poker_state()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'now', now(),
    'phase', t.phase, 'hand', t.hand, 'button', t.button, 'sb', t.sb, 'bb', t.bb,
    'board', t.board, 'current_bet', t.current_bet, 'min_raise', t.min_raise,
    'to_act', t.to_act, 'deadline', t.deadline, 'result', t.result,
    'me', coalesce((select seat from public.poker_seats where player_id = auth.uid() and auth.uid() is not null), -1),
    'seats', coalesce((select json_agg(json_build_object(
        'seat', s.seat, 'pid', s.player_id, 'name', s.name, 'stack', s.stack, 'bet', s.bet,
        'committed', s.committed, 'in_hand', s.in_hand, 'folded', s.folded, 'allin', s.allin,
        'acted', s.acted, 'last', s.last, 'leaving', s.player_id is null, 'won', s.won,
        'hand_name', s.hand_name, 'revealed', s.revealed,
        'has_cards', s.in_hand and not s.folded and cardinality(s.cards) = 2,
        'cards', case when s.revealed or (s.player_id = auth.uid() and auth.uid() is not null) then s.cards else '{}'::integer[] end
      ) order by s.seat) from public.poker_seats s), '[]'::json)
  ) from public.poker_tables t where t.id = 1;
$$;

revoke execute on function public.poker_score5(integer[]), public.poker_best(integer[]), public.poker_hand_name(bigint),
  public._pk_next(integer, text), public._pk_put(integer, bigint), public._pk_pulse(), public._pk_finish(boolean),
  public._pk_advance(), public._pk_start(), public._pk_act(integer, text, bigint), public._pk_cash_out(integer)
  from public, anon, authenticated;
revoke execute on function public.poker_sit(bigint, integer), public.poker_leave(), public.poker_act(text, bigint),
  public.poker_tick(), public.poker_state() from public, anon;
grant execute on function public.poker_sit(bigint, integer), public.poker_leave(), public.poker_act(text, bigint),
  public.poker_tick() to authenticated;
grant execute on function public.poker_state() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Profile pictures and medals: run this part once (after "Admin security").
-- Players pick their own picture; only an admin (with a live admin session)
-- can hand out medals.

alter table public.players add column if not exists avatar smallint check (avatar is null or avatar between 0 and 7);
alter table public.players add column if not exists medals text[] not null default '{}';
grant update (avatar) on public.players to authenticated;

create or replace function public.admin_set_medals(tok uuid, target uuid, new_medals text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if exists (select 1 from unnest(coalesce(new_medals, '{}')) m where m not in
      ('founder', 'highroller', 'lucky', 'pokerking', 'champion', 'legend', 'goodsport', 'bughunter', 'nightowl', 'comeback')) then
    raise exception 'unknown medal';
  end if;
  update public.players set medals = (select coalesce(array_agg(distinct m), '{}') from unnest(coalesce(new_medals, '{}')) m)
    where id = target;
  if not found then raise exception 'no such player'; end if;
end;
$$;

revoke execute on function public.admin_set_medals(uuid, uuid, text[]) from public, anon;
grant execute on function public.admin_set_medals(uuid, uuid, text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Hard reset: run this part once (after "Admin security" and "Neon Name").
-- Gives the admin menu its HARD RESET button: every account, admins
-- included, goes back to 500 credits and level 1, loses the Neon Name, and
-- the online poker table is cleared. Pictures and medals stay. Resetting a
-- single player removes their Neon Name too. Run it again if you ran an
-- older copy of this part.

create or replace function public.admin_hard_reset(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  update public.players set
    credits = 500, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null,
    admin_rev = admin_rev + 1, updated_at = now()
  where true;
  -- Chips at the poker table go too (only if the poker part has run).
  if to_regclass('public.poker_seats') is not null then
    execute 'delete from public.poker_seats where true';
    execute $q$update public.poker_tables set phase = 'waiting', board = '{}', deck = '{}', current_bet = 0,
      to_act = -1, deadline = null, result = null where id = 1$q$;
    execute 'update public.poker_pulse set rev = rev + 1, at = now() where id = 1';
  end if;
end;
$$;

revoke execute on function public.admin_hard_reset(uuid) from public, anon;
grant execute on function public.admin_hard_reset(uuid) to authenticated;

-- Resetting one player also takes away their Neon Name.
create or replace function public.admin_update_player(
  tok uuid,
  target uuid,
  new_credits bigint default null,
  reset boolean default false,
  set_banned boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform public.admin_check(tok);
  if new_credits is not null and new_credits < 0 then raise exception 'credits must be 0 or more'; end if;
  if set_banned and target = auth.uid() then raise exception 'cannot block yourself'; end if;
  update public.players set
    credits = case when reset then coalesce(new_credits, start_credits) else coalesce(new_credits, credits) end,
    best = case when reset then 0 else best end,
    level = case when reset then 1 else level end,
    spins = case when reset then 0 else spins end,
    jackpots = case when reset then 0 else jackpots end,
    game = case when reset then null else game end,
    flair = case when reset then null else flair end,
    is_banned = coalesce(set_banned, is_banned),
    admin_rev = admin_rev + case when reset or new_credits is not null then 1 else 0 end,
    updated_at = now()
  where id = target;
end;
$$;

-- Clean up after a hard reset that ran before this fix: nobody who has not
-- played since keeps the Neon Name.
update public.players set flair = null where flair is not null and game is null;

-- ---------------------------------------------------------------------------
-- Sending credits: run this part once (after "Admin security"). Players can
-- send each other credits from a profile. The database checks the sender's
-- balance and moves the credits in one step; accounts below level 3 that
-- never went Prestige can't send (so fresh accounts can't just pass their
-- start credits on). Run it again if you ran an older copy. Each gift
-- is kept so the recipient sees who sent it.

create table if not exists public.transfers (
  id bigint generated always as identity primary key,
  sender uuid references public.players (id) on delete set null,
  recipient uuid not null references public.players (id) on delete cascade,
  sender_name text not null,
  amount bigint not null check (amount > 0),
  created_at timestamptz not null default now()
);
alter table public.transfers enable row level security;
revoke all on public.transfers from anon, authenticated;
grant select on public.transfers to authenticated;
drop policy if exists "See your own transfers" on public.transfers;
create policy "See your own transfers" on public.transfers
  for select to authenticated using (auth.uid() = sender or auth.uid() = recipient);

create or replace function public.send_credits(target uuid, amount bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.players;
  them public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if target = auth.uid() then raise exception 'cannot send to yourself'; end if;
  if amount is null or amount < 1 then raise exception 'send at least 1'; end if;
  -- Lock both rows in a fixed order so two gifts at once can't deadlock.
  perform 1 from public.players where id in (auth.uid(), target) order by id for update;
  select * into me from public.players where id = auth.uid();
  select * into them from public.players where id = target;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if them is null or them.is_banned then raise exception 'no such player'; end if;
  -- Players who went Prestige may send at any level. (Read through jsonb so this works before the prestige column exists.)
  if me.level < 3 and coalesce((to_jsonb(me) ->> 'prestige')::integer, 0) = 0 then raise exception 'reach level 3 first'; end if;
  if me.credits < amount then raise exception 'not enough credits'; end if;
  update public.players set credits = credits - amount, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  update public.players set credits = credits + amount, admin_rev = admin_rev + 1, updated_at = now() where id = them.id;
  insert into public.transfers (sender, recipient, sender_name, amount) values (me.id, them.id, me.name, amount);
  return me.credits - amount;
end;
$$;

revoke execute on function public.send_credits(uuid, bigint) from public, anon;
grant execute on function public.send_credits(uuid, bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- Prestige: run this part once (after "Hard reset"). Level 20 is the top;
-- from there players can go Prestige (back to level 1 for a badge everyone
-- sees). This stores the prestige count, and the hard reset and a player
-- reset set it back to 0.

alter table public.players add column if not exists prestige smallint not null default 0 check (prestige between 0 and 99);
grant update (prestige) on public.players to authenticated;

create or replace function public.admin_hard_reset(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  update public.players set
    credits = 500, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null, prestige = 0,
    admin_rev = admin_rev + 1, updated_at = now()
  where true;
  -- Chips at the poker table go too (only if the poker part has run).
  if to_regclass('public.poker_seats') is not null then
    execute 'delete from public.poker_seats where true';
    execute $q$update public.poker_tables set phase = 'waiting', board = '{}', deck = '{}', current_bet = 0,
      to_act = -1, deadline = null, result = null where id = 1$q$;
    execute 'update public.poker_pulse set rev = rev + 1, at = now() where id = 1';
  end if;
end;
$$;

revoke execute on function public.admin_hard_reset(uuid) from public, anon;
grant execute on function public.admin_hard_reset(uuid) to authenticated;

-- Resetting one player also takes away their Neon Name and prestige.
create or replace function public.admin_update_player(
  tok uuid,
  target uuid,
  new_credits bigint default null,
  reset boolean default false,
  set_banned boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform public.admin_check(tok);
  if new_credits is not null and new_credits < 0 then raise exception 'credits must be 0 or more'; end if;
  if set_banned and target = auth.uid() then raise exception 'cannot block yourself'; end if;
  update public.players set
    credits = case when reset then coalesce(new_credits, start_credits) else coalesce(new_credits, credits) end,
    best = case when reset then 0 else best end,
    level = case when reset then 1 else level end,
    spins = case when reset then 0 else spins end,
    jackpots = case when reset then 0 else jackpots end,
    game = case when reset then null else game end,
    flair = case when reset then null else flair end,
    prestige = case when reset then 0 else prestige end,
    is_banned = coalesce(set_banned, is_banned),
    admin_rev = admin_rev + case when reset or new_credits is not null then 1 else 0 end,
    updated_at = now()
  where id = target;
end;
$$;


-- ---------------------------------------------------------------------------
-- Setting a player's level: run this part once (after "Admin security").
-- Gives the admin menu a level field per player (1 to 20).

create or replace function public.admin_set_level(tok uuid, target uuid, new_level integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if new_level is null or new_level < 1 or new_level > 20 then raise exception 'level must be 1 to 20'; end if;
  update public.players set level = new_level, admin_rev = admin_rev + 1, updated_at = now() where id = target;
  if not found then raise exception 'no such player'; end if;
end;
$$;

revoke execute on function public.admin_set_level(uuid, uuid, integer) from public, anon;
grant execute on function public.admin_set_level(uuid, uuid, integer) to authenticated;


-- ---------------------------------------------------------------------------
-- Shop: name styles and trophies: run this part once (after "Prestige").
-- Allows the new name styles (gold, fire, ice, galaxy) and adds the trophies
-- players show next to their name. A reset or hard reset clears both.

alter table public.players drop constraint if exists players_flair_check;
alter table public.players add constraint players_flair_check
  check (flair is null or flair in ('neon', 'gold', 'fire', 'ice', 'galaxy'));

alter table public.players add column if not exists trophies text[] not null default '{}'
  check (cardinality(trophies) <= 10);
grant update (trophies) on public.players to authenticated;

create or replace function public.players_clear_cosmetics()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.game is null and old.game is not null then
    new.flair := null;
    new.trophies := '{}';
  end if;
  return new;
end;
$$;

drop trigger if exists players_clear_cosmetics on public.players;
create trigger players_clear_cosmetics before update on public.players
  for each row execute function public.players_clear_cosmetics();

update public.players set trophies = '{}' where game is null and trophies <> '{}';


-- ---------------------------------------------------------------------------
-- Horse racing: run this part once (after "Shop: name styles and trophies").
-- Every 3 minutes one race for everyone: 2 minutes to bet, then the race.
-- The database sets the odds, takes the bets, draws the finishing order when
-- betting closes and pays the winners, so nobody can peek or cheat. The page
-- only shows the race. Keep the timing numbers in step with the page
-- (HR_PERIOD and HR_BET in index.html).

create table if not exists public.horse_races (
  id bigint primary key,                     -- race number: milliseconds since 1970 / 180000
  weights double precision[] not null,       -- strength of horses 1 to 6
  win_odds numeric[] not null,
  place_odds numeric[] not null,
  finish smallint[],                         -- horse numbers in finishing order, set when betting closes
  created_at timestamptz not null default now()
);
alter table public.horse_races enable row level security;
revoke all on public.horse_races from anon, authenticated;

create table if not exists public.horse_bets (
  id bigint generated always as identity primary key,
  race_id bigint not null,
  player uuid not null references public.players (id) on delete cascade,
  name text not null,
  horse smallint not null check (horse between 1 and 6),
  kind text not null check (kind in ('win', 'place')),
  amount bigint not null check (amount > 0),
  odds numeric not null,
  payout bigint,                             -- null until the race is decided
  claimed boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists horse_bets_race on public.horse_bets (race_id);
create index if not exists horse_bets_open on public.horse_bets (player) where not claimed;
alter table public.horse_bets enable row level security;
revoke all on public.horse_bets from anon, authenticated;
grant select on public.horse_bets to authenticated;
drop policy if exists "Everyone sees the bets" on public.horse_bets;
create policy "Everyone sees the bets" on public.horse_bets for select to authenticated using (true);

create or replace function public.horse_now_ms()
returns bigint language sql volatile as $$ select floor(extract(epoch from clock_timestamp()) * 1000)::bigint $$;

-- The field for a race: six random strengths, and odds that keep 92% for the players.
create or replace function public.horse_make(race bigint)
returns public.horse_races
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.horse_races;
  w double precision[] := '{}';
  tot double precision := 0;
  p double precision;
  q double precision;
  wo numeric[] := '{}';
  po numeric[] := '{}';
begin
  select * into r from public.horse_races where id = race;
  if found then return r; end if;
  for i in 1..6 loop
    w := w || exp((random() - 0.5) * 2.4);
    tot := tot + w[i];
  end loop;
  for i in 1..6 loop
    p := w[i] / tot;
    -- Chance to finish first or second.
    q := p;
    for j in 1..6 loop
      if j <> i then q := q + (w[j] / tot) * w[i] / (tot - w[j]); end if;
    end loop;
    wo := wo || greatest(1.1, floor(0.92 / p * 10) / 10)::numeric;
    po := po || greatest(1.05, floor(0.92 / q * 100) / 100)::numeric;
  end loop;
  insert into public.horse_races (id, weights, win_odds, place_odds) values (race, w, wo, po)
    on conflict (id) do nothing;
  -- Old races and bets go after about four days.
  delete from public.horse_bets where race_id < race - 2000 and claimed;
  delete from public.horse_races where id < race - 2000;
  select * into r from public.horse_races where id = race;
  return r;
end;
$$;

-- Draws the finishing order (stronger horses win more often) and settles the bets. Runs once per race.
create or replace function public.horse_settle(race bigint)
returns smallint[]
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.horse_races;
  left_ smallint[] := '{1,2,3,4,5,6}';
  fin smallint[] := '{}';
  tot double precision;
  x double precision;
  pick smallint;
begin
  perform public.horse_make(race);
  select * into r from public.horse_races where id = race for update;
  if r.finish is not null then return r.finish; end if;
  -- The admin's secret code can name the winner; the rest of the field is drawn as usual.
  if (to_jsonb(r) ->> 'forced') is not null then
    pick := (to_jsonb(r) ->> 'forced')::smallint;
    fin := array[pick];
    left_ := array_remove(left_, pick);
  end if;
  while cardinality(left_) > 0 loop
    tot := 0;
    foreach pick in array left_ loop tot := tot + r.weights[pick]; end loop;
    x := random() * tot;
    foreach pick in array left_ loop
      x := x - r.weights[pick];
      exit when x <= 0;
    end loop;
    fin := fin || pick;
    left_ := array_remove(left_, pick);
  end loop;
  update public.horse_races set finish = fin where id = race;
  update public.horse_bets set payout = case
      when (kind = 'win' and horse = fin[1]) or (kind = 'place' and horse in (fin[1], fin[2])) then floor(amount * odds)::bigint
      else 0 end
    where race_id = race and payout is null;
  return fin;
end;
$$;

-- What the page asks for: the field and odds, the server clock, and the finishing order once betting is closed.
create or replace function public.horse_race(race bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  cur bigint := now_ms / 180000;
  r public.horse_races;
  fin smallint[];
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  race := coalesce(race, cur);
  if race > cur or race < cur - 1000 then raise exception 'no such race'; end if;
  r := public.horse_make(race);
  if now_ms >= race * 180000 + 120000 then fin := public.horse_settle(race); end if;
  return jsonb_build_object('id', race, 'now', now_ms, 'weights', to_jsonb(r.weights), 'win', to_jsonb(r.win_odds),
    'place', to_jsonb(r.place_odds), 'finish', to_jsonb(fin));
end;
$$;

-- A bet on the race that is open right now. Takes the credits at once; returns the odds and the new balance.
create or replace function public.horse_bet(race bigint, horse_no integer, bet_kind text, amount bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  me public.players;
  r public.horse_races;
  o numeric;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if race <> now_ms / 180000 or now_ms >= race * 180000 + 120000 then raise exception 'betting closed'; end if;
  if horse_no is null or horse_no < 1 or horse_no > 6 or bet_kind not in ('win', 'place') then raise exception 'no such bet'; end if;
  if amount is null or amount < 1 then raise exception 'bet at least 1'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if me.credits < amount then raise exception 'not enough credits'; end if;
  if (select count(*) from public.horse_bets where race_id = race and player = me.id) >= 12 then raise exception 'too many bets'; end if;
  r := public.horse_make(race);
  o := case when bet_kind = 'win' then r.win_odds[horse_no] else r.place_odds[horse_no] end;
  update public.players set credits = credits - amount, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.horse_bets (race_id, player, name, horse, kind, amount, odds) values (race, me.id, me.name, horse_no, bet_kind, amount, o);
  return jsonb_build_object('odds', o, 'credits', me.credits - amount, 'rev', me.admin_rev + 1);
end;
$$;

-- Collects every finished bet of mine: winnings go onto my balance. Returns the bets and the new balance.
create or replace function public.horse_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  race bigint;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for race in select distinct race_id from public.horse_bets
      where player = auth.uid() and not claimed and race_id * 180000 + 120000 <= now_ms loop
    perform public.horse_settle(race);
  end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  with c as (
    update public.horse_bets set claimed = true
    where player = me.id and not claimed and payout is not null
    returning race_id, horse, kind, amount, odds, payout
  )
  select coalesce(sum(payout), 0), coalesce(jsonb_agg(to_jsonb(c)), '[]') into won, rows_ from c;
  if won > 0 then
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
    return jsonb_build_object('bets', rows_, 'credits', me.credits + won, 'rev', me.admin_rev + 1);
  end if;
  return jsonb_build_object('bets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

revoke execute on function public.horse_make(bigint) from public, anon, authenticated;
revoke execute on function public.horse_settle(bigint) from public, anon, authenticated;
revoke execute on function public.horse_race(bigint) from public, anon;
revoke execute on function public.horse_bet(bigint, integer, text, bigint) from public, anon;
revoke execute on function public.horse_claim() from public, anon;
grant execute on function public.horse_race(bigint) to authenticated;
grant execute on function public.horse_bet(bigint, integer, text, bigint) to authenticated;
grant execute on function public.horse_claim() to authenticated;

-- A reset or hard reset also drops a player's bets that were not collected yet.
create or replace function public.players_clear_cosmetics()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.game is null and old.game is not null then
    new.flair := null;
    new.trophies := '{}';
    delete from public.horse_bets where player = new.id and not claimed;
  end if;
  return new;
end;
$$;


-- ---------------------------------------------------------------------------
-- Global roulette: run this part once (after "Horse racing"). One wheel for
-- everyone: every 45 seconds there are 30 seconds to place chips, then the
-- ball is thrown and bets stay open 4 more seconds while it rolls. The database takes the bets, draws the number when betting
-- closes and pays the winners. Keep the timing in step with the page
-- (RL_PERIOD and RL_BET in index.html).
-- If you ran an older copy of this part, run it again: it keeps the bets and
-- only updates the timing.

create table if not exists public.roulette_rounds (
  id bigint primary key,                     -- round number: milliseconds since 1970 / 45000
  result smallint check (result between 0 and 36),
  created_at timestamptz not null default now()
);
alter table public.roulette_rounds enable row level security;
revoke all on public.roulette_rounds from anon, authenticated;

create table if not exists public.roulette_bets (
  id bigint generated always as identity primary key,
  round_id bigint not null,
  player uuid not null references public.players (id) on delete cascade,
  name text not null,
  bets jsonb not null,                       -- {"red": 100, "n17": 10, …}
  total bigint not null check (total > 0),
  mult numeric not null default 1,           -- the happy-hour win multiplier when the bet was placed
  payout bigint,                             -- null until the number is drawn
  claimed boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists roulette_bets_round on public.roulette_bets (round_id);
create index if not exists roulette_bets_open on public.roulette_bets (player) where not claimed;
alter table public.roulette_bets enable row level security;
revoke all on public.roulette_bets from anon, authenticated;
grant select on public.roulette_bets to authenticated;
drop policy if exists "Everyone sees the roulette bets" on public.roulette_bets;
create policy "Everyone sees the roulette bets" on public.roulette_bets for select to authenticated using (true);

create or replace function public.roulette_key_ok(k text)
returns boolean language sql immutable as $$
  select k ~ '^n([0-9]|[12][0-9]|3[0-6])$' or k in ('red', 'black', 'odd', 'even', 'low', 'high', 'd1', 'd2', 'd3', 'c1', 'c2', 'c3')
$$;
create or replace function public.roulette_hit(k text, n integer)
returns boolean language sql immutable as $$
  select case
    when k like 'n%' then substr(k, 2)::integer = n
    when k = 'red' then n in (1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36)
    when k = 'black' then n > 0 and n not in (1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36)
    when k = 'odd' then n > 0 and n % 2 = 1
    when k = 'even' then n > 0 and n % 2 = 0
    when k = 'low' then n between 1 and 18
    when k = 'high' then n between 19 and 36
    when k = 'd1' then n between 1 and 12
    when k = 'd2' then n between 13 and 24
    when k = 'd3' then n between 25 and 36
    when k = 'c1' then n > 0 and n % 3 = 1
    when k = 'c2' then n > 0 and n % 3 = 2
    when k = 'c3' then n > 0 and n % 3 = 0
    else false end
$$;
create or replace function public.roulette_pays(k text)
returns integer language sql immutable as $$
  select case when k like 'n%' then 35 when k ~ '^[dc][123]$' then 2 else 1 end
$$;

-- Draws the number once betting is closed and settles the round's bets.
create or replace function public.roulette_settle(round bigint)
returns smallint
language plpgsql
security definer
set search_path = public
as $$
declare
  res smallint;
begin
  insert into public.roulette_rounds (id) values (round) on conflict (id) do nothing;
  select result into res from public.roulette_rounds where id = round for update;
  if res is not null then return res; end if;
  -- The admin's secret code can force a zero.
  res := coalesce((select (to_jsonb(x) ->> 'forced')::smallint from public.roulette_rounds x where id = round), floor(random() * 37)::smallint);
  update public.roulette_rounds set result = res where id = round;
  update public.roulette_bets b set payout = (
      select coalesce(sum(case when public.roulette_hit(e.key, res)
        then floor(e.value::bigint * (1 + public.roulette_pays(e.key) * b.mult)) else 0 end), 0)::bigint
      from jsonb_each_text(b.bets) e)
    where round_id = round and payout is null;
  -- Old rounds and bets go after about four days.
  delete from public.roulette_bets where round_id < round - 6000 and claimed;
  delete from public.roulette_rounds where id < round - 6000;
  return res;
end;
$$;

-- What the page asks for: the server clock, the number once betting is closed, and the last numbers.
create or replace function public.roulette_round(round bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  cur bigint := now_ms / 45000;
  res smallint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  round := coalesce(round, cur);
  if round > cur or round < cur - 3000 then raise exception 'no such round'; end if;
  if now_ms >= round * 45000 + 34000 then res := public.roulette_settle(round); end if;
  return jsonb_build_object('id', round, 'now', now_ms, 'result', res,
    'recent', (select coalesce(jsonb_agg(result order by id desc), '[]') from (
      select id, result from public.roulette_rounds where result is not null and id < cur order by id desc limit 14) r));
end;
$$;

-- Places chips on the open round: {"red": 100, "n17": 10}. Takes the credits at once.
create or replace function public.roulette_bet(round bigint, chips jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  me public.players;
  e record;
  tot bigint := 0;
  m numeric;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if round <> now_ms / 45000 or now_ms >= round * 45000 + 34000 then raise exception 'betting closed'; end if;
  if jsonb_typeof(chips) <> 'object' then raise exception 'no such bet'; end if;
  for e in select * from jsonb_each(chips) loop
    if not public.roulette_key_ok(e.key) or jsonb_typeof(e.value) <> 'number' or (e.value)::text !~ '^[1-9][0-9]{0,17}$' then raise exception 'no such bet'; end if;
    tot := tot + (e.value)::text::bigint;
  end loop;
  if tot < 1 then raise exception 'bet at least 1'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if coalesce((select (data ->> 'maintenance')::boolean from public.settings where id = 1), false) and not me.is_admin then raise exception 'paused'; end if;
  if me.credits < tot then raise exception 'not enough credits'; end if;
  if (select count(*) from public.roulette_bets where round_id = round and player = me.id) >= 20 then raise exception 'too many bets'; end if;
  m := least(100, greatest(0.1, coalesce((select (data ->> 'winMultiplier')::numeric from public.settings where id = 1), 1)));
  update public.players set credits = credits - tot, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.roulette_bets (round_id, player, name, bets, total, mult) values (round, me.id, me.name, chips, tot, m);
  return jsonb_build_object('credits', me.credits - tot, 'rev', me.admin_rev + 1);
end;
$$;

-- Collects every finished roulette bet of mine onto my balance.
create or replace function public.roulette_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  round bigint;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for round in select distinct round_id from public.roulette_bets
      where player = auth.uid() and not claimed and round_id * 45000 + 34000 <= now_ms loop
    perform public.roulette_settle(round);
  end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  with c as (
    update public.roulette_bets b set claimed = true
    where player = me.id and not claimed and payout is not null
    returning round_id, bets, total, payout
  )
  select coalesce(sum(c.payout), 0), coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('result', r.result)), '[]') into won, rows_
    from c join public.roulette_rounds r on r.id = c.round_id;
  if won > 0 then
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
    return jsonb_build_object('bets', rows_, 'credits', me.credits + won, 'rev', me.admin_rev + 1);
  end if;
  return jsonb_build_object('bets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

revoke execute on function public.roulette_settle(bigint) from public, anon, authenticated;
revoke execute on function public.roulette_round(bigint) from public, anon;
revoke execute on function public.roulette_bet(bigint, jsonb) from public, anon;
revoke execute on function public.roulette_claim() from public, anon;
grant execute on function public.roulette_round(bigint) to authenticated;
grant execute on function public.roulette_bet(bigint, jsonb) to authenticated;
grant execute on function public.roulette_claim() to authenticated;

-- A reset or hard reset also drops a player's bets that were not collected yet.
create or replace function public.players_clear_cosmetics()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.game is null and old.game is not null then
    new.flair := null;
    new.trophies := '{}';
    delete from public.horse_bets where player = new.id and not claimed;
    delete from public.roulette_bets where player = new.id and not claimed;
  end if;
  return new;
end;
$$;


-- ---------------------------------------------------------------------------
-- Rocket: run this part once (after "Global roulette"). One rocket for
-- everyone: 25 seconds to bet, then it lifts off and the multiplier climbs
-- (2× after about 5 s, 10× after about 17 s, 200× after 40 s). Cash out
-- before it explodes; at 200× it lands on the moon and pays everyone still
-- on board. The database picks the explosion point when the round starts,
-- keeps it secret until it happens and checks every cash-out against its
-- own clock. One rocket in 300 is golden (shown at liftoff) and flies past
-- 30× for sure; the ordinary ones explode a little earlier to pay for it, so
-- over the long run about 96% of bets come back even when every golden
-- rocket is held to 30×.
-- If you ran an older copy of this part, run it again: it keeps the bets and
-- only updates the timing.

create table if not exists public.rocket_rounds (
  id bigint primary key,
  bet_start bigint not null,                 -- milliseconds since 1970
  launch bigint not null,
  crash numeric not null,                    -- kept secret until crash_at
  crash_at bigint not null,
  next_start bigint not null,
  settled boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.rocket_rounds add column if not exists golden boolean not null default false;
alter table public.rocket_rounds enable row level security;
revoke all on public.rocket_rounds from anon, authenticated;

create table if not exists public.rocket_bets (
  id bigint generated always as identity primary key,
  round_id bigint not null,
  player uuid not null references public.players (id) on delete cascade,
  name text not null,
  amount bigint not null check (amount > 0),
  auto numeric check (auto is null or auto between 1.01 and 200),
  cashed numeric,                            -- the multiplier this bet was cashed out at
  payout bigint,                             -- null while the rocket is still flying
  claimed boolean not null default false,
  created_at timestamptz not null default now(),
  unique (round_id, player)
);
create index if not exists rocket_bets_open on public.rocket_bets (player) where not claimed;
alter table public.rocket_bets enable row level security;
revoke all on public.rocket_bets from anon, authenticated;
grant select on public.rocket_bets to authenticated;
drop policy if exists "Everyone sees the rocket bets" on public.rocket_bets;
create policy "Everyone sees the rocket bets" on public.rocket_bets for select to authenticated using (true);

-- The multiplier after a number of milliseconds in the air.
create or replace function public.rocket_mult(elapsed bigint)
returns numeric language sql immutable as $$
  select least(200, floor(power(200::numeric, greatest(0, elapsed) / 40000.0) * 100) / 100)
$$;

-- The round that is on now; starts the next one when the last is over.
create or replace function public.rocket_current()
returns public.rocket_rounds
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  r public.rocket_rounds;
  bs bigint;
  c numeric;
  ca bigint;
  gold boolean := random() < 1.0 / 300;
begin
  select * into r from public.rocket_rounds order by id desc limit 1;
  if r.id is not null and now_ms < r.next_start then return r; end if;
  bs := case when r.id is null or now_ms - r.next_start > 10000 then now_ms else r.next_start end;
  -- Golden: P(reaching m) = 30 / m from 30× up. Ordinary: P(reaching m) = 0.87 / m (13% blow up on the pad). Moon at 200.
  c := case when gold then least(200, floor(30 / (1 - random()) * 100) / 100)
       else least(200, greatest(1, floor(0.87 / (1 - random()) * 100) / 100)) end;
  ca := bs + 25000 + round(40000 * ln(c) / ln(200));
  insert into public.rocket_rounds (id, bet_start, launch, crash, crash_at, next_start, golden)
    values (coalesce(r.id, 0) + 1, bs, bs + 25000, c, ca, ca + case when c >= 200 then 9000 else 5000 end, gold)
    on conflict (id) do nothing;
  delete from public.rocket_bets where round_id < coalesce(r.id, 0) - 5000 and claimed;
  delete from public.rocket_rounds where id < coalesce(r.id, 0) - 5000;
  select * into r from public.rocket_rounds order by id desc limit 1;
  return r;
end;
$$;

-- Once the rocket is gone (or on the moon): auto cash-outs below the explosion win, moon riders get 200×.
create or replace function public.rocket_settle(round bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.rocket_rounds;
begin
  select * into r from public.rocket_rounds where id = round for update;
  if r.id is null or r.settled or public.horse_now_ms() < r.crash_at then return; end if;
  update public.rocket_bets set
      cashed = case when auto is not null and auto < r.crash then auto when r.crash >= 200 then 200 else null end,
      payout = case when auto is not null and auto < r.crash then floor(amount * auto)::bigint when r.crash >= 200 then amount * 200 else 0 end
    where round_id = round and payout is null;
  update public.rocket_rounds set settled = true where id = round;
end;
$$;

create or replace function public.rocket_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  r public.rocket_rounds;
  done boolean;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  r := public.rocket_current();
  perform public.rocket_settle(r.id - 1);
  done := now_ms >= r.crash_at;
  if done then perform public.rocket_settle(r.id); end if;
  return jsonb_build_object('id', r.id, 'now', now_ms, 'bet_start', r.bet_start, 'launch', r.launch,
    'golden', now_ms >= r.launch and r.golden,
    'crash', case when done then r.crash end, 'crash_at', case when done then r.crash_at end, 'next_start', case when done then r.next_start end,
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('c', crash, 'g', golden) order by id desc), '[]') from (
      select id, crash, golden from public.rocket_rounds where crash_at <= now_ms and id < r.id order by id desc limit 14) x));
end;
$$;

-- A bet on the round that is taking bets now, with an optional automatic cash-out.
create or replace function public.rocket_bet(round bigint, amount bigint, auto_at numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  r public.rocket_rounds := public.rocket_current();
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if round <> r.id or now_ms < r.bet_start or now_ms >= r.launch then raise exception 'betting closed'; end if;
  if amount is null or amount < 1 then raise exception 'bet at least 1'; end if;
  if auto_at is not null and (auto_at < 1.01 or auto_at > 200) then raise exception 'auto cash-out must be 1.01 to 200'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if coalesce((select (data ->> 'maintenance')::boolean from public.settings where id = 1), false) and not me.is_admin then raise exception 'paused'; end if;
  if me.credits < amount then raise exception 'not enough credits'; end if;
  if exists (select 1 from public.rocket_bets where round_id = round and player = me.id) then raise exception 'already on board'; end if;
  update public.players set credits = credits - amount, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.rocket_bets (round_id, player, name, amount, auto) values (round, me.id, me.name, amount, auto_at);
  return jsonb_build_object('credits', me.credits - amount, 'rev', me.admin_rev + 1);
end;
$$;

-- Cash out now, at the multiplier on the database's clock (or the automatic one if that came first).
create or replace function public.rocket_cashout(round bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  r public.rocket_rounds;
  b public.rocket_bets;
  m numeric;
  pay bigint;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select * into r from public.rocket_rounds where id = round;
  if r.id is null or now_ms < r.launch then raise exception 'not flying'; end if;
  m := public.rocket_mult(now_ms - r.launch);
  if now_ms >= r.crash_at or m >= r.crash then
    perform public.rocket_settle(round);
    raise exception 'crashed';
  end if;
  select * into b from public.rocket_bets where round_id = round and player = auth.uid() and payout is null for update;
  if b.id is null then raise exception 'no bet'; end if;
  if b.auto is not null and b.auto < m then m := b.auto; end if;
  pay := floor(b.amount * m)::bigint;
  update public.rocket_bets set cashed = m, payout = pay, claimed = true where id = b.id;
  select * into me from public.players where id = auth.uid() for update;
  update public.players set credits = credits + pay, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  return jsonb_build_object('mult', m, 'payout', pay, 'credits', me.credits + pay, 'rev', me.admin_rev + 1);
end;
$$;

-- Collects finished rounds of mine (automatic cash-outs and moon landings) onto my balance.
create or replace function public.rocket_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  round bigint;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for round in select b.round_id from public.rocket_bets b join public.rocket_rounds r on r.id = b.round_id
      where b.player = auth.uid() and not b.claimed and r.crash_at <= now_ms loop
    perform public.rocket_settle(round);
  end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  with c as (
    update public.rocket_bets set claimed = true
    where player = me.id and not claimed and payout is not null
    returning round_id, amount, auto, cashed, payout
  )
  select coalesce(sum(c.payout), 0), coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('crash', r.crash)), '[]') into won, rows_
    from c join public.rocket_rounds r on r.id = c.round_id;
  if won > 0 then
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
    return jsonb_build_object('bets', rows_, 'credits', me.credits + won, 'rev', me.admin_rev + 1);
  end if;
  return jsonb_build_object('bets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

revoke execute on function public.rocket_current() from public, anon, authenticated;
revoke execute on function public.rocket_settle(bigint) from public, anon, authenticated;
revoke execute on function public.rocket_state() from public, anon;
revoke execute on function public.rocket_bet(bigint, bigint, numeric) from public, anon;
revoke execute on function public.rocket_cashout(bigint) from public, anon;
revoke execute on function public.rocket_claim() from public, anon;
grant execute on function public.rocket_state() to authenticated;
grant execute on function public.rocket_bet(bigint, bigint, numeric) to authenticated;
grant execute on function public.rocket_cashout(bigint) to authenticated;
grant execute on function public.rocket_claim() to authenticated;

-- A reset or hard reset also drops a player's bets that were not collected yet.
create or replace function public.players_clear_cosmetics()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.game is null and old.game is not null then
    new.flair := null;
    new.trophies := '{}';
    delete from public.horse_bets where player = new.id and not claimed;
    delete from public.roulette_bets where player = new.id and not claimed;
    delete from public.rocket_bets where player = new.id and not claimed;
  end if;
  return new;
end;
$$;


-- ---------------------------------------------------------------------------
-- Affiliate codes: run this part once (after "Sending credits"). Every player
-- can pick one code of their own (3 to 12 letters or digits). Someone who
-- creates an account with that code starts with 5,000 credits instead of 500,
-- and the code's owner gets 5% of their current credits on top. Each new
-- account can use one code, only in its first 30 minutes and not its own.
-- The bonus is only for the first account on a device: every page has a
-- device key, and a code is refused on a device another account has used.
-- Run this part again if you ran an older copy.

alter table public.players add column if not exists affiliate_code text unique
  check (affiliate_code ~ '^[A-Z0-9]{3,12}$');

create table if not exists public.affiliate_uses (
  id bigint generated always as identity primary key,
  new_player uuid not null unique references public.players (id) on delete cascade,
  new_name text not null,
  affiliate uuid references public.players (id) on delete set null,
  code text not null,
  bonus bigint not null,
  created_at timestamptz not null default now()
);
alter table public.affiliate_uses add column if not exists device text;
create unique index if not exists affiliate_uses_device on public.affiliate_uses (device) where device is not null;
alter table public.affiliate_uses enable row level security;
revoke all on public.affiliate_uses from anon, authenticated;
grant select on public.affiliate_uses to authenticated;
drop policy if exists "See your own affiliate uses" on public.affiliate_uses;
create policy "See your own affiliate uses" on public.affiliate_uses
  for select to authenticated using (auth.uid() = affiliate or auth.uid() = new_player);

-- Which devices each account has been used on (only for the affiliate check).
create table if not exists public.player_devices (
  device text not null check (length(device) between 8 and 64),
  player uuid not null references public.players (id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (device, player)
);
alter table public.player_devices enable row level security;
revoke all on public.player_devices from anon, authenticated;

create or replace function public.note_device(dev text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or dev is null or length(dev) not between 8 and 64 then return; end if;
  insert into public.player_devices (device, player) values (dev, auth.uid())
    on conflict (device, player) do update set seen_at = now();
end;
$$;

-- Is there a player with this code? (Asked on the sign-up screen, before the account exists.)
create or replace function public.affiliate_check(code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.players where affiliate_code = upper(trim(code)) and not is_banned)
$$;

-- Pick or change my own code.
create or replace function public.set_affiliate_code(code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c text := upper(trim(code));
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if c !~ '^[A-Z0-9]{3,12}$' then raise exception 'code must be 3 to 12 letters or digits'; end if;
  if exists (select 1 from public.players where affiliate_code = c and id <> auth.uid()) then raise exception 'code taken'; end if;
  update public.players set affiliate_code = c where id = auth.uid();
  return c;
exception when unique_violation then
  raise exception 'code taken';
end;
$$;

-- Use a code right after creating an account: 4,500 extra for me, 5% of their credits for the code's owner.
drop function if exists public.affiliate_redeem(text);
create or replace function public.affiliate_redeem(code text, dev text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c text := upper(trim(code));
  me public.players;
  aff public.players;
  bonus bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if exists (select 1 from public.affiliate_uses where new_player = auth.uid()) then raise exception 'code already used'; end if;
  if (select created_at from auth.users where id = auth.uid()) < now() - interval '30 minutes' then raise exception 'only for new accounts'; end if;
  if dev is null or length(dev) not between 8 and 64 then raise exception 'reload the page'; end if;
  if exists (select 1 from public.player_devices d where d.device = dev and d.player <> auth.uid())
     or exists (select 1 from public.affiliate_uses u where u.device = dev) then raise exception 'device already has an account'; end if;
  select * into aff from public.players where affiliate_code = c for update;
  if aff.id is null or aff.is_banned then raise exception 'no such code'; end if;
  if aff.id = auth.uid() then raise exception 'not your own code'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  bonus := floor(aff.credits * 0.05)::bigint;
  update public.players set credits = credits + bonus, admin_rev = admin_rev + 1, updated_at = now() where id = aff.id;
  update public.players set credits = credits + 4500, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.affiliate_uses (new_player, new_name, affiliate, code, bonus, device) values (me.id, me.name, aff.id, c, bonus, dev);
  insert into public.player_devices (device, player) values (dev, me.id) on conflict do nothing;
  return jsonb_build_object('credits', me.credits + 4500, 'rev', me.admin_rev + 1, 'affiliate', aff.name);
end;
$$;

revoke execute on function public.affiliate_check(text) from public;
revoke execute on function public.set_affiliate_code(text) from public, anon;
revoke execute on function public.affiliate_redeem(text, text) from public, anon;
revoke execute on function public.note_device(text) from public, anon;
grant execute on function public.note_device(text) to authenticated;
grant execute on function public.affiliate_check(text) to anon, authenticated;
grant execute on function public.set_affiliate_code(text) to authenticated;
grant execute on function public.affiliate_redeem(text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Admin: affiliate overview: run this part once (after "Affiliate codes" and
-- "Admin security"). Lets the admin menu list every affiliate code with the
-- players who joined through it and the credits its owner earned.

create or replace function public.admin_affiliates(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  out jsonb;
begin
  perform public.admin_check(tok);
  select coalesce(jsonb_agg(x order by x.uses desc, x.earned desc, x.name), '[]') into out from (
    select p.id, p.name, p.affiliate_code as code, count(u.id) as uses, coalesce(sum(u.bonus), 0) as earned, max(u.created_at) as last,
      coalesce(jsonb_agg(jsonb_build_object('name', u.new_name, 'bonus', u.bonus, 'at', u.created_at) order by u.created_at desc)
        filter (where u.id is not null), '[]') as refs
    from public.players p left join public.affiliate_uses u on u.affiliate = p.id
    where p.affiliate_code is not null or u.id is not null
    group by p.id
  ) x;
  return out;
end;
$$;

revoke execute on function public.admin_affiliates(uuid) from public, anon;
grant execute on function public.admin_affiliates(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Admin secret code for the live games: run this part once (after "Rocket").
-- With the secret code typed in, an admin's next bet is rigged: the horse
-- they bet on wins, the roulette ball lands on zero, or the rocket they board
-- flies to the moon. It works for everyone at that table, so use it sparingly.

alter table public.horse_races add column if not exists forced smallint check (forced between 1 and 6);
alter table public.roulette_rounds add column if not exists forced smallint check (forced between 0 and 36);

create or replace function public.horse_settle(race bigint)
returns smallint[]
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.horse_races;
  left_ smallint[] := '{1,2,3,4,5,6}';
  fin smallint[] := '{}';
  tot double precision;
  x double precision;
  pick smallint;
begin
  perform public.horse_make(race);
  select * into r from public.horse_races where id = race for update;
  if r.finish is not null then return r.finish; end if;
  -- The admin's secret code can name the winner; the rest of the field is drawn as usual.
  if (to_jsonb(r) ->> 'forced') is not null then
    pick := (to_jsonb(r) ->> 'forced')::smallint;
    fin := array[pick];
    left_ := array_remove(left_, pick);
  end if;
  while cardinality(left_) > 0 loop
    tot := 0;
    foreach pick in array left_ loop tot := tot + r.weights[pick]; end loop;
    x := random() * tot;
    foreach pick in array left_ loop
      x := x - r.weights[pick];
      exit when x <= 0;
    end loop;
    fin := fin || pick;
    left_ := array_remove(left_, pick);
  end loop;
  update public.horse_races set finish = fin where id = race;
  update public.horse_bets set payout = case
      when (kind = 'win' and horse = fin[1]) or (kind = 'place' and horse in (fin[1], fin[2])) then floor(amount * odds)::bigint
      else 0 end
    where race_id = race and payout is null;
  return fin;
end;
$$;

create or replace function public.roulette_settle(round bigint)
returns smallint
language plpgsql
security definer
set search_path = public
as $$
declare
  res smallint;
begin
  insert into public.roulette_rounds (id) values (round) on conflict (id) do nothing;
  select result into res from public.roulette_rounds where id = round for update;
  if res is not null then return res; end if;
  -- The admin's secret code can force a zero.
  res := coalesce((select (to_jsonb(x) ->> 'forced')::smallint from public.roulette_rounds x where id = round), floor(random() * 37)::smallint);
  update public.roulette_rounds set result = res where id = round;
  update public.roulette_bets b set payout = (
      select coalesce(sum(case when public.roulette_hit(e.key, res)
        then floor(e.value::bigint * (1 + public.roulette_pays(e.key) * b.mult)) else 0 end), 0)::bigint
      from jsonb_each_text(b.bets) e)
    where round_id = round and payout is null;
  -- Old rounds and bets go after about four days.
  delete from public.roulette_bets where round_id < round - 6000 and claimed;
  delete from public.roulette_rounds where id < round - 6000;
  return res;
end;
$$;

create or replace function public.admin_me()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin and not is_banned from public.players where id = auth.uid()), false)
$$;

create or replace function public.admin_rig_horse(race bigint, horse_no integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_me() then raise exception 'not allowed'; end if;
  if horse_no is null or horse_no < 1 or horse_no > 6 then raise exception 'no such horse'; end if;
  if public.horse_now_ms() >= race * 180000 + 120000 then raise exception 'betting closed'; end if;
  perform public.horse_make(race);
  update public.horse_races set forced = horse_no where id = race and finish is null;
end;
$$;

create or replace function public.admin_rig_roulette(round bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_me() then raise exception 'not allowed'; end if;
  if public.horse_now_ms() >= round * 45000 + 34000 then raise exception 'betting closed'; end if;
  insert into public.roulette_rounds (id, forced) values (round, 0)
    on conflict (id) do update set forced = 0 where public.roulette_rounds.result is null;
end;
$$;

create or replace function public.admin_rig_rocket(round bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_me() then raise exception 'not allowed'; end if;
  update public.rocket_rounds set crash = 200, crash_at = launch + 40000, next_start = launch + 49000
    where id = round and public.horse_now_ms() < launch;
end;
$$;

revoke execute on function public.admin_me() from public, anon, authenticated;
revoke execute on function public.admin_rig_horse(bigint, integer) from public, anon;
revoke execute on function public.admin_rig_roulette(bigint) from public, anon;
revoke execute on function public.admin_rig_rocket(bigint) from public, anon;
grant execute on function public.admin_rig_horse(bigint, integer) to authenticated;
grant execute on function public.admin_rig_roulette(bigint) to authenticated;
grant execute on function public.admin_rig_rocket(bigint) to authenticated;


-- ---------------------------------------------------------------------------
-- Support tickets: run this part once (after "Admin security"). Every player
-- can send requests (bugs, wishes, questions) from the Support link; they show
-- up in the admin menu, where an admin can set a status and write a reply the
-- player sees.

create table if not exists public.support_tickets (
  id bigint generated always as identity primary key,
  player uuid references public.players (id) on delete set null,
  name text not null,
  category text not null check (category in ('bug', 'wish', 'question', 'other')),
  subject text not null check (length(subject) between 3 and 80),
  body text not null check (length(body) between 5 and 2000),
  status text not null default 'open' check (status in ('open', 'doing', 'done', 'declined')),
  reply text check (reply is null or length(reply) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_tickets_player on public.support_tickets (player);
alter table public.support_tickets enable row level security;
revoke all on public.support_tickets from anon, authenticated;
grant select on public.support_tickets to authenticated;
drop policy if exists "See your own tickets" on public.support_tickets;
create policy "See your own tickets" on public.support_tickets for select to authenticated using (auth.uid() = player);

create or replace function public.submit_ticket(category text, subject text, body text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.players;
  new_id bigint;
begin
  select * into me from public.players where id = auth.uid();
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  if (select count(*) from public.support_tickets where player = me.id and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too many tickets';
  end if;
  insert into public.support_tickets (player, name, category, subject, body)
    values (me.id, me.name, category, trim(subject), trim(body)) returning id into new_id;
  return new_id;
end;
$$;

-- Number of open tickets, for the badge on the Admin link (0 for everyone else).
create or replace function public.open_ticket_count()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case when coalesce((select is_admin from public.players where id = auth.uid()), false)
    then (select count(*)::integer from public.support_tickets where status in ('open', 'doing')) else 0 end
$$;

create or replace function public.admin_tickets(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  return (select coalesce(jsonb_agg(to_jsonb(t) order by (t.status in ('open', 'doing')) desc, t.created_at desc), '[]')
    from (select * from public.support_tickets order by created_at desc limit 300) t);
end;
$$;

create or replace function public.admin_ticket_update(tok uuid, ticket bigint, new_status text, new_reply text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  update public.support_tickets set
    status = coalesce(new_status, status),
    reply = case when new_reply is null then reply else nullif(trim(new_reply), '') end,
    updated_at = now()
  where id = ticket;
  if not found then raise exception 'no such ticket'; end if;
end;
$$;

create or replace function public.admin_ticket_delete(tok uuid, ticket bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  delete from public.support_tickets where id = ticket;
end;
$$;

revoke execute on function public.submit_ticket(text, text, text) from public, anon;
revoke execute on function public.open_ticket_count() from public, anon;
revoke execute on function public.admin_tickets(uuid) from public, anon;
revoke execute on function public.admin_ticket_update(uuid, bigint, text, text) from public, anon;
revoke execute on function public.admin_ticket_delete(uuid, bigint) from public, anon;
grant execute on function public.submit_ticket(text, text, text) to authenticated;
grant execute on function public.open_ticket_count() to authenticated;
grant execute on function public.admin_tickets(uuid) to authenticated;
grant execute on function public.admin_ticket_update(uuid, bigint, text, text) to authenticated;
grant execute on function public.admin_ticket_delete(uuid, bigint) to authenticated;
