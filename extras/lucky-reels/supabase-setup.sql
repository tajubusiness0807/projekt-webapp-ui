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
