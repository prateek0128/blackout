begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users(id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
select ('20000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'authenticated', 'authenticated', 'blackout-phase3b-' || n || '@test.invalid', '', now(), '{}', '{}', true
from generate_series(301, 330) n;

create or replace function pg_temp.blackout_action_game(p_count integer, p_seed integer)
returns uuid language plpgsql as $$
declare
  v_host uuid := ('20000000-0000-4000-8000-' || lpad(p_seed::text, 12, '0'))::uuid;
  v_room_id uuid;
  v_room_code text;
  v_result jsonb;
  i integer;
begin
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  v_result := public.create_room('Action Host ' || p_seed);
  v_room_id := (v_result->'room'->>'id')::uuid;
  select room_code into v_room_code from public.rooms where id = v_room_id;
  for i in 1..(p_count - 1) loop
    perform set_config('request.jwt.claim.sub', ('20000000-0000-4000-8000-' || lpad((p_seed + i)::text, 12, '0')), true);
    perform public.join_room(v_room_code, 'Action Crew ' || i);
  end loop;
  for i in 0..(p_count - 1) loop
    perform set_config('request.jwt.claim.sub', ('20000000-0000-4000-8000-' || lpad((p_seed + i)::text, 12, '0')), true);
    perform public.set_player_ready(v_room_id, true);
  end loop;
  perform set_config('request.jwt.claim.sub', v_host::text, true);
  v_result := public.start_room(v_room_id);
  return (v_result->'game'->>'id')::uuid;
end;
$$;

create temporary table phase3b_games(player_count integer, game_id uuid);
create temporary table phase3b_roles(game_id uuid, role_name text, user_id uuid, player_id uuid);
grant select on phase3b_games, phase3b_roles to authenticated;
insert into phase3b_games values
  (6, pg_temp.blackout_action_game(6, 301)),
  (3, pg_temp.blackout_action_game(3, 311));
insert into phase3b_roles(game_id, role_name, user_id, player_id)
select bp.game_id, o.secret_role, rp.auth_user_id, bp.id
from public.blackout_players bp
join public.room_players rp on rp.id = bp.room_player_id
join public.blackout_objectives o on o.blackout_player_id = bp.id
where bp.game_id in (select game_id from phase3b_games where player_count = 6);
update public.blackout_games g
set state = 'ACTIVE', state_started_at = clock_timestamp(),
    active_started_at = clock_timestamp() - interval '30 seconds',
    active_deadline_at = clock_timestamp() + interval '5 minutes',
    power = 50, security = 50, facility_integrity = 50
where g.id in (select game_id from phase3b_games);

select is((select count(*)::integer from public.blackout_players bp join phase3b_games g on g.game_id = bp.game_id where g.player_count = 3), 3, 'Phase 3B supports a three-player game');
select is((select count(*)::integer from public.blackout_players bp join phase3b_games g on g.game_id = bp.game_id where g.player_count = 6), 6, 'Phase 3B supports a six-player game');
select is((select count(*)::integer from phase3b_roles where role_name = 'SABOTEUR'), 1, 'six-player game still has exactly one Saboteur');
select is((select count(distinct role_name)::integer from phase3b_roles where role_name in ('HACKER', 'SCOUT', 'ENGINEER')), 3, 'six-player game includes each Crew specialization');
select ok((select relrowsecurity from pg_class where oid = 'public.blackout_events'::regclass), 'event log has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.blackout_action_cooldowns'::regclass), 'cooldown table has RLS enabled');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'blackout_events'), 'facility events are published to Realtime');

-- Hacker: private, incomplete information; no shared state mutation.
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'HACKER' limit 1), true);
select lives_ok($$select public.blackout_scan_security((select game_id from phase3b_games where player_count = 6))$$, 'Hacker can scan Security');
select throws_ok($$select public.blackout_scan_security((select game_id from phase3b_games where player_count = 6))$$, 'P0001', 'ACTION_COOLDOWN', 'rapid repeat scan is rejected by cooldown');
select throws_ok($$select public.blackout_repair_power((select game_id from phase3b_games where player_count = 6), 'POWER')$$, 'P0001', 'ROLE_REQUIRED', 'Hacker cannot use Engineer action');
select throws_ok($$select public.blackout_disrupt_power((select game_id from phase3b_games where player_count = 6))$$, 'P0001', 'ROLE_REQUIRED', 'Hacker cannot use Saboteur action');

