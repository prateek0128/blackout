-- BLACKOUT Phase 3D: final blackout, cooperative escape, deterministic outcome,
-- role reveal at results, and host-only same-room replay.

alter table public.blackout_games
  add column final_started_at timestamptz,
  add column final_deadline_at timestamptz;
alter table public.blackout_games
  add constraint blackout_games_final_deadline_check check (
    final_deadline_at is null or final_started_at is not null and final_deadline_at >= final_started_at
  );
alter table public.blackout_games drop constraint if exists blackout_games_room_id_key;

alter table public.blackout_events drop constraint blackout_events_event_type_check;
alter table public.blackout_events add constraint blackout_events_event_type_check
  check (event_type in (
    'POWER_REPAIRED','POWER_DISRUPTED','SECURITY_SCANNED','SECURITY_INCREASED',
    'SECTOR_INVESTIGATED','RELAY_TAMPERED','DISCUSSION_CALLED','VOTE_SEALED',
    'VOTE_RESOLVED','FINAL_BLACKOUT_BEGAN','ESCAPE_ROUTE_LOCATED',
    'ESCAPE_ROUTE_UNLOCKED','ESCAPE_DOOR_POWERED','ESCAPE_DOOR_OPENED',
    'ESCAPE_JAMMED','GAME_RESOLVED'
  ));

create table public.blackout_escape_state (
  game_id uuid primary key references public.blackout_games(id) on delete cascade,
  route_located boolean not null default false,
  route_unlocked boolean not null default false,
  door_powered boolean not null default false,
  door_opened boolean not null default false,
  jam_count integer not null default 0 check (jam_count >= 0),
  started_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (not route_unlocked or route_located),
  check (not door_powered or route_unlocked),
  check (not door_opened or door_powered)
);

create table public.blackout_escape_cooldowns (
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  player_id uuid not null references public.blackout_players(id) on delete cascade,
  action_type text not null check (action_type in (
    'LOCATE_ESCAPE_ROUTE','UNLOCK_EMERGENCY_ROUTE','POWER_ESCAPE_DOOR','OPEN_ESCAPE_DOOR','JAM_ESCAPE'
  )),
  next_available_at timestamptz not null,
  primary key (game_id,player_id,action_type)
);
create index blackout_escape_cooldowns_lookup on public.blackout_escape_cooldowns(game_id,player_id,next_available_at);

create table public.blackout_results (
  game_id uuid primary key references public.blackout_games(id) on delete cascade,
  outcome text not null check (outcome in ('CREW_ESCAPED','SABOTEUR_PREVAILED','FACILITY_FAILURE')),
  summary text not null,
  final_facility jsonb not null,
  final_escape_state jsonb not null,
  role_reveal jsonb not null,
  resolved_at timestamptz not null default clock_timestamp()
);

alter table public.blackout_escape_state enable row level security;
alter table public.blackout_escape_cooldowns enable row level security;
alter table public.blackout_results enable row level security;
create policy "Game members can read shared escape progress" on public.blackout_escape_state
  for select to authenticated using (public.is_blackout_game_member(game_id));
create policy "Players can read their own escape cooldowns" on public.blackout_escape_cooldowns
  for select to authenticated using (public.is_current_user_blackout_player(player_id));
create policy "Game members can read results after resolution" on public.blackout_results
  for select to authenticated using (
    public.is_blackout_game_member(game_id)
    and exists(select 1 from public.blackout_games g where g.id=game_id and g.state='RESULTS')
  );
grant select on public.blackout_escape_state,public.blackout_escape_cooldowns,public.blackout_results to authenticated;
revoke insert,update,delete,truncate,references,trigger on public.blackout_escape_state,public.blackout_escape_cooldowns,public.blackout_results from anon,authenticated;

alter function public.blackout_game_snapshot(uuid) rename to blackout_game_snapshot_phase3c;
revoke all on function public.blackout_game_snapshot_phase3c(uuid) from public,anon,authenticated;

