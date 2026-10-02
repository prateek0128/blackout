begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,is_anonymous)
select ('31000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'authenticated','authenticated',
  'blackout-phase3d-'||n||'@test.invalid','',now(),'{}','{}',true from generate_series(601,616) n;

create temporary table phase3d_context(room_id uuid,game_id uuid,room_code text,host_id uuid,scout_id uuid,hacker_id uuid,saboteur_id uuid);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
insert into phase3d_context(room_id,room_code,host_id)
select (r->'room'->>'id')::uuid,(r->'room'->>'room_code'),'31000000-0000-4000-8000-000000000601'::uuid
from (select public.create_room('Phase 3D Host') r) x;
grant select on phase3d_context to authenticated;
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select public.join_room((select room_code from phase3d_context),'Phase 3D Scout');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000603',true);
select public.join_room((select room_code from phase3d_context),'Phase 3D Hacker');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'host readiness setup succeeds');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'Scout readiness setup succeeds');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000603',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'Hacker readiness setup succeeds');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
update phase3d_context set game_id=(public.start_room(room_id)->'game'->>'id')::uuid;
update phase3d_context c set scout_id=bp.id from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
  where bp.game_id=c.game_id and rp.auth_user_id='31000000-0000-4000-8000-000000000602';
update phase3d_context c set hacker_id=bp.id from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
  where bp.game_id=c.game_id and rp.auth_user_id='31000000-0000-4000-8000-000000000603';
update phase3d_context c set saboteur_id=bp.id from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
  where bp.game_id=c.game_id and rp.auth_user_id='31000000-0000-4000-8000-000000000601';
update public.blackout_objectives set secret_role='SCOUT' where blackout_player_id=(select scout_id from phase3d_context);
update public.blackout_objectives set secret_role='HACKER' where blackout_player_id=(select hacker_id from phase3d_context);
update public.blackout_objectives set secret_role='SABOTEUR' where blackout_player_id=(select saboteur_id from phase3d_context);
with timer as (select clock_timestamp() as started)
update public.blackout_games g set state='ACTIVE',state_started_at=timer.started,state_deadline_at=timer.started+interval '5 minutes',
  active_started_at=timer.started,active_deadline_at=timer.started+interval '5 minutes',active_remaining_ms=300000,
  power=68,security=41,facility_integrity=80 from timer where g.id=(select game_id from phase3d_context);

