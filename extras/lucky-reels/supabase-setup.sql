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

-- Check: this should list both players.
select name, credits from public.players order by name;
