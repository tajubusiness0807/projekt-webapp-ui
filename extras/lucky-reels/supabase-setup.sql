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
-- ball is thrown; for 4 more seconds, while it rolls, players can only move
-- or swap the stacks they placed. The database takes the bets, draws the number when betting
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
  if round <> now_ms / 45000 or now_ms >= round * 45000 + 30000 then raise exception 'betting closed'; end if;
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

-- While the ball rolls: move my chips from one field to another, or swap two fields (no new credits go in).
create or replace function public.roulette_move(round bigint, from_key text, to_key text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if round <> now_ms / 45000 or now_ms >= round * 45000 + 34000 then raise exception 'betting closed'; end if;
  if not public.roulette_key_ok(from_key) or not public.roulette_key_ok(to_key) or from_key = to_key then raise exception 'no such bet'; end if;
  update public.roulette_bets set bets = (bets - from_key - to_key)
      || case when bets ? from_key then jsonb_build_object(to_key, bets -> from_key) else '{}'::jsonb end
      || case when bets ? to_key then jsonb_build_object(from_key, bets -> to_key) else '{}'::jsonb end
    where round_id = round and player = auth.uid() and payout is null and (bets ? from_key or bets ? to_key);
  if not found then raise exception 'no chips there'; end if;
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
revoke execute on function public.roulette_move(bigint, text, text) from public, anon;
grant execute on function public.roulette_move(bigint, text, text) to authenticated;
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

-- Change or switch off my automatic cash-out, also while the rocket is in the air (only to a value it hasn't reached yet).
create or replace function public.rocket_set_auto(round bigint, auto_at numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  r public.rocket_rounds;
  m numeric := 1;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select * into r from public.rocket_rounds where id = round;
  if r.id is null then raise exception 'no such round'; end if;
  if now_ms >= r.launch then m := public.rocket_mult(now_ms - r.launch); end if;
  if now_ms >= r.crash_at or m >= r.crash then perform public.rocket_settle(round); raise exception 'crashed'; end if;
  if auto_at is not null and (auto_at < 1.01 or auto_at > 200) then raise exception 'auto cash-out must be 1.01 to 200'; end if;
  if auto_at is not null and auto_at <= m then raise exception 'too low'; end if;
  update public.rocket_bets set auto = auto_at where round_id = round and player = auth.uid() and payout is null;
  if not found then raise exception 'no bet'; end if;
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
revoke execute on function public.rocket_set_auto(bigint, numeric) from public, anon;
grant execute on function public.rocket_set_auto(bigint, numeric) to authenticated;
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


-- ---------------------------------------------------------------------------
-- Titles: run this part once (after "Admin security"). An admin can give a
-- player a title that shows next to their name everywhere, for now
-- "Bug Abuser". Only the admin menu can set or remove it.

alter table public.players add column if not exists title text check (title is null or title in ('bugabuser'));

create or replace function public.admin_set_title(tok uuid, target uuid, new_title text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if new_title is not null and new_title not in ('bugabuser') then raise exception 'unknown title'; end if;
  update public.players set title = new_title where id = target;
  if not found then raise exception 'no such player'; end if;
end;
$$;

revoke execute on function public.admin_set_title(uuid, uuid, text) from public, anon;
grant execute on function public.admin_set_title(uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Lotto: run this part once (after "Sending credits" and "Rocket"). Two draws
-- a day, at noon and in the evening (German time, 12:00 and 18:00 unless the
-- admin menu says otherwise). While tickets are on sale every player can buy
-- one ticket per draw for a share of their whole balance (20% at noon, 50% in
-- the evening). At draw time the database picks exactly one winner from the
-- tickets (by default the chance follows the ticket price, so it is fair for
-- small and big balances) and the winner gets the pot. While tickets are on
-- sale nobody can send credits, so nobody can shrink their balance to buy a
-- cheap ticket. The numbers come from the admin menu (Lotto tab).

create table if not exists public.lotto_draws (
  id text primary key,                       -- German date and draw, e.g. '2026-10-29-noon' or '2026-10-29-eve'
  kind text not null check (kind in ('noon', 'eve')),
  draw_at timestamptz not null,
  pot bigint,
  tickets integer,
  winner uuid references public.players (id) on delete set null,
  winner_name text,
  winner_cost bigint,
  settled boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.lotto_draws enable row level security;
revoke all on public.lotto_draws from anon, authenticated;
grant select on public.lotto_draws to authenticated;
drop policy if exists "Everyone sees the lotto draws" on public.lotto_draws;
create policy "Everyone sees the lotto draws" on public.lotto_draws for select to authenticated using (true);

create table if not exists public.lotto_tickets (
  id bigint generated always as identity primary key,
  draw_id text not null references public.lotto_draws (id) on delete cascade,
  player uuid not null references public.players (id) on delete cascade,
  name text not null,
  cost bigint not null check (cost > 0),
  payout bigint,
  claimed boolean not null default false,
  created_at timestamptz not null default now(),
  unique (draw_id, player)
);
create index if not exists lotto_tickets_open on public.lotto_tickets (player) where not claimed;
alter table public.lotto_tickets enable row level security;
revoke all on public.lotto_tickets from anon, authenticated;
grant select on public.lotto_tickets to authenticated;
drop policy if exists "Everyone sees the lotto tickets" on public.lotto_tickets;
create policy "Everyone sees the lotto tickets" on public.lotto_tickets for select to authenticated using (true);

-- The lotto settings from the admin menu, with the defaults.
create or replace function public.lotto_cfg()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'on', coalesce((data ->> 'lottoOn')::boolean, true),
    'noonHour', least(23, greatest(0, coalesce((data ->> 'lottoNoonHour')::numeric, 12)))::integer,
    'eveHour', least(23, greatest(0, coalesce((data ->> 'lottoEveHour')::numeric, 18)))::integer,
    'noonPct', least(100, greatest(1, coalesce((data ->> 'lottoNoonPct')::numeric, 20))),
    'evePct', least(100, greatest(1, coalesce((data ->> 'lottoEvePct')::numeric, 50))),
    'openHours', least(24, greatest(0.25, coalesce((data ->> 'lottoOpenHours')::numeric, 5))),
    'closeMin', least(120, greatest(0, coalesce((data ->> 'lottoCloseMin')::numeric, 5))),
    'share', least(500, greatest(0, coalesce((data ->> 'lottoShare')::numeric, 100))),
    'noonBonus', greatest(0, coalesce((data ->> 'lottoNoonBonus')::numeric, 0))::bigint,
    'eveBonus', greatest(0, coalesce((data ->> 'lottoEveBonus')::numeric, 0))::bigint,
    'mode', case when data ->> 'lottoMode' = 'equal' then 'equal' else 'weighted' end)
  from public.settings where id = 1
$$;

-- One draw's times: draw, sales open, sales close.
create or replace function public.lotto_slot(day date, k text, cfg jsonb)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object('id', to_char(day, 'YYYY-MM-DD') || '-' || k, 'kind', k, 'draw_at', d,
    'open_at', d - make_interval(secs => ((cfg ->> 'openHours')::numeric * 3600)::double precision),
    'close_at', d - make_interval(secs => ((cfg ->> 'closeMin')::numeric * 60)::double precision))
  from (select ((day + make_time((cfg ->> (k || 'Hour'))::integer, 0, 0)) at time zone 'Europe/Berlin') as d) x
$$;

-- Are lotto tickets on sale right now?
create or replace function public.lotto_selling()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.lotto_cfg();
  today date := (now() at time zone 'Europe/Berlin')::date;
  d date;
  k text;
  s jsonb;
begin
  if not (cfg ->> 'on')::boolean then return false; end if;
  foreach d in array array[today - 1, today, today + 1] loop
    foreach k in array array['noon', 'eve'] loop
      s := public.lotto_slot(d, k, cfg);
      if now() >= (s ->> 'open_at')::timestamptz and now() < (s ->> 'close_at')::timestamptz then return true; end if;
    end loop;
  end loop;
  return false;
end;
$$;

-- The draw: exactly one winner among the tickets, who gets the pot.
create or replace function public.lotto_settle(draw text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dr public.lotto_draws;
  cfg jsonb := public.lotto_cfg();
  n integer;
  tot numeric;
  v_pot bigint;
  pick public.lotto_tickets;
  x numeric;
begin
  select * into dr from public.lotto_draws where id = draw for update;
  if dr.id is null or dr.settled or now() < dr.draw_at then return; end if;
  select count(*), coalesce(sum(cost), 0) into n, tot from public.lotto_tickets where draw_id = draw;
  if n = 0 then
    update public.lotto_draws set settled = true, pot = 0, tickets = 0 where id = draw;
    return;
  end if;
  v_pot := floor(tot * (cfg ->> 'share')::numeric / 100)::bigint + (cfg ->> (dr.kind || 'Bonus'))::bigint;
  if cfg ->> 'mode' = 'equal' then
    select * into pick from public.lotto_tickets where draw_id = draw order by random() limit 1;
  else
    x := random() * tot;
    select t.id, t.draw_id, t.player, t.name, t.cost, t.payout, t.claimed, t.created_at into pick
      from (select *, sum(cost) over (order by id) as run from public.lotto_tickets where draw_id = draw) t
      where t.run > x order by t.run limit 1;
    if pick.id is null then select * into pick from public.lotto_tickets where draw_id = draw order by id desc limit 1; end if;
  end if;
  update public.lotto_tickets set payout = case when id = pick.id then v_pot else 0 end where draw_id = draw;
  update public.lotto_draws set settled = true, pot = v_pot, tickets = n, winner = pick.player, winner_name = pick.name, winner_cost = pick.cost
    where id = draw;
end;
$$;

-- What the page shows: the next noon and evening draw (or the one being drawn right now), with everyone's tickets.
create or replace function public.lotto_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.lotto_cfg();
  today date := (now() at time zone 'Europe/Berlin')::date;
  k text;
  s jsonb;
  dr public.lotto_draws;
  slots jsonb := '[]';
  d text;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for d in select id from public.lotto_draws where not settled and draw_at <= now() loop
    perform public.lotto_settle(d);
  end loop;
  foreach k in array array['noon', 'eve'] loop
    s := public.lotto_slot(today, k, cfg);
    -- a draw stays on show for three minutes after its time, then the next day's takes over
    if (s ->> 'draw_at')::timestamptz + interval '3 minutes' < now() then s := public.lotto_slot(today + 1, k, cfg); end if;
    -- (a new time from the admin menu moves a draw that has not happened yet)
    insert into public.lotto_draws (id, kind, draw_at) values (s ->> 'id', k, (s ->> 'draw_at')::timestamptz)
      on conflict (id) do update set draw_at = excluded.draw_at where not public.lotto_draws.settled and public.lotto_draws.draw_at > now();
    select * into dr from public.lotto_draws where id = s ->> 'id';
    slots := slots || jsonb_build_array(s || jsonb_build_object(
      'pct', cfg ->> (k || 'Pct'), 'bonus', cfg ->> (k || 'Bonus'), 'share', cfg ->> 'share',
      'settled', dr.settled, 'pot', dr.pot, 'winner', dr.winner, 'winner_name', dr.winner_name, 'winner_cost', dr.winner_cost,
      'people', (select coalesce(jsonb_agg(jsonb_build_object('player', player, 'name', name, 'cost', cost) order by cost desc), '[]')
        from public.lotto_tickets where draw_id = s ->> 'id')));
  end loop;
  return jsonb_build_object('now', floor(extract(epoch from clock_timestamp()) * 1000), 'cfg', cfg, 'slots', slots,
    'recent', (select coalesce(jsonb_agg(to_jsonb(r) order by r.draw_at desc), '[]') from (
      select id, kind, draw_at, pot, tickets, winner, winner_name, winner_cost from public.lotto_draws
      where settled and tickets > 0 order by draw_at desc limit 6) r));
end;
$$;

-- Buy my one ticket for a draw that is on sale: the price is a share of my whole balance right now.
create or replace function public.lotto_buy(draw text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.lotto_cfg();
  k text := split_part(draw, '-', 4);
  s jsonb;
  me public.players;
  c bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if not (cfg ->> 'on')::boolean then raise exception 'lotto is off'; end if;
  if k not in ('noon', 'eve') then raise exception 'no such draw'; end if;
  s := public.lotto_slot(left(draw, 10)::date, k, cfg);
  if s ->> 'id' <> draw then raise exception 'no such draw'; end if;
  if now() < (s ->> 'open_at')::timestamptz or now() >= (s ->> 'close_at')::timestamptz then raise exception 'sales closed'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  if exists (select 1 from public.lotto_tickets where draw_id = draw and player = me.id) then raise exception 'already have a ticket'; end if;
  c := floor(me.credits * (cfg ->> (k || 'Pct'))::numeric / 100)::bigint;
  if c < 1 then raise exception 'not enough credits'; end if;
  insert into public.lotto_draws (id, kind, draw_at) values (draw, k, (s ->> 'draw_at')::timestamptz) on conflict (id) do nothing;
  update public.players set credits = credits - c, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.lotto_tickets (draw_id, player, name, cost) values (draw, me.id, me.name, c);
  return jsonb_build_object('cost', c, 'credits', me.credits - c, 'rev', me.admin_rev + 1);
end;
$$;

-- Collect my finished draws: the winner's pot lands on the balance.
create or replace function public.lotto_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d text;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for d in select t.draw_id from public.lotto_tickets t join public.lotto_draws r on r.id = t.draw_id
      where t.player = auth.uid() and not t.claimed and r.draw_at <= now() loop
    perform public.lotto_settle(d);
  end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  with c as (
    update public.lotto_tickets set claimed = true
    where player = me.id and not claimed and payout is not null
    returning draw_id, cost, payout
  )
  select coalesce(sum(payout), 0), coalesce(jsonb_agg(to_jsonb(c)), '[]') into won, rows_ from c;
  if won > 0 then
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
    return jsonb_build_object('tickets', rows_, 'credits', me.credits + won, 'rev', me.admin_rev + 1);
  end if;
  return jsonb_build_object('tickets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

revoke execute on function public.lotto_cfg() from public, anon, authenticated;
revoke execute on function public.lotto_settle(text) from public, anon, authenticated;
revoke execute on function public.lotto_selling() from public, anon;
revoke execute on function public.lotto_state() from public, anon;
revoke execute on function public.lotto_buy(text) from public, anon;
revoke execute on function public.lotto_claim() from public, anon;
grant execute on function public.lotto_selling() to authenticated;
grant execute on function public.lotto_state() to authenticated;
grant execute on function public.lotto_buy(text) to authenticated;
grant execute on function public.lotto_claim() to authenticated;

-- Sending credits stops while tickets are on sale.
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
  -- While lotto tickets are on sale, nobody can move credits: the ticket price depends on everyone's balance.
  if public.lotto_selling() then raise exception 'lotto sales running'; end if;
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

-- A reset or hard reset also drops a player's lotto tickets that were not collected yet.
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
    delete from public.lotto_tickets where player = new.id and not claimed;
  end if;
  return new;
end;
$$;



-- ---------------------------------------------------------------------------
-- Economy rework: run this part once (after "Lotto"). It brings:
--  * a bet limit per round that grows with your level and prestige (horse racing, roulette, rocket here;
--    the page applies the same limit to the other games),
--  * winnings of the live games and the lotto go straight onto the balance, also for players who are
--    offline (the highscores are always up to date),
--  * a little more house edge on the rocket,
--  * at most 10,000 credits for an affiliate code owner per new player,
--  * a complete hard reset (credits, levels, prestige, goodies, cosmetics, trophies, bets and tickets),
--  * a guard against edited saves: one save can no longer jump levels or add absurd amounts of credits.

alter table public.horse_bets add column if not exists seen boolean not null default false;
alter table public.roulette_bets add column if not exists seen boolean not null default false;
alter table public.rocket_bets add column if not exists seen boolean not null default false;
alter table public.lotto_tickets add column if not exists seen boolean not null default false;
update public.horse_bets set seen = true where claimed and not seen;
update public.roulette_bets set seen = true where claimed and not seen;
update public.rocket_bets set seen = true where claimed and not seen;
update public.lotto_tickets set seen = true where claimed and not seen;
alter table public.players add column if not exists capped_saves integer not null default 0;
revoke update (capped_saves) on public.players from authenticated;

-- The bet limit per round: level 1 starts at 500, level 20 allows 40,000; every prestige adds 25% (up to twice as much).
-- An admin's "highest bet" setting can lower it further.
create or replace function public.lr_bet_limit(lv integer, pr integer)
returns bigint
language sql
immutable
as $$
  select floor((array[500, 750, 1000, 1500, 2000, 2500, 3000, 4000, 5000, 6000, 7500, 9000, 10000, 12500, 15000, 17500, 20000, 25000, 30000, 40000])[least(20, greatest(1, coalesce(lv, 1)))]
    * (1 + 0.25 * least(4, greatest(0, coalesce(pr, 0)))))::bigint
$$;

create or replace function public.lr_over_limit(me public.players, spent bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select spent > least(public.lr_bet_limit(me.level, me.prestige),
    coalesce(nullif((select (data ->> 'maxBet')::bigint from public.settings where id = 1), 0), 9007199254740991))
$$;

-- Settles every finished round that still has unpaid bets (at most every two seconds), so winnings reach offline players too.
create table if not exists public.lr_sweep_at (id integer primary key, at timestamptz not null default now());
insert into public.lr_sweep_at (id, at) values (1, now() - interval '1 hour') on conflict (id) do nothing;
alter table public.lr_sweep_at enable row level security;
revoke all on public.lr_sweep_at from anon, authenticated;

create or replace function public.lr_sweep()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  x bigint;
  d text;
begin
  update public.lr_sweep_at set at = now() where id = 1 and at < now() - interval '2 seconds';
  if not found then return; end if;
  for x in select distinct race_id from public.horse_bets where payout is null and race_id * 180000 + 120000 <= now_ms limit 20 loop
    perform public.horse_settle(x);
  end loop;
  for x in select distinct round_id from public.roulette_bets where payout is null and round_id * 45000 + 34000 <= now_ms limit 20 loop
    perform public.roulette_settle(x);
  end loop;
  for x in select distinct b.round_id from public.rocket_bets b join public.rocket_rounds r on r.id = b.round_id
      where b.payout is null and r.crash_at <= now_ms limit 20 loop
    perform public.rocket_settle(x);
  end loop;
  if to_regclass('public.lotto_draws') is not null then
    for d in select id from public.lotto_draws where not settled and draw_at <= now() limit 5 loop
      perform public.lotto_settle(d);
    end loop;
  end if;
end;
$$;
revoke execute on function public.lr_sweep() from public, anon, authenticated;
revoke execute on function public.lr_over_limit(public.players, bigint) from public, anon, authenticated;

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
  -- Golden: P(reaching m) = 30 / m from 30× up. Ordinary: P(reaching m) = 0.85 / m (15% blow up on the pad). Moon at 200.
  c := case when gold then least(200, floor(30 / (1 - random()) * 100) / 100)
       else least(200, greatest(1, floor(0.85 / (1 - random()) * 100) / 100)) end;
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
  -- Winnings go straight onto the balance, also for players who are offline right now.
  with w as (select player, sum(payout) as s from public.rocket_bets where round_id = round and payout > 0 and not claimed group by player)
  update public.players p set credits = least(9007199254740991, p.credits + w.s), admin_rev = p.admin_rev + 1, updated_at = now() from w where p.id = w.player;
  update public.rocket_bets set claimed = true where round_id = round and payout is not null and not claimed;
  update public.rocket_rounds set settled = true where id = round;
end;
$$;

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
  if r.finish is not null then
    -- Winnings go straight onto the balance, also for players who are offline right now.
    with w as (select player, sum(payout) as s from public.horse_bets where race_id = race and payout > 0 and not claimed group by player)
    update public.players p set credits = least(9007199254740991, p.credits + w.s), admin_rev = p.admin_rev + 1, updated_at = now() from w where p.id = w.player;
    update public.horse_bets set claimed = true where race_id = race and payout is not null and not claimed;
    return r.finish;
  end if;
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
  -- Winnings go straight onto the balance, also for players who are offline right now.
  with w as (select player, sum(payout) as s from public.horse_bets where race_id = race and payout > 0 and not claimed group by player)
  update public.players p set credits = least(9007199254740991, p.credits + w.s), admin_rev = p.admin_rev + 1, updated_at = now() from w where p.id = w.player;
  update public.horse_bets set claimed = true where race_id = race and payout is not null and not claimed;
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
  -- Winnings go straight onto the balance, also for players who are offline right now.
  with w as (select player, sum(payout) as s from public.roulette_bets where round_id = round and payout > 0 and not claimed group by player)
  update public.players p set credits = least(9007199254740991, p.credits + w.s), admin_rev = p.admin_rev + 1, updated_at = now() from w where p.id = w.player;
  update public.roulette_bets set claimed = true where round_id = round and payout is not null and not claimed;
  -- Old rounds and bets go after about four days.
  delete from public.roulette_bets where round_id < round - 6000 and claimed;
  delete from public.roulette_rounds where id < round - 6000;
  return res;
end;
$$;

create or replace function public.lotto_settle(draw text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dr public.lotto_draws;
  cfg jsonb := public.lotto_cfg();
  n integer;
  tot numeric;
  v_pot bigint;
  pick public.lotto_tickets;
  x numeric;
begin
  select * into dr from public.lotto_draws where id = draw for update;
  if dr.id is null or dr.settled or now() < dr.draw_at then return; end if;
  select count(*), coalesce(sum(cost), 0) into n, tot from public.lotto_tickets where draw_id = draw;
  if n = 0 then
    update public.lotto_draws set settled = true, pot = 0, tickets = 0 where id = draw;
    return;
  end if;
  v_pot := floor(tot * (cfg ->> 'share')::numeric / 100)::bigint + (cfg ->> (dr.kind || 'Bonus'))::bigint;
  if cfg ->> 'mode' = 'equal' then
    select * into pick from public.lotto_tickets where draw_id = draw order by random() limit 1;
  else
    x := random() * tot;
    select t.id, t.draw_id, t.player, t.name, t.cost, t.payout, t.claimed, t.created_at into pick
      from (select *, sum(cost) over (order by id) as run from public.lotto_tickets where draw_id = draw) t
      where t.run > x order by t.run limit 1;
    if pick.id is null then select * into pick from public.lotto_tickets where draw_id = draw order by id desc limit 1; end if;
  end if;
  update public.lotto_tickets set payout = case when id = pick.id then v_pot else 0 end where draw_id = draw;
  -- the winner gets the pot right away, online or not
  update public.players set credits = least(9007199254740991, credits + v_pot), admin_rev = admin_rev + 1, updated_at = now() where id = pick.player;
  update public.lotto_tickets set claimed = true where draw_id = draw;
  update public.lotto_draws set settled = true, pot = v_pot, tickets = n, winner = pick.player, winner_name = pick.name, winner_cost = pick.cost
    where id = draw;
end;
$$;

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
  if public.lr_over_limit(me, (amount + coalesce((select sum(b.amount) from public.horse_bets b where b.race_id = race and b.player = me.id), 0))::bigint) then raise exception 'over your bet limit'; end if;
  if (select count(*) from public.horse_bets where race_id = race and player = me.id) >= 12 then raise exception 'too many bets'; end if;
  r := public.horse_make(race);
  o := case when bet_kind = 'win' then r.win_odds[horse_no] else r.place_odds[horse_no] end;
  update public.players set credits = credits - amount, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.horse_bets (race_id, player, name, horse, kind, amount, odds) values (race, me.id, me.name, horse_no, bet_kind, amount, o);
  return jsonb_build_object('odds', o, 'credits', me.credits - amount, 'rev', me.admin_rev + 1);
end;
$$;

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
  if round <> now_ms / 45000 or now_ms >= round * 45000 + 30000 then raise exception 'betting closed'; end if;
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
  if public.lr_over_limit(me, (tot + coalesce((select sum(b.total) from public.roulette_bets b where b.round_id = round and b.player = me.id), 0))::bigint) then raise exception 'over your bet limit'; end if;
  if (select count(*) from public.roulette_bets where round_id = round and player = me.id) >= 20 then raise exception 'too many bets'; end if;
  m := least(100, greatest(0.1, coalesce((select (data ->> 'winMultiplier')::numeric from public.settings where id = 1), 1)));
  update public.players set credits = credits - tot, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.roulette_bets (round_id, player, name, bets, total, mult) values (round, me.id, me.name, chips, tot, m);
  return jsonb_build_object('credits', me.credits - tot, 'rev', me.admin_rev + 1);
end;
$$;

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
  if public.lr_over_limit(me, (amount)::bigint) then raise exception 'over your bet limit'; end if;
  if exists (select 1 from public.rocket_bets where round_id = round and player = me.id) then raise exception 'already on board'; end if;
  update public.players set credits = credits - amount, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.rocket_bets (round_id, player, name, amount, auto) values (round, me.id, me.name, amount, auto_at);
  return jsonb_build_object('credits', me.credits - amount, 'rev', me.admin_rev + 1);
end;
$$;

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
  update public.rocket_bets set cashed = m, payout = pay, claimed = true, seen = true where id = b.id;
  select * into me from public.players where id = auth.uid() for update;
  update public.players set credits = credits + pay, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  return jsonb_build_object('mult', m, 'payout', pay, 'credits', me.credits + pay, 'rev', me.admin_rev + 1);
end;
$$;

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
  perform public.lr_sweep();
  race := coalesce(race, cur);
  if race > cur or race < cur - 1000 then raise exception 'no such race'; end if;
  r := public.horse_make(race);
  if now_ms >= race * 180000 + 120000 then fin := public.horse_settle(race); end if;
  return jsonb_build_object('id', race, 'now', now_ms, 'weights', to_jsonb(r.weights), 'win', to_jsonb(r.win_odds),
    'place', to_jsonb(r.place_odds), 'finish', to_jsonb(fin));
end;
$$;

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
  perform public.lr_sweep();
  round := coalesce(round, cur);
  if round > cur or round < cur - 3000 then raise exception 'no such round'; end if;
  if now_ms >= round * 45000 + 34000 then res := public.roulette_settle(round); end if;
  return jsonb_build_object('id', round, 'now', now_ms, 'result', res,
    'recent', (select coalesce(jsonb_agg(result order by id desc), '[]') from (
      select id, result from public.roulette_rounds where result is not null and id < cur order by id desc limit 14) r));
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
  perform public.lr_sweep();
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

create or replace function public.lotto_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.lotto_cfg();
  today date := (now() at time zone 'Europe/Berlin')::date;
  k text;
  s jsonb;
  dr public.lotto_draws;
  slots jsonb := '[]';
  d text;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  perform public.lr_sweep();
  for d in select id from public.lotto_draws where not settled and draw_at <= now() loop
    perform public.lotto_settle(d);
  end loop;
  foreach k in array array['noon', 'eve'] loop
    s := public.lotto_slot(today, k, cfg);
    -- a draw stays on show for three minutes after its time, then the next day's takes over
    if (s ->> 'draw_at')::timestamptz + interval '3 minutes' < now() then s := public.lotto_slot(today + 1, k, cfg); end if;
    -- (a new time from the admin menu moves a draw that has not happened yet)
    insert into public.lotto_draws (id, kind, draw_at) values (s ->> 'id', k, (s ->> 'draw_at')::timestamptz)
      on conflict (id) do update set draw_at = excluded.draw_at where not public.lotto_draws.settled and public.lotto_draws.draw_at > now();
    select * into dr from public.lotto_draws where id = s ->> 'id';
    slots := slots || jsonb_build_array(s || jsonb_build_object(
      'pct', cfg ->> (k || 'Pct'), 'bonus', cfg ->> (k || 'Bonus'), 'share', cfg ->> 'share',
      'settled', dr.settled, 'pot', dr.pot, 'winner', dr.winner, 'winner_name', dr.winner_name, 'winner_cost', dr.winner_cost,
      'people', (select coalesce(jsonb_agg(jsonb_build_object('player', player, 'name', name, 'cost', cost) order by cost desc), '[]')
        from public.lotto_tickets where draw_id = s ->> 'id')));
  end loop;
  return jsonb_build_object('now', floor(extract(epoch from clock_timestamp()) * 1000), 'cfg', cfg, 'slots', slots,
    'recent', (select coalesce(jsonb_agg(to_jsonb(r) order by r.draw_at desc), '[]') from (
      select id, kind, draw_at, pot, tickets, winner, winner_name, winner_cost from public.lotto_draws
      where settled and tickets > 0 order by draw_at desc limit 6) r));
end;
$$;

create or replace function public.horse_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  x bigint;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for x in select distinct race_id from public.horse_bets where player = auth.uid() and payout is null and race_id * 180000 + 120000 <= now_ms loop perform public.horse_settle(x); end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  -- bets paid out before this update was installed
  select coalesce(sum(payout), 0) into won from public.horse_bets where player = me.id and not claimed and payout is not null;
  if won > 0 then
    update public.horse_bets set claimed = true where player = me.id and not claimed and payout is not null;
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id returning * into me;
  end if;
  with c as (
    update public.horse_bets set seen = true
    where player = me.id and claimed and not seen and payout is not null
    returning race_id, horse, kind, amount, odds, payout
  )
  select coalesce(jsonb_agg(to_jsonb(c)), '[]') into rows_ from c;
  return jsonb_build_object('bets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

create or replace function public.roulette_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  x bigint;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for x in select distinct round_id from public.roulette_bets where player = auth.uid() and payout is null and round_id * 45000 + 34000 <= now_ms loop perform public.roulette_settle(x); end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  -- bets paid out before this update was installed
  select coalesce(sum(payout), 0) into won from public.roulette_bets where player = me.id and not claimed and payout is not null;
  if won > 0 then
    update public.roulette_bets set claimed = true where player = me.id and not claimed and payout is not null;
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id returning * into me;
  end if;
  with c as (
    update public.roulette_bets set seen = true
    where player = me.id and claimed and not seen and payout is not null
    returning round_id, bets, total, payout
  )
  select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('result', r.result)), '[]') into rows_ from c join public.roulette_rounds r on r.id = c.round_id;
  return jsonb_build_object('bets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

create or replace function public.rocket_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  x bigint;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for x in select b.round_id from public.rocket_bets b join public.rocket_rounds r on r.id = b.round_id where b.player = auth.uid() and b.payout is null and r.crash_at <= now_ms loop perform public.rocket_settle(x); end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  -- bets paid out before this update was installed
  select coalesce(sum(payout), 0) into won from public.rocket_bets where player = me.id and not claimed and payout is not null;
  if won > 0 then
    update public.rocket_bets set claimed = true where player = me.id and not claimed and payout is not null;
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id returning * into me;
  end if;
  with c as (
    update public.rocket_bets set seen = true
    where player = me.id and claimed and not seen and payout is not null
    returning round_id, amount, auto, cashed, payout
  )
  select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('crash', r.crash)), '[]') into rows_ from c join public.rocket_rounds r on r.id = c.round_id;
  return jsonb_build_object('bets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

create or replace function public.lotto_claim()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d text;
  won bigint;
  rows_ jsonb;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  for d in select distinct t.draw_id from public.lotto_tickets t join public.lotto_draws r on r.id = t.draw_id
      where t.player = auth.uid() and t.payout is null and r.draw_at <= now() loop
    perform public.lotto_settle(d);
  end loop;
  select * into me from public.players where id = auth.uid() for update;
  if me is null then raise exception 'not allowed'; end if;
  select coalesce(sum(payout), 0) into won from public.lotto_tickets where player = me.id and not claimed and payout is not null;
  if won > 0 then
    update public.lotto_tickets set claimed = true where player = me.id and not claimed and payout is not null;
    update public.players set credits = credits + won, admin_rev = admin_rev + 1, updated_at = now() where id = me.id returning * into me;
  end if;
  with c as (
    update public.lotto_tickets set seen = true where player = me.id and claimed and not seen and payout is not null
    returning draw_id, cost, payout
  )
  select coalesce(jsonb_agg(to_jsonb(c)), '[]') into rows_ from c;
  return jsonb_build_object('tickets', rows_, 'credits', me.credits, 'rev', me.admin_rev);
end;
$$;

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
  -- 5% of the code owner's credits, at most 10,000
  bonus := least(10000, floor(aff.credits * 0.05))::bigint;
  update public.players set credits = credits + bonus, admin_rev = admin_rev + 1, updated_at = now() where id = aff.id;
  update public.players set credits = credits + 4500, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.affiliate_uses (new_player, new_name, affiliate, code, bonus, device) values (me.id, me.name, aff.id, c, bonus, dev);
  insert into public.player_devices (device, player) values (dev, me.id) on conflict do nothing;
  return jsonb_build_object('credits', me.credits + 4500, 'rev', me.admin_rev + 1, 'affiliate', aff.name);
end;
$$;

-- The hard reset: everybody starts again from the start credits. Credits, levels, prestige, goodies, cosmetics,
-- name styles, trophies, achievements, missions, the Lucky Burger career, open bets and lotto tickets all go.
-- Profile pictures, medals, admin titles and affiliate codes stay.
create or replace function public.admin_hard_reset(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform public.admin_check(tok);
  update public.players set
    credits = start_credits, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null, prestige = 0,
    trophies = '{}', capped_saves = 0, admin_rev = admin_rev + 1, updated_at = now()
  where true;
  delete from public.horse_bets where true;
  delete from public.roulette_bets where true;
  delete from public.rocket_bets where true;
  if to_regclass('public.lotto_tickets') is not null then
    execute 'delete from public.lotto_tickets where true';
    execute 'delete from public.lotto_draws where true';
  end if;
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

-- A guard on the players' own saves (the live games and admin changes go through the database functions and are not touched).
-- One save may add at most 6,000× the player's bet limit plus 250,000 credits, at most two levels, and prestige only from level 20.
-- Anything above is cut back, counted in capped_saves (so an admin can see who tried) and the page reloads the balance.
create or replace function public.players_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  cap bigint;
  cut boolean := false;
begin
  if current_user <> 'authenticated' then return new; end if;
  if new.level > old.level + 2 then new.level := old.level + 2; cut := true; end if;
  if new.prestige > old.prestige and (new.prestige > old.prestige + 1 or old.level < 20) then
    new.prestige := old.prestige; new.level := greatest(new.level, old.level); cut := true;
  end if;
  cap := public.lr_bet_limit(old.level, old.prestige) * 6000 + 250000;
  if new.credits > old.credits + cap then new.credits := old.credits + cap; cut := true; end if;
  -- a cut save also makes the page reload the balance from the database
  if cut then new.capped_saves := old.capped_saves + 1; new.admin_rev := old.admin_rev + 1; end if;
  return new;
end;
$$;
drop trigger if exists players_guard on public.players;
create trigger players_guard before update on public.players for each row execute function public.players_guard();


-- ---------------------------------------------------------------------------
-- Stock market: run this part once (after "Economy rework"). Six shares, the same prices for everyone:
-- every 5 minutes each share moves once, up with its own chance (the safe ones rise often but a little,
-- the wild ones rarely but a lot), and on average a move is worth nothing either way, so the house
-- only earns the 1% fee on every buy and sell. A share that falls below 5% of its starting price goes
-- bankrupt (whoever holds it loses it); one that reaches 10x is taken over (whoever holds it gets paid
-- out at that price, online or not). Then it starts again at its starting price.
-- Portfolios live here in the database: buy, log out, play something else, come back.

create table if not exists public.stocks (
  id text primary key,
  name text not null,
  color text not null,
  sort smallint not null,
  p_up numeric not null,        -- chance to go up in a 5-minute step
  up numeric not null,          -- factor when it goes up
  down numeric not null,        -- factor when it goes down
  news numeric not null default 0,   -- chance of breaking news in a step
  news_size numeric not null default 0,
  ipo numeric not null,         -- starting price (again after a bankruptcy or takeover)
  price numeric not null,
  prev numeric not null,
  tick bigint not null,         -- the last 5-minute step drawn
  gen integer not null default 1
);
alter table public.stocks enable row level security;
revoke all on public.stocks from anon, authenticated;
grant select on public.stocks to authenticated;
drop policy if exists "Everyone sees the stocks" on public.stocks;
create policy "Everyone sees the stocks" on public.stocks for select to authenticated using (true);

-- down = (1 - p_up * up) / (1 - p_up): a step is worth exactly 1 on average. The two safe shares get a
-- touch more (half their variance) so their price stays flat instead of slowly sagging.
insert into public.stocks (id, name, color, sort, p_up, up, down, news, news_size, ipo, price, prev, tick) values
  ('LBK',  'Lucky Bank',    '#4fa8e0', 1, 0.65, 1.005,  (1.0000231 - 0.65 * 1.005) / 0.35,  0,     0,    100, 100, 100, public.horse_now_ms() / 300000 - 96),
  ('BRG',  'Burger Corp',   '#d62828', 2, 0.60, 1.0065, (1.000032 - 0.60 * 1.0065) / 0.40, 0,     0,     60,  60,  60, public.horse_now_ms() / 300000 - 96),
  ('GLD',  'Golden Mines',  '#e9a23b', 3, 0.55, 1.011,  (1 - 0.55 * 1.011) / 0.45,          0.003, 0.15, 150, 150, 150, public.horse_now_ms() / 300000 - 96),
  ('NEO',  'Neon Games',    '#a77bff', 4, 0.50, 1.015,  (1 - 0.50 * 1.015) / 0.50,          0.004, 0.15,  80,  80,  80, public.horse_now_ms() / 300000 - 96),
  ('RKT',  'Rocket Labs',   '#7fd18b', 5, 0.42, 1.025,  (1 - 0.42 * 1.025) / 0.58,          0.005, 0.20,  40,  40,  40, public.horse_now_ms() / 300000 - 96),
  ('MOON', 'Moon Coin',     '#f3c94b', 6, 0.30, 1.045,  (1 - 0.30 * 1.045) / 0.70,          0.006, 0.25,  10,  10,  10, public.horse_now_ms() / 300000 - 96)
on conflict (id) do nothing;

create table if not exists public.stock_prices (
  stock text not null references public.stocks (id) on delete cascade,
  tick bigint not null,
  price numeric not null,
  primary key (stock, tick)
);
alter table public.stock_prices enable row level security;
revoke all on public.stock_prices from anon, authenticated;
grant select on public.stock_prices to authenticated;
drop policy if exists "Everyone sees the stock prices" on public.stock_prices;
create policy "Everyone sees the stock prices" on public.stock_prices for select to authenticated using (true);

create table if not exists public.stock_holdings (
  player uuid not null references public.players (id) on delete cascade,
  stock text not null references public.stocks (id) on delete cascade,
  name text not null,
  shares bigint not null check (shares > 0),
  cost bigint not null,          -- what the shares cost, fees included
  primary key (player, stock)
);
alter table public.stock_holdings enable row level security;
revoke all on public.stock_holdings from anon, authenticated;
grant select on public.stock_holdings to authenticated;
drop policy if exists "Everyone sees who holds what" on public.stock_holdings;
create policy "Everyone sees who holds what" on public.stock_holdings for select to authenticated using (true);

-- Trades, breaking news, bankruptcies and takeovers: the feed on the page (and the player's own notes).
create table if not exists public.stock_events (
  id bigint generated always as identity primary key,
  tick bigint not null,
  stock text not null,
  kind text not null check (kind in ('buy', 'sell', 'boom', 'crash', 'bust', 'takeover', 'lost', 'paid')),
  player uuid references public.players (id) on delete cascade,
  name text,
  shares bigint,
  price numeric,
  total bigint,
  seen boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists stock_events_mine on public.stock_events (player) where not seen;
alter table public.stock_events enable row level security;
revoke all on public.stock_events from anon, authenticated;

-- Draws every 5-minute step that is due (after a long quiet spell only the last week).
create or replace function public.stock_advance()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  cur bigint := public.horse_now_ms() / 300000;
  s public.stocks;
  f numeric;
  ev text;
begin
  if not exists (select 1 from public.stocks where tick < cur) then return; end if;
  perform pg_advisory_xact_lock(717171);
  for s in select * from public.stocks where tick < cur order by sort for update loop
    if s.tick < cur - 2016 then s.tick := cur - 2016; end if;
    while s.tick < cur loop
      s.tick := s.tick + 1;
      f := case when random() < s.p_up then s.up else s.down end;
      ev := null;
      if s.news > 0 and random() < s.news then
        if random() < 0.5 then f := f * (1 + s.news_size); ev := 'boom'; else f := f * (1 - s.news_size); ev := 'crash'; end if;
      end if;
      s.prev := s.price;
      s.price := round(s.price * f, 4);
      if ev is not null then insert into public.stock_events (tick, stock, kind, price) values (s.tick, s.id, ev, s.price); end if;
      if s.price < s.ipo * 0.05 then
        -- bankrupt: the shares are worth nothing, the company starts over
        insert into public.stock_events (tick, stock, kind, player, name, shares, price, total)
          select s.tick, s.id, 'lost', player, name, shares, s.price, 0 from public.stock_holdings where stock = s.id;
        insert into public.stock_events (tick, stock, kind, price) values (s.tick, s.id, 'bust', s.price);
        delete from public.stock_holdings where stock = s.id;
        s.price := s.ipo; s.prev := s.ipo; s.gen := s.gen + 1;
      elsif s.price >= s.ipo * 10 then
        -- taken over at ten times the starting price: every holder is paid out right away
        insert into public.stock_events (tick, stock, kind, player, name, shares, price, total)
          select s.tick, s.id, 'paid', player, name, shares, s.price, floor(shares * s.price)::bigint from public.stock_holdings where stock = s.id;
        update public.players p set credits = least(9007199254740991, p.credits + floor(h.shares * s.price)::bigint), admin_rev = p.admin_rev + 1, updated_at = now()
          from public.stock_holdings h where h.stock = s.id and p.id = h.player;
        insert into public.stock_events (tick, stock, kind, price) values (s.tick, s.id, 'takeover', s.price);
        delete from public.stock_holdings where stock = s.id;
        s.price := s.ipo; s.prev := s.ipo; s.gen := s.gen + 1;
      end if;
      insert into public.stock_prices (stock, tick, price) values (s.id, s.tick, s.price)
        on conflict (stock, tick) do update set price = excluded.price;
    end loop;
    update public.stocks set price = s.price, prev = s.prev, tick = s.tick, gen = s.gen where id = s.id;
  end loop;
  delete from public.stock_prices where tick < cur - 600;
  delete from public.stock_events where created_at < now() - interval '3 days' and (player is null or seen);
end;
$$;

-- Everything the exchange page shows, and my notes about bankruptcies and takeovers.
create or replace function public.stock_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cur bigint;
  notes jsonb;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  perform public.stock_advance();
  cur := public.horse_now_ms() / 300000;
  with n as (
    update public.stock_events set seen = true where player = auth.uid() and not seen and kind in ('lost', 'paid')
    returning stock, kind, shares, price, total
  ) select coalesce(jsonb_agg(to_jsonb(n)), '[]') into notes from n;
  return jsonb_build_object('now', public.horse_now_ms(), 'tick', cur, 'next_at', (cur + 1) * 300000,
    'stocks', (select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'color', s.color, 'p_up', s.p_up, 'up', s.up, 'down', s.down,
        'ipo', s.ipo, 'price', s.price, 'prev', s.prev, 'gen', s.gen,
        'hist', (select coalesce(jsonb_agg(x.price order by x.tick), '[]') from (select price, tick from public.stock_prices where stock = s.id order by tick desc limit 97) x))
      order by s.sort) from public.stocks s),
    'holders', (select coalesce(jsonb_agg(jsonb_build_object('player', h.player, 'name', h.name, 'stock', h.stock, 'shares', h.shares, 'cost', h.cost)), '[]')
      from (select * from public.stock_holdings order by shares desc limit 400) h),
    'feed', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'stock', e.stock, 'name', e.name, 'shares', e.shares, 'price', e.price, 'total', e.total, 'tick', e.tick, 'at', e.created_at) order by e.id desc), '[]')
      from (select * from public.stock_events where kind <> 'lost' and kind <> 'paid' order by id desc limit 30) e),
    'notes', notes);
end;
$$;

-- Buy or sell at the current price. Buying: price plus 1% fee, at most one bet limit per order and
-- 25 bet limits in one share. Selling: price minus 1% fee.
create or replace function public.stock_trade(stock_id text, qty bigint, side text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.stocks;
  me public.players;
  h public.stock_holdings;
  total bigint;
  lim bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if qty is null or qty < 1 or qty > 1000000000 then raise exception 'enter a number of shares'; end if;
  if side not in ('buy', 'sell') then raise exception 'no such trade'; end if;
  perform public.stock_advance();
  select * into s from public.stocks where id = stock_id for update;
  if s.id is null then raise exception 'no such share'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if coalesce((select (data ->> 'maintenance')::boolean from public.settings where id = 1), false) and not me.is_admin then raise exception 'paused'; end if;
  select * into h from public.stock_holdings where player = me.id and stock = s.id for update;
  if side = 'buy' then
    total := ceil(qty * s.price * 1.01)::bigint;
    if me.credits < total then raise exception 'not enough credits'; end if;
    if public.lr_over_limit(me, total) then raise exception 'over your bet limit'; end if;
    lim := least(public.lr_bet_limit(me.level, me.prestige), coalesce(nullif((select (data ->> 'maxBet')::bigint from public.settings where id = 1), 0), 9007199254740991));
    if coalesce(h.cost, 0) + total > lim * 25 then raise exception 'position too big'; end if;
    update public.players set credits = credits - total, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
    insert into public.stock_holdings (player, stock, name, shares, cost) values (me.id, s.id, me.name, qty, total)
      on conflict (player, stock) do update set shares = public.stock_holdings.shares + qty, cost = public.stock_holdings.cost + total, name = excluded.name;
    insert into public.stock_events (tick, stock, kind, player, name, shares, price, total, seen) values (s.tick, s.id, 'buy', me.id, me.name, qty, s.price, total, true);
    return jsonb_build_object('credits', me.credits - total, 'rev', me.admin_rev + 1, 'total', total, 'price', s.price);
  end if;
  if h.player is null or h.shares < qty then raise exception 'not that many shares'; end if;
  total := floor(qty * s.price * 0.99)::bigint;
  if h.shares = qty then delete from public.stock_holdings where player = me.id and stock = s.id;
  else update public.stock_holdings set shares = shares - qty, cost = cost - floor(cost * qty::numeric / shares)::bigint where player = me.id and stock = s.id;
  end if;
  update public.players set credits = least(9007199254740991, credits + total), admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.stock_events (tick, stock, kind, player, name, shares, price, total, seen) values (s.tick, s.id, 'sell', me.id, me.name, qty, s.price, total, true);
  return jsonb_build_object('credits', me.credits + total, 'rev', me.admin_rev + 1, 'total', total, 'price', s.price);
end;
$$;

revoke execute on function public.stock_advance() from public, anon, authenticated;
revoke execute on function public.stock_state() from public, anon;
revoke execute on function public.stock_trade(text, bigint, text) from public, anon;
grant execute on function public.stock_state() to authenticated;
grant execute on function public.stock_trade(text, bigint, text) to authenticated;

-- The hard reset and a player's reset also empty the portfolios.
create or replace function public.admin_hard_reset(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform public.admin_check(tok);
  update public.players set
    credits = start_credits, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null, prestige = 0,
    trophies = '{}', capped_saves = 0, admin_rev = admin_rev + 1, updated_at = now()
  where true;
  delete from public.horse_bets where true;
  delete from public.roulette_bets where true;
  delete from public.rocket_bets where true;
  if to_regclass('public.stock_holdings') is not null then
    execute 'delete from public.stock_holdings where true';
    execute 'delete from public.stock_events where player is not null';
  end if;
  if to_regclass('public.lotto_tickets') is not null then
    execute 'delete from public.lotto_tickets where true';
    execute 'delete from public.lotto_draws where true';
  end if;
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
    delete from public.lotto_tickets where player = new.id and not claimed;
    delete from public.stock_holdings where player = new.id;
  end if;
  return new;
end;
$$;


-- ---------------------------------------------------------------------------
-- Bet limits by level: run this part once (after "Stock market"). The limit per round now grows with the
-- level alone, up to 100,000 at level 20; prestige no longer changes it.
create or replace function public.lr_bet_limit(lv integer, pr integer)
returns bigint
language sql
immutable
as $$
  select (array[500, 750, 1000, 1500, 2000, 3000, 4000, 5000, 6500, 8000, 10000, 12500, 15000, 20000, 25000, 32500, 40000, 55000, 75000, 100000]::bigint[])[least(20, greatest(1, coalesce(lv, 1)))]
$$;


-- ---------------------------------------------------------------------------
-- Timed hard reset: run this part once (after "Bet limits by level"). An admin can set a time in the
-- admin menu; everyone sees a countdown, and at that time the first page that asks runs the hard reset
-- (also if no admin is online).
create or replace function public.lr_do_hard_reset()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  update public.players set
    credits = start_credits, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null, prestige = 0,
    trophies = '{}', capped_saves = 0, admin_rev = admin_rev + 1, updated_at = now()
  where true;
  delete from public.horse_bets where true;
  delete from public.roulette_bets where true;
  delete from public.rocket_bets where true;
  if to_regclass('public.stock_holdings') is not null then
    execute 'delete from public.stock_holdings where true';
    execute 'delete from public.stock_events where player is not null';
  end if;
  if to_regclass('public.lotto_tickets') is not null then
    execute 'delete from public.lotto_tickets where true';
    execute 'delete from public.lotto_draws where true';
  end if;
  if to_regclass('public.poker_seats') is not null then
    execute 'delete from public.poker_seats where true';
    execute $q$update public.poker_tables set phase = 'waiting', board = '{}', deck = '{}', current_bet = 0,
      to_act = -1, deadline = null, result = null where id = 1$q$;
    execute 'update public.poker_pulse set rev = rev + 1, at = now() where id = 1';
  end if;
end;
$$;

create or replace function public.admin_hard_reset(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  perform public.lr_do_hard_reset();
  update public.settings set data = data || '{"resetAt": 0}'::jsonb where id = 1;
end;
$$;

create or replace function public.reset_check()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  at bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select coalesce((data ->> 'resetAt')::bigint, 0) into at from public.settings where id = 1 for update;
  if at <= 0 or at > floor(extract(epoch from clock_timestamp()) * 1000) then return jsonb_build_object('done', false); end if;
  perform public.lr_do_hard_reset();
  update public.settings set data = data || jsonb_build_object('resetAt', 0, 'resetDone', at) where id = 1;
  return jsonb_build_object('done', true);
end;
$$;
revoke execute on function public.lr_do_hard_reset() from public, anon, authenticated;
revoke execute on function public.admin_hard_reset(uuid) from public, anon;
grant execute on function public.admin_hard_reset(uuid) to authenticated;
revoke execute on function public.reset_check() from public, anon;
grant execute on function public.reset_check() to authenticated;


-- ---------------------------------------------------------------------------
-- Admin cheats switch: run this part once (after "Timed hard reset"). The admin menu can switch the admin
-- secret code off for everyone; the live games then refuse it here too. The lotto gets the code as well:
-- an admin with a ticket wins the draw.
alter table public.lotto_draws add column if not exists forced uuid;
create or replace function public.admin_rig_horse(race bigint, horse_no integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_me() then raise exception 'not allowed'; end if;
  if not coalesce((select (data ->> 'cheats')::boolean from public.settings where id = 1), true) then raise exception 'cheats are off'; end if;
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
  if not coalesce((select (data ->> 'cheats')::boolean from public.settings where id = 1), true) then raise exception 'cheats are off'; end if;
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
  if not coalesce((select (data ->> 'cheats')::boolean from public.settings where id = 1), true) then raise exception 'cheats are off'; end if;
  update public.rocket_rounds set crash = 200, crash_at = launch + 40000, next_start = launch + 49000
    where id = round and public.horse_now_ms() < launch;
end;
$$;

create or replace function public.lotto_settle(draw text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dr public.lotto_draws;
  cfg jsonb := public.lotto_cfg();
  n integer;
  tot numeric;
  v_pot bigint;
  pick public.lotto_tickets;
  x numeric;
begin
  select * into dr from public.lotto_draws where id = draw for update;
  if dr.id is null or dr.settled or now() < dr.draw_at then return; end if;
  select count(*), coalesce(sum(cost), 0) into n, tot from public.lotto_tickets where draw_id = draw;
  if n = 0 then
    update public.lotto_draws set settled = true, pot = 0, tickets = 0 where id = draw;
    return;
  end if;
  v_pot := floor(tot * (cfg ->> 'share')::numeric / 100)::bigint + (cfg ->> (dr.kind || 'Bonus'))::bigint;
  -- the admin's secret code can name the winner (if that admin has a ticket)
  if (to_jsonb(dr) ->> 'forced') is not null then
    select * into pick from public.lotto_tickets where draw_id = draw and player = (to_jsonb(dr) ->> 'forced')::uuid;
  end if;
  if pick.id is not null then null;
  elsif cfg ->> 'mode' = 'equal' then
    select * into pick from public.lotto_tickets where draw_id = draw order by random() limit 1;
  else
    x := random() * tot;
    select t.id, t.draw_id, t.player, t.name, t.cost, t.payout, t.claimed, t.created_at into pick
      from (select *, sum(cost) over (order by id) as run from public.lotto_tickets where draw_id = draw) t
      where t.run > x order by t.run limit 1;
    if pick.id is null then select * into pick from public.lotto_tickets where draw_id = draw order by id desc limit 1; end if;
  end if;
  update public.lotto_tickets set payout = case when id = pick.id then v_pot else 0 end where draw_id = draw;
  -- the winner gets the pot right away, online or not
  update public.players set credits = least(9007199254740991, credits + v_pot), admin_rev = admin_rev + 1, updated_at = now() where id = pick.player;
  update public.lotto_tickets set claimed = true where draw_id = draw;
  update public.lotto_draws set settled = true, pot = v_pot, tickets = n, winner = pick.player, winner_name = pick.name, winner_cost = pick.cost
    where id = draw;
end;
$$;

create or replace function public.admin_rig_lotto(draw text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.admin_me() then raise exception 'not allowed'; end if;
  if not coalesce((select (data ->> 'cheats')::boolean from public.settings where id = 1), true) then raise exception 'cheats are off'; end if;
  if not exists (select 1 from public.lotto_tickets where draw_id = draw and player = auth.uid()) then raise exception 'no ticket'; end if;
  update public.lotto_draws set forced = auth.uid() where id = draw and not settled;
end;
$$;
revoke execute on function public.admin_rig_lotto(text) from public, anon;
grant execute on function public.admin_rig_lotto(text) to authenticated;


-- ---------------------------------------------------------------------------
-- Rocket cheat: golden rocket: run this part once (after "Admin cheats switch"). The admin secret code
-- makes the next rocket a golden one (it surely flies past 30×) instead of sending it straight to the moon.
create or replace function public.admin_rig_rocket(round bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c numeric := least(200, floor(30 / (1 - random()) * 100) / 100);
begin
  if not public.admin_me() then raise exception 'not allowed'; end if;
  if not coalesce((select (data ->> 'cheats')::boolean from public.settings where id = 1), true) then raise exception 'cheats are off'; end if;
  update public.rocket_rounds set golden = true, crash = c, crash_at = launch + round(40000 * ln(c) / ln(200)),
      next_start = launch + round(40000 * ln(c) / ln(200)) + case when c >= 200 then 9000 else 5000 end
    where id = round and public.horse_now_ms() < launch;
end;
$$;


-- ---------------------------------------------------------------------------
-- Affiliate settings: run this part once (after "Affiliate codes"). The admin menu's Affiliates tab sets
-- what a new player and the code owner get; the code is redeemed with these numbers from the settings.
create or replace function public.affiliate_redeem(code text, dev text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c text := upper(trim(code));
  s jsonb := coalesce((select data from public.settings where id = 1), '{}');
  one_device boolean := coalesce((s ->> 'affOneDevice')::boolean, true);
  new_bonus bigint := greatest(0, least(1000000, coalesce((s ->> 'affNew')::numeric, 4500)))::bigint;
  pct numeric := greatest(0, least(100, coalesce((s ->> 'affPct')::numeric, 5)));
  cap bigint := greatest(0, coalesce((s ->> 'affMax')::numeric, 10000))::bigint;
  fixed bigint := greatest(0, least(1000000, coalesce((s ->> 'affFixed')::numeric, 0)))::bigint;
  me public.players;
  aff public.players;
  bonus bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if not coalesce((s ->> 'affOn')::boolean, true) then raise exception 'codes are off'; end if;
  if exists (select 1 from public.affiliate_uses where new_player = auth.uid()) then raise exception 'code already used'; end if;
  if (select created_at from auth.users where id = auth.uid()) < now() - interval '30 minutes' then raise exception 'only for new accounts'; end if;
  if dev is null or length(dev) not between 8 and 64 then raise exception 'reload the page'; end if;
  if one_device and (exists (select 1 from public.player_devices d where d.device = dev and d.player <> auth.uid())
     or exists (select 1 from public.affiliate_uses u where u.device = dev)) then raise exception 'device already has an account'; end if;
  select * into aff from public.players where affiliate_code = c for update;
  if aff.id is null or aff.is_banned then raise exception 'no such code'; end if;
  if aff.id = auth.uid() then raise exception 'not your own code'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  -- the set share of the code owner's credits (up to the limit, 0 = no limit), plus the fixed extra
  bonus := floor(greatest(aff.credits, 0) * pct / 100)::bigint;
  if cap > 0 then bonus := least(cap, bonus); end if;
  bonus := bonus + fixed;
  update public.players set credits = credits + bonus, admin_rev = admin_rev + 1, updated_at = now() where id = aff.id;
  update public.players set credits = credits + new_bonus, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  -- the unique device index allows a device only once, so without the device rule it is not stored
  insert into public.affiliate_uses (new_player, new_name, affiliate, code, bonus, device)
    values (me.id, me.name, aff.id, c, bonus, case when one_device then dev end);
  insert into public.player_devices (device, player) values (dev, me.id) on conflict do nothing;
  return jsonb_build_object('credits', me.credits + new_bonus, 'rev', me.admin_rev + 1, 'affiliate', aff.name);
end;
$$;
revoke execute on function public.affiliate_redeem(text, text) from public, anon;
grant execute on function public.affiliate_redeem(text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Gifts only from level 3: run this part once (after "Sending credits" and "Lotto"). Credits can only be sent
-- to players who reached level 3 (or went Prestige), the same rule as for sending.
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
  -- While lotto tickets are on sale, nobody can move credits: the ticket price depends on everyone's balance.
  if public.lotto_selling() then raise exception 'lotto sales running'; end if;
  if target = auth.uid() then raise exception 'cannot send to yourself'; end if;
  if amount is null or amount < 1 then raise exception 'send at least 1'; end if;
  -- Lock both rows in a fixed order so two gifts at once can't deadlock.
  perform 1 from public.players where id in (auth.uid(), target) order by id for update;
  select * into me from public.players where id = auth.uid();
  select * into them from public.players where id = target;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if them is null or them.is_banned then raise exception 'no such player'; end if;
  if me.level < 3 and me.prestige = 0 then raise exception 'reach level 3 first'; end if;
  if them.level < 3 and them.prestige = 0 then raise exception 'recipient below level 3'; end if;
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
-- Lotto without cheats: run this part once (after "Admin cheats switch"). Nobody can pick the lotto winner,
-- not even an admin: the cheat function goes, a winner picked before is forgotten, and the draw is always random.
drop function if exists public.admin_rig_lotto(text);
alter table public.lotto_draws drop column if exists forced;
create or replace function public.lotto_settle(draw text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dr public.lotto_draws;
  cfg jsonb := public.lotto_cfg();
  n integer;
  tot numeric;
  v_pot bigint;
  pick public.lotto_tickets;
  x numeric;
begin
  select * into dr from public.lotto_draws where id = draw for update;
  if dr.id is null or dr.settled or now() < dr.draw_at then return; end if;
  select count(*), coalesce(sum(cost), 0) into n, tot from public.lotto_tickets where draw_id = draw;
  if n = 0 then
    update public.lotto_draws set settled = true, pot = 0, tickets = 0 where id = draw;
    return;
  end if;
  v_pot := floor(tot * (cfg ->> 'share')::numeric / 100)::bigint + (cfg ->> (dr.kind || 'Bonus'))::bigint;
  if cfg ->> 'mode' = 'equal' then
    select * into pick from public.lotto_tickets where draw_id = draw order by random() limit 1;
  else
    x := random() * tot;
    select t.id, t.draw_id, t.player, t.name, t.cost, t.payout, t.claimed, t.created_at into pick
      from (select *, sum(cost) over (order by id) as run from public.lotto_tickets where draw_id = draw) t
      where t.run > x order by t.run limit 1;
    if pick.id is null then select * into pick from public.lotto_tickets where draw_id = draw order by id desc limit 1; end if;
  end if;
  update public.lotto_tickets set payout = case when id = pick.id then v_pot else 0 end where draw_id = draw;
  -- the winner gets the pot right away, online or not
  update public.players set credits = least(9007199254740991, credits + v_pot), admin_rev = admin_rev + 1, updated_at = now() where id = pick.player;
  update public.lotto_tickets set claimed = true where draw_id = draw;
  update public.lotto_draws set settled = true, pot = v_pot, tickets = n, winner = pick.player, winner_name = pick.name, winner_cost = pick.cost
    where id = draw;
end;
$$;


-- ---------------------------------------------------------------------------
-- Admin: player passwords: run this part once (after "Admin security"). An admin can give a player who
-- forgot their password a new one. The player is signed out on their devices and signs in with the new one.
create or replace function public.admin_set_password(tok uuid, target uuid, new_pw text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.admin_check(tok);
  if new_pw is null or length(new_pw) < 6 then raise exception 'password too short'; end if;
  if target = auth.uid() then raise exception 'change your own password in your profile'; end if;
  if not exists (select 1 from public.players where id = target) then raise exception 'no such player'; end if;
  update auth.users set encrypted_password = crypt(new_pw, gen_salt('bf')) where id = target;
  -- end the player's open sessions so the old password is really gone
  if to_regclass('auth.sessions') is not null then execute 'delete from auth.sessions where user_id = $1' using target; end if;
  if to_regclass('auth.refresh_tokens') is not null then execute 'delete from auth.refresh_tokens where user_id = $1::text' using target; end if;
end;
$$;
revoke execute on function public.admin_set_password(uuid, uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Lucky Burger career is kept: run this part once (after "Economy rework"). A page that is behind (an
-- old tab or another device) can no longer save a lower Lucky Burger career over a higher one; the
-- database keeps the higher numbers and makes that page load them. "Start over" still resets it.
create or replace function public.players_keep_job()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  o jsonb;
  n jsonb;
  oj jsonb;
  nj jsonb;
  k text;
  fixed boolean := false;
begin
  if current_user <> 'authenticated' or new.game is null or old.game is null then return new; end if;
  begin
    o := old.game::jsonb;
    n := new.game::jsonb;
    oj := o -> 'job';
    if oj is null or jsonb_typeof(oj) <> 'object' then return new; end if;
    -- "Start over" marks the save with a newer jobReset
    if coalesce((n ->> 'jobReset')::numeric, 0) > coalesce((o ->> 'jobReset')::numeric, 0) then return new; end if;
    nj := case when jsonb_typeof(n -> 'job') = 'object' then n -> 'job' else '{}'::jsonb end;
    foreach k in array array['worked', 'earned', 'shifts', 'pos'] loop
      if coalesce((oj ->> k)::numeric, 0) > coalesce((nj ->> k)::numeric, 0) then
        nj := jsonb_set(nj, array[k], oj -> k);
        fixed := true;
      end if;
    end loop;
  exception when others then return new;
  end;
  if fixed then
    new.game := jsonb_set(n, '{job}', nj)::text;
    -- the page that sent the old numbers reloads from the database
    new.admin_rev := greatest(new.admin_rev, old.admin_rev + 1);
  end if;
  return new;
end;
$$;
drop trigger if exists players_keep_job on public.players;
create trigger players_keep_job before update on public.players for each row execute function public.players_keep_job();


-- ---------------------------------------------------------------------------
-- Admin: Lucky Burger career: run this part once (after "Lucky Burger career is kept"). The admin menu
-- can set a player's Lucky Burger position (up or down). The save gets a newer jobReset mark, so the
-- player's page takes the new career, and a page that hasn't seen it yet can't save the old one back.
create or replace function public.admin_set_job(tok uuid, target uuid, new_worked integer, new_pos integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  g jsonb;
begin
  perform public.admin_check(tok);
  if new_worked is null or new_worked < 0 or new_worked > 10000000 or new_pos is null or new_pos < 0 or new_pos > 7 then raise exception 'bad career'; end if;
  select game::jsonb into g from public.players where id = target for update;
  if not found then raise exception 'no such player'; end if;
  if g is null then raise exception 'no save yet'; end if;
  g := jsonb_set(g, '{job}', coalesce(case when jsonb_typeof(g -> 'job') = 'object' then g -> 'job' end, '{}'::jsonb)
    || jsonb_build_object('worked', new_worked, 'pos', new_pos));
  g := jsonb_set(g, '{jobReset}', to_jsonb(floor(extract(epoch from clock_timestamp()) * 1000)::bigint));
  update public.players set game = g::text, admin_rev = admin_rev + 1, updated_at = now() where id = target;
end;
$$;
revoke execute on function public.admin_set_job(uuid, uuid, integer, integer) from public, anon;
grant execute on function public.admin_set_job(uuid, uuid, integer, integer) to authenticated;

create or replace function public.players_keep_job()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  o jsonb;
  n jsonb;
  oj jsonb;
  nj jsonb;
  k text;
  om numeric;
  nm numeric;
  fixed boolean := false;
begin
  if current_user <> 'authenticated' or new.game is null or old.game is null then return new; end if;
  begin
    o := old.game::jsonb;
    n := new.game::jsonb;
    oj := o -> 'job';
    if oj is null or jsonb_typeof(oj) <> 'object' then return new; end if;
    om := coalesce((o ->> 'jobReset')::numeric, 0);
    nm := coalesce((n ->> 'jobReset')::numeric, 0);
    -- "Start over" on the page: a newer mark, the lower career goes through
    if nm > om then return new; end if;
    if nm < om then
      -- the page hasn't seen what an admin set yet: the admin's career stays
      n := jsonb_set(jsonb_set(n, '{job}', oj), '{jobReset}', o -> 'jobReset');
      fixed := true;
    else
      nj := case when jsonb_typeof(n -> 'job') = 'object' then n -> 'job' else '{}'::jsonb end;
      foreach k in array array['worked', 'earned', 'shifts', 'pos'] loop
        if coalesce((oj ->> k)::numeric, 0) > coalesce((nj ->> k)::numeric, 0) then
          nj := jsonb_set(nj, array[k], oj -> k);
          fixed := true;
        end if;
      end loop;
      if fixed then n := jsonb_set(n, '{job}', nj); end if;
    end if;
  exception when others then return new;
  end;
  if fixed then
    new.game := n::text;
    -- the page that sent the old numbers reloads from the database
    new.admin_rev := greatest(new.admin_rev, old.admin_rev + 1);
  end if;
  return new;
end;
$$;


-- ---------------------------------------------------------------------------
-- Database speed-up: run this part once (after "Economy rework"). With many players online, every page
-- asked the database to settle finished rounds every few seconds, and all of them waited in one queue for
-- each other; the search for unsettled bets also read every bet ever placed. Now the pages don't wait for
-- each other and indexes find the open bets directly.
create index if not exists horse_bets_unsettled on public.horse_bets (race_id) where payout is null;
create index if not exists roulette_bets_unsettled on public.roulette_bets (round_id) where payout is null;
create index if not exists rocket_bets_unsettled on public.rocket_bets (round_id) where payout is null;
create index if not exists lotto_draws_unsettled on public.lotto_draws (draw_at) where not settled;
create or replace function public.lr_sweep()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  now_ms bigint := public.horse_now_ms();
  x bigint;
  d text;
begin
  -- only one page at a time does the sweep; the others go on right away instead of queueing behind it
  perform 1 from public.lr_sweep_at where id = 1 and at < now() - interval '2 seconds' for update skip locked;
  if not found then return; end if;
  update public.lr_sweep_at set at = now() where id = 1;
  for x in select distinct race_id from public.horse_bets where payout is null and race_id * 180000 + 120000 <= now_ms limit 20 loop
    perform public.horse_settle(x);
  end loop;
  for x in select distinct round_id from public.roulette_bets where payout is null and round_id * 45000 + 34000 <= now_ms limit 20 loop
    perform public.roulette_settle(x);
  end loop;
  for x in select distinct b.round_id from public.rocket_bets b join public.rocket_rounds r on r.id = b.round_id
      where b.payout is null and r.crash_at <= now_ms limit 20 loop
    perform public.rocket_settle(x);
  end loop;
  if to_regclass('public.lotto_draws') is not null then
    for d in select id from public.lotto_draws where not settled and draw_at <= now() limit 5 loop
      perform public.lotto_settle(d);
    end loop;
  end if;
end;
$$;
revoke execute on function public.lr_sweep() from public, anon, authenticated;
analyze public.horse_bets;
analyze public.roulette_bets;
analyze public.rocket_bets;


-- ---------------------------------------------------------------------------
-- FIX for the Lucky Burger career trigger: run this part once (after "Admin: Lucky Burger career").
-- The earlier version made the page reload after every save it corrected. With Night School the page
-- rounded the time worked down (12.5 s per paycheck), so it sent a tiny bit less every time: correct,
-- reload, save, correct, ... in an endless loop that flooded the database. Now the trigger only keeps
-- the higher career quietly and never makes the page reload, and small differences are left alone.
create or replace function public.players_keep_job()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  o jsonb;
  n jsonb;
  oj jsonb;
  nj jsonb;
  om numeric;
  nm numeric;
begin
  if current_user <> 'authenticated' or new.game is null or old.game is null then return new; end if;
  begin
    o := old.game::jsonb;
    oj := o -> 'job';
    if oj is null or jsonb_typeof(oj) <> 'object' then return new; end if;
    n := new.game::jsonb;
    om := coalesce((o ->> 'jobReset')::numeric, 0);
    nm := coalesce((n ->> 'jobReset')::numeric, 0);
    -- "Start over" on the page: a newer mark, the lower career goes through
    if nm > om then return new; end if;
    nj := case when jsonb_typeof(n -> 'job') = 'object' then n -> 'job' else '{}'::jsonb end;
    if nm < om
       or coalesce((oj ->> 'pos')::numeric, 0) > coalesce((nj ->> 'pos')::numeric, 0)
       or coalesce((oj ->> 'worked')::numeric, 0) > coalesce((nj ->> 'worked')::numeric, 0) + 60 then
      -- an old page: the career in the database stays (with an admin's mark, if any)
      n := jsonb_set(n, '{job}', oj);
      if o ? 'jobReset' then n := jsonb_set(n, '{jobReset}', o -> 'jobReset'); end if;
      new.game := n::text;
    end if;
  exception when others then return new;
  end;
  return new;
end;
$$;
drop trigger if exists players_keep_job on public.players;
create trigger players_keep_job before update on public.players for each row execute function public.players_keep_job();


-- ---------------------------------------------------------------------------
-- Database load: run this part once. The pages no longer get a live feed of the players table (they ask
-- every few seconds instead): with the feed, every save of every player was sent to every page, which then
-- reloaded the whole player list, so the work grew with the square of the players online.
do $$
begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'players') then
    alter publication supabase_realtime drop table public.players;
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- Admin name: run this part once (after "Shop: name styles and trophies"). Allows the red admin name
-- style, and only on admins: anyone else who sends it gets no name style.
alter table public.players drop constraint if exists players_flair_check;
alter table public.players add constraint players_flair_check
  check (flair is null or flair in ('neon', 'gold', 'fire', 'ice', 'galaxy', 'admin'));

create or replace function public.players_admin_flair()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.flair = 'admin' and not new.is_admin then new.flair := null; end if;
  return new;
end;
$$;
drop trigger if exists players_admin_flair on public.players;
create trigger players_admin_flair before insert or update on public.players for each row execute function public.players_admin_flair();


-- ---------------------------------------------------------------------------
-- Suspicious jumps: run this part once (after "Economy rework" and "Admin security"). Every save a page
-- sends itself is checked; jumps in credits that are too big for the player's bet limit and don't come
-- from a jackpot are written to a list the admin menu shows. Winnings the database pays itself (horses,
-- roulette, rocket, lotto, stocks) and admin changes are not checked. Nothing is blocked, only noted.
create table if not exists public.lr_suspicious (
  id bigint generated always as identity primary key,
  player uuid not null references public.players (id) on delete cascade,
  name text not null,
  at timestamptz not null default now(),
  reason text not null,
  gain bigint not null,
  before bigint not null,
  after bigint not null,
  bet_limit bigint not null,
  game text,
  spins integer,
  jackpots integer
);
create index if not exists lr_suspicious_at on public.lr_suspicious (at desc);
alter table public.lr_suspicious enable row level security;
revoke all on public.lr_suspicious from anon, authenticated;
-- the check runs as the player who saves, so they may add rows about themselves only (and read none)
grant insert on public.lr_suspicious to authenticated;
drop policy if exists "Note own saves" on public.lr_suspicious;
create policy "Note own saves" on public.lr_suspicious for insert to authenticated with check (player = auth.uid());

-- credits won in the last 10 minutes (without jackpots), kept on the player row
alter table public.players add column if not exists watch_from timestamptz;
alter table public.players add column if not exists watch_gain bigint not null default 0;
alter table public.players add column if not exists watch_noted boolean not null default false;

create or replace function public.players_watch()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  gain bigint := new.credits - old.credits;
  lim bigint;
  jp boolean := coalesce(new.jackpots, 0) > coalesce(old.jackpots, 0);
  g text;
  why text;
begin
  if current_user <> 'authenticated' or new.id <> auth.uid() then return new; end if;
  lim := public.lr_bet_limit(old.level, old.prestige);
  begin g := new.game::jsonb ->> 'mode'; exception when others then g := null; end;
  -- one save: more than 60x the bet limit (a jackpot may bring far more)
  if not jp and gain > greatest(lim * 60, 30000) then why := 'big jump';
  elsif jp and gain > greatest(lim * 6000, 3000000) then why := 'jackpot too big';
  end if;
  -- 10 minutes: more than 300x the bet limit in total, jackpots not counted
  if new.watch_from is null or new.watch_from < now() - interval '10 minutes' then
    new.watch_from := now(); new.watch_gain := 0; new.watch_noted := false;
  end if;
  -- a jump already noted on its own doesn't count again, and a jackpot save is never "fast growth"
  if not jp and why is null and gain > 0 then new.watch_gain := new.watch_gain + gain; end if;
  if why is null and not jp and not new.watch_noted and new.watch_gain > greatest(lim * 300, 150000) then
    why := 'fast growth'; new.watch_noted := true;
  end if;
  if why is not null then
    insert into public.lr_suspicious (player, name, reason, gain, before, after, bet_limit, game, spins, jackpots)
      values (new.id, new.name, why, case when why = 'fast growth' then new.watch_gain else gain end, old.credits, new.credits, lim, g,
        coalesce(new.spins, 0) - coalesce(old.spins, 0), coalesce(new.jackpots, 0) - coalesce(old.jackpots, 0));
  end if;
  return new;
exception when others then return new;
end;
$$;
drop trigger if exists players_watch on public.players;
create trigger players_watch before update on public.players for each row execute function public.players_watch();

create or replace function public.admin_suspicious(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  out jsonb;
begin
  perform public.admin_check(tok);
  delete from public.lr_suspicious where at < now() - interval '30 days';
  select coalesce(jsonb_agg(to_jsonb(s) order by s.at desc), '[]') into out
    from (select * from public.lr_suspicious order by at desc limit 300) s;
  return out;
end;
$$;
revoke execute on function public.admin_suspicious(uuid) from public, anon;
grant execute on function public.admin_suspicious(uuid) to authenticated;

create or replace function public.admin_suspicious_clear(tok uuid, entry bigint default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if entry is null then delete from public.lr_suspicious; else delete from public.lr_suspicious where id = entry; end if;
end;
$$;
revoke execute on function public.admin_suspicious_clear(uuid, bigint) from public, anon;
grant execute on function public.admin_suspicious_clear(uuid, bigint) to authenticated;


-- ---------------------------------------------------------------------------
-- Russian roulette: run this part once (after "Stock market" and "Bet limits by level"). Two players, one
-- revolver with six chambers and one live round. They take turns pulling the trigger; whoever gets the live
-- round loses everything to the other: credits, goodies and shares, and starts again from the start (like an
-- admin reset). Everything happens here in the database, the pages only show it. Each player can play once
-- per day (German time), from level 3 (or Prestige). A turn left alone for 45 seconds counts as lost.
create table if not exists public.rr_games (
  id bigint generated always as identity primary key,
  challenger uuid not null references public.players (id) on delete cascade,
  opponent uuid not null references public.players (id) on delete cascade,
  c_name text not null,
  o_name text not null,
  status text not null default 'pending' check (status in ('pending', 'active', 'done', 'declined', 'expired', 'cancelled')),
  bullet smallint,
  shot smallint not null default 0,
  turn uuid,
  turn_at timestamptz,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz,
  winner uuid,
  loser uuid,
  reason text,
  pot_credits bigint,
  pot_goodies integer
);
create index if not exists rr_games_open on public.rr_games (status) where status in ('pending', 'active');
create index if not exists rr_games_players on public.rr_games (challenger, opponent, created_at desc);
alter table public.rr_games enable row level security;
revoke all on public.rr_games from anon, authenticated;

create or replace function public.rr_day(t timestamptz) returns date language sql stable as $$ select (t at time zone 'Europe/Berlin')::date $$;

-- played today = a game that started today (declined or expired challenges don't count)
create or replace function public.rr_played_today(p uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.rr_games where (challenger = p or opponent = p) and started_at is not null and public.rr_day(started_at) = public.rr_day(now()))
$$;
revoke execute on function public.rr_played_today(uuid) from public, anon, authenticated;

-- the loser's credits, goodies and shares go to the winner, the loser starts over
create or replace function public.rr_settle(g public.rr_games, lose uuid, why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  win uuid := case when lose = g.challenger then g.opponent else g.challenger end;
  w public.players;
  l public.players;
  wg jsonb;
  wo jsonb;
  lo jsonb;
  k text;
  v jsonb;
  moved integer := 0;
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform 1 from public.players where id in (win, lose) order by id for update;
  select * into w from public.players where id = win;
  select * into l from public.players where id = lose;
  begin wg := coalesce(w.game::jsonb, '{}'::jsonb); exception when others then wg := '{}'::jsonb; end;
  begin lo := coalesce(l.game::jsonb -> 'owned', '{}'::jsonb); exception when others then lo := '{}'::jsonb; end;
  wo := case when jsonb_typeof(wg -> 'owned') = 'object' then wg -> 'owned' else '{}'::jsonb end;
  if jsonb_typeof(lo) = 'object' then
    for k, v in select * from jsonb_each(lo) loop
      if jsonb_typeof(v) = 'number' and (v #>> '{}')::numeric > 0 then
        if coalesce((wo ->> k)::numeric, 0) < (v #>> '{}')::numeric then wo := jsonb_set(wo, array[k], v); moved := moved + 1; end if;
      elsif v = 'true'::jsonb then
        if coalesce(wo -> k, 'false'::jsonb) <> 'true'::jsonb then wo := jsonb_set(wo, array[k], 'true'::jsonb); moved := moved + 1; end if;
      end if;
    end loop;
  end if;
  wg := jsonb_set(wg, '{owned}', wo);
  -- the winner's page takes over the goodies when it sees this mark
  wg := jsonb_set(wg, '{rrAt}', to_jsonb(floor(extract(epoch from clock_timestamp()) * 1000)::bigint));
  update public.players set credits = least(9007199254740991, credits + greatest(l.credits, 0)), game = wg::text,
    admin_rev = admin_rev + 1, updated_at = now() where id = win;
  -- shares change hands too
  if to_regclass('public.stock_holdings') is not null then
    insert into public.stock_holdings (player, stock, name, shares, cost)
      select win, stock, w.name, shares, cost from public.stock_holdings where player = lose
      on conflict (player, stock) do update set shares = public.stock_holdings.shares + excluded.shares, cost = public.stock_holdings.cost + excluded.cost;
    delete from public.stock_holdings where player = lose;
  end if;
  update public.players set credits = start_credits, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null, prestige = 0,
    admin_rev = admin_rev + 1, updated_at = now() where id = lose;
  update public.rr_games set status = 'done', ended_at = now(), winner = win, loser = lose, reason = why,
    pot_credits = greatest(l.credits, 0), pot_goodies = moved where id = g.id;
end;
$$;
revoke execute on function public.rr_settle(public.rr_games, uuid, text) from public, anon, authenticated;

-- old challenges run out, a turn left alone too long is lost
create or replace function public.rr_tidy(p uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  g public.rr_games;
begin
  update public.rr_games set status = 'expired', ended_at = now() where status = 'pending' and created_at < now() - interval '90 seconds';
  for g in select * from public.rr_games where status = 'active' and (challenger = p or opponent = p) and turn_at < now() - interval '45 seconds' for update loop
    perform public.rr_settle(g, g.turn, 'timeout');
  end loop;
end;
$$;
revoke execute on function public.rr_tidy(uuid) from public, anon, authenticated;

create or replace function public.rr_view(g public.rr_games) returns jsonb language sql stable as $$
  select case when g.id is null then null else jsonb_build_object('id', g.id, 'status', g.status, 'challenger', g.challenger, 'opponent', g.opponent,
    'c_name', g.c_name, 'o_name', g.o_name, 'shot', g.shot, 'turn', g.turn, 'turn_at', floor(extract(epoch from g.turn_at) * 1000),
    'created_at', floor(extract(epoch from g.created_at) * 1000), 'winner', g.winner, 'loser', g.loser, 'reason', g.reason,
    'pot_credits', g.pot_credits, 'pot_goodies', g.pot_goodies, 'ended_at', floor(extract(epoch from g.ended_at) * 1000),
    -- where the live round was: only once it's over
    'bullet', case when g.status = 'done' then g.bullet end) end
$$;

create or replace function public.rr_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  g public.rr_games;
  last public.rr_games;
begin
  if me is null then raise exception 'not allowed'; end if;
  perform public.rr_tidy(me);
  select * into g from public.rr_games where status in ('pending', 'active') and (challenger = me or opponent = me) order by id desc limit 1;
  select * into last from public.rr_games where status in ('done', 'declined', 'expired', 'cancelled') and (challenger = me or opponent = me)
    and coalesce(ended_at, created_at) > now() - interval '3 minutes' order by id desc limit 1;
  return jsonb_build_object('now', floor(extract(epoch from clock_timestamp()) * 1000), 'played', public.rr_played_today(me),
    'busy', coalesce((select jsonb_agg(x) from (select challenger as x from public.rr_games where status in ('pending', 'active') union select opponent from public.rr_games where status in ('pending', 'active')) s), '[]'::jsonb),
    'today', coalesce((select jsonb_agg(x) from (select challenger as x from public.rr_games where started_at is not null and public.rr_day(started_at) = public.rr_day(now())
      union select opponent from public.rr_games where started_at is not null and public.rr_day(started_at) = public.rr_day(now())) s), '[]'::jsonb),
    'game', public.rr_view(g), 'last', public.rr_view(last));
end;
$$;

create or replace function public.rr_challenge(target uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.players;
  them public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  perform public.rr_tidy(auth.uid());
  select * into me from public.players where id = auth.uid();
  select * into them from public.players where id = target;
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  if them.id is null or them.is_banned or them.id = me.id then raise exception 'no such player'; end if;
  if (me.level < 3 and me.prestige = 0) or (them.level < 3 and them.prestige = 0) then raise exception 'level 3 first'; end if;
  if public.rr_played_today(me.id) or public.rr_played_today(them.id) then raise exception 'played today'; end if;
  if exists (select 1 from public.rr_games where status in ('pending', 'active') and (challenger in (me.id, them.id) or opponent in (me.id, them.id))) then raise exception 'busy'; end if;
  insert into public.rr_games (challenger, opponent, c_name, o_name) values (me.id, them.id, me.name, them.name);
  return public.rr_state();
end;
$$;

create or replace function public.rr_respond(game bigint, accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  g public.rr_games;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  perform public.rr_tidy(auth.uid());
  select * into g from public.rr_games where id = game for update;
  if g.id is null or g.status <> 'pending' then raise exception 'gone'; end if;
  if auth.uid() = g.challenger and not accept then
    update public.rr_games set status = 'cancelled', ended_at = now() where id = g.id;
  elsif auth.uid() <> g.opponent then raise exception 'not allowed';
  elsif not accept then
    update public.rr_games set status = 'declined', ended_at = now() where id = g.id;
  else
    if public.rr_played_today(g.challenger) or public.rr_played_today(g.opponent) then raise exception 'played today'; end if;
    -- the cylinder is spun once: one live round in six chambers; who starts is a coin toss
    update public.rr_games set status = 'active', started_at = now(), bullet = 1 + floor(random() * 6)::smallint, shot = 0,
      turn = case when random() < 0.5 then g.challenger else g.opponent end, turn_at = now() where id = g.id;
  end if;
  return public.rr_state();
end;
$$;

create or replace function public.rr_pull(game bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  g public.rr_games;
  bang boolean;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  perform public.rr_tidy(auth.uid());
  select * into g from public.rr_games where id = game for update;
  if g.id is null or g.status <> 'active' then raise exception 'gone'; end if;
  if g.turn <> auth.uid() then raise exception 'not your turn'; end if;
  bang := g.shot + 1 = g.bullet;
  update public.rr_games set shot = shot + 1, turn = case when bang then turn when turn = challenger then opponent else challenger end, turn_at = now()
    where id = g.id returning * into g;
  if bang then perform public.rr_settle(g, auth.uid(), 'shot'); end if;
  return public.rr_state();
end;
$$;

revoke execute on function public.rr_state() from public, anon;
revoke execute on function public.rr_challenge(uuid) from public, anon;
revoke execute on function public.rr_respond(bigint, boolean) from public, anon;
revoke execute on function public.rr_pull(bigint) from public, anon;
grant execute on function public.rr_state() to authenticated;
grant execute on function public.rr_challenge(uuid) to authenticated;
grant execute on function public.rr_respond(bigint, boolean) to authenticated;
grant execute on function public.rr_pull(bigint) to authenticated;


-- ---------------------------------------------------------------------------
-- No cheat code any more: run this part once. The admin secret code is gone from the game; here go the
-- database functions it used and the places where a forced result was kept, so horses, roulette, rocket and
-- lotto can only ever be drawn at random.
drop function if exists public.admin_rig_horse(bigint, integer);
drop function if exists public.admin_rig_roulette(bigint);
drop function if exists public.admin_rig_rocket(bigint);
drop function if exists public.admin_rig_lotto(text);
alter table public.horse_races drop column if exists forced;
alter table public.roulette_rounds drop column if exists forced;
do $$ begin
  if to_regclass('public.lotto_draws') is not null then alter table public.lotto_draws drop column if exists forced; end if;
end $$;
update public.settings set data = data - 'cheats' where id = 1;


-- ---------------------------------------------------------------------------
-- Russian roulette: 2 minutes to answer: run this part once (after "Russian roulette"). A challenge now
-- waits 2 minutes instead of 90 seconds for an answer.
create or replace function public.rr_tidy(p uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  g public.rr_games;
begin
  update public.rr_games set status = 'expired', ended_at = now() where status = 'pending' and created_at < now() - interval '2 minutes';
  for g in select * from public.rr_games where status = 'active' and (challenger = p or opponent = p) and turn_at < now() - interval '45 seconds' for update loop
    perform public.rr_settle(g, g.turn, 'timeout');
  end loop;
end;
$$;
revoke execute on function public.rr_tidy(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- Jackpots are kept, saves in order: run this part once (after "Economy rework" and "Suspicious jumps").
-- 1) The save check cut big wins: one save could add at most 6,000x the bet limit. A jackpot with the
--    horseshoes, free spins, lightning and an event or happy hour can bring more, and the page then took
--    the cut balance and the player lost the jackpot. The limit now grows with the happy hour and running
--    events, and a save with a jackpot may bring far more.
-- 2) A page that is behind (an old tab or another device) could save its older credits and level over the
--    newer ones. Every save now counts up save_seq; a page whose count is behind reloads instead.
alter table public.players add column if not exists save_seq bigint not null default 0;
grant update (save_seq) on public.players to authenticated;

-- how much the wins are multiplied right now: happy hour times the strongest running event
create or replace function public.lr_win_boost()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with s as (select coalesce(data, '{}'::jsonb) as d from public.settings where id = 1),
  now_ms as (select floor(extract(epoch from now()) * 1000) as t)
  select greatest(1, coalesce((select (d ->> 'winMultiplier')::numeric from s), 1))
    * greatest(1, least(20, coalesce((
        select max(greatest(1, coalesce((e -> 'fx' -> 'mult' ->> 'all')::numeric, 1))
          * greatest(1, coalesce((select max(v::numeric) from jsonb_each_text(case when jsonb_typeof(e -> 'fx' -> 'mult') = 'object' then e -> 'fx' -> 'mult' else '{}'::jsonb end) x(k, v) where k <> 'all'), 1)))
        from s, now_ms, jsonb_array_elements(case when jsonb_typeof(d -> 'events') = 'array' then d -> 'events' else '[]'::jsonb end) e
        where (e ->> 'start')::numeric <= now_ms.t and (e ->> 'end')::numeric > now_ms.t), 1)))
$$;

create or replace function public.players_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  lim bigint;
  boost numeric;
  cap numeric;
  jp_pay numeric;
  cut boolean := false;
begin
  if current_user <> 'authenticated' then return new; end if;
  if new.level > old.level + 2 then new.level := old.level + 2; cut := true; end if;
  if new.prestige > old.prestige and (new.prestige > old.prestige + 1 or old.level < 20) then
    new.prestige := old.prestige; new.level := greatest(new.level, old.level); cut := true;
  end if;
  lim := public.lr_bet_limit(old.level, old.prestige);
  begin boost := public.lr_win_boost(); exception when others then boost := 1; end;
  cap := lim * 6000 * boost + 250000;
  if coalesce(new.jackpots, 0) > coalesce(old.jackpots, 0) then
    -- three sevens: the jackpot pay plus 8 per horseshoe, the free spin multiplier, win streak up to x1.5, lightning up to x10
    jp_pay := coalesce((select (data ->> 'jackpotPay')::numeric from public.settings where id = 1), 150) + 24;
    cap := greatest(cap, lim * jp_pay * greatest(2, coalesce((select (data ->> 'freeMult')::numeric from public.settings where id = 1), 2)) * 1.5 * 10 * boost
      * (new.jackpots - old.jackpots) * 1.2 + 250000);
  end if;
  if new.credits > old.credits + cap then new.credits := old.credits + floor(cap)::bigint; cut := true; end if;
  -- a cut save also makes the page reload the balance from the database
  if cut then new.capped_saves := old.capped_saves + 1; new.admin_rev := old.admin_rev + 1; end if;
  return new;
end;
$$;
drop trigger if exists players_guard on public.players;
create trigger players_guard before update on public.players for each row execute function public.players_guard();


-- ---------------------------------------------------------------------------
-- Old pages may not save any more: run this part once (after "Jackpots are kept, saves in order"). A page
-- that has not been reloaded since the save order came in doesn't count save_seq up and could still save an
-- older game over a newer one (a phone with the game open in the background, for example). Such a save is
-- now refused; the page has to be reloaded. Tip: the admin menu's "Ask everyone to reload" button.
create or replace function public.players_seq()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user = 'authenticated' and new.save_seq <= old.save_seq then
    raise exception 'old page: reload the page to keep playing';
  end if;
  return new;
end;
$$;
drop trigger if exists players_seq on public.players;
create trigger players_seq before update on public.players for each row execute function public.players_seq();


-- ---------------------------------------------------------------------------
-- Milestones: run this part once. Notes the moment each player first has 1 million, 10 million,
-- 100 million and 1 billion credits, on every change of the balance (also payouts by the database).
-- Players who are already above a mark when this runs are noted as "already above" without a time.
create table if not exists public.lr_milestones (
  player uuid not null references public.players (id) on delete cascade,
  mark bigint not null,
  name text not null,
  reached_at timestamptz not null default now(),
  credits bigint not null,
  before_start boolean not null default false,
  primary key (player, mark)
);
alter table public.lr_milestones enable row level security;
revoke all on public.lr_milestones from anon, authenticated;

create or replace function public.players_milestones()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m bigint;
begin
  foreach m in array array[1000000, 10000000, 100000000, 1000000000]::bigint[] loop
    if new.credits >= m and coalesce(old.credits, 0) < m then
      insert into public.lr_milestones (player, mark, name, credits) values (new.id, m, new.name, new.credits) on conflict do nothing;
    end if;
  end loop;
  return null;
exception when others then return null;
end;
$$;
drop trigger if exists players_milestones on public.players;
create trigger players_milestones after update of credits on public.players for each row execute function public.players_milestones();

insert into public.lr_milestones (player, mark, name, credits, before_start)
  select p.id, m, p.name, p.credits, true from public.players p, unnest(array[1000000, 10000000, 100000000, 1000000000]::bigint[]) m
  where p.credits >= m
  on conflict do nothing;

create or replace function public.admin_milestones(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  return coalesce((select jsonb_agg(jsonb_build_object('player', player, 'mark', mark, 'name', name, 'at', floor(extract(epoch from reached_at) * 1000),
    'credits', credits, 'before', before_start) order by mark, before_start desc, reached_at) from public.lr_milestones), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_milestones(uuid) from public, anon;
grant execute on function public.admin_milestones(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Account age and lotto refunds: run this part once (after "Lotto" and "Admin security").
-- The admin menu shows how old each account is, and can give players back what a lotto ticket cost:
-- a ticket for a draw that hasn't happened yet is taken out of the drum; after the draw the player just
-- gets the price back (the winner keeps the pot). A ticket can be refunded only once.
alter table public.lotto_tickets add column if not exists refunded boolean not null default false;

create or replace function public.admin_player_ages(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  return coalesce((select jsonb_object_agg(p.id, floor(extract(epoch from u.created_at) * 1000))
    from public.players p join auth.users u on u.id = p.id), '{}'::jsonb);
end;
$$;
revoke execute on function public.admin_player_ages(uuid) from public, anon;
grant execute on function public.admin_player_ages(uuid) to authenticated;

create or replace function public.admin_lotto_tickets(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'draw', t.draw_id, 'kind', d.kind, 'draw_at', floor(extract(epoch from d.draw_at) * 1000),
      'settled', d.settled, 'winner', d.winner_name, 'pot', d.pot, 'player', t.player, 'name', t.name, 'cost', t.cost, 'payout', t.payout,
      'refunded', t.refunded, 'at', floor(extract(epoch from t.created_at) * 1000)) order by d.draw_at desc, t.cost desc)
    from public.lotto_tickets t join public.lotto_draws d on d.id = t.draw_id
    where d.draw_at > now() - interval '14 days'), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_lotto_tickets(uuid) from public, anon;
grant execute on function public.admin_lotto_tickets(uuid) to authenticated;

-- one ticket (ticket) or every ticket of a draw (draw)
create or replace function public.admin_lotto_refund(tok uuid, ticket bigint default null, draw text default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  n integer := 0;
begin
  perform public.admin_check(tok);
  if ticket is null and draw is null then raise exception 'nothing to refund'; end if;
  for t in select x.*, d.settled from public.lotto_tickets x join public.lotto_draws d on d.id = x.draw_id
      where not x.refunded and (x.id = ticket or x.draw_id = draw) for update of x loop
    update public.players set credits = least(9007199254740991, credits + t.cost), admin_rev = admin_rev + 1, updated_at = now() where id = t.player;
    if t.settled then update public.lotto_tickets set refunded = true where id = t.id;
    else delete from public.lotto_tickets where id = t.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.admin_lotto_refund(uuid, bigint, text) from public, anon;
grant execute on function public.admin_lotto_refund(uuid, bigint, text) to authenticated;


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


-- ---------------------------------------------------------------------------
-- Automatic prestige: run this part once (after "Games on the server"). Whoever reaches level 20 goes
-- Prestige right away: one prestige more, back to level 1 (the level 20 prize is paid first).
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
  pr integer := public.lr_n(g, 'prestige')::integer;
begin
  f := least(5, public.lr_evf(c, 'xp'));
  xp := xp + case when f > 1 then round(n * f) else n end;
  while lv < 20 and xp >= public.lr_xp_need(lv) loop
    xp := xp - public.lr_xp_need(lv);
    lv := lv + 1;
    cr := cr + 250 * lv;
    g := public.lr_out(g, 'levels', to_jsonb(lv));
  end loop;
  if lv >= 20 and pr < 99 then
    pr := pr + 1;
    lv := 1;
    xp := 0;
    g := public.lr_out(g, 'prestige', to_jsonb(pr));
    g := public.lr_ach(g || jsonb_build_object('credits', cr, 'prestige', pr, 'level', lv), jsonb_build_object('prestige', pr));
    cr := public.lr_n(g, 'credits');
  elsif lv >= 20 then xp := public.lr_xp_need(20);
  end if;
  return g || jsonb_build_object('xp', xp, 'level', lv, 'credits', cr, 'prestige', pr);
end;
$$;


-- ---------------------------------------------------------------------------
-- Lotto price, gifts during sales, prestige bet limit: run this part once (after "Automatic prestige").
-- A lotto ticket can cost a fixed number of credits instead of a share of the balance (0 = the share counts).
-- The admin decides whether credits can be sent while tickets are on sale. Prestige keeps the full bet limit
-- of level 20.
create or replace function public.lotto_cfg()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'on', coalesce((data ->> 'lottoOn')::boolean, true),
    'noonHour', least(23, greatest(0, coalesce((data ->> 'lottoNoonHour')::numeric, 12)))::integer,
    'eveHour', least(23, greatest(0, coalesce((data ->> 'lottoEveHour')::numeric, 18)))::integer,
    'noonPct', least(100, greatest(1, coalesce((data ->> 'lottoNoonPct')::numeric, 20))),
    'evePct', least(100, greatest(1, coalesce((data ->> 'lottoEvePct')::numeric, 50))),
    'noonFixed', greatest(0, coalesce((data ->> 'lottoNoonFixed')::numeric, 0))::bigint,
    'eveFixed', greatest(0, coalesce((data ->> 'lottoEveFixed')::numeric, 0))::bigint,
    'giftLock', coalesce((data ->> 'lottoGiftLock')::boolean, true),
    'openHours', least(24, greatest(0.25, coalesce((data ->> 'lottoOpenHours')::numeric, 5))),
    'closeMin', least(120, greatest(0, coalesce((data ->> 'lottoCloseMin')::numeric, 5))),
    'share', least(500, greatest(0, coalesce((data ->> 'lottoShare')::numeric, 100))),
    'noonBonus', greatest(0, coalesce((data ->> 'lottoNoonBonus')::numeric, 0))::bigint,
    'eveBonus', greatest(0, coalesce((data ->> 'lottoEveBonus')::numeric, 0))::bigint,
    'mode', case when data ->> 'lottoMode' = 'equal' then 'equal' else 'weighted' end)
  from public.settings where id = 1
$$;

create or replace function public.lotto_buy(draw text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.lotto_cfg();
  k text := split_part(draw, '-', 4);
  s jsonb;
  me public.players;
  c bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if not (cfg ->> 'on')::boolean then raise exception 'lotto is off'; end if;
  if k not in ('noon', 'eve') then raise exception 'no such draw'; end if;
  s := public.lotto_slot(left(draw, 10)::date, k, cfg);
  if s ->> 'id' <> draw then raise exception 'no such draw'; end if;
  if now() < (s ->> 'open_at')::timestamptz or now() >= (s ->> 'close_at')::timestamptz then raise exception 'sales closed'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  if exists (select 1 from public.lotto_tickets where draw_id = draw and player = me.id) then raise exception 'already have a ticket'; end if;
  -- a fixed price, or a share of the balance
  c := case when (cfg ->> (k || 'Fixed'))::bigint > 0 then (cfg ->> (k || 'Fixed'))::bigint
    else floor(me.credits * (cfg ->> (k || 'Pct'))::numeric / 100)::bigint end;
  if c < 1 or me.credits < c then raise exception 'not enough credits'; end if;
  insert into public.lotto_draws (id, kind, draw_at) values (draw, k, (s ->> 'draw_at')::timestamptz) on conflict (id) do nothing;
  update public.players set credits = credits - c, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.lotto_tickets (draw_id, player, name, cost) values (draw, me.id, me.name, c);
  return jsonb_build_object('cost', c, 'credits', me.credits - c, 'rev', me.admin_rev + 1);
end;
$$;

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
  -- while lotto tickets are on sale, credits stay where they are (if the admin wants it so)
  if (public.lotto_cfg() ->> 'giftLock')::boolean and public.lotto_selling() then raise exception 'lotto sales running'; end if;
  if target = auth.uid() then raise exception 'cannot send to yourself'; end if;
  if amount is null or amount < 1 then raise exception 'send at least 1'; end if;
  -- Lock both rows in a fixed order so two gifts at once can't deadlock.
  perform 1 from public.players where id in (auth.uid(), target) order by id for update;
  select * into me from public.players where id = auth.uid();
  select * into them from public.players where id = target;
  if me is null or me.is_banned then raise exception 'not allowed'; end if;
  if them is null or them.is_banned then raise exception 'no such player'; end if;
  if me.level < 3 and me.prestige = 0 then raise exception 'reach level 3 first'; end if;
  if them.level < 3 and them.prestige = 0 then raise exception 'recipient below level 3'; end if;
  if me.credits < amount then raise exception 'not enough credits'; end if;
  update public.players set credits = credits - amount, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  update public.players set credits = credits + amount, admin_rev = admin_rev + 1, updated_at = now() where id = them.id;
  insert into public.transfers (sender, recipient, sender_name, amount) values (me.id, them.id, me.name, amount);
  return me.credits - amount;
end;
$$;
revoke execute on function public.send_credits(uuid, bigint) from public, anon;
grant execute on function public.send_credits(uuid, bigint) to authenticated;

-- after a prestige the bet limit stays at the level 20 limit
create or replace function public.lr_bet_limit(lv integer, pr integer)
returns bigint
language sql
immutable
as $$
  select case when coalesce(pr, 0) > 0 then 100000::bigint
    else (array[500, 750, 1000, 1500, 2000, 3000, 4000, 5000, 6500, 8000, 10000, 12500, 15000, 20000, 25000, 32500, 40000, 55000, 75000, 100000]::bigint[])[least(20, greatest(1, coalesce(lv, 1)))] end
$$;
-- the games on the server: the limit of whoever plays (with their prestige)
create or replace function public.lr_lim(c jsonb, lv integer)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select least(public.lr_bet_limit(lv, coalesce((select prestige from public.players where id = auth.uid()), 0)),
    case when (c ->> 'maxBet')::numeric > 0 then (c ->> 'maxBet')::numeric else 9007199254740991 end)
$$;


-- ---------------------------------------------------------------------------
-- Missions can't be farmed: run this part once (after "Lotto price, gifts during sales, prestige bet limit").
-- A finished mission pays at most 2% of what was bet on slot spins since it started (so spins at the smallest
-- bet bring almost nothing), and swapping one costs 150 x the level instead of 25 x.
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
  return jsonb_build_object('t', t, 'goal', public.lr_goal(t, tier), 'prog', 0, 'reward', 150 * greatest(1, lv) * (tier + 1), 'staked', 0);
end;
$$;

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
        'prog', public.lr_num(m -> 'prog', 0, 0, 1e9), 'reward', least(150 * 20 * 3, greatest(0, (m ->> 'reward')::numeric)),
        'staked', public.lr_num(m -> 'staked', 0, 0, 1e15)));
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

-- a paid spin's bet goes onto every mission
create or replace function public.lr_stake(g jsonb, bet numeric)
returns jsonb
language sql
immutable
as $$
  select g || jsonb_build_object('missions', coalesce((select jsonb_agg(m || jsonb_build_object('staked', public.lr_n(m, 'staked') + bet) order by o)
    from jsonb_array_elements(case when jsonb_typeof(g -> 'missions') = 'array' then g -> 'missions' else '[]'::jsonb end) with ordinality u(m, o)), '[]'::jsonb))
$$;

create or replace function public.lr_mission(g jsonb, t text, amount numeric default 1)
returns jsonb
language plpgsql
volatile
as $$
declare
  ms jsonb := coalesce(g -> 'missions', '[]'::jsonb);
  m jsonb;
  pr numeric;
  pay numeric;
  done boolean := false;
begin
  for i in 0 .. jsonb_array_length(ms) - 1 loop
    m := ms -> i;
    if m ->> 't' is distinct from t then continue; end if;
    pr := case when t = 'streak' then greatest(public.lr_n(m, 'prog'), amount) else public.lr_n(m, 'prog') + amount end;
    if pr < public.lr_n(m, 'goal') then ms := jsonb_set(ms, array[i::text, 'prog'], to_jsonb(pr)); continue; end if;
    -- at most 2% of what was bet since the mission started
    pay := least(public.lr_n(m, 'reward'), floor(public.lr_n(m, 'staked') * 0.02));
    g := public.lr_add(public.lr_add(g, 'credits', pay), 'missionsDone', 1);
    g := public.lr_out(g, 'missions', jsonb_build_object('t', t, 'goal', m -> 'goal', 'reward', pay));
    ms := jsonb_set(ms, array[i::text], public.lr_new_mission(array(select x ->> 't' from jsonb_array_elements(ms) x), public.lr_n(g, 'level')::integer));
    done := true;
  end loop;
  g := g || jsonb_build_object('missions', ms);
  if done then g := public.lr_ach(g); end if;
  return g;
end;
$$;

create or replace function public.game_swap(p_i integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players := public.lr_me();
  g jsonb := public.lr_fill(public.lr_g(p));
  cost numeric := 150 * p.level;
begin
  if p_i not between 0 and 2 then raise exception 'mission'; end if;
  if public.lr_n(g, 'credits') < cost then raise exception 'credits'; end if;
  g := public.lr_add(g, 'credits', -cost);
  g := jsonb_set(g, array['missions', p_i::text], public.lr_new_mission(array(select x ->> 't' from jsonb_array_elements(g -> 'missions') x), p.level));
  return public.lr_put(p.id, g, jsonb_build_object('cost', cost));
end;
$$;

-- the spin as before, and its bet counts towards the missions
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
  -- what was bet counts towards the missions' pay
  if not free then g := public.lr_stake(g, bet); end if;
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


-- ---------------------------------------------------------------------------
-- Archive and rename accounts: run this part once. An archived account is out of the live game (no sign-in,
-- not on the lists) but nothing of it is deleted: an admin can bring it back as it was. A renamed player
-- signs in with the new name from then on (the password stays).
alter table public.players add column if not exists archived boolean not null default false;
alter table public.players add column if not exists archived_ban boolean not null default false;

create or replace function public.admin_archive(tok uuid, target uuid, on_ boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if target = auth.uid() then raise exception 'not yourself'; end if;
  if on_ then
    -- blocked while archived; whether it was blocked before comes back with it
    update public.players set archived_ban = case when archived then archived_ban else is_banned end, archived = true, is_banned = true,
      admin_rev = admin_rev + 1, updated_at = now() where id = target and not is_admin;
    if not found then raise exception 'no such player or an admin'; end if;
  else
    update public.players set archived = false, is_banned = archived_ban, archived_ban = false, admin_rev = admin_rev + 1, updated_at = now()
      where id = target and archived;
  end if;
  if to_regclass('auth.sessions') is not null then execute 'delete from auth.sessions where user_id = $1' using target; end if;
  if to_regclass('auth.refresh_tokens') is not null then execute 'delete from auth.refresh_tokens where user_id = $1::text' using target; end if;
end;
$$;
revoke execute on function public.admin_archive(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_archive(uuid, uuid, boolean) to authenticated;

create or replace function public.admin_rename(tok uuid, target uuid, new_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  n text := trim(coalesce(new_name, ''));
  mail text := lower(trim(coalesce(new_name, ''))) || '@lucky-reels.app';
begin
  perform public.admin_check(tok);
  -- the same rule as for signing up: letters, digits, _ and -, at most 40
  if n !~ '^[A-Za-z0-9_-]{1,40}$' then raise exception 'invalid name'; end if;
  if not exists (select 1 from public.players where id = target) then raise exception 'no such player'; end if;
  if exists (select 1 from public.players where lower(name) = lower(n) and id <> target)
     or exists (select 1 from auth.users where lower(email) = mail and id <> target) then raise exception 'name taken'; end if;
  update public.players set name = n, admin_rev = admin_rev + 1, updated_at = now() where id = target;
  update auth.users set email = mail, raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('name', n) where id = target;
  if to_regclass('auth.identities') is not null then
    execute $q$update auth.identities set identity_data = coalesce(identity_data, '{}'::jsonb) || jsonb_build_object('email', $2) where user_id = $1 and provider = 'email'$q$ using target, mail;
  end if;
end;
$$;
revoke execute on function public.admin_rename(uuid, uuid, text) from public, anon;
grant execute on function public.admin_rename(uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- Lucky Bank rises: run this part once. The calmest share takes smaller steps that go up over time: about
-- 2% to 10% a day, 6% on average (288 steps of 5 minutes a day). Like the others it is taken over at 10x its
-- starting price: holders are paid out and it starts again at 100.
update public.stocks set p_up = 0.65, up = 1.001067, down = (1.000202 - 0.65 * 1.001067) / 0.35, news = 0, news_size = 0 where id = 'LBK';


-- ---------------------------------------------------------------------------
-- Bot tag: run this part once. An admin can mark accounts as bots (test accounts); everyone sees a BOT tag
-- next to their name. Players can't set it themselves.
alter table public.players add column if not exists is_bot boolean not null default false;

create or replace function public.admin_set_bot(tok uuid, target uuid, on_ boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  update public.players set is_bot = coalesce(on_, false) where id = target;
  if not found then raise exception 'no such player'; end if;
end;
$$;
revoke execute on function public.admin_set_bot(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_set_bot(uuid, uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- Russian roulette XP: run this part once (after "Russian roulette" and "Games on the server"). The winner
-- also gets half of the loser's XP (all the levels and prestiges they climbed); new levels pay their prize
-- as usual, and level 20 goes Prestige.
create or replace function public.rr_settle(g public.rr_games, lose uuid, why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  win uuid := case when lose = g.challenger then g.opponent else g.challenger end;
  w public.players;
  l public.players;
  wg jsonb;
  wo jsonb;
  lo jsonb;
  k text;
  v jsonb;
  moved integer := 0;
  lxp numeric := 0;
  wx jsonb;
  start_credits bigint := coalesce((select (data ->> 'startCredits')::bigint from public.settings where id = 1), 500);
begin
  perform 1 from public.players where id in (win, lose) order by id for update;
  select * into w from public.players where id = win;
  select * into l from public.players where id = lose;
  begin wg := coalesce(w.game::jsonb, '{}'::jsonb); exception when others then wg := '{}'::jsonb; end;
  begin lo := coalesce(l.game::jsonb -> 'owned', '{}'::jsonb); exception when others then lo := '{}'::jsonb; end;
  wo := case when jsonb_typeof(wg -> 'owned') = 'object' then wg -> 'owned' else '{}'::jsonb end;
  if jsonb_typeof(lo) = 'object' then
    for k, v in select * from jsonb_each(lo) loop
      if jsonb_typeof(v) = 'number' and (v #>> '{}')::numeric > 0 then
        if coalesce((wo ->> k)::numeric, 0) < (v #>> '{}')::numeric then wo := jsonb_set(wo, array[k], v); moved := moved + 1; end if;
      elsif v = 'true'::jsonb then
        if coalesce(wo -> k, 'false'::jsonb) <> 'true'::jsonb then wo := jsonb_set(wo, array[k], 'true'::jsonb); moved := moved + 1; end if;
      end if;
    end loop;
  end if;
  wg := jsonb_set(wg, '{owned}', wo);
  -- the winner's page takes over the goodies when it sees this mark
  wg := jsonb_set(wg, '{rrAt}', to_jsonb(floor(extract(epoch from clock_timestamp()) * 1000)::bigint));
  update public.players set credits = least(9007199254740991, credits + greatest(l.credits, 0)), game = wg::text,
    admin_rev = admin_rev + 1, updated_at = now() where id = win;
  -- shares change hands too
  if to_regclass('public.stock_holdings') is not null then
    insert into public.stock_holdings (player, stock, name, shares, cost)
      select win, stock, w.name, shares, cost from public.stock_holdings where player = lose
      on conflict (player, stock) do update set shares = public.stock_holdings.shares + excluded.shares, cost = public.stock_holdings.cost + excluded.cost;
    delete from public.stock_holdings where player = lose;
  end if;
  update public.players set credits = start_credits, best = 0, level = 1, spins = 0, jackpots = 0, game = null, flair = null, prestige = 0,
    admin_rev = admin_rev + 1, updated_at = now() where id = lose;
  -- the winner gets half of the loser's XP: all levels and prestiges they climbed, and what they had on top
  begin lxp := coalesce((l.game::jsonb ->> 'xp')::numeric, 0); exception when others then lxp := 0; end;
  lxp := coalesce(l.prestige, 0) * (select sum(public.lr_xp_need(x)) from generate_series(1, 19) x)
    + coalesce((select sum(public.lr_xp_need(x)) from generate_series(1, least(19, l.level - 1)) x), 0) + least(lxp, public.lr_xp_need(20));
  if lxp >= 2 then
    select * into w from public.players where id = win;
    wx := public.lr_ach(public.lr_xp(public.lr_g(w), public.lr_cfg(), floor(lxp / 2)));
    perform public.lr_put(win, wx);
  end if;
  update public.rr_games set status = 'done', ended_at = now(), winner = win, loser = lose, reason = why,
    pot_credits = greatest(l.credits, 0), pot_goodies = moved where id = g.id;
end;
$$;
revoke execute on function public.rr_settle(public.rr_games, uuid, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- Lotto: players who can't win: run this part once (after "Account age and lotto refunds"). An admin can
-- pick players whose tickets never win; they still buy tickets as usual and see nothing of it. The list is in
-- a table only the admin functions can read. If only such players bought tickets for a draw, nobody wins and
-- their tickets are refunded.
create table if not exists public.lr_lotto_block (
  player uuid primary key references public.players (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.lr_lotto_block enable row level security;
revoke all on public.lr_lotto_block from anon, authenticated;

create or replace function public.lotto_settle(draw text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dr public.lotto_draws;
  cfg jsonb := public.lotto_cfg();
  n integer;
  tot numeric;
  etot numeric;
  v_pot bigint;
  pick public.lotto_tickets;
  x numeric;
begin
  select * into dr from public.lotto_draws where id = draw for update;
  if dr.id is null or dr.settled or now() < dr.draw_at then return; end if;
  select count(*), coalesce(sum(cost), 0) into n, tot from public.lotto_tickets where draw_id = draw;
  if n = 0 then
    update public.lotto_draws set settled = true, pot = 0, tickets = 0 where id = draw;
    return;
  end if;
  -- only tickets of players who can win take part in the draw
  select coalesce(sum(cost), 0) into etot from public.lotto_tickets t where t.draw_id = draw and not exists (select 1 from public.lr_lotto_block b where b.player = t.player);
  if etot = 0 then
    update public.players p set credits = least(9007199254740991, p.credits + t.cost), admin_rev = p.admin_rev + 1, updated_at = now()
      from public.lotto_tickets t where t.draw_id = draw and p.id = t.player;
    update public.lotto_tickets set payout = 0, claimed = true, refunded = true where draw_id = draw;
    update public.lotto_draws set settled = true, pot = 0, tickets = n where id = draw;
    return;
  end if;
  v_pot := floor(tot * (cfg ->> 'share')::numeric / 100)::bigint + (cfg ->> (dr.kind || 'Bonus'))::bigint;
  if cfg ->> 'mode' = 'equal' then
    select * into pick from public.lotto_tickets t where t.draw_id = draw and not exists (select 1 from public.lr_lotto_block b where b.player = t.player)
      order by random() limit 1;
  else
    x := random() * etot;
    select q.id, q.draw_id, q.player, q.name, q.cost, q.payout, q.claimed, q.created_at into pick
      from (select t.*, sum(t.cost) over (order by t.id) as run from public.lotto_tickets t
            where t.draw_id = draw and not exists (select 1 from public.lr_lotto_block b where b.player = t.player)) q
      where q.run > x order by q.run limit 1;
    if pick.id is null then
      select * into pick from public.lotto_tickets t where t.draw_id = draw and not exists (select 1 from public.lr_lotto_block b where b.player = t.player)
        order by t.id desc limit 1;
    end if;
  end if;
  update public.lotto_tickets set payout = case when id = pick.id then v_pot else 0 end where draw_id = draw;
  -- the winner gets the pot right away, online or not
  update public.players set credits = least(9007199254740991, credits + v_pot), admin_rev = admin_rev + 1, updated_at = now() where id = pick.player;
  update public.lotto_tickets set claimed = true where draw_id = draw;
  update public.lotto_draws set settled = true, pot = v_pot, tickets = n, winner = pick.player, winner_name = pick.name, winner_cost = pick.cost
    where id = draw;
end;
$$;

create or replace function public.admin_lotto_blocked(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  return coalesce((select jsonb_agg(player) from public.lr_lotto_block), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_lotto_blocked(uuid) from public, anon;
grant execute on function public.admin_lotto_blocked(uuid) to authenticated;

create or replace function public.admin_lotto_block(tok uuid, target uuid, on_ boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  if on_ then insert into public.lr_lotto_block (player) values (target) on conflict do nothing;
  else delete from public.lr_lotto_block where player = target;
  end if;
end;
$$;
revoke execute on function public.admin_lotto_block(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_lotto_block(uuid, uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- Mega-Prestige: run this part once (after "Games on the server"). Every 10 prestiges make one Mega-Prestige
-- (the page shows a crowned badge). For Mega-Prestige I to V there is a name style in the shop that can only be
-- bought from that tier on.
alter table public.players drop constraint if exists players_flair_check;
alter table public.players add constraint players_flair_check
  check (flair is null or flair in ('neon', 'gold', 'fire', 'ice', 'galaxy', 'admin', 'mega1', 'mega2', 'mega3', 'mega4', 'mega5'));

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
        when 'fire' then 'fireName' when 'ice' then 'iceName' when 'galaxy' then 'galaxyName' when 'mega1' then 'mega1' when 'mega2' then 'mega2' when 'mega3' then 'mega3' when 'mega4' then 'mega4' when 'mega5' then 'mega5' else '-' end))::boolean, false) is not true then new.flair := null; end if;
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
    when 'mega1' then 100000 when 'mega2' then 250000 when 'mega3' then 500000 when 'mega4' then 1000000 when 'mega5' then 2500000
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
  -- the Mega name styles only from their Mega-Prestige on (every 10 prestiges)
  if p_id ~ '^mega[1-5]$' and p.prestige < 10 * substr(p_id, 5)::integer then raise exception 'locked'; end if;
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


-- ---------------------------------------------------------------------------
-- Admin: give goodies: run this part once (after "Games on the server"). An admin can give a player a goodie
-- from the shop (or take one away), for example as a refund. The Lucky Horseshoe goes up or down one level.
create or replace function public.admin_set_goodie(tok uuid, target uuid, goodie text, give boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players;
  g jsonb;
  lv numeric;
begin
  perform public.admin_check(tok);
  if public.lr_price(goodie, '{}'::jsonb) is null or goodie = 'adminName' then raise exception 'unknown goodie'; end if;
  select * into p from public.players where id = target for update;
  if p.id is null then raise exception 'no such player'; end if;
  begin g := coalesce(p.game::jsonb, '{}'::jsonb); exception when others then g := '{}'::jsonb; end;
  if jsonb_typeof(g -> 'owned') is distinct from 'object' then g := jsonb_set(g, '{owned}', '{}'::jsonb); end if;
  if goodie = 'horseshoe' then
    lv := least(3, greatest(0, public.lr_n(g -> 'owned', 'horseshoe') + case when give then 1 else -1 end));
    g := jsonb_set(g, '{owned,horseshoe}', to_jsonb(lv));
  else
    g := jsonb_set(g, array['owned', goodie], to_jsonb(coalesce(give, false)));
  end if;
  update public.players set game = g::text, admin_rev = admin_rev + 1, updated_at = now() where id = target;
end;
$$;
revoke execute on function public.admin_set_goodie(uuid, uuid, text, boolean) from public, anon;
grant execute on function public.admin_set_goodie(uuid, uuid, text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- Name change requests: run this part once (after "Archive and rename accounts"). A player can ask for a new
-- name for the price an admin sets (nameChangePrice, default 50,000). The credits are paid with the request; an
-- admin approves it (the player signs in with the new name from then on) or declines it (the credits come back).
-- The player can also take the request back before an admin decides.
create table if not exists public.lr_name_requests (
  id bigint generated always as identity primary key,
  player uuid not null references public.players (id) on delete cascade,
  old_name text not null,
  new_name text not null,
  cost bigint not null default 0,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index if not exists lr_name_requests_pending on public.lr_name_requests (player) where status = 'pending';
alter table public.lr_name_requests enable row level security;
revoke all on public.lr_name_requests from anon, authenticated;

create or replace function public.request_name_change(new_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.players;
  n text := trim(coalesce(new_name, ''));
  price bigint := greatest(0, coalesce((select (data ->> 'nameChangePrice')::numeric from public.settings where id = 1), 50000))::bigint;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select * into me from public.players where id = auth.uid() for update;
  if me.id is null or me.is_banned then raise exception 'not allowed'; end if;
  if n !~ '^[A-Za-z0-9_-]{1,40}$' then raise exception 'invalid name'; end if;
  if lower(n) = lower(me.name) then raise exception 'same name'; end if;
  if exists (select 1 from public.players where lower(name) = lower(n) and id <> me.id)
     or exists (select 1 from auth.users where lower(email) = lower(n) || '@lucky-reels.app' and id <> me.id)
     or exists (select 1 from public.lr_name_requests q where q.status = 'pending' and lower(q.new_name) = lower(n) and q.player <> me.id) then raise exception 'name taken'; end if;
  if exists (select 1 from public.lr_name_requests where player = me.id and status = 'pending') then raise exception 'already asked'; end if;
  if me.credits < price then raise exception 'not enough credits'; end if;
  update public.players set credits = credits - price, admin_rev = admin_rev + 1, updated_at = now() where id = me.id;
  insert into public.lr_name_requests (player, old_name, new_name, cost) values (me.id, me.name, n, price);
  return jsonb_build_object('cost', price, 'credits', me.credits - price, 'rev', me.admin_rev + 1);
end;
$$;
revoke execute on function public.request_name_change(text) from public, anon;
grant execute on function public.request_name_change(text) to authenticated;

-- the player's latest request (to show its state)
create or replace function public.my_name_request()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select jsonb_build_object('id', id, 'new_name', new_name, 'cost', cost, 'status', status, 'decided_at', floor(extract(epoch from decided_at) * 1000))
    from public.lr_name_requests where player = auth.uid() order by id desc limit 1), '{}'::jsonb)
$$;
revoke execute on function public.my_name_request() from public, anon;
grant execute on function public.my_name_request() to authenticated;

create or replace function public.cancel_name_request()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.lr_name_requests;
  me public.players;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select * into r from public.lr_name_requests where player = auth.uid() and status = 'pending' order by id desc limit 1 for update;
  if r.id is null then raise exception 'no request'; end if;
  update public.lr_name_requests set status = 'cancelled', decided_at = now() where id = r.id;
  update public.players set credits = least(9007199254740991, credits + r.cost), admin_rev = admin_rev + 1, updated_at = now() where id = r.player returning * into me;
  return jsonb_build_object('credits', me.credits, 'rev', me.admin_rev);
end;
$$;
revoke execute on function public.cancel_name_request() from public, anon;
grant execute on function public.cancel_name_request() to authenticated;

create or replace function public.admin_name_requests(tok uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.admin_check(tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'player', r.player, 'old_name', r.old_name, 'name', p.name, 'new_name', r.new_name, 'cost', r.cost,
    'status', r.status, 'at', floor(extract(epoch from r.created_at) * 1000)) order by r.id desc)
    from public.lr_name_requests r join public.players p on p.id = r.player
    where r.status = 'pending' or r.decided_at > now() - interval '7 days'), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_name_requests(uuid) from public, anon;
grant execute on function public.admin_name_requests(uuid) to authenticated;

create or replace function public.admin_name_decide(tok uuid, req bigint, approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.lr_name_requests;
begin
  perform public.admin_check(tok);
  select * into r from public.lr_name_requests where id = req and status = 'pending' for update;
  if r.id is null then raise exception 'no request'; end if;
  if approve then
    perform public.admin_rename(tok, r.player, r.new_name);
    update public.lr_name_requests set status = 'approved', decided_at = now() where id = r.id;
  else
    update public.lr_name_requests set status = 'declined', decided_at = now() where id = r.id;
    update public.players set credits = least(9007199254740991, credits + r.cost), admin_rev = admin_rev + 1, updated_at = now() where id = r.player;
  end if;
end;
$$;
revoke execute on function public.admin_name_decide(uuid, bigint, boolean) from public, anon;
grant execute on function public.admin_name_decide(uuid, bigint, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- Wild spins: run this part once (after "Missions can't be farmed"). Three wilds no longer pay 80x straight
-- away: they start 10 wild spins at the same bet where every win counts x13. On average that is about the
-- same 80x, it only lasts longer. Three wilds during wild spins add 10 more.
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
    'freeSpins', 'freeBet', 'freeTotal', 'nudges', 'missions', 'missionsDone', 'ach', 'sl', 'job', 'jobReset', 'rrAt', 'srv', 'evGifts', 'wildSpins', 'wildBet', 'wildTotal'] loop
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

create or replace function public.lr_view(g jsonb)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('credits', g -> 'credits', 'level', g -> 'level', 'prestige', g -> 'prestige', 'spins', g -> 'spins', 'jackpots', g -> 'jackpots',
    'best', g -> 'best', 'lastWin', g -> 'lastWin', 'owned', g -> 'owned', 'xp', g -> 'xp', 'streak', g -> 'streak', 'stars', g -> 'stars',
    'starBank', g -> 'starBank', 'freeSpins', g -> 'freeSpins', 'freeBet', g -> 'freeBet', 'freeTotal', g -> 'freeTotal', 'nudges', g -> 'nudges',
    'missions', g -> 'missions', 'missionsDone', g -> 'missionsDone', 'ach', g -> 'ach', 'sl', g -> 'sl', 'job', g -> 'job', 'jobReset', g -> 'jobReset',
    'rrAt', g -> 'rrAt', 'evGifts', g -> 'evGifts', 'wildSpins', g -> 'wildSpins', 'wildBet', g -> 'wildBet', 'wildTotal', g -> 'wildTotal',
    'bj', jsonb_build_object('round', g #> '{bj,round}', 'hands', g #> '{bj,hands}', 'lastBet', g #> '{bj,lastBet}', 'shoeLeft', g #> '{bj,shoeLeft}'),
    'pl', jsonb_build_object('drops', g #> '{pl,drops}'), 'ck', jsonb_build_object('round', g #> '{ck,round}', 'games', g #> '{ck,games}'),
    'cf', jsonb_build_object('round', g #> '{cf,round}', 'flips', g #> '{cf,flips}'), 'pk', jsonb_build_object('solo', g #> '{pk,solo}', 'hands', g #> '{pk,hands}'))
$$;

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
    'freeBet', 0, 'freeTotal', 0, 'wildSpins', 0, 'wildBet', 0, 'wildTotal', 0, 'nudges', 0, 'sl', '{}'::jsonb, 'job', jsonb_build_object('worked', 0, 'earned', 0, 'shifts', 0, 'pos', 0),
    'jobReset', floor(extract(epoch from now()) * 1000));
  g := g || jsonb_build_object('bj', coalesce(g -> 'bj', '{}'::jsonb) || '{"round": null, "hands": 0, "lastBet": 0, "shoe": []}',
    'pl', coalesce(g -> 'pl', '{}'::jsonb) || '{"drops": 0, "pending": []}', 'ck', coalesce(g -> 'ck', '{}'::jsonb) || '{"round": null, "games": 0}',
    'cf', coalesce(g -> 'cf', '{}'::jsonb) || '{"round": null, "flips": 0}', 'pk', coalesce(g -> 'pk', '{}'::jsonb) || '{"solo": null, "hands": 0}');
  return public.lr_put(p.id, public.lr_fill(g), '{}'::jsonb);
end;
$$;

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
  wild boolean := false;
  wtrig boolean := false;
  wover boolean := false;
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  sl := coalesce(g -> 'sl', '{}'::jsonb);
  if sl ? 'gm' then raise exception 'gamble open'; end if;
  pos := coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x), '{}');
  if coalesce(array_length(pos, 1), 0) <> 3 then pos := array[public.lr_rand(27), public.lr_rand(27), public.lr_rand(27)]; end if;
  -- wild spins (from three wilds) come first, then free spins
  wild := public.lr_n(g, 'wildSpins') > 0;
  free := wild or public.lr_n(g, 'freeSpins') > 0;
  if wild then
    bet := greatest(1, public.lr_n(g, 'wildBet'));
    g := public.lr_add(g, 'wildSpins', -1);
    if not coalesce((sl ->> 'inWild')::boolean, false) then g := g || jsonb_build_object('wildTotal', 0); sl := sl || '{"inWild": true}'; end if;
  elsif free then
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
  -- what was bet counts towards the missions' pay
  if not free then g := public.lr_stake(g, bet); end if;
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
  -- three wilds pay nothing straight away: they start 10 wild spins where every win counts x13 (on average about 80x the bet)
  if line = 'wild' then base := 0; wtrig := true; end if;
  smult := case when base > 0 and not wild then 1 + 0.1 * least(public.lr_n(g, 'streak'), 5) else 1 end;
  mult := base * (case when wild then 13 when free then (c ->> 'freeMult')::numeric else 1 end) * smult * public.lr_wm(c, 'slots');
  if public.lr_has(g, 'lightning') and base > 0 and public.lr_rand(1000) < 10 then
    roll := public.lr_rand(100);
    bolt := case when roll < 70 then 2 when roll < 90 then 3 when roll < 98 then 5 else 10 end;
  end if;
  win := floor(mult * bet * greatest(bolt, 1));
  if base = 0 and public.lr_has(g, 'piggy') then refund := floor(bet * 0.02); end if;
  g := public.lr_add(g, 'credits', win + refund) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win),
    'streak', case when base > 0 then public.lr_n(g, 'streak') + 1 else 0 end);
  if wild then g := public.lr_add(g, 'wildTotal', win); elsif free then g := public.lr_add(g, 'freeTotal', win); end if;
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
  if wtrig then
    if not wild then g := g || jsonb_build_object('wildBet', bet, 'wildTotal', 0); end if;
    g := public.lr_add(g, 'wildSpins', 10);
  end if;
  if wild and public.lr_n(g, 'wildSpins') = 0 then sl := sl || '{"inWild": false}'; wover := true; end if;
  if free and not wild and public.lr_n(g, 'freeSpins') = 0 then sl := sl || '{"inBonus": false}'; over := true; end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(tg), 'lastBet', bet);
  g := public.lr_ach(g || jsonb_build_object('sl', sl), jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet, 'jackpot', coalesce(line = 'seven', false),
    'triggered', trig, 'bet', bet, 'wildLine', line is not null and 'wild' = any(syms)));
  return public.lr_put(p.id, g, jsonb_build_object('targets', to_jsonb(tg), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'smult', smult,
    'mult', round(mult * greatest(bolt, 1), 2), 'bolt', bolt, 'win', win, 'refund', refund, 'bet', bet, 'free', free, 'stars', sc, 'wilds', wc,
    'triggered', trig, 'nudgesAdded', nadd, 'jackpot', coalesce(line = 'seven', false), 'bonusOver', over, 'held', to_jsonb(holds), 'wild', wild, 'wildTrig', wtrig, 'wildOver', wover, 'wildTotal', public.lr_n(g, 'wildTotal')));
end;
$$;


-- ---------------------------------------------------------------------------
-- Sticky wilds: run this part once (after "Wild spins"). During wild spins every wild that is rolled sticks to
-- its reel until the wild spins are over, and every win counts x3.3 (on average still about 80x the bet over the
-- 10 spins). Three wilds during wild spins now pay their line instead of adding spins.
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
  wild boolean := false;
  wtrig boolean := false;
  wover boolean := false;
  sticky boolean[] := array[false, false, false];
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  sl := coalesce(g -> 'sl', '{}'::jsonb);
  if sl ? 'gm' then raise exception 'gamble open'; end if;
  pos := coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x), '{}');
  if coalesce(array_length(pos, 1), 0) <> 3 then pos := array[public.lr_rand(27), public.lr_rand(27), public.lr_rand(27)]; end if;
  -- wild spins (from three wilds) come first, then free spins
  wild := public.lr_n(g, 'wildSpins') > 0;
  free := wild or public.lr_n(g, 'freeSpins') > 0;
  if wild then
    bet := greatest(1, public.lr_n(g, 'wildBet'));
    g := public.lr_add(g, 'wildSpins', -1);
    if not coalesce((sl ->> 'inWild')::boolean, false) then g := g || jsonb_build_object('wildTotal', 0); sl := sl || '{"inWild": true, "sticky": [false, false, false]}'; end if;
    -- wilds rolled during wild spins stick: their reels stay as they are
    sticky := coalesce(array(select (x #>> '{}')::boolean from jsonb_array_elements(sl -> 'sticky') x), array[false, false, false]);
    if coalesce(array_length(sticky, 1), 0) <> 3 then sticky := array[false, false, false]; end if;
    holds := sticky;
  elsif free then
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
  -- what was bet counts towards the missions' pay
  if not free then g := public.lr_stake(g, bet); end if;
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
  -- three wilds pay nothing straight away: they start 10 wild spins where every win counts x13 (on average about 80x the bet)
  if line = 'wild' and not wild then base := 0; wtrig := true; end if;
  smult := case when base > 0 and not wild then 1 + 0.1 * least(public.lr_n(g, 'streak'), 5) else 1 end;
  mult := base * (case when wild then 3.3 when free then (c ->> 'freeMult')::numeric else 1 end) * smult * public.lr_wm(c, 'slots');
  if public.lr_has(g, 'lightning') and base > 0 and public.lr_rand(1000) < 10 then
    roll := public.lr_rand(100);
    bolt := case when roll < 70 then 2 when roll < 90 then 3 when roll < 98 then 5 else 10 end;
  end if;
  win := floor(mult * bet * greatest(bolt, 1));
  if base = 0 and public.lr_has(g, 'piggy') then refund := floor(bet * 0.02); end if;
  g := public.lr_add(g, 'credits', win + refund) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win),
    'streak', case when base > 0 then public.lr_n(g, 'streak') + 1 else 0 end);
  if wild then g := public.lr_add(g, 'wildTotal', win); elsif free then g := public.lr_add(g, 'freeTotal', win); end if;
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
  if wtrig then
    if not wild then g := g || jsonb_build_object('wildBet', bet, 'wildTotal', 0); end if;
    g := public.lr_add(g, 'wildSpins', 10);
  end if;
  if wild then
    sticky := array(select sticky[k] or syms[k] = 'wild' from generate_series(1, 3) k);
    sl := sl || jsonb_build_object('sticky', to_jsonb(sticky));
  end if;
  if wild and public.lr_n(g, 'wildSpins') = 0 then sl := sl || '{"inWild": false, "sticky": [false, false, false]}'; wover := true; end if;
  if free and not wild and public.lr_n(g, 'freeSpins') = 0 then sl := sl || '{"inBonus": false}'; over := true; end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(tg), 'lastBet', bet);
  g := public.lr_ach(g || jsonb_build_object('sl', sl), jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet, 'jackpot', coalesce(line = 'seven', false),
    'triggered', trig, 'bet', bet, 'wildLine', line is not null and 'wild' = any(syms)));
  return public.lr_put(p.id, g, jsonb_build_object('targets', to_jsonb(tg), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'smult', smult,
    'mult', round(mult * greatest(bolt, 1), 2), 'bolt', bolt, 'win', win, 'refund', refund, 'bet', bet, 'free', free, 'stars', sc, 'wilds', wc,
    'triggered', trig, 'nudgesAdded', nadd, 'jackpot', coalesce(line = 'seven', false), 'bonusOver', over, 'held', to_jsonb(holds), 'wild', wild, 'wildTrig', wtrig, 'wildOver', wover, 'wildTotal', public.lr_n(g, 'wildTotal'), 'sticky', to_jsonb(sticky)));
end;
$$;


-- ---------------------------------------------------------------------------
-- Calmer wild spins and the admin's wild test: run this part once (after "Sticky wilds"). In wild spins the reels
-- carry no sevens, stars or bars and a wild sticks only rarely (5% for the first, 0.2% for the second, 0.05% for
-- the third); every win counts x10.8, still about 80x the bet on average, and more than 300x only about once in
-- a thousand bonuses. An admin can make their own next paid slot spin land three wilds.
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
  wild boolean := false;
  wtrig boolean := false;
  wover boolean := false;
  sticky boolean[] := array[false, false, false];
  nst integer;
  forced boolean := false;
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  sl := coalesce(g -> 'sl', '{}'::jsonb);
  if sl ? 'gm' then raise exception 'gamble open'; end if;
  pos := coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x), '{}');
  if coalesce(array_length(pos, 1), 0) <> 3 then pos := array[public.lr_rand(27), public.lr_rand(27), public.lr_rand(27)]; end if;
  -- wild spins (from three wilds) come first, then free spins
  wild := public.lr_n(g, 'wildSpins') > 0;
  free := wild or public.lr_n(g, 'freeSpins') > 0;
  if wild then
    bet := greatest(1, public.lr_n(g, 'wildBet'));
    g := public.lr_add(g, 'wildSpins', -1);
    if not coalesce((sl ->> 'inWild')::boolean, false) then g := g || jsonb_build_object('wildTotal', 0); sl := sl || '{"inWild": true, "sticky": [false, false, false]}'; end if;
    -- wilds rolled during wild spins stick: their reels stay as they are
    sticky := coalesce(array(select (x #>> '{}')::boolean from jsonb_array_elements(sl -> 'sticky') x), array[false, false, false]);
    if coalesce(array_length(sticky, 1), 0) <> 3 then sticky := array[false, false, false]; end if;
    holds := sticky;
  elsif free then
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
  -- what was bet counts towards the missions' pay
  if not free then g := public.lr_stake(g, bet); end if;
  sl := sl || jsonb_build_object('holdOffer', false, 'nudgeOpen', false, 'gamble', 0);
  tg := array(select case when holds[i] then pos[i] else public.lr_rand(27) end from generate_series(1, 3) i);
  -- three sevens are a bit rarer than the reels alone make them: a quarter of them get the last free reel drawn again
  if wild then
    -- in wild spins the reels carry no sevens, stars or bars, and a wild rarely sticks:
    -- 5% for the first, 0.2% for the second, 0.05% for the third (the others are drawn again)
    nst := (select count(*) from unnest(sticky) x where x);
    for k in 1 .. 3 loop
      if holds[k] then continue; end if;
      loop
        tg[k] := public.lr_rand(27);
        exit when strip[tg[k] + 1] not in ('seven', 'star', 'bar', 'wild')
          or (strip[tg[k] + 1] = 'wild' and random() < (array[0.05, 0.002, 0.0005])[least(nst, 2) + 1]);
      end loop;
      if strip[tg[k] + 1] = 'wild' then nst := nst + 1; end if;
    end loop;
  elsif not free and coalesce((sl ->> 'forceWild')::boolean, false) and p.is_admin then
    -- the admin's own test: this spin lands three wilds
    tg := array[2, 2, 2];
    forced := true;
    sl := sl - 'forceWild';
  end if;
  free7 := case when wild or forced then null else (select i from unnest(array[3, 2, 1]) i where not holds[i] limit 1) end;
  if free7 is not null and public.lr_line(strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]) = 'seven' and public.lr_rand(100) < 25 then
    tg[free7] := public.lr_rand(27);
  end if;
  syms := array[strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]];
  line := public.lr_line(syms[1], syms[2], syms[3]);
  base := public.lr_payout(g, c, syms[1], syms[2], syms[3]);
  -- three wilds pay nothing straight away: they start 10 wild spins where every win counts x13 (on average about 80x the bet)
  if line = 'wild' and not wild then base := 0; wtrig := true; end if;
  smult := case when base > 0 and not wild then 1 + 0.1 * least(public.lr_n(g, 'streak'), 5) else 1 end;
  mult := base * (case when wild then 10.8 when free then (c ->> 'freeMult')::numeric else 1 end) * smult * public.lr_wm(c, 'slots');
  if public.lr_has(g, 'lightning') and base > 0 and public.lr_rand(1000) < 10 then
    roll := public.lr_rand(100);
    bolt := case when roll < 70 then 2 when roll < 90 then 3 when roll < 98 then 5 else 10 end;
  end if;
  win := floor(mult * bet * greatest(bolt, 1));
  if base = 0 and public.lr_has(g, 'piggy') then refund := floor(bet * 0.02); end if;
  g := public.lr_add(g, 'credits', win + refund) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win),
    'streak', case when base > 0 then public.lr_n(g, 'streak') + 1 else 0 end);
  if wild then g := public.lr_add(g, 'wildTotal', win); elsif free then g := public.lr_add(g, 'freeTotal', win); end if;
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
  if wtrig then
    if not wild then g := g || jsonb_build_object('wildBet', bet, 'wildTotal', 0); end if;
    g := public.lr_add(g, 'wildSpins', 10);
  end if;
  if wild then
    sticky := array(select sticky[k] or syms[k] = 'wild' from generate_series(1, 3) k);
    sl := sl || jsonb_build_object('sticky', to_jsonb(sticky));
  end if;
  if wild and public.lr_n(g, 'wildSpins') = 0 then sl := sl || '{"inWild": false, "sticky": [false, false, false]}'; wover := true; end if;
  if free and not wild and public.lr_n(g, 'freeSpins') = 0 then sl := sl || '{"inBonus": false}'; over := true; end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(tg), 'lastBet', bet);
  g := public.lr_ach(g || jsonb_build_object('sl', sl), jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet, 'jackpot', coalesce(line = 'seven', false),
    'triggered', trig, 'bet', bet, 'wildLine', line is not null and 'wild' = any(syms)));
  return public.lr_put(p.id, g, jsonb_build_object('targets', to_jsonb(tg), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'smult', smult,
    'mult', round(mult * greatest(bolt, 1), 2), 'bolt', bolt, 'win', win, 'refund', refund, 'bet', bet, 'free', free, 'stars', sc, 'wilds', wc,
    'triggered', trig, 'nudgesAdded', nadd, 'jackpot', coalesce(line = 'seven', false), 'bonusOver', over, 'held', to_jsonb(holds), 'wild', wild, 'wildTrig', wtrig, 'wildOver', wover, 'wildTotal', public.lr_n(g, 'wildTotal'), 'sticky', to_jsonb(sticky)));
end;
$$;

create or replace function public.admin_force_wild(tok uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.players;
  g jsonb;
begin
  perform public.admin_check(tok);
  select * into p from public.players where id = auth.uid() for update;
  if p.id is null or not p.is_admin then raise exception 'not allowed'; end if;
  g := public.lr_g(p);
  g := jsonb_set(g, '{sl}', coalesce(g -> 'sl', '{}'::jsonb) || '{"forceWild": true}');
  perform public.lr_put(p.id, g);
end;
$$;
revoke execute on function public.admin_force_wild(uuid) from public, anon;
grant execute on function public.admin_force_wild(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- More sticky wilds: run this part once (after "Calmer wild spins and the admin's wild test"). In wild spins the
-- first wild that is rolled sticks far more often (60% instead of 5%; more than half of all wild bonuses get one),
-- a second or third still only rarely. Wins count x8.7 instead of x10.8, so it stays at about 80x the bet.
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
  wild boolean := false;
  wtrig boolean := false;
  wover boolean := false;
  sticky boolean[] := array[false, false, false];
  nst integer;
  forced boolean := false;
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  sl := coalesce(g -> 'sl', '{}'::jsonb);
  if sl ? 'gm' then raise exception 'gamble open'; end if;
  pos := coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x), '{}');
  if coalesce(array_length(pos, 1), 0) <> 3 then pos := array[public.lr_rand(27), public.lr_rand(27), public.lr_rand(27)]; end if;
  -- wild spins (from three wilds) come first, then free spins
  wild := public.lr_n(g, 'wildSpins') > 0;
  free := wild or public.lr_n(g, 'freeSpins') > 0;
  if wild then
    bet := greatest(1, public.lr_n(g, 'wildBet'));
    g := public.lr_add(g, 'wildSpins', -1);
    if not coalesce((sl ->> 'inWild')::boolean, false) then g := g || jsonb_build_object('wildTotal', 0); sl := sl || '{"inWild": true, "sticky": [false, false, false]}'; end if;
    -- wilds rolled during wild spins stick: their reels stay as they are
    sticky := coalesce(array(select (x #>> '{}')::boolean from jsonb_array_elements(sl -> 'sticky') x), array[false, false, false]);
    if coalesce(array_length(sticky, 1), 0) <> 3 then sticky := array[false, false, false]; end if;
    holds := sticky;
  elsif free then
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
  -- what was bet counts towards the missions' pay
  if not free then g := public.lr_stake(g, bet); end if;
  sl := sl || jsonb_build_object('holdOffer', false, 'nudgeOpen', false, 'gamble', 0);
  tg := array(select case when holds[i] then pos[i] else public.lr_rand(27) end from generate_series(1, 3) i);
  -- three sevens are a bit rarer than the reels alone make them: a quarter of them get the last free reel drawn again
  if wild then
    -- in wild spins the reels carry no sevens, stars or bars, and a wild rarely sticks:
    -- 60% for the first, 0.2% for the second, 0.05% for the third (the others are drawn again)
    nst := (select count(*) from unnest(sticky) x where x);
    for k in 1 .. 3 loop
      if holds[k] then continue; end if;
      loop
        tg[k] := public.lr_rand(27);
        exit when strip[tg[k] + 1] not in ('seven', 'star', 'bar', 'wild')
          or (strip[tg[k] + 1] = 'wild' and random() < (array[0.6, 0.002, 0.0005])[least(nst, 2) + 1]);
      end loop;
      if strip[tg[k] + 1] = 'wild' then nst := nst + 1; end if;
    end loop;
  elsif not free and coalesce((sl ->> 'forceWild')::boolean, false) and p.is_admin then
    -- the admin's own test: this spin lands three wilds
    tg := array[2, 2, 2];
    forced := true;
    sl := sl - 'forceWild';
  end if;
  free7 := case when wild or forced then null else (select i from unnest(array[3, 2, 1]) i where not holds[i] limit 1) end;
  if free7 is not null and public.lr_line(strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]) = 'seven' and public.lr_rand(100) < 25 then
    tg[free7] := public.lr_rand(27);
  end if;
  syms := array[strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]];
  line := public.lr_line(syms[1], syms[2], syms[3]);
  base := public.lr_payout(g, c, syms[1], syms[2], syms[3]);
  -- three wilds pay nothing straight away: they start 10 wild spins where every win counts x13 (on average about 80x the bet)
  if line = 'wild' and not wild then base := 0; wtrig := true; end if;
  smult := case when base > 0 and not wild then 1 + 0.1 * least(public.lr_n(g, 'streak'), 5) else 1 end;
  mult := base * (case when wild then 8.7 when free then (c ->> 'freeMult')::numeric else 1 end) * smult * public.lr_wm(c, 'slots');
  if public.lr_has(g, 'lightning') and base > 0 and public.lr_rand(1000) < 10 then
    roll := public.lr_rand(100);
    bolt := case when roll < 70 then 2 when roll < 90 then 3 when roll < 98 then 5 else 10 end;
  end if;
  win := floor(mult * bet * greatest(bolt, 1));
  if base = 0 and public.lr_has(g, 'piggy') then refund := floor(bet * 0.02); end if;
  g := public.lr_add(g, 'credits', win + refund) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win),
    'streak', case when base > 0 then public.lr_n(g, 'streak') + 1 else 0 end);
  if wild then g := public.lr_add(g, 'wildTotal', win); elsif free then g := public.lr_add(g, 'freeTotal', win); end if;
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
  if wtrig then
    if not wild then g := g || jsonb_build_object('wildBet', bet, 'wildTotal', 0); end if;
    g := public.lr_add(g, 'wildSpins', 10);
  end if;
  if wild then
    sticky := array(select sticky[k] or syms[k] = 'wild' from generate_series(1, 3) k);
    sl := sl || jsonb_build_object('sticky', to_jsonb(sticky));
  end if;
  if wild and public.lr_n(g, 'wildSpins') = 0 then sl := sl || '{"inWild": false, "sticky": [false, false, false]}'; wover := true; end if;
  if free and not wild and public.lr_n(g, 'freeSpins') = 0 then sl := sl || '{"inBonus": false}'; over := true; end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(tg), 'lastBet', bet);
  g := public.lr_ach(g || jsonb_build_object('sl', sl), jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet, 'jackpot', coalesce(line = 'seven', false),
    'triggered', trig, 'bet', bet, 'wildLine', line is not null and 'wild' = any(syms)));
  return public.lr_put(p.id, g, jsonb_build_object('targets', to_jsonb(tg), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'smult', smult,
    'mult', round(mult * greatest(bolt, 1), 2), 'bolt', bolt, 'win', win, 'refund', refund, 'bet', bet, 'free', free, 'stars', sc, 'wilds', wc,
    'triggered', trig, 'nudgesAdded', nadd, 'jackpot', coalesce(line = 'seven', false), 'bonusOver', over, 'held', to_jsonb(holds), 'wild', wild, 'wildTrig', wtrig, 'wildOver', wover, 'wildTotal', public.lr_n(g, 'wildTotal'), 'sticky', to_jsonb(sticky)));
end;
$$;


-- ---------------------------------------------------------------------------
-- Wilds replace every symbol: run this part once (after "More sticky wilds"). A wild now also stands in for stars
-- and counts as a cherry for the small cherry wins. So that the slots don't pay more than before, two cherries pay
-- 1x instead of 1.5x and a cherry on reel one 0.45x instead of 0.5x (the payout rate stays as it was), and wins in
-- wild spins count x8.1 instead of x8.7 (still about 80x the bet per bonus).
create or replace function public.lr_line(a text, b text, c text) returns text language sql immutable as $$
  select case
    when n = 0 then 'wild'
    when cnt = 1 then s
  end
  from (select count(*) filter (where x <> 'wild') n, count(distinct x) filter (where x <> 'wild') cnt, max(x) filter (where x <> 'wild') s
    from unnest(array[a, b, c]) x) q
$$;

create or replace function public.lr_payout(g jsonb, c jsonb, a text, b text, cc text) returns numeric language plpgsql immutable as $$
declare
  line text := public.lr_line(a, b, cc);
  cherries integer := (a in ('cherry', 'wild'))::integer + (b in ('cherry', 'wild'))::integer + (cc in ('cherry', 'wild'))::integer;
begin
  if line = 'seven' then return (c ->> 'jackpotPay')::numeric + 8 * public.lr_n(g -> 'owned', 'horseshoe'); end if;
  if line = 'cherry' and public.lr_has(g, 'goldCherry') then return 3.5; end if;
  if line is not null then return case line when 'wild' then 80 when 'star' then 40 when 'bar' then 20 when 'bell' then 10 when 'plum' then 6 when 'lemon' then 4 else 3 end; end if;
  if cherries >= 2 then return 1; end if;
  if a in ('cherry', 'wild') then return 0.45; end if;
  return 0;
end;
$$;

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
  wild boolean := false;
  wtrig boolean := false;
  wover boolean := false;
  sticky boolean[] := array[false, false, false];
  nst integer;
  forced boolean := false;
begin
  if (c ->> 'maintenance')::boolean and not p.is_admin then raise exception 'paused'; end if;
  sl := coalesce(g -> 'sl', '{}'::jsonb);
  if sl ? 'gm' then raise exception 'gamble open'; end if;
  pos := coalesce(array(select (x #>> '{}')::integer from jsonb_array_elements(sl -> 'pos') x), '{}');
  if coalesce(array_length(pos, 1), 0) <> 3 then pos := array[public.lr_rand(27), public.lr_rand(27), public.lr_rand(27)]; end if;
  -- wild spins (from three wilds) come first, then free spins
  wild := public.lr_n(g, 'wildSpins') > 0;
  free := wild or public.lr_n(g, 'freeSpins') > 0;
  if wild then
    bet := greatest(1, public.lr_n(g, 'wildBet'));
    g := public.lr_add(g, 'wildSpins', -1);
    if not coalesce((sl ->> 'inWild')::boolean, false) then g := g || jsonb_build_object('wildTotal', 0); sl := sl || '{"inWild": true, "sticky": [false, false, false]}'; end if;
    -- wilds rolled during wild spins stick: their reels stay as they are
    sticky := coalesce(array(select (x #>> '{}')::boolean from jsonb_array_elements(sl -> 'sticky') x), array[false, false, false]);
    if coalesce(array_length(sticky, 1), 0) <> 3 then sticky := array[false, false, false]; end if;
    holds := sticky;
  elsif free then
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
  -- what was bet counts towards the missions' pay
  if not free then g := public.lr_stake(g, bet); end if;
  sl := sl || jsonb_build_object('holdOffer', false, 'nudgeOpen', false, 'gamble', 0);
  tg := array(select case when holds[i] then pos[i] else public.lr_rand(27) end from generate_series(1, 3) i);
  -- three sevens are a bit rarer than the reels alone make them: a quarter of them get the last free reel drawn again
  if wild then
    -- in wild spins the reels carry no sevens, stars or bars, and a wild rarely sticks:
    -- 60% for the first, 0.2% for the second, 0.05% for the third (the others are drawn again)
    nst := (select count(*) from unnest(sticky) x where x);
    for k in 1 .. 3 loop
      if holds[k] then continue; end if;
      loop
        tg[k] := public.lr_rand(27);
        exit when strip[tg[k] + 1] not in ('seven', 'star', 'bar', 'wild')
          or (strip[tg[k] + 1] = 'wild' and random() < (array[0.6, 0.002, 0.0005])[least(nst, 2) + 1]);
      end loop;
      if strip[tg[k] + 1] = 'wild' then nst := nst + 1; end if;
    end loop;
  elsif not free and coalesce((sl ->> 'forceWild')::boolean, false) and p.is_admin then
    -- the admin's own test: this spin lands three wilds
    tg := array[2, 2, 2];
    forced := true;
    sl := sl - 'forceWild';
  end if;
  free7 := case when wild or forced then null else (select i from unnest(array[3, 2, 1]) i where not holds[i] limit 1) end;
  if free7 is not null and public.lr_line(strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]) = 'seven' and public.lr_rand(100) < 25 then
    tg[free7] := public.lr_rand(27);
  end if;
  syms := array[strip[tg[1] + 1], strip[tg[2] + 1], strip[tg[3] + 1]];
  line := public.lr_line(syms[1], syms[2], syms[3]);
  base := public.lr_payout(g, c, syms[1], syms[2], syms[3]);
  -- three wilds pay nothing straight away: they start 10 wild spins where every win counts x13 (on average about 80x the bet)
  if line = 'wild' and not wild then base := 0; wtrig := true; end if;
  smult := case when base > 0 and not wild then 1 + 0.1 * least(public.lr_n(g, 'streak'), 5) else 1 end;
  mult := base * (case when wild then 8.1 when free then (c ->> 'freeMult')::numeric else 1 end) * smult * public.lr_wm(c, 'slots');
  if public.lr_has(g, 'lightning') and base > 0 and public.lr_rand(1000) < 10 then
    roll := public.lr_rand(100);
    bolt := case when roll < 70 then 2 when roll < 90 then 3 when roll < 98 then 5 else 10 end;
  end if;
  win := floor(mult * bet * greatest(bolt, 1));
  if base = 0 and public.lr_has(g, 'piggy') then refund := floor(bet * 0.02); end if;
  g := public.lr_add(g, 'credits', win + refund) || jsonb_build_object('lastWin', win, 'best', greatest(public.lr_n(g, 'best'), win),
    'streak', case when base > 0 then public.lr_n(g, 'streak') + 1 else 0 end);
  if wild then g := public.lr_add(g, 'wildTotal', win); elsif free then g := public.lr_add(g, 'freeTotal', win); end if;
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
  if wtrig then
    if not wild then g := g || jsonb_build_object('wildBet', bet, 'wildTotal', 0); end if;
    g := public.lr_add(g, 'wildSpins', 10);
  end if;
  if wild then
    sticky := array(select sticky[k] or syms[k] = 'wild' from generate_series(1, 3) k);
    sl := sl || jsonb_build_object('sticky', to_jsonb(sticky));
  end if;
  if wild and public.lr_n(g, 'wildSpins') = 0 then sl := sl || '{"inWild": false, "sticky": [false, false, false]}'; wover := true; end if;
  if free and not wild and public.lr_n(g, 'freeSpins') = 0 then sl := sl || '{"inBonus": false}'; over := true; end if;
  sl := sl || jsonb_build_object('pos', to_jsonb(tg), 'lastBet', bet);
  g := public.lr_ach(g || jsonb_build_object('sl', sl), jsonb_build_object('win', win, 'three', line is not null, 'ratio', win / bet, 'jackpot', coalesce(line = 'seven', false),
    'triggered', trig, 'bet', bet, 'wildLine', line is not null and 'wild' = any(syms)));
  return public.lr_put(p.id, g, jsonb_build_object('targets', to_jsonb(tg), 'syms', to_jsonb(syms), 'line', line, 'base', base, 'smult', smult,
    'mult', round(mult * greatest(bolt, 1), 2), 'bolt', bolt, 'win', win, 'refund', refund, 'bet', bet, 'free', free, 'stars', sc, 'wilds', wc,
    'triggered', trig, 'nudgesAdded', nadd, 'jackpot', coalesce(line = 'seven', false), 'bonusOver', over, 'held', to_jsonb(holds), 'wild', wild, 'wildTrig', wtrig, 'wildOver', wover, 'wildTotal', public.lr_n(g, 'wildTotal'), 'sticky', to_jsonb(sticky)));
end;
$$;
