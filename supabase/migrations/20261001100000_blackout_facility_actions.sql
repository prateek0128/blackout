-- BLACKOUT Phase 3B: compact facility actions, public events, and private intel.

create table public.blackout_events (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  recipient_player_id uuid references public.blackout_players(id) on delete cascade,
  visibility text not null check (visibility in ('PUBLIC', 'PRIVATE')),
  event_type text not null check (event_type in (
    'POWER_REPAIRED', 'POWER_DISRUPTED', 'SECURITY_SCANNED',
    'SECURITY_INCREASED', 'SECTOR_INVESTIGATED', 'RELAY_TAMPERED'
  )),
  sector text check (sector is null or sector in ('SECURITY', 'POWER', 'MEDICAL', 'OPERATIONS', 'MAINTENANCE')),
  message text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  constraint blackout_events_visibility_recipient_check check (
    (visibility = 'PUBLIC' and recipient_player_id is null)
    or (visibility = 'PRIVATE' and recipient_player_id is not null)
  )
);

create index blackout_events_public_timeline
  on public.blackout_events(game_id, created_at desc, id desc)
  where visibility = 'PUBLIC';
create index blackout_events_private_timeline
  on public.blackout_events(game_id, recipient_player_id, created_at desc, id desc)
  where visibility = 'PRIVATE';

create table public.blackout_action_cooldowns (
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  player_id uuid not null references public.blackout_players(id) on delete cascade,
  action_type text not null check (action_type in (
    'SCAN_SECURITY', 'REPAIR_POWER', 'INVESTIGATE',
    'DISRUPT_POWER', 'INCREASE_SECURITY', 'TAMPER_RELAY'
  )),
  next_available_at timestamptz not null,
  primary key (game_id, player_id, action_type)
);

create or replace function public.is_current_user_blackout_player(p_player_id uuid)
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
    where bp.id = p_player_id
      and rp.auth_user_id = (select auth.uid())
      and rp.left_at is null
  );
$$;

revoke all on function public.is_current_user_blackout_player(uuid) from public, anon;
grant execute on function public.is_current_user_blackout_player(uuid) to authenticated;

alter table public.blackout_events enable row level security;
alter table public.blackout_action_cooldowns enable row level security;

create policy "Game members can read public events and their own intel"
  on public.blackout_events for select to authenticated
  using (
    public.is_blackout_game_member(game_id)
    and (visibility = 'PUBLIC' or public.is_current_user_blackout_player(recipient_player_id))
  );
create policy "Players can read their own action cooldowns"
  on public.blackout_action_cooldowns for select to authenticated
  using (public.is_current_user_blackout_player(player_id));

grant select on public.blackout_events, public.blackout_action_cooldowns to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.blackout_events from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.blackout_action_cooldowns from anon, authenticated;

