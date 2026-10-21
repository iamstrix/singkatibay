-- Online rooms: two players join by code, build at the same time on their own devices,
-- and the server records when each one locked in. Picks stay secret until both are in;
-- both clients then run the same rules on the same picks, so results always match.

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host uuid not null references auth.users (id) on delete cascade,
  guest uuid references auth.users (id) on delete set null,
  seed int not null,
  round smallint not null default 0,
  status text not null default 'lobby' check (status in ('lobby', 'build', 'reveal', 'closed')),
  build_start timestamptz,          -- building opens at this time; it lasts 60 seconds
  locked0 timestamptz,              -- when the host locked in this round
  locked1 timestamptz,              -- when the guest locked in this round
  ready0 boolean not null default false,  -- ready for the next round
  ready1 boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.rooms enable row level security;
grant select on public.rooms to authenticated;

create policy "players see the rooms they are in"
  on public.rooms for select to authenticated
  using ((select auth.uid()) = host or (select auth.uid()) = guest);

-- Room updates are pushed to both players through Supabase Realtime.
alter publication supabase_realtime add table public.rooms;

-- No grants: picks are only reachable through the functions below, so neither player
-- can read the other's build before both have locked in.
create table public.picks (
  room_id uuid not null references public.rooms (id) on delete cascade,
  round smallint not null,
  player smallint not null check (player in (0, 1)),
  pick jsonb not null,
  locked_at timestamptz not null,
  primary key (room_id, round, player)
);

alter table public.picks enable row level security;

create function public.server_now()
returns timestamptz
language sql stable
as $$ select now() $$;

create function public.create_room()
returns public.rooms
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- no 0/O or 1/I/L
  c text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  -- one open lobby per player
  update public.rooms set status = 'closed' where host = auth.uid() and status = 'lobby';
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    begin
      insert into public.rooms (code, host, seed)
      values (c, auth.uid(), 10000 + floor(random() * 90000)::int)
      returning * into r;
      return r;
    exception when unique_violation then
      -- code already taken, try another
    end;
  end loop;
end;
$$;

create function public.join_room(p_code text)
returns public.rooms
language plpgsql security definer set search_path = ''
as $$
declare r public.rooms;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into r from public.rooms
    where code = upper(trim(p_code)) and status <> 'closed'
    for update;
  if not found or r.created_at < now() - interval '1 day' then
    raise exception 'Room not found';
  end if;
  if auth.uid() = r.host or auth.uid() is not distinct from r.guest then return r; end if;
  if r.guest is not null then raise exception 'Room is full'; end if;
  update public.rooms set guest = auth.uid() where id = r.id returning * into r;
  return r;
end;
$$;

-- Round 0: the host starts the match once a guest has joined.
-- Later rounds: each player marks themselves ready; the round starts when both are.
-- Building opens 12 seconds after the start so both devices can show the flyover and warning.
create function public.start_round(p_room uuid, p_round int)
returns public.rooms
language plpgsql security definer set search_path = ''
as $$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room for update;
  if not found or (auth.uid() is distinct from r.host and auth.uid() is distinct from r.guest) then
    raise exception 'Room not found';
  end if;
  if r.status = 'build' and r.round = p_round then return r; end if;

  if p_round = 0 then
    if r.status <> 'lobby' or auth.uid() <> r.host or r.guest is null then
      raise exception 'The match cannot start yet';
    end if;
  else
    if r.status <> 'reveal' or p_round <> r.round + 1 or p_round > 2 then
      raise exception 'The next round cannot start yet';
    end if;
    if auth.uid() = r.host then
      update public.rooms set ready0 = true where id = p_room returning * into r;
    else
      update public.rooms set ready1 = true where id = p_room returning * into r;
    end if;
    if not (r.ready0 and r.ready1) then return r; end if;
  end if;

  update public.rooms
    set round = p_round, status = 'build', build_start = now() + interval '12 seconds',
        locked0 = null, locked1 = null, ready0 = false, ready1 = false
    where id = p_room
    returning * into r;
  return r;
