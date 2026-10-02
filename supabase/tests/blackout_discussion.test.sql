begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,is_anonymous)
select ('30000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'authenticated','authenticated',
  'blackout-phase3c-'||n||'@test.invalid','',now(),'{}','{}',true from generate_series(401,430) n;

create or replace function pg_temp.phase3c_game(p_count integer,p_seed integer)
returns uuid language plpgsql as $$
declare v_host uuid:=('30000000-0000-4000-8000-'||lpad(p_seed::text,12,'0'))::uuid;
  v_room uuid; v_code text; v_result jsonb; i integer;
begin
  perform set_config('request.jwt.claim.sub',v_host::text,true);
  v_result:=public.create_room('Phase3C Host '||p_seed);
  v_room:=(v_result->'room'->>'id')::uuid;
  select room_code into v_code from public.rooms where id=v_room;
  for i in 1..p_count-1 loop
    perform set_config('request.jwt.claim.sub',('30000000-0000-4000-8000-'||lpad((p_seed+i)::text,12,'0')),true);
    perform public.join_room(v_code,'Phase3C Operator '||i);
  end loop;
  for i in 0..p_count-1 loop
    perform set_config('request.jwt.claim.sub',('30000000-0000-4000-8000-'||lpad((p_seed+i)::text,12,'0')),true);
    perform public.set_player_ready(v_room,true);
  end loop;
  perform set_config('request.jwt.claim.sub',v_host::text,true);
  v_result:=public.start_room(v_room);
  return (v_result->'game'->>'id')::uuid;
end $$;

create temporary table phase3c_games(game_tag text,player_count integer,seed integer,game_id uuid);
insert into phase3c_games values ('tie6',6,401,pg_temp.phase3c_game(6,401)),
  ('clear3',3,411,pg_temp.phase3c_game(3,411)),('timer3',3,421,pg_temp.phase3c_game(3,421));
create temporary table phase3c_members(game_tag text,seat integer,game_id uuid,user_id uuid,player_id uuid);
insert into phase3c_members(game_tag,seat,game_id,user_id,player_id)
select g.game_tag,n,g.game_id,('30000000-0000-4000-8000-'||lpad((g.seed+n)::text,12,'0'))::uuid,null
  from phase3c_games g cross join lateral generate_series(0,g.player_count-1) n;
update phase3c_members m set player_id=bp.id from public.blackout_players bp join public.room_players rp on rp.id=bp.room_player_id
  where bp.game_id=m.game_id and rp.auth_user_id=m.user_id;
grant select on phase3c_games,phase3c_members to authenticated;
update public.blackout_objectives o set secret_role='HACKER'
  from phase3c_members m where o.blackout_player_id=m.player_id;
update public.blackout_objectives o set secret_role=case m.seat when 0 then 'SABOTEUR' when 1 then 'HACKER' when 2 then 'SCOUT' when 3 then 'ENGINEER' else 'SCOUT' end
  from phase3c_members m where o.blackout_player_id=m.player_id;
update public.blackout_games g set state='ACTIVE',state_started_at=clock_timestamp(),state_deadline_at=clock_timestamp()+interval '5 minutes',
  active_started_at=clock_timestamp(),active_deadline_at=clock_timestamp()+interval '5 minutes',active_remaining_ms=300000,
  power=64,security=38,facility_integrity=77
  where g.id in(select distinct game_id from phase3c_members);

select is((select count(distinct game_id)::integer from phase3c_members where game_tag='tie6'),1,'six-player test game is established');
select is((select count(*)::integer from phase3c_members where game_tag='tie6'),6,'six-player roster remains supported');
select is((select count(*)::integer from phase3c_members where game_tag='clear3'),3,'three-player clear-result game is established');
select ok((select relrowsecurity from pg_class where oid='public.blackout_discussions'::regclass),'discussion state has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.blackout_accusations'::regclass),'accusations have RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.blackout_votes'::regclass),'ballots have RLS enabled');
select ok(has_function_privilege('authenticated','public.blackout_cast_vote(uuid,uuid)','EXECUTE'),'vote RPC is available to authenticated members');
select ok(not has_table_privilege('authenticated','public.blackout_votes','INSERT'),'ballots cannot be written directly by clients');
select ok(exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='blackout_accusations'),'public accusations are in Realtime publication');

