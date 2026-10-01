begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users(id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
select ('10000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'authenticated', 'authenticated', 'blackout-phase3a-' || n || '@test.invalid', '', now(), '{}', '{}', true
from generate_series(101, 140) n;

create or replace function pg_temp.blackout_started_game(p_count integer, p_seed integer)
returns uuid language plpgsql as $$
declare
  v_host uuid := ('10000000-0000-4000-8000-' || lpad(p_seed::text, 12, '0'))::uuid;
  v_id uuid;
  v_code text;
  v_result jsonb;
  i integer;
begin
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  v_result := public.create_room('Phase3A Host ' || p_seed);
  v_id := (v_result->'room'->>'id')::uuid;
  select room_code into v_code from public.rooms where id = v_id;
  for i in 1..(p_count - 1) loop
    perform set_config('request.jwt.claim.sub', ('10000000-0000-4000-8000-' || lpad((p_seed + i)::text, 12, '0')), true);
    perform public.join_room(v_code, 'Phase3A Crew ' || i);
  end loop;
  -- Start is rejected until every connected player is ready.
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  if p_seed = 101 then
    begin
      perform public.start_room(v_id);
      raise exception 'Expected PLAYERS_NOT_READY';
    exception when sqlstate 'P0001' then
      if sqlerrm <> 'PLAYERS_NOT_READY' then raise; end if;
    end;
    perform set_config('request.jwt.claim.sub', ('10000000-0000-4000-8000-' || lpad((p_seed + 1)::text, 12, '0')), true);
    begin
      perform public.start_room(v_id);
      raise exception 'Expected HOST_REQUIRED';
    exception when sqlstate 'P0001' then
      if sqlerrm <> 'HOST_REQUIRED' then raise; end if;
    end;
  end if;
  for i in 0..(p_count - 1) loop
    perform set_config('request.jwt.claim.sub', ('10000000-0000-4000-8000-' || lpad((p_seed + i)::text, 12, '0')), true);
    perform public.set_player_ready(v_id, true);
  end loop;
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  v_result := public.start_room(v_id);
  return (v_result->'game'->>'id')::uuid;
end;
$$;

create temporary table phase3a_games(player_count integer, game_id uuid);
grant select on phase3a_games to authenticated;
insert into phase3a_games values
  (3, pg_temp.blackout_started_game(3, 101)),
  (4, pg_temp.blackout_started_game(4, 111)),
  (5, pg_temp.blackout_started_game(5, 121)),
  (6, pg_temp.blackout_started_game(6, 131));

select is((select count(*)::integer from phase3a_games), 4, 'started games cover each supported room size');
select is((select count(*)::integer from public.blackout_players bp join phase3a_games g on g.game_id = bp.game_id where g.player_count = 3), 3, 'three-player game has three game players');
select is((select count(*)::integer from public.blackout_players bp join phase3a_games g on g.game_id = bp.game_id where g.player_count = 4), 4, 'four-player game has four game players');
select is((select count(*)::integer from public.blackout_players bp join phase3a_games g on g.game_id = bp.game_id where g.player_count = 5), 5, 'five-player game has five game players');
select is((select count(*)::integer from public.blackout_players bp join phase3a_games g on g.game_id = bp.game_id where g.player_count = 6), 6, 'six-player game has six game players');
select is((select count(*)::integer from (select g.game_id from public.blackout_objectives o join phase3a_games g on g.game_id = o.game_id where o.secret_role = 'SABOTEUR' group by g.game_id having count(*) = 1) saboteur_games), 4, 'every supported game has exactly one Saboteur');
select is((select count(*)::integer from public.blackout_objectives o join phase3a_games g on g.game_id = o.game_id where o.secret_role in ('HACKER', 'SCOUT', 'ENGINEER')), 14, 'all remaining roles are crew roles');
select is((select count(*)::integer from public.blackout_games bg join phase3a_games g on g.game_id = bg.id where bg.state = 'ROLE_REVEAL'), 4, 'new games enter the role reveal state');
select is((select count(*)::integer from public.rooms r join public.blackout_games bg on bg.room_id = r.id join phase3a_games g on g.game_id = bg.id where r.status = 'IN_GAME'), 4, 'successful starts atomically mark rooms in game');

-- Non-host start requests are rejected and public roster snapshots omit secrets.
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000102', true);
select is((public.blackout_game_snapshot((select game_id from phase3a_games where player_count = 3))->'players'->0) ? 'secret_role', false, 'public roster does not contain role fields');
select is((public.blackout_game_snapshot((select game_id from phase3a_games where player_count = 3))->'my_player'->>'secret_role') is not null, true, 'a member receives their own private role');
select ok(not has_function_privilege('authenticated', 'public.blackout_game_snapshot(uuid)', 'EXECUTE'), 'snapshot helper is not directly executable by clients');

-- Direct table reads expose only the caller's private assignment.
set local role authenticated;
select is((select count(*)::integer from public.blackout_objectives o join public.blackout_players bp on bp.id = o.blackout_player_id join phase3a_games g on g.game_id = bp.game_id where g.player_count = 3), 1, 'objective RLS reveals only the caller assignment');
select is((select count(*)::integer from public.blackout_games bg join phase3a_games g on g.game_id = bg.id), 1, 'game state is visible only to a member');
reset role;

-- An authenticated nonmember cannot read game state or recover a game snapshot.
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000130', true);
set local role authenticated;
select is((select count(*)::integer from public.blackout_games bg join phase3a_games g on g.game_id = bg.id), 0, 'nonmember cannot read game state');
select throws_ok($$select public.get_my_game()$$, 'P0001', 'GAME_MEMBERSHIP_REQUIRED', 'nonmember cannot recover a game');
reset role;

-- The active deadline is generated by the server and fixed at five minutes.
update public.blackout_games set state = 'FACILITY_INTRO', state_deadline_at = now() - interval '1 second'
where id = (select game_id from phase3a_games where player_count = 3);
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000101', true);
select lives_ok($$select public.get_my_game()$$, 'member polling advances an expired briefing');
select is((select state from public.blackout_games where id = (select game_id from phase3a_games where player_count = 3)), 'ACTIVE', 'expired briefing advances to active');
select is((select active_deadline_at - active_started_at from public.blackout_games where id = (select game_id from phase3a_games where player_count = 3)), interval '5 minutes', 'server active timer is exactly five minutes');

select * from finish();
rollback;
