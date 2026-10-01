-- Keep transition and snapshot helpers callable only from server-owned functions.
revoke all on function public.advance_blackout_game(uuid) from public, anon, authenticated;
revoke all on function public.blackout_game_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.blackout_game_snapshot_phase3b(uuid) from public, anon, authenticated;
