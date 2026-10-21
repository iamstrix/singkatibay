-- Lobby ready-up: each player marks themselves ready (or not ready) after naming.
-- The match starts on its own once a guest has joined and both players are ready.
-- Reuses rooms.ready0 / ready1, which start_round also uses between rounds.

create function public.set_ready(p_room uuid, p_ready boolean)
returns public.rooms
language plpgsql security definer set search_path = ''
as $$
declare r public.rooms;
begin
  select * into r from public.rooms where id = p_room for update;
  if not found or (auth.uid() is distinct from r.host and auth.uid() is distinct from r.guest) then
    raise exception 'Room not found';
  end if;
  if r.status <> 'lobby' then return r; end if;

  if auth.uid() = r.host then
    update public.rooms set ready0 = p_ready where id = p_room returning * into r;
  else
    update public.rooms set ready1 = p_ready where id = p_room returning * into r;
  end if;

  if r.guest is not null and r.ready0 and r.ready1 then
    update public.rooms
      set round = 0, status = 'build', build_start = now() + interval '12 seconds',
          locked0 = null, locked1 = null, ready0 = false, ready1 = false
      where id = p_room
      returning * into r;
  end if;
  return r;
end;
$$;

revoke execute on function public.set_ready(uuid, boolean) from public, anon;
grant execute on function public.set_ready(uuid, boolean) to authenticated;
