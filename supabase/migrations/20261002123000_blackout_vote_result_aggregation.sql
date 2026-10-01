-- Phase 3C follow-up: calculate vote totals in a separate aggregate layer.
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
      select coalesce(max(t.votes), 0) into v_max from (
        select bp.id, count(v.id)::integer as votes from public.blackout_players bp
        left join public.blackout_votes v on v.target_player_id = bp.id and v.discussion_id = v_discussion.id
        where bp.game_id = p_game_id and bp.is_active and bp.is_alive group by bp.id
      ) t;
      select count(*)::integer into v_winners from (
        select bp.id, count(v.id)::integer as votes from public.blackout_players bp left join public.blackout_votes v
          on v.target_player_id = bp.id and v.discussion_id = v_discussion.id
        where bp.game_id = p_game_id and bp.is_active and bp.is_alive group by bp.id
      ) t where t.votes = v_max;
      v_tied := v_winners <> 1 or v_max = 0;
      select jsonb_build_object(
        'tied', v_tied,
        'winner_player_id', case when v_tied then null else (select t.id from (
          select bp.id,count(v.id)::integer as votes from public.blackout_players bp left join public.blackout_votes v
            on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
          where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id
        ) t where t.votes=v_max limit 1) end,
        'highest_vote_count', v_max,
        'votes', coalesce((select jsonb_agg(jsonb_build_object('player_id', t.id, 'display_name', t.display_name, 'votes', t.votes) order by t.created_at,t.id)
          from (select bp.id,bp.display_name,bp.created_at,count(v.id)::integer as votes
            from public.blackout_players bp left join public.blackout_votes v on v.target_player_id=bp.id and v.discussion_id=v_discussion.id
            where bp.game_id=p_game_id and bp.is_active and bp.is_alive group by bp.id) t), '[]'::jsonb)
      ) into v_result;
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