select has_table('public','blackout_escape_state','shared escape state exists');
select has_table('public','blackout_escape_cooldowns','escape cooldown state exists');
select has_table('public','blackout_results','durable results exist');
select ok((select relrowsecurity from pg_class where oid='public.blackout_escape_state'::regclass),'escape state has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.blackout_escape_cooldowns'::regclass),'cooldowns have RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.blackout_results'::regclass),'results have RLS enabled');
select ok(has_function_privilege('authenticated','public.blackout_escape_action(uuid,text)','EXECUTE'),'members can call server-side escape action RPC');
select ok(has_function_privilege('authenticated','public.blackout_restart_game(uuid)','EXECUTE'),'authenticated players may request host-checked replay RPC');
select ok(not has_function_privilege('authenticated','public.advance_blackout_game(uuid)','EXECUTE'),'deadline transition helper is not directly callable');
select ok(not has_table_privilege('authenticated','public.blackout_escape_state','INSERT'),'clients cannot directly write escape state');
select ok(exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_escape_state'),'escape state is published to Realtime');
select ok(exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_results'),'results are published to Realtime');
select ok(exists(select 1 from pg_indexes where schemaname='public' and indexname='blackout_escape_cooldowns_lookup'),'escape cooldown lookup index exists');

-- Expired active time advances from a member read into the server-owned blackout window.
with expired as (select clock_timestamp() as now_at)
update public.blackout_games g set active_started_at=expired.now_at-interval '6 minutes',
  active_deadline_at=expired.now_at-interval '1 second',state_deadline_at=expired.now_at-interval '1 second'
  from expired where g.id=(select game_id from phase3d_context);
select is((public.get_my_game()->'game'->>'state'),'FINAL_BLACKOUT','active deadline starts final blackout');
select ok((select final_deadline_at-final_started_at=interval '45 seconds' from public.blackout_games where id=(select game_id from phase3d_context)),'final escape window is exactly 45 seconds');
select is(public.get_my_game()->'results','null'::jsonb,'results and identities stay hidden before resolution');
select is(public.get_my_game()->'my_player'->>'secret_role','SABOTEUR','player snapshot discloses only the caller own role');
select is((select count(*)::integer from public.blackout_escape_state where game_id=(select game_id from phase3d_context)),1,'escape state is created once on transition');
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3d_context);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select is((public.get_my_game()->'game'->>'state'),'ESCAPE','final transition restores as escape after reconnect');
select is(jsonb_array_length(public.get_my_game()->'escape'->'my_available_actions'),3,'Scout receives Scout access plus fallback controls for unassigned crew roles');
select ok(not ((public.get_my_game()->'players'->0) ? 'secret_role'),'shared roster does not expose another player role before results');
select throws_ok($$select public.blackout_investigate((select game_id from phase3d_context),'POWER')$$,'P0001','GAME_NOT_ACTIVE','normal facility actions stop during the escape phase');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
update public.blackout_players set last_seen_at=clock_timestamp()-interval '60 seconds'
where id=(select saboteur_id from phase3d_context);
select throws_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'JAM_ESCAPE')$$,'P0001','PLAYER_DISCONNECTED','stale Saboteur cannot interfere with escape progress');
select lives_ok($$select public.get_my_game()$$,'game snapshot reconnects the Saboteur before escape actions');
select throws_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'LOCATE_ESCAPE_ROUTE')$$,'P0001','ROLE_REQUIRED','Saboteur cannot perform a crew escape action');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000604',true);
select throws_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'LOCATE_ESCAPE_ROUTE')$$,'P0001','GAME_MEMBERSHIP_REQUIRED','nonmember cannot act on escape state');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select throws_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'UNRECOGNIZED')$$,'P0001','INVALID_ESCAPE_ACTION','unknown escape action is rejected');
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'LOCATE_ESCAPE_ROUTE')$$,'Scout locates the shared route');
select is((public.get_my_game()->'escape'->>'route_located')::boolean,true,'roster snapshot receives shared route update');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'JAM_ESCAPE')$$,'Saboteur can interfere with completed escape progress');
select is((select facility_integrity::integer from public.blackout_games where id=(select game_id from phase3d_context)),75,'Saboteur interference damages facility integrity by five');
select is((select route_located from public.blackout_escape_state where game_id=(select game_id from phase3d_context)),false,'Saboteur interference rolls back route progress');
select throws_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'JAM_ESCAPE')$$,'P0001','ESCAPE_ACTION_COOLDOWN','Saboteur escape action cooldown is enforced');
update public.blackout_escape_cooldowns set next_available_at=clock_timestamp()-interval '1 second' where game_id=(select game_id from phase3d_context);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'LOCATE_ESCAPE_ROUTE')$$,'crew restores route progress after interference');

select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000603',true);
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'UNLOCK_EMERGENCY_ROUTE')$$,'Hacker unlocks the emergency route');
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'POWER_ESCAPE_DOOR')$$,'missing Engineer role receives cooperative fallback power control');
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_context),'OPEN_ESCAPE_DOOR')$$,'Crew opens powered emergency door');
select is((public.get_my_game()->'game'->>'state'),'RESULTS','successful timely escape resolves the game');
select is((public.get_my_game()->'results'->>'outcome'),'CREW_ESCAPED','crew escape is the resolved outcome');
select is(jsonb_array_length(public.get_my_game()->'results'->'role_reveal'),3,'all roles are revealed only in results');
select is((select status from public.rooms where id=(select room_id from phase3d_context)),'COMPLETED','result marks the room complete');
select is((select count(*)::integer from public.blackout_events where game_id=(select game_id from phase3d_context) and event_type like 'ESCAPE_%' and visibility='PUBLIC'),6,'escape progress and Saboteur interference publish six shared events');

