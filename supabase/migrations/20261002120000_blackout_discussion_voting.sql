-- BLACKOUT Phase 3C: evidence-triggered discussion, accusations, private ballots,
-- public vote results, and an authoritative paused active-game clock.

alter table public.blackout_games
  drop constraint blackout_games_state_check;
alter table public.blackout_games
  add constraint blackout_games_state_check
  check (state in ('STARTING','ROLE_REVEAL','FACILITY_INTRO','ACTIVE','DISCUSSION','VOTING','VOTE_RESULT','FINAL_BLACKOUT','ESCAPE','RESULTS'));
alter table public.blackout_games
  add column active_remaining_ms bigint check (active_remaining_ms is null or active_remaining_ms >= 0);

alter table public.blackout_events drop constraint blackout_events_event_type_check;
alter table public.blackout_events add constraint blackout_events_event_type_check
  check (event_type in (
    'POWER_REPAIRED','POWER_DISRUPTED','SECURITY_SCANNED','SECURITY_INCREASED',
    'SECTOR_INVESTIGATED','RELAY_TAMPERED','DISCUSSION_CALLED','VOTE_SEALED','VOTE_RESOLVED'
  ));

create table public.blackout_discussions (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  triggering_event_id uuid not null references public.blackout_events(id),
  evidence_event_id uuid references public.blackout_events(id),
  sector text not null check (sector in ('SECURITY','POWER','MEDICAL','OPERATIONS','MAINTENANCE')),
  started_at timestamptz not null,
  deadline_at timestamptz not null,
  completed_at timestamptz,
  result jsonb,
  created_at timestamptz not null default clock_timestamp(),
  check (deadline_at > started_at)
);
create index blackout_discussions_game_timeline on public.blackout_discussions(game_id, started_at desc);
alter table public.blackout_games add column current_discussion_id uuid references public.blackout_discussions(id);

