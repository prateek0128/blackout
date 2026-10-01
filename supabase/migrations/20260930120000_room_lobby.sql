-- BLACKOUT Phase 2: room lifecycle, anonymous player membership, and lobby RPCs.
-- All state-changing operations run with the database as the authority.

create extension if not exists pgcrypto with schema extensions;

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  host_player_id uuid,
  status text not null default 'LOBBY'
    check (status in ('LOBBY', 'STARTING', 'IN_GAME', 'COMPLETED', 'EXPIRED')),
  max_players smallint not null default 6 check (max_players between 3 and 6),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '60 minutes'),
  constraint rooms_code_format check (room_code ~ '^[A-HJ-NP-Z2-9]{5}$')
);

create table public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 2 and 18),
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ready boolean not null default false,
  connection_state text not null default 'connected'
    check (connection_state in ('connected', 'disconnected')),
  is_host boolean not null default false,
  left_at timestamptz,
  constraint room_players_room_user_unique unique (room_id, auth_user_id)
);

create unique index room_players_one_active_room_per_user
  on public.room_players(auth_user_id)
  where left_at is null;
create index room_players_room_active_order
  on public.room_players(room_id, joined_at, id)
  where left_at is null;
create index rooms_lobby_expiration on public.rooms(expires_at) where status = 'LOBBY';

alter table public.rooms
  add constraint rooms_host_membership_fk
  foreign key (host_player_id)
  references public.room_players(id)
  on delete set null;

create unique index room_players_single_host
  on public.room_players(room_id)
  where is_host and left_at is null;

create or replace function public.set_room_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger rooms_set_updated_at
before update on public.rooms
for each row execute function public.set_room_updated_at();

revoke all on function public.set_room_updated_at() from public, anon, authenticated;

create or replace function public.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_players rp
    where rp.room_id = p_room_id
      and rp.auth_user_id = (select auth.uid())
      and rp.left_at is null
  );
$$;

revoke all on function public.is_room_member(uuid) from public, anon;
grant execute on function public.is_room_member(uuid) to authenticated;

create or replace function public.is_current_user_lobby_channel_member()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_topic text := realtime.topic();
  v_room_id uuid;
begin
  if v_topic is null or v_topic not like 'blackout:lobby:%' then return false; end if;
  begin
    v_room_id := split_part(v_topic, ':', 3)::uuid;
  exception when invalid_text_representation then
    return false;
  end;
  return public.is_room_member(v_room_id);
end;
$$;

revoke all on function public.is_current_user_lobby_channel_member() from public, anon;
grant execute on function public.is_current_user_lobby_channel_member() to authenticated;

create policy "Room members can receive private lobby presence"
  on realtime.messages for select to authenticated
  using (
    extension = 'presence'
    and public.is_current_user_lobby_channel_member()
  );
create policy "Room members can publish private lobby presence"
  on realtime.messages for insert to authenticated
  with check (
    extension = 'presence'
    and public.is_current_user_lobby_channel_member()
  );

alter table public.rooms enable row level security;
alter table public.room_players enable row level security;

create policy "Room members can read their room"
  on public.rooms for select to authenticated
  using (public.is_room_member(id));
create policy "Room members can read the roster"
  on public.room_players for select to authenticated
  using (public.is_room_member(room_id));

grant select on public.rooms, public.room_players to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.rooms from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.room_players from anon, authenticated;

create or replace function public.blackout_room_snapshot(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_player public.room_players%rowtype;
  v_room public.rooms%rowtype;
  v_players jsonb;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;

  select rp.* into v_player
  from public.room_players rp
  where rp.room_id = p_room_id and rp.auth_user_id = v_user_id and rp.left_at is null;
  if not found then
    raise exception using message = 'ROOM_MEMBERSHIP_REQUIRED', errcode = 'P0001';
  end if;

  select r.* into v_room from public.rooms r where r.id = p_room_id;
  if not found then
    raise exception using message = 'ROOM_NOT_FOUND', errcode = 'P0001';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', rp.id,
    'display_name', rp.display_name,
    'joined_at', rp.joined_at,
    'last_seen_at', rp.last_seen_at,
    'ready', rp.ready,
    'connection_state', case
      when rp.left_at is not null then 'left'
      when rp.last_seen_at < now() - interval '45 seconds' then 'disconnected'
      else 'connected'
    end,
    'is_host', rp.id = v_room.host_player_id,
    'is_current_player', rp.id = v_player.id
  ) order by rp.joined_at, rp.id) filter (where rp.left_at is null), '[]'::jsonb)
  into v_players
  from public.room_players rp
  where rp.room_id = p_room_id;

  return jsonb_build_object(
    'room', jsonb_build_object(
      'id', v_room.id,
      'room_code', v_room.room_code,
      'host_player_id', v_room.host_player_id,
      'status', v_room.status,
      'max_players', v_room.max_players,
      'created_at', v_room.created_at,
      'updated_at', v_room.updated_at,
      'expires_at', v_room.expires_at
    ),
    'players', v_players,
    'current_player_id', v_player.id
  );