create or replace function public.blackout_finish_game(p_game_id uuid,p_outcome text,p_now timestamptz default clock_timestamp())
returns void language plpgsql security definer set search_path = '' as $$
declare v_game public.blackout_games%rowtype; v_escape public.blackout_escape_state%rowtype; v_summary text; v_roles jsonb;
begin
  if p_outcome not in ('CREW_ESCAPED','SABOTEUR_PREVAILED','FACILITY_FAILURE') then
    raise exception using message='INVALID_OUTCOME',errcode='P0001';
  end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id for update;
  if not found or v_game.state='RESULTS' then return; end if;
  select e.* into v_escape from public.blackout_escape_state e where e.game_id=p_game_id;
  v_summary:=case p_outcome
    when 'CREW_ESCAPED' then 'The crew opened the emergency route and escaped the facility.'
    when 'SABOTEUR_PREVAILED' then 'The escape window closed before the crew could get out.'
    else 'Facility integrity failed before evacuation was complete.' end;
  select coalesce(jsonb_agg(jsonb_build_object(
    'player_id',bp.id,'display_name',bp.display_name,'role',o.secret_role,
    'outcome',case
      when p_outcome='CREW_ESCAPED' and o.secret_role='SABOTEUR' then 'DEFEAT'
      when p_outcome='CREW_ESCAPED' then 'VICTORY'
      when p_outcome='SABOTEUR_PREVAILED' and o.secret_role='SABOTEUR' then 'VICTORY'
      when p_outcome='SABOTEUR_PREVAILED' then 'DEFEAT'
      else 'FACILITY FAILURE' end
  ) order by bp.created_at,bp.id),'[]'::jsonb) into v_roles
  from public.blackout_players bp join public.blackout_objectives o on o.blackout_player_id=bp.id
  where bp.game_id=p_game_id;
  insert into public.blackout_results(game_id,outcome,summary,final_facility,final_escape_state,role_reveal,resolved_at)
    values(p_game_id,p_outcome,v_summary,
      jsonb_build_object('power',v_game.power,'security',v_game.security,'facility_integrity',v_game.facility_integrity),
      jsonb_build_object('route_located',coalesce(v_escape.route_located,false),'route_unlocked',coalesce(v_escape.route_unlocked,false),
        'door_powered',coalesce(v_escape.door_powered,false),'door_opened',coalesce(v_escape.door_opened,false),'jam_count',coalesce(v_escape.jam_count,0)),
      v_roles,p_now) on conflict(game_id) do nothing;
  update public.blackout_games set state='RESULTS',state_started_at=p_now,state_deadline_at=null where id=p_game_id;
  update public.rooms set status='COMPLETED' where id=v_game.room_id;
  insert into public.blackout_events(game_id,visibility,event_type,message,payload)
    values(p_game_id,'PUBLIC','GAME_RESOLVED',v_summary,jsonb_build_object('outcome',p_outcome));
end;
$$;

-- The scheduler is request-driven: member snapshots, votes, or actions call this
-- function. Every deadline decision and outcome is made under the game row lock.
create or replace function public.advance_blackout_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_game public.blackout_games%rowtype; v_discussion public.blackout_discussions%rowtype;
  v_escape public.blackout_escape_state%rowtype; v_now timestamptz;
  v_eligible integer; v_cast integer; v_result jsonb; v_max integer; v_winners integer; v_tied boolean;
