begin;
create extension if not exists pgtap with schema extensions;
select plan(48);

select has_table('public', 'rooms', 'rooms table exists');
select has_table('public', 'room_players', 'room_players table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.rooms'::regclass), 'RLS is enabled for rooms');
select ok((select relrowsecurity from pg_class where oid = 'public.room_players'::regclass), 'RLS is enabled for room_players');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rooms'), 'rooms are published to Realtime');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_players'), 'room_players are published to Realtime');
select ok(exists (select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages' and policyname = 'Room members can receive private lobby channel messages' and cmd = 'SELECT' and qual like '%presence%' and qual like '%is_current_user_lobby_channel_member%'), 'Realtime presence reads require room membership');
select ok(exists (select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages' and policyname = 'Room members can publish private lobby presence'), 'Realtime presence writes require room membership');

insert into auth.users(id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values
  ('00000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'blackout-host@test.invalid', '', now(), '{}', '{}', true),
  ('00000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'blackout-p2@test.invalid', '', now(), '{}', '{}', true),
  ('00000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'blackout-p3@test.invalid', '', now(), '{}', '{}', true),
  ('00000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'blackout-p4@test.invalid', '', now(), '{}', '{}', true),
  ('00000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'blackout-p5@test.invalid', '', now(), '{}', '{}', true),
  ('00000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'blackout-p6@test.invalid', '', now(), '{}', '{}', true),
  ('00000000-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'blackout-p7@test.invalid', '', now(), '{}', '{}', true);

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
create temporary table test_room as
select (public.create_room('Host One')->'room'->>'id')::uuid as id;
grant select on test_room to authenticated;
select is((select status from public.rooms where id = (select id from test_room)), 'LOBBY', 'room starts in the lobby');
select is((select count(*)::integer from public.room_players where room_id = (select id from test_room) and is_host and left_at is null), 1, 'creator is the single host');

set local role authenticated;
select is((select count(*)::integer from public.rooms where id = (select id from test_room)), 1, 'member can read their room under RLS');
select is((select count(*)::integer from public.room_players where room_id = (select id from test_room)), 1, 'member can read their roster under RLS');
select throws_ok($$update public.rooms set status = 'IN_GAME' where id = (select id from test_room)$$, '42501', null, 'member cannot directly change room state');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000007', true);
set local role authenticated;
select is((select count(*)::integer from public.rooms where id = (select id from test_room)), 0, 'nonmember cannot read another room under RLS');
select is((select count(*)::integer from public.room_players where room_id = (select id from test_room)), 0, 'nonmember cannot read another roster under RLS');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Two')$$, 'second player joins');
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Two')$$, 'same session reconnects without a duplicate');
select is((select count(*)::integer from public.room_players where room_id = (select id from test_room) and left_at is null), 2, 'reconnect preserves one membership');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Three')$$, 'third player joins');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000004', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Four')$$, 'fourth player joins');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000005', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Five')$$, 'fifth player joins');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000006', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Six')$$, 'sixth player joins');
select is((select count(*)::integer from public.room_players where room_id = (select id from test_room) and left_at is null), 6, 'room accepts six players');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000007', true);
select throws_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Seven')$$, 'P0001', 'ROOM_FULL', 'seventh player is rejected');
select throws_ok($$select public.join_room('!!!!!', 'Operator Seven')$$, 'P0001', 'INVALID_ROOM_CODE', 'invalid room code is rejected');
select throws_ok($$select public.join_room('ZZZZZ', 'Operator Seven')$$, 'P0001', 'ROOM_NOT_FOUND', 'unknown room code is rejected');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
select lives_ok($$select public.set_player_ready((select id from test_room), true)$$, 'host can set ready state');
select ok((select ready from public.room_players where room_id = (select id from test_room) and auth_user_id = auth.uid()), 'ready state is stored');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
select throws_ok($$select public.start_room((select id from test_room))$$, 'P0001', 'HOST_REQUIRED', 'non-host cannot start the room');

update public.room_players set left_at = now(), ready = false, connection_state = 'disconnected'
where room_id = (select id from test_room) and auth_user_id in (
  '00000000-0000-4000-8000-000000000003',
  '00000000-0000-4000-8000-000000000004',
  '00000000-0000-4000-8000-000000000005',
  '00000000-0000-4000-8000-000000000006'
);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
select lives_ok($$select public.set_player_ready((select id from test_room), true)$$, 'host ready state can be refreshed');
select throws_ok($$select public.start_room((select id from test_room))$$, 'P0001', 'NOT_ENOUGH_PLAYERS', 'fewer than three players cannot start');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from test_room)), 'Operator Three')$$, 'departed member can reclaim their seat');
select lives_ok($$select public.set_player_ready((select id from test_room), true)$$, 'third player can become ready');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
select lives_ok($$select public.set_player_ready((select id from test_room), true)$$, 'second player can become ready');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
select lives_ok($$select public.start_room((select id from test_room))$$, 'host starts when three players are ready');
select is((select status from public.rooms where id = (select id from test_room)), 'IN_GAME', 'accepted start atomically advances the room into the game');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000004', true);
create temporary table migration_room as
select (public.create_room('Migration Host')->'room'->>'id')::uuid as id;
select is((select count(*)::integer from public.room_players where room_id = (select id from migration_room) and is_host and left_at is null), 1, 'new room has exactly one host');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000005', true);
select lives_ok($$select public.join_room((select room_code from public.rooms where id = (select id from migration_room)), 'Next Host')$$, 'second migration candidate joins');
update public.room_players set last_seen_at = now() - interval '90 seconds', connection_state = 'disconnected'
where room_id = (select id from migration_room) and is_host;
select lives_ok($$select public.heartbeat_room((select id from migration_room))$$, 'connected player reconciles a disconnected host');
select is((select host_player_id from public.rooms where id = (select id from migration_room)), (select id from public.room_players where room_id = (select id from migration_room) and auth_user_id = auth.uid()), 'host migrates to the oldest connected player');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000004', true);
select lives_ok($$select public.heartbeat_room((select id from migration_room))$$, 'returning player refreshes their heartbeat');
select lives_ok($$select public.get_my_lobby()$$, 'refresh restores the existing lobby');
select is((select count(*)::integer from public.room_players where room_id = (select id from migration_room) and auth_user_id = auth.uid() and left_at is null), 1, 'refresh does not create duplicate membership');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000005', true);
select lives_ok($$select public.leave_room((select id from migration_room))$$, 'host can leave the lobby');
select is((select host_player_id from public.rooms where id = (select id from migration_room)), (select id from public.room_players where room_id = (select id from migration_room) and auth_user_id = '00000000-0000-4000-8000-000000000004'), 'host migrates on intentional leave');

create temporary table expiring_room as
select (public.create_room('Expiry Host')->'room'->>'id')::uuid as id;
update public.rooms set expires_at = now() - interval '1 minute' where id = (select id from expiring_room);
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000007', true);
select throws_ok($$select public.join_room((select room_code from public.rooms where id = (select id from expiring_room)), 'Late Joiner')$$, 'P0001', 'ROOM_EXPIRED', 'expired room rejects joins');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000005', true);
select ok(public.get_my_lobby() is null, 'expired membership is not restored');
select is((select status from public.rooms where id = (select id from expiring_room)), 'EXPIRED', 'expired lobby is marked expired during recovery');

select * from finish();
rollback;
