-- Enforce escape action cooldown before step checks, so duplicate attempts are consistently rate-limited.
create or replace function public.blackout_escape_action(p_game_id uuid,p_action_type text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid:=auth.uid(); v_game public.blackout_games%rowtype; v_player public.blackout_players%rowtype;
  v_escape public.blackout_escape_state%rowtype; v_role text; v_now timestamptz; v_next timestamptz;
  v_cooldown_action text;
begin
  if v_user is null then raise exception using message='AUTH_REQUIRED',errcode='P0001'; end if;
  if p_action_type is null or p_action_type not in ('LOCATE_ESCAPE_ROUTE','UNLOCK_EMERGENCY_ROUTE','POWER_ESCAPE_DOOR','OPEN_ESCAPE_DOOR','JAM_ESCAPE') then
    raise exception using message='INVALID_ESCAPE_ACTION',errcode='P0001'; end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id for update;
  if not found then raise exception using message='GAME_NOT_FOUND',errcode='P0001'; end if;
  select bp.* into v_player from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
    where bp.game_id=p_game_id and rp.auth_user_id=v_user and rp.left_at is null for update of bp;
  if not found then raise exception using message='GAME_MEMBERSHIP_REQUIRED',errcode='P0001'; end if;
  if not v_player.is_alive or not v_player.is_active then raise exception using message='PLAYER_INACTIVE',errcode='P0001'; end if;
  select o.secret_role into v_role from public.blackout_objectives o where o.blackout_player_id=v_player.id;
  if v_role is null then raise exception using message='ROLE_ASSIGNMENT_REQUIRED',errcode='P0001'; end if;
  perform public.advance_blackout_game(p_game_id);
  select g.* into v_game from public.blackout_games g where g.id=p_game_id;
  if v_game.state not in ('FINAL_BLACKOUT','ESCAPE') then return jsonb_build_object('ok',false,'error','ESCAPE_NOT_ACTIVE'); end if;
  v_now:=clock_timestamp();
  if v_game.final_deadline_at is null or v_game.final_deadline_at<=v_now then return jsonb_build_object('ok',false,'error','ESCAPE_DEADLINE_EXPIRED'); end if;
  if p_action_type='JAM_ESCAPE' then
    if v_role<>'SABOTEUR' then raise exception using message='ROLE_REQUIRED',errcode='P0001'; end if;
  else
    if v_role='SABOTEUR' then raise exception using message='ROLE_REQUIRED',errcode='P0001'; end if;
    if p_action_type='LOCATE_ESCAPE_ROUTE' and v_role<>'SCOUT'
      and exists(select 1 from public.blackout_objectives where game_id=p_game_id and secret_role='SCOUT') then raise exception using message='ROLE_REQUIRED',errcode='P0001'; end if;
    if p_action_type='UNLOCK_EMERGENCY_ROUTE' and v_role<>'HACKER'
      and exists(select 1 from public.blackout_objectives where game_id=p_game_id and secret_role='HACKER') then raise exception using message='ROLE_REQUIRED',errcode='P0001'; end if;
    if p_action_type='POWER_ESCAPE_DOOR' and v_role<>'ENGINEER'
      and exists(select 1 from public.blackout_objectives where game_id=p_game_id and secret_role='ENGINEER') then raise exception using message='ROLE_REQUIRED',errcode='P0001'; end if;
  end if;
  select e.* into v_escape from public.blackout_escape_state e where e.game_id=p_game_id for update;
  if not found then raise exception using message='ESCAPE_STATE_MISSING',errcode='P0001'; end if;
  select c.next_available_at into v_next from public.blackout_escape_cooldowns c
    where c.game_id=p_game_id and c.player_id=v_player.id and c.action_type=p_action_type;
  if v_next is not null and v_next>v_now then raise exception using message='ESCAPE_ACTION_COOLDOWN',errcode='P0001'; end if;
  if (p_action_type='LOCATE_ESCAPE_ROUTE' and v_escape.route_located)
    or (p_action_type='UNLOCK_EMERGENCY_ROUTE' and (not v_escape.route_located or v_escape.route_unlocked))
    or (p_action_type='POWER_ESCAPE_DOOR' and (not v_escape.route_unlocked or v_escape.door_powered))
    or (p_action_type='OPEN_ESCAPE_DOOR' and (not v_escape.door_powered or v_escape.door_opened))
    or (p_action_type='JAM_ESCAPE' and not (v_escape.route_located or v_escape.route_unlocked or v_escape.door_powered or v_escape.door_opened)) then
    raise exception using message='ESCAPE_STEP_NOT_AVAILABLE',errcode='P0001'; end if;
  insert into public.blackout_escape_cooldowns(game_id,player_id,action_type,next_available_at)
    values(p_game_id,v_player.id,p_action_type,v_now+interval '5 seconds')
    on conflict(game_id,player_id,action_type) do update set next_available_at=excluded.next_available_at;

  if p_action_type='LOCATE_ESCAPE_ROUTE' then
    update public.blackout_escape_state set route_located=true,updated_at=v_now where game_id=p_game_id;
    insert into public.blackout_events(game_id,visibility,event_type,sector,message,payload)
      values(p_game_id,'PUBLIC','ESCAPE_ROUTE_LOCATED',null,'A route marker is confirmed in the maintenance corridor.',jsonb_build_object('progress_step','ROUTE'));
  elsif p_action_type='UNLOCK_EMERGENCY_ROUTE' then
    update public.blackout_escape_state set route_unlocked=true,updated_at=v_now where game_id=p_game_id;
    insert into public.blackout_events(game_id,visibility,event_type,sector,message,payload)
      values(p_game_id,'PUBLIC','ESCAPE_ROUTE_UNLOCKED',null,'Emergency route locks released.',jsonb_build_object('progress_step','ROUTE'));
  elsif p_action_type='POWER_ESCAPE_DOOR' then
    update public.blackout_escape_state set door_powered=true,updated_at=v_now where game_id=p_game_id;
    insert into public.blackout_events(game_id,visibility,event_type,sector,message,payload)
      values(p_game_id,'PUBLIC','ESCAPE_DOOR_POWERED',null,'Emergency door power restored.',jsonb_build_object('progress_step','POWER'));
  elsif p_action_type='OPEN_ESCAPE_DOOR' then
    update public.blackout_escape_state set door_opened=true,updated_at=v_now where game_id=p_game_id;
    insert into public.blackout_events(game_id,visibility,event_type,sector,message,payload)
      values(p_game_id,'PUBLIC','ESCAPE_DOOR_OPENED',null,'The escape door is open. Move now.',jsonb_build_object('progress_step','DOOR'));
  else
    update public.blackout_escape_state set
      door_opened=case when door_opened then false else door_opened end,
      door_powered=case when door_opened then false when door_powered then false else door_powered end,
      route_unlocked=case when door_opened or door_powered then false when route_unlocked then false else route_unlocked end,
      route_located=case when door_opened or door_powered or route_unlocked then false else route_located end,
      jam_count=jam_count+1,updated_at=v_now where game_id=p_game_id;
    update public.blackout_games set facility_integrity=greatest(0,facility_integrity-5) where id=p_game_id returning * into v_game;
    insert into public.blackout_events(game_id,visibility,event_type,message,payload)
      values(p_game_id,'PUBLIC','ESCAPE_JAMMED','Emergency systems interference detected.',jsonb_build_object('integrity_delta',-least(5,v_game.facility_integrity+5)));
  end if;
  if v_game.state='FINAL_BLACKOUT' then
    update public.blackout_games set state='ESCAPE',state_started_at=v_now,state_deadline_at=final_deadline_at where id=p_game_id;
  end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id;
  select e.* into v_escape from public.blackout_escape_state e where e.game_id=p_game_id;
  -- Deterministic precedence: facility failure, timely crew escape, then timeout.
  if v_game.facility_integrity<=0 then perform public.blackout_finish_game(p_game_id,'FACILITY_FAILURE',clock_timestamp());
  elsif v_escape.door_opened and v_game.final_deadline_at>clock_timestamp() then perform public.blackout_finish_game(p_game_id,'CREW_ESCAPED',clock_timestamp());
  elsif v_game.final_deadline_at<=clock_timestamp() then perform public.blackout_finish_game(p_game_id,'SABOTEUR_PREVAILED',clock_timestamp()); end if;
  return jsonb_build_object('ok',true,'action',p_action_type);
end;
$$;
