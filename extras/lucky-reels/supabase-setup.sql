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
