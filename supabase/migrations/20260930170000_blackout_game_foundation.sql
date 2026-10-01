-- BLACKOUT Phase 3A: authoritative game creation, private role/objective data,
-- shared facility state, and private game-channel authorization.

create table public.blackout_games (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null unique references public.rooms(id) on delete cascade,
  state text not null default 'STARTING'
    check (state in ('STARTING', 'ROLE_REVEAL', 'FACILITY_INTRO', 'ACTIVE', 'DISCUSSION', 'VOTING', 'FINAL_BLACKOUT', 'ESCAPE', 'RESULTS')),
  power smallint not null default 100 check (power between 0 and 100),
  security smallint not null default 20 check (security between 0 and 100),
  facility_integrity smallint not null default 100 check (facility_integrity between 0 and 100),
  created_at timestamptz not null default now(),
  state_started_at timestamptz not null default now(),
  state_deadline_at timestamptz,
  active_started_at timestamptz,
  active_deadline_at timestamptz,
  constraint blackout_games_active_deadline_check check (
    active_deadline_at is null or active_started_at is not null and active_deadline_at >= active_started_at
  )
);

create index blackout_games_state_deadline on public.blackout_games(state, state_deadline_at);

create table public.blackout_players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  room_player_id uuid not null references public.room_players(id) on delete cascade,
  display_name text not null,
  connection_state text not null default 'connected' check (connection_state in ('connected', 'disconnected')),
  is_alive boolean not null default true,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint blackout_players_game_room_player_unique unique (game_id, room_player_id)
);

create index blackout_players_game_active_order on public.blackout_players(game_id, created_at, id) where is_active;