-- Extend the safe, per-player snapshot with public events, private intel, and only
-- the current player's cooldowns. Roles and recipients never enter the public roster.
create or replace function public.blackout_game_snapshot(p_game_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.blackout_games%rowtype;
  v_me public.blackout_players%rowtype;
  v_roster jsonb;
  v_secret jsonb;
  v_public_events jsonb;
  v_private_intel jsonb;
  v_cooldowns jsonb;
  v_allowed_actions text[];
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

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'event_type', e.event_type, 'sector', e.sector,
    'message', e.message, 'created_at', e.created_at, 'payload', e.payload
  ) order by e.created_at desc, e.id desc), '[]'::jsonb)
  into v_public_events
  from (
    select e.* from public.blackout_events e
    where e.game_id = p_game_id and e.visibility = 'PUBLIC'
    order by e.created_at desc, e.id desc limit 30
  ) e;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'event_type', e.event_type, 'sector', e.sector,
    'message', e.message, 'created_at', e.created_at, 'payload', e.payload
  ) order by e.created_at desc, e.id desc), '[]'::jsonb)
  into v_private_intel
  from (
    select e.* from public.blackout_events e
    where e.game_id = p_game_id and e.visibility = 'PRIVATE'
      and e.recipient_player_id = v_me.id
    order by e.created_at desc, e.id desc limit 30
  ) e;

  v_allowed_actions := case v_secret->>'role'
    when 'HACKER' then array['SCAN_SECURITY']
    when 'ENGINEER' then array['REPAIR_POWER']
    when 'SCOUT' then array['INVESTIGATE']
    when 'SABOTEUR' then array['DISRUPT_POWER', 'INCREASE_SECURITY', 'TAMPER_RELAY']
    else array[]::text[]
  end;
  select coalesce(jsonb_agg(jsonb_build_object(
    'action', actions.action_type,
    'next_available_at', c.next_available_at
  ) order by actions.ordinality), '[]'::jsonb)
  into v_cooldowns
  from unnest(v_allowed_actions) with ordinality as actions(action_type, ordinality)
  left join public.blackout_action_cooldowns c
    on c.game_id = p_game_id and c.player_id = v_me.id and c.action_type = actions.action_type;

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
    'public_events', v_public_events,
    'my_intel', v_private_intel,
    'my_cooldowns', v_cooldowns,
    'server_now', clock_timestamp()
  );
end;
$$;