-- Engineer: bounded shared repair and action-specific sector validation.
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'ENGINEER' limit 1), true);
select lives_ok($$select public.blackout_repair_power((select game_id from phase3b_games where player_count = 6), 'POWER')$$, 'Engineer can repair Power');
select is((select power::integer from public.blackout_games where id = (select game_id from phase3b_games where player_count = 6)), 62, 'repair increases Power by twelve');
select is((select facility_integrity::integer from public.blackout_games where id = (select game_id from phase3b_games where player_count = 6)), 52, 'repair slightly restores Integrity');
select throws_ok($$select public.blackout_repair_power((select game_id from phase3b_games where player_count = 6), 'SECURITY')$$, 'P0001', 'SECTOR_NOT_VALID_FOR_ACTION', 'Engineer repair rejects an incompatible sector');
select throws_ok($$select public.blackout_scan_security((select game_id from phase3b_games where player_count = 6))$$, 'P0001', 'ROLE_REQUIRED', 'Engineer cannot use Hacker action');

-- Scout: private discoveries scoped to the selected sector.
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'SCOUT' limit 1), true);
select lives_ok($$select public.blackout_investigate((select game_id from phase3b_games where player_count = 6), 'OPERATIONS')$$, 'Scout can investigate Operations');
select throws_ok($$select public.blackout_investigate((select game_id from phase3b_games where player_count = 6), 'INVALID')$$, 'P0001', 'INVALID_SECTOR', 'invalid facility sector is rejected');
-- An investigation now correctly opens discussion; restore the isolated test
-- fixture to ACTIVE before testing other role actions in the same game.
update public.blackout_games set state = 'ACTIVE', state_started_at = clock_timestamp(),
  active_started_at = clock_timestamp(), active_deadline_at = clock_timestamp() + interval '5 minutes',
  active_remaining_ms = 300000, state_deadline_at = clock_timestamp() + interval '5 minutes'
where id = (select game_id from phase3b_games where player_count = 6);
select throws_ok($$select public.blackout_disrupt_power((select game_id from phase3b_games where player_count = 6))$$, 'P0001', 'ROLE_REQUIRED', 'Scout cannot use Saboteur action');
select throws_ok($$select public.blackout_repair_power((select game_id from phase3b_games where player_count = 6), 'POWER')$$, 'P0001', 'ROLE_REQUIRED', 'Scout cannot use Engineer action');

-- Saboteur: all three actions work but public messages do not identify the actor.
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'SABOTEUR' limit 1), true);
select lives_ok($$select public.blackout_disrupt_power((select game_id from phase3b_games where player_count = 6))$$, 'Saboteur can disrupt Power');
select lives_ok($$select public.blackout_increase_security((select game_id from phase3b_games where player_count = 6))$$, 'Saboteur can increase Security');
select lives_ok($$select public.blackout_tamper_relay((select game_id from phase3b_games where player_count = 6), 'MAINTENANCE')$$, 'Saboteur can tamper with a relay');
select throws_ok($$select public.blackout_scan_security((select game_id from phase3b_games where player_count = 6))$$, 'P0001', 'ROLE_REQUIRED', 'Saboteur cannot use Hacker action');
select throws_ok($$select public.blackout_repair_power((select game_id from phase3b_games where player_count = 6), 'POWER')$$, 'P0001', 'ROLE_REQUIRED', 'Saboteur cannot use Engineer action');
select throws_ok($$select public.blackout_investigate((select game_id from phase3b_games where player_count = 6), 'POWER')$$, 'P0001', 'ROLE_REQUIRED', 'Saboteur cannot use Scout action');
select is((select count(*)::integer from public.blackout_events where game_id = (select game_id from phase3b_games where player_count = 6) and visibility = 'PUBLIC' and message ilike '%saboteur%'), 0, 'public action feed never names the Saboteur');
select is((select count(*)::integer from public.blackout_events where game_id = (select game_id from phase3b_games where player_count = 6) and visibility = 'PUBLIC' and recipient_player_id is not null), 0, 'public events contain no private recipient identity');