-- Roles, objectives, and personal information are stored outside the shared roster.
create table public.blackout_objectives (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  blackout_player_id uuid not null unique references public.blackout_players(id) on delete cascade,
  secret_role text not null check (secret_role in ('SABOTEUR', 'HACKER', 'SCOUT', 'ENGINEER')),
  objective text not null,
  personal_information jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index blackout_objectives_one_saboteur_per_game
  on public.blackout_objectives(game_id) where secret_role = 'SABOTEUR';
create index blackout_objectives_game_lookup on public.blackout_objectives(game_id);

create or replace function public.is_blackout_game_member(p_game_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.blackout_players bp
    join public.room_players rp on rp.id = bp.room_player_id
    where bp.game_id = p_game_id
      and rp.auth_user_id = (select auth.uid())
      and rp.left_at is null
  );
$$;

revoke all on function public.is_blackout_game_member(uuid) from public, anon;
grant execute on function public.is_blackout_game_member(uuid) to authenticated;

create or replace function public.is_blackout_objective_owner(p_blackout_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.blackout_players bp
    join public.room_players rp on rp.id = bp.room_player_id
    where bp.id = p_blackout_player_id
      and rp.auth_user_id = (select auth.uid())
      and rp.left_at is null
  );
$$;

revoke all on function public.is_blackout_objective_owner(uuid) from public, anon;
grant execute on function public.is_blackout_objective_owner(uuid) to authenticated;

create or replace function public.is_current_user_blackout_game_channel_member()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_topic text := realtime.topic();
  v_game_id uuid;
begin
  if v_topic is null or v_topic not like 'blackout:game:%' then return false; end if;
  begin
    v_game_id := split_part(v_topic, ':', 3)::uuid;
  exception when invalid_text_representation then
    return false;
  end;
  return public.is_blackout_game_member(v_game_id);
end;
$$;

revoke all on function public.is_current_user_blackout_game_channel_member() from public, anon;
grant execute on function public.is_current_user_blackout_game_channel_member() to authenticated;

alter table public.blackout_games enable row level security;
alter table public.blackout_players enable row level security;
alter table public.blackout_objectives enable row level security;

create policy "Game members can read shared game state"
  on public.blackout_games for select to authenticated
  using (public.is_blackout_game_member(id));
create policy "Game members can read the shared player roster"
  on public.blackout_players for select to authenticated
  using (public.is_blackout_game_member(game_id));
create policy "Players can read only their own secret objective"
  on public.blackout_objectives for select to authenticated
  using (public.is_blackout_objective_owner(blackout_player_id));

grant select on public.blackout_games, public.blackout_players, public.blackout_objectives to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.blackout_games from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.blackout_players from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.blackout_objectives from anon, authenticated;

create policy "Game members can join private game channels"
  on realtime.messages for select to authenticated
  using (
    extension in ('broadcast', 'presence')
    and public.is_current_user_blackout_game_channel_member()
  );
create policy "Game members can publish private game presence"
  on realtime.messages for insert to authenticated
  with check (
    extension = 'presence'
    and public.is_current_user_blackout_game_channel_member()
  );

create or replace function public.blackout_game_snapshot(p_game_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.blackout_games%rowtype;
  v_me public.blackout_players%rowtype;
  v_roster jsonb;
  v_secret jsonb;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;

  select bp.* into v_me
  from public.blackout_players bp
  join public.room_players rp on rp.id = bp.room_player_id
  where bp.game_id = p_game_id and rp.auth_user_id = v_user_id and rp.left_at is null;
  if not found then
    raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001';
  end if;

  select g.* into v_game from public.blackout_games g where g.id = p_game_id;
  if not found then
    raise exception using message = 'GAME_NOT_FOUND', errcode = 'P0001';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', bp.id,
    'display_name', bp.display_name,
    'connection_state', case
      when rp.left_at is not null then 'disconnected'
      when bp.last_seen_at < now() - interval '45 seconds' then 'disconnected'
      else bp.connection_state
    end,
    'is_alive', bp.is_alive,
    'is_active', bp.is_active,
    'is_current_player', bp.id = v_me.id
  ) order by bp.created_at, bp.id), '[]'::jsonb)
  into v_roster
  from public.blackout_players bp
  join public.room_players rp on rp.id = bp.room_player_id
  where bp.game_id = p_game_id;

  select jsonb_build_object(
    'role', o.secret_role,
    'objective', o.objective,
    'personal_information', o.personal_information
  ) into v_secret
  from public.blackout_objectives o
  where o.blackout_player_id = v_me.id;

  return jsonb_build_object(
    'game', jsonb_build_object(
      'id', v_game.id,
      'room_id', v_game.room_id,
      'state', v_game.state,
      'power', v_game.power,
      'security', v_game.security,
      'facility_integrity', v_game.facility_integrity,
      'created_at', v_game.created_at,
      'state_started_at', v_game.state_started_at,
      'state_deadline_at', v_game.state_deadline_at,
      'active_started_at', v_game.active_started_at,
      'active_deadline_at', v_game.active_deadline_at
    ),
    'players', v_roster,
    'my_player', jsonb_build_object(
      'id', v_me.id,
      'display_name', v_me.display_name,
      'secret_role', v_secret->'role',
      'objective', v_secret->'objective',
      'personal_information', v_secret->'personal_information'
    ),
    'server_now', now()
  );
end;
$$;

create or replace function public.advance_blackout_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.blackout_games%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if auth.uid() is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;
  if not public.is_blackout_game_member(p_game_id) then
    raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001';
  end if;

  select g.* into v_game from public.blackout_games g where g.id = p_game_id for update;
  if not found then
    raise exception using message = 'GAME_NOT_FOUND', errcode = 'P0001';
  end if;

  if v_game.state = 'ROLE_REVEAL' and v_game.state_deadline_at <= v_now then
    update public.blackout_games
      set state = 'FACILITY_INTRO', state_started_at = v_now, state_deadline_at = v_now + interval '10 seconds'
      where id = p_game_id;
  elsif v_game.state = 'FACILITY_INTRO' and v_game.state_deadline_at <= v_now then
    update public.blackout_games
      set state = 'ACTIVE', state_started_at = v_now, active_started_at = v_now,
          active_deadline_at = v_now + interval '5 minutes', state_deadline_at = v_now + interval '5 minutes'
      where id = p_game_id;
  end if;
end;
$$;