-- A Scout investigation is the server-owned discussion trigger. It preserves
-- facility values and freezes active time while making only a neutral public cue.
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=2),true);
select lives_ok($$select public.blackout_investigate((select game_id from phase3c_members where game_tag='tie6' limit 1),'MAINTENANCE')$$,'Scout investigation succeeds and creates evidence');
select is((select state from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),'DISCUSSION','meaningful investigation opens discussion');
select is((select active_deadline_at from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),null::timestamptz,'active gameplay deadline pauses during discussion');
select ok((select active_remaining_ms between 295000 and 300000 from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),'remaining operation time is retained server-side');
select is((select count(*)::integer from public.blackout_discussions where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),1,'discussion stores one server-timed phase record');
select ok((select deadline_at-started_at=interval '45 seconds' from public.blackout_discussions where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),'discussion has a 45 second server deadline');
select is((select state from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),'DISCUSSION','all members observe the same discussion state');
select is((select power::integer from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),64,'discussion preserves Power');
select is((select security::integer from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),38,'discussion preserves Security');
select is((select facility_integrity::integer from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),77,'discussion preserves Integrity');
select is((select count(*)::integer from public.blackout_events where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1) and visibility='PUBLIC' and event_type='DISCUSSION_CALLED'),1,'public evidence cue is written for discussion');
select ok((select message not ilike '%private%' from public.blackout_events where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1) and event_type='DISCUSSION_CALLED'),'public trigger does not copy private intel');
select throws_ok($$select public.blackout_repair_power((select game_id from phase3c_members where game_tag='tie6' limit 1),'POWER')$$,'P0001','GAME_NOT_ACTIVE','facility actions are rejected during discussion');
select is((public.get_my_game()->'discussion'->>'sector'),'MAINTENANCE','reconnect snapshot restores discussion sector');
select ok((public.get_my_game()->'discussion'->>'deadline_at') is not null,'reconnect snapshot restores discussion timer');
select is(jsonb_array_length(public.get_my_game()->'my_intel'),1,'Scout reconnect restores only the caller private evidence');

-- Accusations reject self, invalid target, inaccessible private evidence, and nonmembers.
select lives_ok($$select public.blackout_accuse((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=0),(select id from public.blackout_events where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1) and visibility='PRIVATE' limit 1))$$,'Scout can attach their own private evidence to a public accusation');
select throws_ok($$select public.blackout_accuse((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=2))$$,'P0001','SELF_ACCUSATION_NOT_ALLOWED','self accusation is rejected');
select throws_ok($$select public.blackout_accuse((select game_id from phase3c_members where game_tag='tie6' limit 1),'ffffffff-ffff-4fff-8fff-ffffffffffff')$$,'P0001','INVALID_TARGET','accusation rejects an invalid target');
select is((public.get_my_game()->'discussion'->'accusations'->0->>'accused_player_id'),(select player_id::text from phase3c_members where game_tag='tie6' and seat=0),'valid accusation appears in shared discussion state');
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000430',true);
select throws_ok($$select public.blackout_accuse((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=0))$$,'P0001','GAME_MEMBERSHIP_REQUIRED','nonmember cannot accuse in another game');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=0),true);
set local role authenticated;
select is((select count(*)::integer from public.blackout_events where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1) and visibility='PRIVATE'),0,'another member cannot query Scout private evidence');
select is((public.get_my_game()->'my_intel' is not null and jsonb_array_length(public.get_my_game()->'my_intel')=0),true,'another member recovery contains no Scout private evidence');
reset role;

-- Discussion timeout opens a 20 second ballot phase without unpausing the main clock.
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3c_members where game_tag='tie6' limit 1);
select is((public.get_my_game()->'game'->>'state'),'VOTING','discussion timer advances to voting on server snapshot');
select ok((select state_deadline_at between clock_timestamp()+interval '19 seconds' and clock_timestamp()+interval '20 seconds' from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),'voting receives a 20 second server deadline');
select is((select active_deadline_at from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),null::timestamptz,'active clock stays paused through voting');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=0),true);
select throws_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=0))$$,'P0001','SELF_VOTE_NOT_ALLOWED','self vote is rejected');
select throws_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),'ffffffff-ffff-4fff-8fff-ffffffffffff')$$,'P0001','INVALID_TARGET','vote rejects a target outside the roster');
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=1))$$,'valid member vote is accepted');
select is((public.get_my_game()->'discussion'->'my_vote'->>'target_player_id'),(select player_id::text from phase3c_members where game_tag='tie6' and seat=1),'reconnect during voting restores the caller own sealed ballot');
select throws_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=1))$$,'P0001','ALREADY_VOTED','duplicate ballot is rejected');
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000430',true);
select throws_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=1))$$,'P0001','GAME_MEMBERSHIP_REQUIRED','nonmember cannot vote');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=0),true);
set local role authenticated;
select is((select count(*)::integer from public.blackout_votes where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),1,'ballot RLS exposes only the caller own vote');
reset role;
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=1),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=0))$$,'second member ballot is accepted');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=2),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=0))$$,'third member ballot is accepted');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=3),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=1))$$,'fourth member ballot is accepted');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=4),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=2))$$,'fifth member ballot is accepted');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='tie6' and seat=5),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='tie6' limit 1),(select player_id from phase3c_members where game_tag='tie6' and seat=2))$$,'sixth vote resolves the ballot early');
select is((public.get_my_game()->'game'->>'state'),'VOTE_RESULT','all active votes move directly to vote result');
select is((public.get_my_game()->'discussion'->'result'->>'tied'),'true','equal top totals produce an explicit tie');
select is((public.get_my_game()->'discussion'->'result'->>'winner_player_id'),null,'tie does not randomly select a player');
select is(jsonb_array_length(public.get_my_game()->'discussion'->'result'->'votes'),6,'six-player tally includes every active operator');
select ok((select count(*)=6 from public.blackout_events where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1) and event_type='VOTE_SEALED'),'vote submissions produce public sealed-ballot progress events');
select is((select count(*)::integer from public.blackout_players where game_id=(select game_id from phase3c_members where game_tag='tie6' limit 1) and is_active),6,'vote result removes no player');