begin
  if auth.uid() is null then raise exception using message='AUTH_REQUIRED',errcode='P0001'; end if;
  if not public.is_blackout_game_member(p_game_id) then raise exception using message='GAME_MEMBERSHIP_REQUIRED',errcode='P0001'; end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id for update;
  if not found then raise exception using message='GAME_NOT_FOUND',errcode='P0001'; end if;
  v_now:=clock_timestamp();
  if v_game.state='ROLE_REVEAL' and v_game.state_deadline_at<=v_now then
    update public.blackout_games set state='FACILITY_INTRO',state_started_at=v_now,state_deadline_at=v_now+interval '10 seconds' where id=p_game_id;
  elsif v_game.state='FACILITY_INTRO' and v_game.state_deadline_at<=v_now then
    update public.blackout_games set state='ACTIVE',state_started_at=v_now,active_started_at=v_now,
      active_deadline_at=v_now+interval '5 minutes',active_remaining_ms=300000,state_deadline_at=v_now+interval '5 minutes' where id=p_game_id;
  elsif v_game.state='DISCUSSION' and v_game.state_deadline_at<=v_now then
    update public.blackout_games set state='VOTING',state_started_at=v_now,state_deadline_at=v_now+interval '20 seconds' where id=p_game_id;
    update public.blackout_discussions set deadline_at=v_now+interval '20 seconds' where id=v_game.current_discussion_id and completed_at is null;
  elsif v_game.state='VOTING' then
    select d.* into v_discussion from public.blackout_discussions d where d.id=v_game.current_discussion_id for update;
    select count(*)::integer into v_eligible from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
      where bp.game_id=p_game_id and bp.is_active and bp.is_alive and rp.left_at is null;
    select count(*)::integer into v_cast from public.blackout_votes where discussion_id=v_discussion.id;
    if v_game.state_deadline_at<=v_now or (v_eligible>0 and v_cast>=v_eligible) then
      select coalesce(max(t.votes),0) into v_max from (
        select bp.id,count(v.id)::integer votes from public.blackout_players bp left join public.blackout_votes v
          on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
        where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id) t;
      select count(*)::integer into v_winners from (
        select bp.id,count(v.id)::integer votes from public.blackout_players bp left join public.blackout_votes v
          on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
        where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id) t where t.votes=v_max;
      v_tied:=v_winners<>1 or v_max=0;
      select jsonb_build_object('tied',v_tied,
        'winner_player_id',case when v_tied then null else (select t.id from (
          select bp.id,count(v.id)::integer votes from public.blackout_players bp left join public.blackout_votes v
            on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
          where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id) t where t.votes=v_max limit 1) end,
        'highest_vote_count',v_max,
        'votes',coalesce((select jsonb_agg(jsonb_build_object('player_id',t.id,'display_name',t.display_name,'votes',t.votes) order by t.created_at,t.id)
          from (select bp.id,bp.display_name,bp.created_at,count(v.id)::integer votes from public.blackout_players bp
            left join public.blackout_votes v on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
            where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id) t),'[]'::jsonb)) into v_result;
      update public.blackout_discussions set result=v_result,completed_at=v_now where id=v_discussion.id;
      insert into public.blackout_events(game_id,visibility,event_type,message,payload)
        values(p_game_id,'PUBLIC','VOTE_RESOLVED',case when v_tied then 'No consensus. No operator was removed.' else 'Vote result recorded. No operator was removed.' end,v_result);
      update public.blackout_games set state='VOTE_RESULT',state_started_at=v_now,state_deadline_at=v_now+interval '8 seconds' where id=p_game_id;
    end if;
  elsif v_game.state='VOTE_RESULT' and v_game.state_deadline_at<=v_now then
    update public.blackout_games set state='ACTIVE',state_started_at=v_now,
      active_started_at=v_now-(interval '5 minutes'-make_interval(secs=>coalesce(active_remaining_ms,0)::double precision/1000)),
      active_deadline_at=v_now+make_interval(secs=>coalesce(active_remaining_ms,0)::double precision/1000),
      state_deadline_at=v_now+make_interval(secs=>coalesce(active_remaining_ms,0)::double precision/1000) where id=p_game_id;
  elsif v_game.state='ACTIVE' and v_game.active_deadline_at is not null and v_game.active_deadline_at<=v_now then
    insert into public.blackout_escape_state(game_id) values(p_game_id) on conflict(game_id) do nothing;
    update public.blackout_games set state='FINAL_BLACKOUT',state_started_at=v_now,state_deadline_at=v_now+interval '5 seconds',
      final_started_at=v_now,final_deadline_at=v_now+interval '45 seconds',active_remaining_ms=0,active_deadline_at=null
      where id=p_game_id;
    insert into public.blackout_events(game_id,visibility,event_type,message,payload)
      values(p_game_id,'PUBLIC','FINAL_BLACKOUT_BEGAN','Final blackout. Emergency escape window: 00:45.',jsonb_build_object('duration_seconds',45));
    if v_game.facility_integrity<=0 then perform public.blackout_finish_game(p_game_id,'FACILITY_FAILURE',v_now); end if;
  elsif v_game.state in ('FINAL_BLACKOUT','ESCAPE') then
    select e.* into v_escape from public.blackout_escape_state e where e.game_id=p_game_id;
    if v_game.facility_integrity<=0 then
      perform public.blackout_finish_game(p_game_id,'FACILITY_FAILURE',v_now);
    elsif coalesce(v_escape.door_opened,false) and v_game.final_deadline_at>v_now then
      perform public.blackout_finish_game(p_game_id,'CREW_ESCAPED',v_now);
    elsif v_game.final_deadline_at<=v_now then
      perform public.blackout_finish_game(p_game_id,'SABOTEUR_PREVAILED',v_now);
    elsif v_game.state='FINAL_BLACKOUT' and v_game.state_deadline_at<=v_now then
      update public.blackout_games set state='ESCAPE',state_started_at=v_now,state_deadline_at=final_deadline_at where id=p_game_id;
    end if;
  end if;