end;
$$;

create or replace function public.create_room(p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
  v_player_id uuid;
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_attempt integer;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  if char_length(btrim(coalesce(p_display_name, ''))) not between 2 and 18 then
    raise exception using message = 'INVALID_DISPLAY_NAME', errcode = 'P0001';
  end if;

  update public.room_players rp
  set left_at = now(), ready = false, connection_state = 'disconnected'
  from public.rooms r
  where rp.room_id = r.id and rp.auth_user_id = v_user_id and rp.left_at is null
    and (r.status = 'EXPIRED' or r.expires_at <= now());
  update public.rooms r set status = 'EXPIRED'
  where r.status in ('LOBBY', 'STARTING') and r.expires_at <= now();

  if exists (
    select 1 from public.room_players rp
    join public.rooms r on r.id = rp.room_id
    where rp.auth_user_id = v_user_id and rp.left_at is null
      and r.status in ('LOBBY', 'STARTING') and r.expires_at > now()
  ) then
    raise exception using message = 'ALREADY_IN_ROOM', errcode = 'P0001';
  end if;

  for v_attempt in 1..10 loop
    v_code := '';
    for i in 1..5 loop
      v_code := v_code || substr(v_alphabet, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % length(v_alphabet)), 1);
    end loop;
    begin
      insert into public.rooms(room_code) values (v_code) returning id into v_room_id;
      exit;
    exception when unique_violation then
      if v_attempt = 10 then
        raise exception using message = 'ROOM_CODE_GENERATION_FAILED', errcode = 'P0001';
      end if;
    end;
  end loop;

  insert into public.room_players(room_id, auth_user_id, display_name, is_host)
  values (v_room_id, v_user_id, btrim(p_display_name), true)
  returning id into v_player_id;
  update public.rooms set host_player_id = v_player_id where id = v_room_id;
  return public.blackout_room_snapshot(v_room_id);
end;
$$;