create table public.blackout_accusations (
  id uuid primary key default gen_random_uuid(),
  discussion_id uuid not null references public.blackout_discussions(id) on delete cascade,
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  accuser_player_id uuid not null references public.blackout_players(id) on delete cascade,
  accused_player_id uuid not null references public.blackout_players(id) on delete cascade,
  evidence_event_id uuid references public.blackout_events(id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (accuser_player_id <> accused_player_id),
  unique (discussion_id, accuser_player_id)
);
create index blackout_accusations_game on public.blackout_accusations(game_id, discussion_id, created_at);

create table public.blackout_votes (
  id uuid primary key default gen_random_uuid(),
  discussion_id uuid not null references public.blackout_discussions(id) on delete cascade,
  game_id uuid not null references public.blackout_games(id) on delete cascade,
  voter_player_id uuid not null references public.blackout_players(id) on delete cascade,
  target_player_id uuid not null references public.blackout_players(id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (voter_player_id <> target_player_id),
  unique (discussion_id, voter_player_id)
);
create index blackout_votes_game_discussion on public.blackout_votes(game_id, discussion_id);

alter table public.blackout_discussions enable row level security;
alter table public.blackout_accusations enable row level security;
alter table public.blackout_votes enable row level security;
create policy "Game members can read public discussion state" on public.blackout_discussions
  for select to authenticated using (public.is_blackout_game_member(game_id));
create policy "Game members can read public accusations" on public.blackout_accusations
  for select to authenticated using (public.is_blackout_game_member(game_id));
create policy "Players can read only their own ballot" on public.blackout_votes
  for select to authenticated using (public.is_current_user_blackout_player(voter_player_id));
grant select on public.blackout_discussions, public.blackout_accusations, public.blackout_votes to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.blackout_discussions, public.blackout_accusations, public.blackout_votes from anon, authenticated;
alter function public.blackout_game_snapshot(uuid) rename to blackout_game_snapshot_phase3b;
revoke all on function public.blackout_game_snapshot_phase3b(uuid) from public, anon, authenticated;

-- An investigation always yields incomplete Scout-only intel. The server also
-- opens discussion and emits a neutral public signal; the private clue text is
-- never copied to public state or a Realtime payload.
create or replace function public.start_blackout_discussion_after_investigation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_game public.blackout_games%rowtype;
  v_now timestamptz := clock_timestamp();
  v_public_event_id uuid;
  v_discussion_id uuid;
  v_remaining bigint;
begin
  if new.event_type <> 'SECTOR_INVESTIGATED' or new.visibility <> 'PRIVATE' then return new; end if;
  select g.* into v_game from public.blackout_games g where g.id = new.game_id for update;
  if not found or v_game.state <> 'ACTIVE' or v_game.active_deadline_at is null or v_game.active_deadline_at <= v_now then
    return new;
  end if;
  v_remaining := greatest(0, floor(extract(epoch from (v_game.active_deadline_at - v_now)) * 1000)::bigint);
  insert into public.blackout_events(game_id, visibility, event_type, sector, message, payload)
    values (new.game_id, 'PUBLIC', 'DISCUSSION_CALLED', new.sector,
      format('Evidence recovered near %s. Crew discussion requested.', initcap(lower(new.sector))),
      jsonb_build_object('duration_seconds', 45))
    returning id into v_public_event_id;
  insert into public.blackout_discussions(game_id, triggering_event_id, evidence_event_id, sector, started_at, deadline_at)
    values (new.game_id, v_public_event_id, new.id, new.sector, v_now, v_now + interval '45 seconds')
    returning id into v_discussion_id;
  update public.blackout_games set state = 'DISCUSSION', state_started_at = v_now,
    state_deadline_at = v_now + interval '45 seconds', active_remaining_ms = v_remaining,
    active_deadline_at = null, current_discussion_id = v_discussion_id
    where id = new.game_id;
  return new;
end;
$$;
create trigger blackout_investigation_starts_discussion
  after insert on public.blackout_events for each row
  when (new.event_type = 'SECTOR_INVESTIGATED' and new.visibility = 'PRIVATE')
  execute function public.start_blackout_discussion_after_investigation();

-- Vote submissions publish only a neutral sealed-ballot event. Target choices
-- remain inaccessible until the server stores aggregated results.
create or replace function public.publish_blackout_vote_progress()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  select count(*)::integer into v_count from public.blackout_votes where discussion_id = new.discussion_id;
  insert into public.blackout_events(game_id, visibility, event_type, message, payload)
    values (new.game_id, 'PUBLIC', 'VOTE_SEALED', 'A crew ballot was sealed.', jsonb_build_object('votes_cast', v_count));
  return new;
end;
$$;
create trigger blackout_vote_progress_event after insert on public.blackout_votes
  for each row execute function public.publish_blackout_vote_progress();

create or replace function public.blackout_game_snapshot(p_game_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_snapshot jsonb;
  v_game public.blackout_games%rowtype;
  v_me public.blackout_players%rowtype;
  v_discussion public.blackout_discussions%rowtype;
  v_user_id uuid := auth.uid();
  v_my_vote jsonb;
  v_vote_count integer := 0;
  v_active_count integer := 0;
  v_accusations jsonb := '[]'::jsonb;
  v_public_discussion jsonb;
begin
  select bp.* into v_me from public.blackout_players bp join public.room_players rp on rp.id = bp.room_player_id
    where bp.game_id = p_game_id and rp.auth_user_id = v_user_id and rp.left_at is null;
  if not found then raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001'; end if;
  v_snapshot := public.blackout_game_snapshot_phase3b(p_game_id);
  select g.* into v_game from public.blackout_games g where g.id = p_game_id;
  if v_game.current_discussion_id is not null then
    select d.* into v_discussion from public.blackout_discussions d where d.id = v_game.current_discussion_id;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'accuser_player_id', a.accuser_player_id,
      'accused_player_id', a.accused_player_id, 'evidence_event_id', a.evidence_event_id,
      'created_at', a.created_at
    ) order by a.created_at, a.id), '[]'::jsonb) into v_accusations
      from public.blackout_accusations a where a.discussion_id = v_discussion.id;
    select jsonb_build_object('target_player_id', v.target_player_id, 'created_at', v.created_at)
      into v_my_vote from public.blackout_votes v where v.discussion_id = v_discussion.id and v.voter_player_id = v_me.id;
    select count(*)::integer into v_vote_count from public.blackout_votes v where v.discussion_id = v_discussion.id;
    select count(*)::integer into v_active_count from public.blackout_players bp
      join public.room_players rp on rp.id = bp.room_player_id
      where bp.game_id = p_game_id and bp.is_active and bp.is_alive and rp.left_at is null;
  end if;
  v_public_discussion := case when v_discussion.id is null then 'null'::jsonb else jsonb_build_object(
          'id', v_discussion.id, 'sector', v_discussion.sector,
          'started_at', v_discussion.started_at, 'deadline_at', v_discussion.deadline_at,
          'triggering_event_id', v_discussion.triggering_event_id,
          'evidence_event_id', v_discussion.evidence_event_id,
          'accusations', v_accusations,
          'votes_cast', v_vote_count, 'eligible_voters', v_active_count,
          'my_vote', v_my_vote, 'result', v_discussion.result
        ) end;
  v_snapshot := jsonb_set(v_snapshot, '{game,active_remaining_ms}', coalesce(to_jsonb(v_game.active_remaining_ms), 'null'::jsonb));
  v_snapshot := v_snapshot || jsonb_build_object('discussion', v_public_discussion, 'server_now', clock_timestamp());
  return v_snapshot;
