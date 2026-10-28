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