create or replace function public.get_my_game()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid;
  v_player_id uuid;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;

  select g.id, bp.id into v_game_id, v_player_id
  from public.blackout_games g
  join public.blackout_players bp on bp.game_id = g.id
  join public.room_players rp on rp.id = bp.room_player_id
  where rp.auth_user_id = v_user_id and rp.left_at is null
  order by g.created_at desc limit 1;
  if v_game_id is null then
    raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001';
  end if;

  update public.blackout_players
    set last_seen_at = case when id = v_player_id then clock_timestamp() else last_seen_at end,
        connection_state = case
          when id = v_player_id then 'connected'
          when last_seen_at < clock_timestamp() - interval '45 seconds' then 'disconnected'
          else connection_state
        end
    where game_id = v_game_id;

  perform public.advance_blackout_game(v_game_id);
  return public.blackout_game_snapshot(v_game_id);
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
  v_saboteur_player_id uuid;
  v_game_id uuid;
  v_game_player_id uuid;
  v_member record;
  v_crew_roles text[];
  v_crew_index integer := 0;
  v_role text;
  v_objective text;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;

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
  if v_connected_count > 6 then raise exception using message = 'ROOM_FULL', errcode = 'P0001'; end if;
  if exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.last_seen_at >= now() - interval '45 seconds'
      and not rp.ready
  ) then raise exception using message = 'PLAYERS_NOT_READY', errcode = 'P0001'; end if;

  select rp.id into v_saboteur_player_id from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.last_seen_at >= now() - interval '45 seconds'
    order by extensions.gen_random_bytes(16) limit 1;
  select array_agg(role_name order by extensions.gen_random_bytes(16)) into v_crew_roles
    from unnest(array['HACKER', 'SCOUT', 'ENGINEER']) as crew(role_name);

  update public.rooms set status = 'STARTING' where id = p_room_id;
  insert into public.blackout_games(room_id, state, state_started_at, state_deadline_at)
    values (p_room_id, 'STARTING', clock_timestamp(), clock_timestamp() + interval '12 seconds')
    returning id into v_game_id;

  for v_member in
    select rp.id, rp.display_name, rp.last_seen_at
    from public.room_players rp
    where rp.room_id = p_room_id and rp.left_at is null and rp.last_seen_at >= now() - interval '45 seconds'
    order by rp.joined_at, rp.id
  loop
    insert into public.blackout_players(game_id, room_player_id, display_name, last_seen_at)
      values (v_game_id, v_member.id, v_member.display_name, v_member.last_seen_at)
      returning id into v_game_player_id;

    if v_member.id = v_saboteur_player_id then
      v_role := 'SABOTEUR';
      v_objective := 'Remain undetected and prevent the facility from stabilizing.';
    else
      v_crew_index := v_crew_index + 1;
      v_role := v_crew_roles[((v_crew_index - 1) % array_length(v_crew_roles, 1)) + 1];
      v_objective := case v_role
        when 'HACKER' then 'Access the security terminal.'
        when 'SCOUT' then 'Locate the emergency access route.'
        else 'Stabilize the power relay.'
      end;
    end if;

    insert into public.blackout_objectives(game_id, blackout_player_id, secret_role, objective)
      values (v_game_id, v_game_player_id, v_role, v_objective);
  end loop;

  update public.blackout_games
    set state = 'ROLE_REVEAL', state_started_at = clock_timestamp(), state_deadline_at = clock_timestamp() + interval '12 seconds'
    where id = v_game_id;
  update public.rooms set status = 'IN_GAME' where id = p_room_id;

  return public.blackout_game_snapshot(v_game_id);
end;
$$;

revoke all on function public.blackout_game_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.advance_blackout_game(uuid) from public, anon, authenticated;
revoke all on function public.get_my_game() from public, anon;
revoke all on function public.start_room(uuid) from public, anon;
grant execute on function public.get_my_game() to authenticated;
grant execute on function public.start_room(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'blackout_games') then
      alter publication supabase_realtime add table public.blackout_games;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'blackout_players') then
      alter publication supabase_realtime add table public.blackout_players;
    end if;
  end if;
end;
$$;