end;
$$;
-- Preserve the Phase 3B snapshot implementation and layer only the public
-- discussion state and caller's own ballot over it.
grant execute on function public.blackout_game_snapshot(uuid) to authenticated;

create or replace function public.advance_blackout_game(p_game_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_game public.blackout_games%rowtype;
  v_discussion public.blackout_discussions%rowtype;
  v_now timestamptz;
  v_eligible integer;
  v_cast integer;
  v_result jsonb;
  v_max integer;
  v_winners integer;
  v_tied boolean;
begin
  if auth.uid() is null then raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001'; end if;
  if not public.is_blackout_game_member(p_game_id) then raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001'; end if;
  select g.* into v_game from public.blackout_games g where g.id = p_game_id for update;
  if not found then raise exception using message = 'GAME_NOT_FOUND', errcode = 'P0001'; end if;
  v_now := clock_timestamp();
  if v_game.state = 'ROLE_REVEAL' and v_game.state_deadline_at <= v_now then
    update public.blackout_games set state = 'FACILITY_INTRO', state_started_at = v_now, state_deadline_at = v_now + interval '10 seconds' where id = p_game_id;
  elsif v_game.state = 'FACILITY_INTRO' and v_game.state_deadline_at <= v_now then
    update public.blackout_games set state = 'ACTIVE', state_started_at = v_now,
      active_started_at = v_now, active_deadline_at = v_now + interval '5 minutes',
      active_remaining_ms = 300000, state_deadline_at = v_now + interval '5 minutes' where id = p_game_id;
  elsif v_game.state = 'DISCUSSION' and v_game.state_deadline_at <= v_now then
    update public.blackout_games set state = 'VOTING', state_started_at = v_now,
      state_deadline_at = v_now + interval '20 seconds' where id = p_game_id;
    update public.blackout_discussions set deadline_at = v_now + interval '20 seconds'
      where id = v_game.current_discussion_id and completed_at is null;
  elsif v_game.state = 'VOTING' then
    select d.* into v_discussion from public.blackout_discussions d where d.id = v_game.current_discussion_id for update;
    select count(*)::integer into v_eligible from public.blackout_players bp join public.room_players rp on rp.id = bp.room_player_id
      where bp.game_id = p_game_id and bp.is_active and bp.is_alive and rp.left_at is null;
    select count(*)::integer into v_cast from public.blackout_votes where discussion_id = v_discussion.id;
    if v_game.state_deadline_at <= v_now or (v_eligible > 0 and v_cast >= v_eligible) then
      select coalesce(max(votes), 0) into v_max from (
        select bp.id, count(v.id)::integer as votes from public.blackout_players bp
        left join public.blackout_votes v on v.target_player_id = bp.id and v.discussion_id = v_discussion.id
        where bp.game_id = p_game_id and bp.is_active and bp.is_alive group by bp.id
      ) totals;
      select count(*)::integer into v_winners from (
        select bp.id from public.blackout_players bp left join public.blackout_votes v
          on v.target_player_id = bp.id and v.discussion_id = v_discussion.id
        where bp.game_id = p_game_id and bp.is_active and bp.is_alive group by bp.id having count(v.id) = v_max
      ) tied_players;
      v_tied := v_winners <> 1 or v_max = 0;
      select jsonb_build_object(
        'tied', v_tied,
        'winner_player_id', case when v_tied then null else (select bp.id from public.blackout_players bp left join public.blackout_votes v on v.target_player_id=bp.id and v.discussion_id=v_discussion.id where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id having count(v.id)=v_max limit 1) end,
        'highest_vote_count', v_max,
        'votes', coalesce(jsonb_agg(jsonb_build_object('player_id', bp.id, 'display_name', bp.display_name, 'votes', count(v.id)) order by bp.created_at, bp.id), '[]'::jsonb)
      ) into v_result
      from public.blackout_players bp left join public.blackout_votes v on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
      where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by v_max, v_tied;
      update public.blackout_discussions set result = v_result, completed_at = v_now where id = v_discussion.id;
      insert into public.blackout_events(game_id, visibility, event_type, message, payload)
        values (p_game_id, 'PUBLIC', 'VOTE_RESOLVED', case when v_tied then 'No consensus. No operator was removed.' else 'Vote result recorded. No operator was removed.' end, v_result);
      update public.blackout_games set state = 'VOTE_RESULT', state_started_at = v_now,
        state_deadline_at = v_now + interval '8 seconds' where id = p_game_id;
    end if;
  elsif v_game.state = 'VOTE_RESULT' and v_game.state_deadline_at <= v_now then
    update public.blackout_games set state = 'ACTIVE', state_started_at = v_now,
      active_started_at = v_now - (interval '5 minutes' - make_interval(secs => coalesce(active_remaining_ms, 0)::double precision / 1000)),
      active_deadline_at = v_now + make_interval(secs => coalesce(active_remaining_ms, 0)::double precision / 1000),
      state_deadline_at = v_now + make_interval(secs => coalesce(active_remaining_ms, 0)::double precision / 1000)
      where id = p_game_id;
  end if;
end;
$$;
revoke all on function public.advance_blackout_game(uuid) from public, anon, authenticated;
grant execute on function public.advance_blackout_game(uuid) to authenticated;

create or replace function public.blackout_accuse(
  p_game_id uuid, p_target_player_id uuid, p_evidence_event_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_game public.blackout_games%rowtype; v_me public.blackout_players%rowtype; v_id uuid;
begin
  if auth.uid() is null then raise exception using message='AUTH_REQUIRED',errcode='P0001'; end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id for update;
  if not found then raise exception using message='GAME_NOT_FOUND',errcode='P0001'; end if;
  perform public.advance_blackout_game(p_game_id);
  select g.* into v_game from public.blackout_games g where g.id=p_game_id;
  if v_game.state <> 'DISCUSSION' then raise exception using message='DISCUSSION_NOT_ACTIVE',errcode='P0001'; end if;
  select bp.* into v_me from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
    where bp.game_id=p_game_id and rp.auth_user_id=auth.uid() and rp.left_at is null and bp.is_alive and bp.is_active;
  if not found then raise exception using message='PLAYER_INACTIVE',errcode='P0001'; end if;
  if p_target_player_id=v_me.id then raise exception using message='SELF_ACCUSATION_NOT_ALLOWED',errcode='P0001'; end if;
  if not exists(select 1 from public.blackout_players where id=p_target_player_id and game_id=p_game_id and is_alive and is_active) then
    raise exception using message='INVALID_TARGET',errcode='P0001'; end if;
  if p_evidence_event_id is not null and not exists(select 1 from public.blackout_events e where e.id=p_evidence_event_id and e.game_id=p_game_id and (e.visibility='PUBLIC' or e.recipient_player_id=v_me.id)) then
    raise exception using message='EVIDENCE_NOT_ACCESSIBLE',errcode='P0001'; end if;
  insert into public.blackout_accusations(discussion_id,game_id,accuser_player_id,accused_player_id,evidence_event_id)
    values(v_game.current_discussion_id,p_game_id,v_me.id,p_target_player_id,p_evidence_event_id)
    on conflict(discussion_id,accuser_player_id) do update set accused_player_id=excluded.accused_player_id,
      evidence_event_id=excluded.evidence_event_id,updated_at=clock_timestamp()
    returning id into v_id;
  return jsonb_build_object('id',v_id);
end;
$$;

create or replace function public.blackout_cast_vote(p_game_id uuid,p_target_player_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_game public.blackout_games%rowtype; v_me public.blackout_players%rowtype; v_vote_id uuid; v_discussion_id uuid;
begin
  if auth.uid() is null then raise exception using message='AUTH_REQUIRED',errcode='P0001'; end if;
  select g.* into v_game from public.blackout_games g where g.id=p_game_id for update;
  if not found then raise exception using message='GAME_NOT_FOUND',errcode='P0001'; end if;
  perform public.advance_blackout_game(p_game_id);
  select g.* into v_game from public.blackout_games g where g.id=p_game_id;
  if v_game.state <> 'VOTING' or v_game.state_deadline_at <= clock_timestamp() then raise exception using message='VOTING_NOT_ACTIVE',errcode='P0001'; end if;
  select bp.* into v_me from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
    where bp.game_id=p_game_id and rp.auth_user_id=auth.uid() and rp.left_at is null and bp.is_alive and bp.is_active;
  if not found then raise exception using message='PLAYER_INACTIVE',errcode='P0001'; end if;
  if not exists(select 1 from public.blackout_players where id=p_target_player_id and game_id=p_game_id and is_alive and is_active) then raise exception using message='INVALID_TARGET',errcode='P0001'; end if;
  if p_target_player_id=v_me.id then raise exception using message='SELF_VOTE_NOT_ALLOWED',errcode='P0001'; end if;
  v_discussion_id := v_game.current_discussion_id;
  begin
    insert into public.blackout_votes(discussion_id,game_id,voter_player_id,target_player_id)
      values(v_discussion_id,p_game_id,v_me.id,p_target_player_id) returning id into v_vote_id;
  exception when unique_violation then raise exception using message='ALREADY_VOTED',errcode='P0001';
  end;
  perform public.advance_blackout_game(p_game_id);
  return jsonb_build_object('ok',true,'vote_id',v_vote_id);
end;
$$;

revoke all on function public.blackout_accuse(uuid,uuid,uuid) from public,anon;
revoke all on function public.blackout_cast_vote(uuid,uuid) from public,anon;
grant execute on function public.blackout_accuse(uuid,uuid,uuid) to authenticated;
grant execute on function public.blackout_cast_vote(uuid,uuid) to authenticated;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_discussions') then alter publication supabase_realtime add table public.blackout_discussions; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_accusations') then alter publication supabase_realtime add table public.blackout_accusations; end if;
  end if;
end $$;