end;
$$;

create function public.lock_in(p_room uuid, p_round int, p_pick jsonb)
returns public.rooms
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  me smallint;
  t timestamptz := greatest(now(), (select build_start from public.rooms where id = p_room));
begin
  select * into r from public.rooms where id = p_room for update;
  if not found then raise exception 'Room not found'; end if;
  me := case when auth.uid() = r.host then 0 when auth.uid() = r.guest then 1 end;
  if me is null then raise exception 'Room not found'; end if;
  if r.status <> 'build' or r.round <> p_round then raise exception 'Not in the build phase'; end if;
  if octet_length(p_pick::text) > 2000 then raise exception 'Build data is too large'; end if;

  -- the first lock-in counts; repeats are ignored
  insert into public.picks (room_id, round, player, pick, locked_at)
    values (p_room, p_round, me, p_pick, t)
    on conflict do nothing;
  update public.rooms
    set locked0 = case when me = 0 then coalesce(locked0, t) else locked0 end,
        locked1 = case when me = 1 then coalesce(locked1, t) else locked1 end
    where id = p_room
    returning * into r;
  if r.locked0 is not null and r.locked1 is not null then
    update public.rooms set status = 'reveal' where id = p_room returning * into r;
  end if;
  return r;
end;
$$;

-- If a player disconnects, the other can end the round 20 seconds after the build timer
-- runs out. The missing player gets an empty build, which the game turns into an auto-pick.
create function public.claim_timeout(p_room uuid, p_round int)
returns public.rooms
language plpgsql security definer set search_path = ''
as $$
declare
  r public.rooms;
  deadline timestamptz;
begin
  select * into r from public.rooms where id = p_room for update;
  if not found or (auth.uid() is distinct from r.host and auth.uid() is distinct from r.guest) then
    raise exception 'Room not found';
  end if;
  if r.status <> 'build' or r.round <> p_round then return r; end if;
  deadline := r.build_start + interval '60 seconds';
  if now() < deadline + interval '20 seconds' then return r; end if;

  insert into public.picks (room_id, round, player, pick, locked_at)
    select p_room, p_round, pl, '{}'::jsonb, deadline
    from (values (0::smallint), (1::smallint)) as v (pl)
    on conflict do nothing;
  update public.rooms
    set locked0 = coalesce(locked0, deadline), locked1 = coalesce(locked1, deadline), status = 'reveal'
    where id = p_room
    returning * into r;
  return r;
end;
$$;

-- Both builds for a round, only once both players have locked in.
create function public.get_picks(p_room uuid, p_round int)
returns table (player smallint, pick jsonb, locked_at timestamptz, build_start timestamptz)
language plpgsql security definer set search_path = ''
as $$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room;
  if not found or (auth.uid() is distinct from r.host and auth.uid() is distinct from r.guest) then
    raise exception 'Room not found';
  end if;
  if (select count(*) from public.picks p where p.room_id = p_room and p.round = p_round) < 2 then
    return;
  end if;
  return query
    select p.player, p.pick, p.locked_at, r.build_start
    from public.picks p
    where p.room_id = p_room and p.round = p_round
    order by p.player;
end;
$$;

create function public.leave_room(p_room uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.rooms set status = 'closed'
    where id = p_room and (auth.uid() = host or auth.uid() = guest);
end;
$$;

revoke execute on function
  public.server_now(), public.create_room(), public.join_room(text),
  public.start_round(uuid, int), public.lock_in(uuid, int, jsonb),
  public.claim_timeout(uuid, int), public.get_picks(uuid, int), public.leave_room(uuid)
  from public, anon;
grant execute on function
  public.server_now(), public.create_room(), public.join_room(text),
  public.start_round(uuid, int), public.lock_in(uuid, int, jsonb),
  public.claim_timeout(uuid, int), public.get_picks(uuid, int), public.leave_room(uuid)
  to authenticated;