-- The server resumes the exact paused operation budget after the result display.
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3c_members where game_tag='tie6' limit 1);
select is((public.get_my_game()->'game'->>'state'),'ACTIVE','result display returns to ACTIVE');
select ok((select active_deadline_at>clock_timestamp() and active_remaining_ms between 295000 and 300000 from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),'operation clock resumes with preserved remaining time');
select is((select power::integer from public.blackout_games where id=(select game_id from phase3c_members where game_tag='tie6' limit 1)),64,'facility Power remains intact after vote');

-- A separate three-player game resolves a clear highest vote count without
-- elimination; another proves timer expiry resolves an empty ballot as a tie.
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='clear3' and seat=2),true);
select lives_ok($$select public.blackout_investigate((select game_id from phase3c_members where game_tag='clear3' limit 1),'OPERATIONS')$$,'three-player Scout can begin discussion');
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3c_members where game_tag='clear3' limit 1);
select is((public.get_my_game()->'game'->>'state'),'VOTING','three-player discussion advances to vote');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='clear3' and seat=0),true);
update public.blackout_players set last_seen_at=clock_timestamp()-interval '60 seconds'
where id=(select player_id from phase3c_members where game_tag='clear3' and seat=0);
select throws_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='clear3' limit 1),(select player_id from phase3c_members where game_tag='clear3' and seat=1))$$,'P0001','PLAYER_DISCONNECTED','stale player cannot submit a vote');
select lives_ok($$select public.get_my_game()$$,'get_my_game restores voting access after reconnect');
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='clear3' limit 1),(select player_id from phase3c_members where game_tag='clear3' and seat=1))$$,'first vote in clear-result game is accepted');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='clear3' and seat=1),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='clear3' limit 1),(select player_id from phase3c_members where game_tag='clear3' and seat=0))$$,'second vote in clear-result game is accepted');
select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='clear3' and seat=2),true);
select lives_ok($$select public.blackout_cast_vote((select game_id from phase3c_members where game_tag='clear3' limit 1),(select player_id from phase3c_members where game_tag='clear3' and seat=0))$$,'third vote resolves the three-player ballot');
select is((public.get_my_game()->'discussion'->'result'->>'tied'),'false','unique highest vote is not a tie');
select is((public.get_my_game()->'discussion'->'result'->>'winner_player_id'),(select player_id::text from phase3c_members where game_tag='clear3' and seat=0),'server selects the highest vote recipient');
select is((select is_active from public.blackout_players where id=(select player_id from phase3c_members where game_tag='clear3' and seat=0)),true,'highest vote does not eliminate the player');

select set_config('request.jwt.claim.sub',(select user_id::text from phase3c_members where game_tag='timer3' and seat=2),true);
select lives_ok($$select public.blackout_investigate((select game_id from phase3c_members where game_tag='timer3' limit 1),'POWER')$$,'timer test investigation opens discussion');
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3c_members where game_tag='timer3' limit 1);
select is((public.get_my_game()->'game'->>'state'),'VOTING','discussion deadline is server-enforced');
update public.blackout_games set state_deadline_at=clock_timestamp()-interval '1 second' where id=(select game_id from phase3c_members where game_tag='timer3' limit 1);
select is((public.get_my_game()->'game'->>'state'),'VOTE_RESULT','voting timer expires into server result');
select is((public.get_my_game()->'discussion'->'result'->>'tied'),'true','no votes resolve as no consensus');
select is((public.get_my_game()->'discussion'->'result'->>'winner_player_id'),null,'expired empty vote never randomly selects a target');

select * from finish();
rollback;