-- Results are member-scoped, replay is host-only, and old game history remains intact.
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000604',true);
set local role authenticated;
select is((select count(*)::integer from public.blackout_results where game_id=(select game_id from phase3d_context)),0,'nonmember cannot read result rows under RLS');
reset role;
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select throws_ok($$select public.blackout_restart_game((select game_id from phase3d_context))$$,'P0001','HOST_REQUIRED','nonhost member cannot restart the room');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000604',true);
select throws_ok($$select public.blackout_restart_game((select game_id from phase3d_context))$$,'P0001','GAME_MEMBERSHIP_REQUIRED','nonmember cannot request a replay');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
update public.blackout_players bp set last_seen_at=clock_timestamp()-interval '60 seconds'
from public.room_players rp
where bp.room_player_id=rp.id and bp.game_id=(select game_id from phase3d_context)
  and rp.auth_user_id='31000000-0000-4000-8000-000000000601';
select throws_ok($$select public.blackout_restart_game((select game_id from phase3d_context))$$,'P0001','PLAYER_DISCONNECTED','stale host cannot restart a resolved game');
select lives_ok($$select public.get_my_game()$$,'host game recovery refreshes liveness before replay');
select lives_ok($$select public.blackout_restart_game((select game_id from phase3d_context))$$,'host can restart from resolved results');
select is((select status from public.rooms where id=(select room_id from phase3d_context)),'LOBBY','replay returns same room to the lobby');
select is((select count(*)::integer from public.blackout_games where room_id=(select room_id from phase3d_context)),1,'previous game remains as durable history');
select is((select count(*)::integer from public.room_players where room_id=(select room_id from phase3d_context) and ready),0,'replay resets all readiness');
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'host replay readiness succeeds');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'Scout replay readiness succeeds');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000603',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'Hacker replay readiness succeeds');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
select is((select status from public.rooms where id=(select room_id from phase3d_context)),'LOBBY','room remains in lobby after readiness resets');
update phase3d_context set game_id=(public.start_room(room_id)->'game'->>'id')::uuid;
select is((select count(*)::integer from public.blackout_games where room_id=(select room_id from phase3d_context)),2,'both completed and new game rows remain in history');
update public.blackout_games set created_at=clock_timestamp() where id=(select game_id from phase3d_context);
select is((select count(*)::integer from public.blackout_players where game_id=(select game_id from phase3d_context)),3,'new round has a fresh player roster');
select is((select count(*)::integer from public.blackout_objectives where game_id=(select game_id from phase3d_context)),3,'new round receives fresh role assignments');
select is((select count(*)::integer from public.blackout_escape_state where game_id=(select game_id from phase3d_context)),0,'new round begins without previous escape progress');
select is((select count(*)::integer from public.blackout_events where game_id=(select game_id from phase3d_context)),0,'new round begins without previous game events');

-- Facility failure takes precedence over an opened door and expired deadline.
with past as (select clock_timestamp() as t)
update public.blackout_games g set state='ESCAPE',state_started_at=past.t-interval '50 seconds',state_deadline_at=past.t-interval '1 second',
  final_started_at=past.t-interval '45 seconds',final_deadline_at=past.t-interval '1 second',facility_integrity=0
from past where g.id=(select game_id from phase3d_context);
insert into public.blackout_escape_state(game_id,route_located,route_unlocked,door_powered,door_opened)
values((select game_id from phase3d_context),true,true,true,true)
on conflict(game_id) do update set route_located=true,route_unlocked=true,door_powered=true,door_opened=true;
select is((public.get_my_game()->'results'->>'outcome'),'FACILITY_FAILURE','facility failure deterministically outranks escape and timeout');
select is((public.get_my_game()->'game'->>'state'),'RESULTS','facility failure resolves the current game');

-- A separate replay verifies that an expired final deadline awards the Saboteur.
select lives_ok($$select public.blackout_restart_game((select game_id from phase3d_context))$$,'host can restart after facility failure');
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'host readies for timeout test');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000602',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'Scout readies for timeout test');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000603',true);
select lives_ok($$select public.set_player_ready((select room_id from phase3d_context),true)$$,'Hacker readies for timeout test');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000601',true);
update phase3d_context set game_id=(public.start_room(room_id)->'game'->>'id')::uuid;
update public.blackout_games set created_at=clock_timestamp() where id=(select game_id from phase3d_context);
with past as (select clock_timestamp() as t)
update public.blackout_games g set state='ESCAPE',state_started_at=past.t-interval '50 seconds',state_deadline_at=past.t-interval '1 second',
  final_started_at=past.t-interval '45 seconds',final_deadline_at=past.t-interval '1 second',facility_integrity=52
