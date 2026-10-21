-- Every change to a room bumps its version, so clients can ignore room data that arrives
-- out of order (e.g. a slow backup poll answering after a newer realtime update).

alter table public.rooms add column version bigint not null default 0;

create function public.bump_room_version()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.version := old.version + 1;
  return new;
end;
$$;

create trigger rooms_bump_version
  before update on public.rooms
  for each row execute function public.bump_room_version();