-- Each authenticated member sees the shared event feed and only their own intel.
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'HACKER' limit 1), true);
set local role authenticated;
select is((select count(*)::integer from public.blackout_events where game_id = (select game_id from phase3b_games where player_count = 6) and visibility = 'PRIVATE'), 1, 'Hacker RLS exposes only the Hacker discovery');
select is(jsonb_array_length(public.get_my_game()->'public_events') > 0, true, 'game recovery includes the public event history');
select is(jsonb_array_length(public.get_my_game()->'my_intel'), 1, 'game recovery restores private discoveries');
select is((select count(*)::integer from public.blackout_action_cooldowns where game_id = (select game_id from phase3b_games where player_count = 6)), 1, 'cooldown RLS exposes only the caller cooldown');
select is((select count(*)::integer from jsonb_array_elements(public.get_my_game()->'my_cooldowns') as c(value) where value->>'action' <> 'SCAN_SECURITY'), 0, 'recovered cooldown list contains only actions for this role');
reset role;

-- Nonmembers cannot read either event stream or invoke an action.
select set_config('request.jwt.claim.sub', '20000000-0000-4000-8000-000000000330', true);
set local role authenticated;
select is((select count(*)::integer from public.blackout_events where game_id = (select game_id from phase3b_games where player_count = 6)), 0, 'nonmember cannot read the event stream');
select throws_ok($$select public.blackout_disrupt_power((select game_id from phase3b_games where player_count = 6))$$, 'P0001', 'GAME_MEMBERSHIP_REQUIRED', 'nonmember cannot invoke an action');
reset role;

-- Alive/active, state, deadline, and hard numeric bounds are enforced by the server.
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'SCOUT' limit 1), true);
update public.blackout_players set is_alive = false where id = (select player_id from phase3b_roles where role_name = 'SCOUT' limit 1);
select throws_ok($$select public.blackout_investigate((select game_id from phase3b_games where player_count = 6), 'OPERATIONS')$$, 'P0001', 'PLAYER_INACTIVE', 'dead player cannot act');
update public.blackout_players set is_alive = true where id = (select player_id from phase3b_roles where role_name = 'SCOUT' limit 1);
update public.blackout_games set state = 'DISCUSSION' where id = (select game_id from phase3b_games where player_count = 6);
select throws_ok($$select public.blackout_investigate((select game_id from phase3b_games where player_count = 6), 'OPERATIONS')$$, 'P0001', 'GAME_NOT_ACTIVE', 'actions are rejected outside ACTIVE');
update public.blackout_games set state = 'ACTIVE', active_started_at = clock_timestamp() - interval '5 minutes',
  active_deadline_at = clock_timestamp() - interval '1 second' where id = (select game_id from phase3b_games where player_count = 6);
select throws_ok($$select public.blackout_investigate((select game_id from phase3b_games where player_count = 6), 'OPERATIONS')$$, 'P0001', 'GAME_TIMER_EXPIRED', 'actions are rejected after the active deadline');

update public.blackout_games set state = 'ACTIVE', active_deadline_at = clock_timestamp() + interval '5 minutes', power = 0, security = 100, facility_integrity = 0 where id = (select game_id from phase3b_games where player_count = 6);
update public.blackout_action_cooldowns set next_available_at = clock_timestamp() - interval '1 second' where game_id = (select game_id from phase3b_games where player_count = 6);
select set_config('request.jwt.claim.sub', (select user_id::text from phase3b_roles where role_name = 'SABOTEUR' limit 1), true);
select lives_ok($$select public.blackout_disrupt_power((select game_id from phase3b_games where player_count = 6))$$, 'Saboteur can act at the lower Power bound');
select lives_ok($$select public.blackout_increase_security((select game_id from phase3b_games where player_count = 6))$$, 'Saboteur can act at the upper Security bound');
select lives_ok($$select public.blackout_tamper_relay((select game_id from phase3b_games where player_count = 6), 'POWER')$$, 'Saboteur can act at the lower Integrity bound');
select is((select power::integer from public.blackout_games where id = (select game_id from phase3b_games where player_count = 6)), 0, 'Power is clamped at zero');
select is((select security::integer from public.blackout_games where id = (select game_id from phase3b_games where player_count = 6)), 100, 'Security is clamped at one hundred');
select is((select facility_integrity::integer from public.blackout_games where id = (select game_id from phase3b_games where player_count = 6)), 0, 'Integrity is clamped at zero');
select ok((select power between 0 and 100 and security between 0 and 100 and facility_integrity between 0 and 100 from public.blackout_games where id = (select game_id from phase3b_games where player_count = 6)), 'all shared facility values remain within their constraints');

select * from finish();
rollback;