create or replace function public.join_room(p_room_code text, p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_existing public.room_players%rowtype;
  v_existing_found boolean := false;
  v_count integer;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  if char_length(btrim(coalesce(p_display_name, ''))) not between 2 and 18 then
    raise exception using message = 'INVALID_DISPLAY_NAME', errcode = 'P0001';
  end if;
  if upper(regexp_replace(coalesce(p_room_code, ''), '[[:space:]]', '', 'g')) !~ '^[A-HJ-NP-Z2-9]{5}$' then
    raise exception using message = 'INVALID_ROOM_CODE', errcode = 'P0001';
  end if;

  select r.* into v_room from public.rooms r
  where r.room_code = upper(regexp_replace(p_room_code, '[[:space:]]', '', 'g'))
  for update;
  if not found then
    raise exception using message = 'ROOM_NOT_FOUND', errcode = 'P0001';
  end if;
  if v_room.expires_at <= now() or v_room.status = 'EXPIRED' then
    raise exception using message = 'ROOM_EXPIRED', errcode = 'P0001';
  end if;
  if v_room.status <> 'LOBBY' then
    raise exception using message = 'ROOM_NOT_JOINABLE', errcode = 'P0001';
  end if;

  select rp.* into v_existing from public.room_players rp
  where rp.room_id = v_room.id and rp.auth_user_id = v_user_id;
  v_existing_found := found;
  if v_existing_found and v_existing.left_at is null then
    update public.room_players set display_name = btrim(p_display_name), last_seen_at = now(), connection_state = 'connected'
    where id = v_existing.id;
    return public.blackout_room_snapshot(v_room.id);
  end if;
  if exists (select 1 from public.room_players rp where rp.auth_user_id = v_user_id and rp.left_at is null) then
    raise exception using message = 'ALREADY_IN_ROOM', errcode = 'P0001';
  end if;

  select count(*) into v_count from public.room_players rp where rp.room_id = v_room.id and rp.left_at is null;
  if v_count >= v_room.max_players then
    raise exception using message = 'ROOM_FULL', errcode = 'P0001';
  end if;

  if v_existing_found then
    update public.room_players set display_name = btrim(p_display_name), joined_at = now(), last_seen_at = now(),
      ready = false, connection_state = 'connected', left_at = null
    where id = v_existing.id;
  else
    insert into public.room_players(room_id, auth_user_id, display_name)
    values (v_room.id, v_user_id, btrim(p_display_name));
  end if;
  return public.blackout_room_snapshot(v_room.id);
end;
$$;

create or replace function public.get_my_lobby()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;
  update public.rooms set status = 'EXPIRED'
    where status in ('LOBBY', 'STARTING') and expires_at <= now();
  update public.room_players rp set left_at = now(), ready = false, connection_state = 'disconnected'
    from public.rooms r
    where rp.room_id = r.id and rp.auth_user_id = v_user_id and rp.left_at is null and r.status = 'EXPIRED';
  select rp.room_id into v_room_id
    from public.room_players rp join public.rooms r on r.id = rp.room_id
    where rp.auth_user_id = v_user_id and rp.left_at is null and r.status in ('LOBBY', 'STARTING')
    order by rp.joined_at desc limit 1;
  if v_room_id is null then return null; end if;
  update public.room_players set last_seen_at = now(), connection_state = 'connected'
    where room_id = v_room_id and auth_user_id = v_user_id and left_at is null;
  return public.blackout_room_snapshot(v_room_id);
end;
$$;

create or replace function public.heartbeat_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_player public.room_players%rowtype;
  v_next_host uuid;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;
  select r.* into v_room from public.rooms r where r.id = p_room_id for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND', errcode = 'P0001'; end if;
  select rp.* into v_player from public.room_players rp
    where rp.room_id = p_room_id and rp.auth_user_id = v_user_id and rp.left_at is null;
  if not found then raise exception using message = 'ROOM_MEMBERSHIP_REQUIRED', errcode = 'P0001'; end if;

  if v_room.expires_at <= now() and v_room.status in ('LOBBY', 'STARTING') then
    update public.rooms set status = 'EXPIRED' where id = p_room_id;
    update public.room_players set left_at = now(), ready = false, connection_state = 'disconnected'
      where room_id = p_room_id and left_at is null;
    raise exception using message = 'ROOM_EXPIRED', errcode = 'P0001';
  end if;

  update public.room_players set last_seen_at = now(), connection_state = 'connected'
    where id = v_player.id;
  update public.room_players set connection_state = 'disconnected'
    where room_id = p_room_id and left_at is null and last_seen_at < now() - interval '45 seconds'
      and connection_state <> 'disconnected';

  if v_room.status = 'LOBBY' and exists (
    select 1 from public.room_players rp
    where rp.id = v_room.host_player_id and rp.left_at is null and rp.last_seen_at < now() - interval '45 seconds'
  ) then
    select rp.id into v_next_host from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.id <> v_room.host_player_id
      and rp.last_seen_at >= now() - interval '45 seconds'
    order by rp.joined_at, rp.id limit 1;
    if v_next_host is not null then
      update public.room_players set is_host = false where id = v_room.host_player_id;
      update public.room_players set is_host = true where id = v_next_host;
      update public.rooms set host_player_id = v_next_host where id = p_room_id;
    end if;
  end if;
  return public.blackout_room_snapshot(p_room_id);
end;
$$;

create or replace function public.set_player_ready(p_room_id uuid, p_ready boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
begin
  if v_user_id is null then raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select r.* into v_room from public.rooms r where r.id = p_room_id for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND', errcode = 'P0001'; end if;
  if v_room.status <> 'LOBBY' then raise exception using message = 'ROOM_NOT_LOBBY', errcode = 'P0001'; end if;
  if v_room.expires_at <= now() then raise exception using message = 'ROOM_EXPIRED', errcode = 'P0001'; end if;
  update public.room_players set ready = p_ready, last_seen_at = now(), connection_state = 'connected'
    where room_id = p_room_id and auth_user_id = v_user_id and left_at is null;
  if not found then raise exception using message = 'ROOM_MEMBERSHIP_REQUIRED', errcode = 'P0001'; end if;
  return public.blackout_room_snapshot(p_room_id);
end;
$$;

create or replace function public.leave_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_player public.room_players%rowtype;
  v_next_host uuid;
begin
  if v_user_id is null then raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 0));
  select r.* into v_room from public.rooms r where r.id = p_room_id for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND', errcode = 'P0001'; end if;
  select rp.* into v_player from public.room_players rp
    where rp.room_id = p_room_id and rp.auth_user_id = v_user_id and rp.left_at is null;
  if not found then raise exception using message = 'ROOM_MEMBERSHIP_REQUIRED', errcode = 'P0001'; end if;

  update public.room_players set left_at = now(), ready = false, connection_state = 'disconnected', is_host = false
    where id = v_player.id;
  if v_room.status = 'LOBBY' and v_room.host_player_id = v_player.id then
    select rp.id into v_next_host from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.last_seen_at >= now() - interval '45 seconds'
    order by rp.joined_at, rp.id limit 1;
    if v_next_host is null then
      update public.rooms set host_player_id = null, status = 'EXPIRED' where id = p_room_id;
    else
      update public.room_players set is_host = true where id = v_next_host;
      update public.rooms set host_player_id = v_next_host where id = p_room_id;
    end if;
  end if;
  if v_room.status = 'LOBBY' and not exists (
    select 1 from public.room_players rp where rp.room_id = p_room_id and rp.left_at is null
  ) then
    update public.rooms set status = 'EXPIRED', host_player_id = null where id = p_room_id;
  end if;
  return jsonb_build_object('left', true, 'room_id', p_room_id);