create or replace function public.apply_blackout_action(
  p_game_id uuid,
  p_action_type text,
  p_sector text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.blackout_games%rowtype;
  v_player public.blackout_players%rowtype;
  v_role text;
  v_now timestamptz;
  v_next_available timestamptz;
  v_event_id uuid;
  v_event_type text;
  v_message text;
  v_private_message text;
  v_sector text;
  v_public_event boolean := true;
  v_delta integer;
  v_payload jsonb;
  v_recent_sector text;
begin
  if v_user_id is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;
  if p_action_type is null or p_action_type not in ('SCAN_SECURITY', 'REPAIR_POWER', 'INVESTIGATE', 'DISRUPT_POWER', 'INCREASE_SECURITY', 'TAMPER_RELAY') then
    raise exception using message = 'INVALID_ACTION', errcode = 'P0001';
  end if;
  if p_sector is not null and p_sector not in ('SECURITY', 'POWER', 'MEDICAL', 'OPERATIONS', 'MAINTENANCE') then
    raise exception using message = 'INVALID_SECTOR', errcode = 'P0001';
  end if;

  select g.* into v_game from public.blackout_games g where g.id = p_game_id for update;
  if not found then
    raise exception using message = 'GAME_NOT_FOUND', errcode = 'P0001';
  end if;
  select bp.* into v_player
  from public.blackout_players bp
  join public.room_players rp on rp.id = bp.room_player_id
  where bp.game_id = p_game_id and rp.auth_user_id = v_user_id and rp.left_at is null
  for update of bp;
  if not found then
    raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001';
  end if;
  -- Start validation only after lock acquisition so waiting actions cannot cross
  -- the active deadline using a timestamp captured before the wait.
  v_now := clock_timestamp();
  if v_game.state <> 'ACTIVE' then
    raise exception using message = 'GAME_NOT_ACTIVE', errcode = 'P0001';
  end if;
  if v_game.active_deadline_at is null or v_game.active_deadline_at <= v_now then
    raise exception using message = 'GAME_TIMER_EXPIRED', errcode = 'P0001';
  end if;
  if not v_player.is_alive or not v_player.is_active then
    raise exception using message = 'PLAYER_INACTIVE', errcode = 'P0001';
  end if;

  select o.secret_role into v_role
  from public.blackout_objectives o
  where o.blackout_player_id = v_player.id and o.game_id = p_game_id;
  if not found then
    raise exception using message = 'ROLE_ASSIGNMENT_REQUIRED', errcode = 'P0001';
  end if;
  if (p_action_type = 'SCAN_SECURITY' and v_role <> 'HACKER')
    or (p_action_type = 'REPAIR_POWER' and v_role <> 'ENGINEER')
    or (p_action_type = 'INVESTIGATE' and v_role <> 'SCOUT')
    or (p_action_type in ('DISRUPT_POWER', 'INCREASE_SECURITY', 'TAMPER_RELAY') and v_role <> 'SABOTEUR') then
    raise exception using message = 'ROLE_REQUIRED', errcode = 'P0001';
  end if;

  if p_action_type = 'REPAIR_POWER' and p_sector not in ('POWER', 'OPERATIONS', 'MAINTENANCE') then
    raise exception using message = 'SECTOR_NOT_VALID_FOR_ACTION', errcode = 'P0001';
  end if;
  if p_action_type = 'TAMPER_RELAY' and p_sector not in ('POWER', 'MAINTENANCE') then
    raise exception using message = 'SECTOR_NOT_VALID_FOR_ACTION', errcode = 'P0001';
  end if;
  if p_action_type in ('INVESTIGATE', 'REPAIR_POWER', 'TAMPER_RELAY') and p_sector is null then
    raise exception using message = 'SECTOR_REQUIRED', errcode = 'P0001';
  end if;

  select c.next_available_at into v_next_available
  from public.blackout_action_cooldowns c
  where c.game_id = p_game_id and c.player_id = v_player.id and c.action_type = p_action_type;
  if v_next_available is not null and v_next_available > v_now then
    raise exception using message = 'ACTION_COOLDOWN', errcode = 'P0001';
  end if;
  insert into public.blackout_action_cooldowns(game_id, player_id, action_type, next_available_at)
    values (p_game_id, v_player.id, p_action_type, v_now + interval '10 seconds')
    on conflict (game_id, player_id, action_type)
    do update set next_available_at = excluded.next_available_at;

  case p_action_type
    when 'SCAN_SECURITY' then
      v_event_type := 'SECURITY_SCANNED';
      v_sector := 'SECURITY';
      v_public_event := false;
      v_private_message := (array[
        'Unauthorized access detected in Sector 4.',
        'Security terminal reports a failed override.',
        'A door access record points to Operations.'
      ])[1 + floor(random() * 3)::integer];
    when 'REPAIR_POWER' then
      v_event_type := 'POWER_REPAIRED';
      v_sector := p_sector;
      v_delta := least(12, 100 - v_game.power);
      v_payload := jsonb_build_object(
        'power_delta', v_delta,
        'integrity_delta', least(2, 100 - v_game.facility_integrity),
        'cooldown_seconds', 10
      );
      update public.blackout_games
        set power = least(100, power + 12), facility_integrity = least(100, facility_integrity + 2)
        where id = p_game_id;
      v_message := format('Power relay stabilized at %s. Power +%s; integrity +%s.', initcap(lower(p_sector)), v_delta, least(2, 100 - v_game.facility_integrity));
    when 'INVESTIGATE' then
      v_event_type := 'SECTOR_INVESTIGATED';
      v_sector := p_sector;
      v_public_event := false;
      select e.sector into v_recent_sector
      from public.blackout_events e
      where e.game_id = p_game_id and e.visibility = 'PUBLIC'
        and e.sector = p_sector
        and e.created_at >= v_now - interval '90 seconds'
      order by e.created_at desc, e.id desc limit 1;
      v_private_message := case
        when v_recent_sector is not null then format('Recent activity was recorded near %s.', initcap(lower(v_recent_sector)))
        when p_sector = 'MAINTENANCE' then 'An emergency route appears partially blocked. The extent is unclear.'
        when p_sector = 'OPERATIONS' then 'A power fluctuation may have originated near Operations.'
        when p_sector = 'SECURITY' then 'One access record is incomplete; the terminal cannot identify who used it.'
        when p_sector = 'POWER' then 'The relay casing shows signs of recent vibration.'
        else 'Medical reports show a brief interruption, but the source is unknown.'
      end;
    when 'DISRUPT_POWER' then
      v_event_type := 'POWER_DISRUPTED';
      v_sector := 'POWER';
      v_delta := least(10, v_game.power);
      update public.blackout_games set power = greatest(0, power - 10) where id = p_game_id;
      v_message := 'Power fluctuation detected.';
    when 'INCREASE_SECURITY' then
      v_event_type := 'SECURITY_INCREASED';
      v_sector := 'SECURITY';
      v_delta := least(10, 100 - v_game.security);
      update public.blackout_games set security = least(100, security + 10) where id = p_game_id;
      v_message := 'Security lockdown increased.';
    when 'TAMPER_RELAY' then
      v_event_type := 'RELAY_TAMPERED';
      v_sector := p_sector;
      v_delta := least(8, v_game.facility_integrity);
      update public.blackout_games
        set facility_integrity = greatest(0, facility_integrity - 8)
        where id = p_game_id;
      v_message := format('Relay instability detected in %s.', initcap(lower(p_sector)));
  end case;

  if v_public_event then
    insert into public.blackout_events(game_id, visibility, event_type, sector, message, payload)
      values (p_game_id, 'PUBLIC', v_event_type, v_sector, v_message,
        coalesce(v_payload, jsonb_build_object('delta', v_delta, 'cooldown_seconds', 10)))
      returning id into v_event_id;
  else
    insert into public.blackout_events(game_id, recipient_player_id, visibility, event_type, sector, message, payload)
      values (p_game_id, v_player.id, 'PRIVATE', v_event_type, v_sector, v_private_message,
        jsonb_build_object('confidence', 'INCOMPLETE', 'cooldown_seconds', 10))
      returning id into v_event_id;
  end if;

  return jsonb_build_object('ok', true, 'event_id', v_event_id, 'server_now', clock_timestamp());
end;
$$;

revoke all on function public.apply_blackout_action(uuid, text, text) from public, anon, authenticated;

create or replace function public.blackout_scan_security(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return public.apply_blackout_action(p_game_id, 'SCAN_SECURITY', null); end;
$$;
create or replace function public.blackout_repair_power(p_game_id uuid, p_sector text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return public.apply_blackout_action(p_game_id, 'REPAIR_POWER', p_sector); end;
$$;
create or replace function public.blackout_investigate(p_game_id uuid, p_sector text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return public.apply_blackout_action(p_game_id, 'INVESTIGATE', p_sector); end;
$$;
create or replace function public.blackout_disrupt_power(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return public.apply_blackout_action(p_game_id, 'DISRUPT_POWER', null); end;
$$;
create or replace function public.blackout_increase_security(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return public.apply_blackout_action(p_game_id, 'INCREASE_SECURITY', null); end;
$$;
create or replace function public.blackout_tamper_relay(p_game_id uuid, p_sector text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin return public.apply_blackout_action(p_game_id, 'TAMPER_RELAY', p_sector); end;
$$;

revoke all on function public.blackout_scan_security(uuid) from public, anon;
revoke all on function public.blackout_repair_power(uuid, text) from public, anon;
revoke all on function public.blackout_investigate(uuid, text) from public, anon;
revoke all on function public.blackout_disrupt_power(uuid) from public, anon;
revoke all on function public.blackout_increase_security(uuid) from public, anon;
revoke all on function public.blackout_tamper_relay(uuid, text) from public, anon;
grant execute on function public.blackout_scan_security(uuid) to authenticated;
grant execute on function public.blackout_repair_power(uuid, text) to authenticated;
grant execute on function public.blackout_investigate(uuid, text) to authenticated;
grant execute on function public.blackout_disrupt_power(uuid) to authenticated;
grant execute on function public.blackout_increase_security(uuid) to authenticated;
grant execute on function public.blackout_tamper_relay(uuid, text) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'blackout_events') then
    alter publication supabase_realtime add table public.blackout_events;
  end if;
end;
$$;
