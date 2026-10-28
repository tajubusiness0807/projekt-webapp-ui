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
