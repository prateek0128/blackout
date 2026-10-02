-- Reject stale anonymous sessions at every gameplay mutation boundary.
-- The client heartbeat and the existing public connection-state projection both
-- use a 45 second liveness window. get_my_game remains the recovery heartbeat.

create or replace function public.require_current_blackout_player_connected(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_last_seen_at timestamptz;
begin
  if auth.uid() is null then
    raise exception using message = 'AUTH_REQUIRED', errcode = 'P0001';
  end if;

  select bp.last_seen_at into v_last_seen_at
  from public.blackout_players bp
  join public.room_players rp on rp.id = bp.room_player_id
  where bp.game_id = p_game_id
    and rp.auth_user_id = auth.uid()
    and rp.left_at is null;

  if not found then
    raise exception using message = 'GAME_MEMBERSHIP_REQUIRED', errcode = 'P0001';
  end if;
  if v_last_seen_at is null or v_last_seen_at < clock_timestamp() - interval '45 seconds' then
    raise exception using message = 'PLAYER_DISCONNECTED', errcode = 'P0001';
  end if;
end;
$$;

revoke all on function public.require_current_blackout_player_connected(uuid) from public, anon;
grant execute on function public.require_current_blackout_player_connected(uuid) to authenticated;

-- Keep the existing server-authoritative action implementation intact; add a
-- liveness gate to each authenticated RPC wrapper before it can reach it.
create or replace function public.blackout_scan_security(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.apply_blackout_action(p_game_id, 'SCAN_SECURITY', null);
end;
$$;
create or replace function public.blackout_repair_power(p_game_id uuid, p_sector text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.apply_blackout_action(p_game_id, 'REPAIR_POWER', p_sector);
end;
$$;
create or replace function public.blackout_investigate(p_game_id uuid, p_sector text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.apply_blackout_action(p_game_id, 'INVESTIGATE', p_sector);
end;
$$;
create or replace function public.blackout_disrupt_power(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.apply_blackout_action(p_game_id, 'DISRUPT_POWER', null);
end;
$$;
create or replace function public.blackout_increase_security(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.apply_blackout_action(p_game_id, 'INCREASE_SECURITY', null);
end;
$$;
create or replace function public.blackout_tamper_relay(p_game_id uuid, p_sector text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.apply_blackout_action(p_game_id, 'TAMPER_RELAY', p_sector);
end;
$$;

-- Preserve the mature discussion/vote/escape implementations behind a new
-- caller check. The old entry points become owner-only implementation helpers.
alter function public.blackout_accuse(uuid, uuid, uuid) rename to blackout_accuse_unchecked;
revoke all on function public.blackout_accuse_unchecked(uuid, uuid, uuid) from public, anon, authenticated;
create function public.blackout_accuse(
  p_game_id uuid,
  p_target_player_id uuid,
  p_evidence_event_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.blackout_accuse_unchecked(p_game_id, p_target_player_id, p_evidence_event_id);
end;
$$;
revoke all on function public.blackout_accuse(uuid, uuid, uuid) from public, anon;
grant execute on function public.blackout_accuse(uuid, uuid, uuid) to authenticated;

alter function public.blackout_cast_vote(uuid, uuid) rename to blackout_cast_vote_unchecked;
revoke all on function public.blackout_cast_vote_unchecked(uuid, uuid) from public, anon, authenticated;
create function public.blackout_cast_vote(p_game_id uuid, p_target_player_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.blackout_cast_vote_unchecked(p_game_id, p_target_player_id);
end;
$$;
revoke all on function public.blackout_cast_vote(uuid, uuid) from public, anon;
grant execute on function public.blackout_cast_vote(uuid, uuid) to authenticated;

alter function public.blackout_escape_action(uuid, text) rename to blackout_escape_action_unchecked;
revoke all on function public.blackout_escape_action_unchecked(uuid, text) from public, anon, authenticated;
create function public.blackout_escape_action(p_game_id uuid, p_action_type text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.blackout_escape_action_unchecked(p_game_id, p_action_type);
end;
$$;
revoke all on function public.blackout_escape_action(uuid, text) from public, anon;
grant execute on function public.blackout_escape_action(uuid, text) to authenticated;

alter function public.blackout_restart_game(uuid) rename to blackout_restart_game_unchecked;
revoke all on function public.blackout_restart_game_unchecked(uuid) from public, anon, authenticated;
create function public.blackout_restart_game(p_game_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_current_blackout_player_connected(p_game_id);
  return public.blackout_restart_game_unchecked(p_game_id);
end;
$$;
revoke all on function public.blackout_restart_game(uuid) from public, anon;
grant execute on function public.blackout_restart_game(uuid) to authenticated;
