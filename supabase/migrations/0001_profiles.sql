-- Player profiles: one row per account, guest or signed up.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Guest',
  created_at timestamptz not null default now(),
  constraint display_name_length check (char_length(display_name) between 1 and 24)
);

alter table public.profiles enable row level security;

-- New tables are not exposed to the Data API automatically, so grant only what the policies need.
grant select, update (display_name) on public.profiles to authenticated;

-- Anyone signed in (including guests) can see names, e.g. an opponent's in a room.
create policy "profiles are readable by signed-in players"
  on public.profiles for select to authenticated using (true);

create policy "players update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Create the profile automatically when an account (or anonymous guest) is created.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