end;
$$;

create or replace function public.blackout_game_snapshot(p_game_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_snapshot jsonb:=public.blackout_game_snapshot_phase3c(p_game_id);
  v_game public.blackout_games%rowtype; v_me public.blackout_players%rowtype;
  v_role text; v_escape public.blackout_escape_state%rowtype; v_result public.blackout_results%rowtype;
  v_actions text[]; v_progress integer; v_is_host boolean;
begin
  select g.* into v_game from public.blackout_games g where g.id=p_game_id;
  select bp.* into v_me from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
    where bp.game_id=p_game_id and rp.auth_user_id=auth.uid() and rp.left_at is null;
  select o.secret_role into v_role from public.blackout_objectives o where o.blackout_player_id=v_me.id;
  select exists(select 1 from public.room_players rp join public.rooms r on r.host_player_id=rp.id
    where rp.id=v_me.room_player_id and rp.auth_user_id=auth.uid() and rp.left_at is null) into v_is_host;
  select e.* into v_escape from public.blackout_escape_state e where e.game_id=p_game_id;
  if found then
    v_actions:=case v_role
      when 'SCOUT' then array['LOCATE_ESCAPE_ROUTE']
      when 'HACKER' then array['UNLOCK_EMERGENCY_ROUTE']
      when 'ENGINEER' then array['POWER_ESCAPE_DOOR']
      when 'SABOTEUR' then array['JAM_ESCAPE'] else array[]::text[] end;
    if v_role<>'SABOTEUR' then
      if not exists(select 1 from public.blackout_objectives where game_id=p_game_id and secret_role='SCOUT') then v_actions:=array_append(v_actions,'LOCATE_ESCAPE_ROUTE'); end if;
      if not exists(select 1 from public.blackout_objectives where game_id=p_game_id and secret_role='HACKER') then v_actions:=array_append(v_actions,'UNLOCK_EMERGENCY_ROUTE'); end if;
      if not exists(select 1 from public.blackout_objectives where game_id=p_game_id and secret_role='ENGINEER') then v_actions:=array_append(v_actions,'POWER_ESCAPE_DOOR'); end if;
      v_actions:=array_append(v_actions,'OPEN_ESCAPE_DOOR');
    end if;
    v_progress:=(case when v_escape.route_located and v_escape.route_unlocked then 1 else 0 end)
      +(case when v_escape.door_powered then 1 else 0 end)
      +(case when v_escape.door_opened then 1 else 0 end);
  else v_actions:=array[]::text[]; v_progress:=0; end if;
  select r.* into v_result from public.blackout_results r where r.game_id=p_game_id;
  v_snapshot:=jsonb_set(v_snapshot,'{game,final_started_at}',coalesce(to_jsonb(v_game.final_started_at),'null'::jsonb));
  v_snapshot:=jsonb_set(v_snapshot,'{game,final_deadline_at}',coalesce(to_jsonb(v_game.final_deadline_at),'null'::jsonb));
  v_snapshot:=v_snapshot||jsonb_build_object(
    'escape',case when v_escape.game_id is null then 'null'::jsonb else jsonb_build_object(
      'route_located',v_escape.route_located,'route_unlocked',v_escape.route_unlocked,
      'door_powered',v_escape.door_powered,'door_opened',v_escape.door_opened,
      'jam_count',v_escape.jam_count,'progress',v_progress,'step_count',4,
      'my_available_actions',v_actions,
      'my_cooldowns',coalesce((select jsonb_agg(jsonb_build_object('action',c.action_type,'next_available_at',c.next_available_at))
        from public.blackout_escape_cooldowns c where c.game_id=p_game_id and c.player_id=v_me.id),'[]'::jsonb)
    ) end,
    'results',case when v_game.state<>'RESULTS' or v_result.game_id is null then 'null'::jsonb else jsonb_build_object(
      'outcome',v_result.outcome,'summary',v_result.summary,'final_facility',v_result.final_facility,
      'final_escape_state',v_result.final_escape_state,'role_reveal',v_result.role_reveal,'resolved_at',v_result.resolved_at
    ) end,
    'can_restart',v_game.state='RESULTS' and v_is_host,
    'server_now',clock_timestamp()
  );
  return v_snapshot;
end;
$$;

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
  if (p_action_type='LOCATE_ESCAPE_ROUTE' and v_escape.route_located)
    or (p_action_type='UNLOCK_EMERGENCY_ROUTE' and (not v_escape.route_located or v_escape.route_unlocked))
    or (p_action_type='POWER_ESCAPE_DOOR' and (not v_escape.route_unlocked or v_escape.door_powered))
    or (p_action_type='OPEN_ESCAPE_DOOR' and (not v_escape.door_powered or v_escape.door_opened))
    or (p_action_type='JAM_ESCAPE' and not (v_escape.route_located or v_escape.route_unlocked or v_escape.door_powered or v_escape.door_opened)) then
    raise exception using message='ESCAPE_STEP_NOT_AVAILABLE',errcode='P0001'; end if;
  select c.next_available_at into v_next from public.blackout_escape_cooldowns c
    where c.game_id=p_game_id and c.player_id=v_player.id and c.action_type=p_action_type;
  if v_next is not null and v_next>v_now then raise exception using message='ESCAPE_ACTION_COOLDOWN',errcode='P0001'; end if;
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
      values(p_game_id,'PUBLIC','ESCAPE_DOOR_POWERED','Emergency door power restored.',jsonb_build_object('progress_step','POWER'));
  elsif p_action_type='OPEN_ESCAPE_DOOR' then
    update public.blackout_escape_state set door_opened=true,updated_at=v_now where game_id=p_game_id;
    insert into public.blackout_events(game_id,visibility,event_type,sector,message,payload)
      values(p_game_id,'PUBLIC','ESCAPE_DOOR_OPENED','The escape door is open. Move now.',jsonb_build_object('progress_step','DOOR'));
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

create or replace function public.blackout_restart_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_game public.blackout_games%rowtype; v_room public.rooms%rowtype; v_host public.room_players%rowtype;
begin
  if auth.uid() is null then raise exception using message='AUTH_REQUIRED',errcode='P0001'; end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id for update;
  if not found or v_game.state<>'RESULTS' then raise exception using message='GAME_NOT_COMPLETE',errcode='P0001'; end if;
  select r.* into v_room from public.rooms r where r.id=v_game.room_id for update;
  select rp.* into v_host from public.room_players rp where rp.id=v_room.host_player_id and rp.auth_user_id=auth.uid() and rp.left_at is null;
  if not found then raise exception using message='HOST_REQUIRED',errcode='P0001'; end if;
  update public.room_players set ready=false,last_seen_at=clock_timestamp(),connection_state='connected'
    where room_id=v_room.id and left_at is null;
  update public.rooms set status='LOBBY',expires_at=clock_timestamp()+interval '60 minutes' where id=v_room.id;
  return public.blackout_room_snapshot(v_room.id);
end;
$$;

revoke all on function public.blackout_finish_game(uuid,text,timestamptz) from public,anon,authenticated;
revoke all on function public.blackout_escape_action(uuid,text) from public,anon;
revoke all on function public.blackout_restart_game(uuid) from public,anon;
revoke all on function public.advance_blackout_game(uuid) from public,anon,authenticated;
revoke all on function public.blackout_game_snapshot(uuid) from public,anon,authenticated;
grant execute on function public.blackout_escape_action(uuid,text) to authenticated;
grant execute on function public.blackout_restart_game(uuid) to authenticated;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_escape_state') then alter publication supabase_realtime add table public.blackout_escape_state; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_results') then alter publication supabase_realtime add table public.blackout_results; end if;
  end if;
end $$;