from past where g.id=(select game_id from phase3d_context);
insert into public.blackout_escape_state(game_id) values((select game_id from phase3d_context)) on conflict(game_id) do nothing;
select is((public.get_my_game()->'results'->>'outcome'),'SABOTEUR_PREVAILED','escape deadline expiry awards the Saboteur');
select is((public.get_my_game()->'game'->>'state'),'RESULTS','deadline is resolved during reconnect recovery');

-- Six-player coverage confirms the same authoritative steps and reveals all seats.
create temporary table phase3d_six(room_id uuid,room_code text,game_id uuid);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000610',true);
insert into phase3d_six(room_id,room_code)
select (result->'room'->>'id')::uuid,result->'room'->>'room_code' from (select public.create_room('Six Seat Host') result) created;
grant select on phase3d_six to authenticated;
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000611',true);
select public.join_room((select room_code from phase3d_six),'Six Seat Hacker');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000612',true);
select public.join_room((select room_code from phase3d_six),'Six Seat Scout');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000613',true);
select public.join_room((select room_code from phase3d_six),'Six Seat Engineer');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000614',true);
select public.join_room((select room_code from phase3d_six),'Six Seat Crew');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000615',true);
select public.join_room((select room_code from phase3d_six),'Six Seat Crew Two');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000610',true);
select public.set_player_ready((select room_id from phase3d_six),true);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000611',true);
select public.set_player_ready((select room_id from phase3d_six),true);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000612',true);
select public.set_player_ready((select room_id from phase3d_six),true);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000613',true);
select public.set_player_ready((select room_id from phase3d_six),true);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000614',true);
select public.set_player_ready((select room_id from phase3d_six),true);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000615',true);
select public.set_player_ready((select room_id from phase3d_six),true);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000610',true);
update phase3d_six set game_id=(public.start_room(room_id)->'game'->>'id')::uuid;
update public.blackout_games set created_at=clock_timestamp() where id=(select game_id from phase3d_six);
update public.blackout_objectives set secret_role='HACKER' where game_id=(select game_id from phase3d_six);
update public.blackout_objectives o set secret_role=case rp.auth_user_id
  when '31000000-0000-4000-8000-000000000610'::uuid then 'SABOTEUR'
  when '31000000-0000-4000-8000-000000000611'::uuid then 'HACKER'
  when '31000000-0000-4000-8000-000000000612'::uuid then 'SCOUT'
  when '31000000-0000-4000-8000-000000000613'::uuid then 'ENGINEER'
  else 'HACKER' end
from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
where o.blackout_player_id=bp.id and bp.game_id=(select game_id from phase3d_six);
with expired as (select clock_timestamp() t)
update public.blackout_games g set state='ACTIVE',state_started_at=expired.t-interval '6 minutes',state_deadline_at=expired.t-interval '1 second',
  active_started_at=expired.t-interval '6 minutes',active_deadline_at=expired.t-interval '1 second',active_remaining_ms=0
from expired where g.id=(select game_id from phase3d_six);
select is((public.get_my_game()->'game'->>'state'),'FINAL_BLACKOUT','six-player active round advances to final blackout');
select is(jsonb_array_length(public.get_my_game()->'players'),6,'six-player final snapshot keeps all seats');
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3d_six);
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000612',true);
select is((public.get_my_game()->'game'->>'state'),'ESCAPE','six-player reconnect restores escape phase');
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_six),'LOCATE_ESCAPE_ROUTE')$$,'six-player Scout locates the route');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000611',true);
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_six),'UNLOCK_EMERGENCY_ROUTE')$$,'six-player Hacker unlocks the route');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000613',true);
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_six),'POWER_ESCAPE_DOOR')$$,'six-player Engineer powers the exit');
select set_config('request.jwt.claim.sub','31000000-0000-4000-8000-000000000614',true);
select lives_ok($$select public.blackout_escape_action((select game_id from phase3d_six),'OPEN_ESCAPE_DOOR')$$,'six-player Crew operator opens the door');
select is((public.get_my_game()->'results'->>'outcome'),'CREW_ESCAPED','six-player sequence resolves Crew victory');
select is(jsonb_array_length(public.get_my_game()->'results'->'role_reveal'),6,'six-player results reveal every role');

select * from finish();
rollback;