end;
$$;

create or replace function public.start_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms%rowtype;
  v_connected_count integer;
begin
  if v_user_id is null then raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001'; end if;
  select r.* into v_room from public.rooms r where r.id = p_room_id for update;
  if not found then raise exception using message = 'ROOM_NOT_FOUND', errcode = 'P0001'; end if;
  if v_room.status <> 'LOBBY' then raise exception using message = 'ROOM_NOT_LOBBY', errcode = 'P0001'; end if;
  if v_room.expires_at <= now() then raise exception using message = 'ROOM_EXPIRED', errcode = 'P0001'; end if;
  if not exists (
    select 1 from public.room_players rp
    where rp.id = v_room.host_player_id and rp.auth_user_id = v_user_id and rp.left_at is null
      and rp.last_seen_at >= now() - interval '45 seconds'
  ) then raise exception using message = 'HOST_REQUIRED', errcode = 'P0001'; end if;

  select count(*) into v_connected_count from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.last_seen_at >= now() - interval '45 seconds';
  if v_connected_count < 3 then raise exception using message = 'NOT_ENOUGH_PLAYERS', errcode = 'P0001'; end if;
  if exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.last_seen_at >= now() - interval '45 seconds'
      and not rp.ready
  ) then raise exception using message = 'PLAYERS_NOT_READY', errcode = 'P0001'; end if;

  update public.rooms set status = 'STARTING' where id = p_room_id;
  return public.blackout_room_snapshot(p_room_id);
end;
$$;

revoke all on function public.blackout_room_snapshot(uuid) from public, anon;
revoke all on function public.create_room(text) from public, anon;
revoke all on function public.join_room(text, text) from public, anon;
revoke all on function public.get_my_lobby() from public, anon;
revoke all on function public.heartbeat_room(uuid) from public, anon;
revoke all on function public.set_player_ready(uuid, boolean) from public, anon;
revoke all on function public.leave_room(uuid) from public, anon;
revoke all on function public.start_room(uuid) from public, anon;
grant execute on function public.create_room(text) to authenticated;
grant execute on function public.join_room(text, text) to authenticated;
grant execute on function public.get_my_lobby() to authenticated;
grant execute on function public.heartbeat_room(uuid) to authenticated;
grant execute on function public.set_player_ready(uuid, boolean) to authenticated;
grant execute on function public.leave_room(uuid) to authenticated;
grant execute on function public.start_room(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rooms') then
      alter publication supabase_realtime add table public.rooms;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_players') then
      alter publication supabase_realtime add table public.room_players;
    end if;
  end if;
end;
$$;
