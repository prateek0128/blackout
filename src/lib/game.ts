import type { RealtimeChannel } from '@supabase/supabase-js'
import { ensureAnonymousSession, getSupabaseClient, SupabaseConfigurationError } from './supabase'

export type GameState = 'STARTING' | 'ROLE_REVEAL' | 'FACILITY_INTRO' | 'ACTIVE' | 'DISCUSSION' | 'VOTING' | 'VOTE_RESULT' | 'FINAL_BLACKOUT' | 'ESCAPE' | 'RESULTS'
export type SecretRole = 'SABOTEUR' | 'HACKER' | 'SCOUT' | 'ENGINEER'
export type FacilitySector = 'SECURITY' | 'POWER' | 'MEDICAL' | 'OPERATIONS' | 'MAINTENANCE'
export type GameActionType = 'SCAN_SECURITY' | 'REPAIR_POWER' | 'INVESTIGATE' | 'DISRUPT_POWER' | 'INCREASE_SECURITY' | 'TAMPER_RELAY'

export type GameEvent = {
  id: string
  event_type: string
  sector: FacilitySector | null
  message: string
  created_at: string
  payload: Record<string, unknown>
}

export type VoteResult = {
  tied: boolean
  winner_player_id: string | null
  highest_vote_count: number
  votes: Array<{ player_id: string; display_name: string; votes: number }>
}

export type DiscussionSnapshot = {
  id: string
  sector: FacilitySector
  started_at: string
  deadline_at: string
  triggering_event_id: string
  evidence_event_id: string
  accusations: Array<{
    id: string
    accuser_player_id: string
    accused_player_id: string
    evidence_event_id: string | null
    created_at: string
  }>
  votes_cast: number
  eligible_voters: number
  my_vote: { target_player_id: string; created_at: string } | null
  result: VoteResult | null
}

export type EscapeActionType = 'LOCATE_ESCAPE_ROUTE' | 'UNLOCK_EMERGENCY_ROUTE' | 'POWER_ESCAPE_DOOR' | 'OPEN_ESCAPE_DOOR' | 'JAM_ESCAPE'

export type EscapeSnapshot = {
  route_located: boolean
  route_unlocked: boolean
  door_powered: boolean
  door_opened: boolean
  jam_count: number
  progress: number
  step_count: number
  my_available_actions: EscapeActionType[]
  my_cooldowns: Array<{ action: EscapeActionType; next_available_at: string }>
}

export type BlackoutResult = {
  outcome: 'CREW_ESCAPED' | 'SABOTEUR_PREVAILED' | 'FACILITY_FAILURE'
  summary: string
  final_facility: { power: number; security: number; facility_integrity: number }
  final_escape_state: { route_located: boolean; route_unlocked: boolean; door_powered: boolean; door_opened: boolean; jam_count: number }
  role_reveal: Array<{ player_id: string; display_name: string; role: SecretRole; outcome: 'VICTORY' | 'DEFEAT' | 'FACILITY FAILURE' }>
  resolved_at: string
}

export type BlackoutGameSnapshot = {
  game: {
    id: string
    room_id: string
    state: GameState
    power: number
    security: number
    facility_integrity: number
    created_at: string
    state_started_at: string
    state_deadline_at: string | null
    active_started_at: string | null
    active_deadline_at: string | null
    active_remaining_ms: number | null
    final_started_at: string | null
    final_deadline_at: string | null
  }
  players: Array<{
    id: string
    display_name: string
    connection_state: 'connected' | 'disconnected'
    is_alive: boolean
    is_active: boolean
    is_current_player: boolean
  }>
  my_player: {
    id: string
    display_name: string
    secret_role: SecretRole
    objective: string
    personal_information: Record<string, unknown>
  }
  public_events: GameEvent[]
  my_intel: GameEvent[]
  my_cooldowns: Array<{ action: GameActionType; next_available_at: string | null }>
  discussion: DiscussionSnapshot | null
  escape: EscapeSnapshot | null
  results: BlackoutResult | null
  can_restart: boolean
  server_now: string
}

export class GameActionError extends Error {
  readonly code: string
  constructor(code: string, message: string) {
    super(message)
    this.name = 'GameActionError'
    this.code = code
  }
}

function gameError(error: { message?: string; code?: string } | null): GameActionError {
  if (!error) return new GameActionError('UNKNOWN', 'The game service could not be reached.')
  const codes = ['AUTH_REQUIRED', 'GAME_MEMBERSHIP_REQUIRED', 'GAME_NOT_FOUND', 'GAME_NOT_ACTIVE', 'GAME_TIMER_EXPIRED', 'PLAYER_DISCONNECTED', 'PLAYER_INACTIVE', 'ROLE_REQUIRED', 'ROLE_ASSIGNMENT_REQUIRED', 'INVALID_ACTION', 'INVALID_SECTOR', 'SECTOR_REQUIRED', 'SECTOR_NOT_VALID_FOR_ACTION', 'ACTION_COOLDOWN', 'DISCUSSION_NOT_ACTIVE', 'VOTING_NOT_ACTIVE', 'SELF_ACCUSATION_NOT_ALLOWED', 'SELF_VOTE_NOT_ALLOWED', 'INVALID_TARGET', 'EVIDENCE_NOT_ACCESSIBLE', 'ALREADY_VOTED', 'INVALID_ESCAPE_ACTION', 'ESCAPE_NOT_ACTIVE', 'ESCAPE_DEADLINE_EXPIRED', 'ESCAPE_STEP_NOT_AVAILABLE', 'ESCAPE_ACTION_COOLDOWN', 'ESCAPE_STATE_MISSING', 'GAME_NOT_COMPLETE', 'HOST_REQUIRED']
  const code = codes.find(candidate => error.message?.includes(candidate))
  if (code === 'AUTH_REQUIRED') return new GameActionError(code, 'Your player session expired. Refresh and try again.')
  if (code === 'GAME_MEMBERSHIP_REQUIRED' || code === 'GAME_NOT_FOUND') return new GameActionError(code, 'No active game is linked to this player session.')
  if (code === 'GAME_NOT_ACTIVE') return new GameActionError(code, 'Actions are available during the active phase only.')
  if (code === 'GAME_TIMER_EXPIRED') return new GameActionError(code, 'The five-minute operation window has expired.')
  if (code === 'PLAYER_DISCONNECTED') return new GameActionError(code, 'Your game link went idle. Reconnect to restore your latest server state, then try again.')
  if (code === 'PLAYER_INACTIVE') return new GameActionError(code, 'This operator cannot perform actions right now.')
  if (code === 'ROLE_REQUIRED') return new GameActionError(code, 'That action is not available to your assigned role.')
  if (code === 'ACTION_COOLDOWN') return new GameActionError(code, 'That action is cooling down. Try again when its timer clears.')
  if (code === 'DISCUSSION_NOT_ACTIVE') return new GameActionError(code, 'Accusations are available during discussion only.')
  if (code === 'VOTING_NOT_ACTIVE') return new GameActionError(code, 'Voting is not open right now.')
  if (code === 'SELF_ACCUSATION_NOT_ALLOWED' || code === 'SELF_VOTE_NOT_ALLOWED') return new GameActionError(code, 'You cannot select yourself.')
  if (code === 'INVALID_TARGET') return new GameActionError(code, 'Choose an active operator in this game.')
  if (code === 'EVIDENCE_NOT_ACCESSIBLE') return new GameActionError(code, 'That evidence is not available to your player session.')
  if (code === 'ALREADY_VOTED') return new GameActionError(code, 'Your ballot has already been sealed.')
  if (code === 'INVALID_ESCAPE_ACTION') return new GameActionError(code, 'That escape action is unavailable.')
  if (code === 'ESCAPE_NOT_ACTIVE') return new GameActionError(code, 'The escape sequence is not active.')
  if (code === 'ESCAPE_DEADLINE_EXPIRED') return new GameActionError(code, 'The escape window has closed.')
  if (code === 'ESCAPE_STEP_NOT_AVAILABLE') return new GameActionError(code, 'Complete the prior escape step before continuing.')
  if (code === 'ESCAPE_ACTION_COOLDOWN') return new GameActionError(code, 'Emergency controls are resetting. Try again in a moment.')
  if (code === 'GAME_NOT_COMPLETE') return new GameActionError(code, 'Play Again is available after the result is recorded.')
  if (code === 'HOST_REQUIRED') return new GameActionError(code, 'Only the room host can restart this operation.')
  if (code === 'INVALID_SECTOR' || code === 'SECTOR_REQUIRED' || code === 'SECTOR_NOT_VALID_FOR_ACTION') return new GameActionError(code, 'Select a valid facility sector for this action.')
  return new GameActionError(error.code || 'NETWORK', 'Could not reach the game service. Check your connection and try again.')
}

function isGameSnapshot(value: unknown): value is BlackoutGameSnapshot {
  return !!value && typeof value === 'object' && 'game' in value && 'players' in value && 'my_player' in value && 'server_now' in value
}

export async function getMyGame(): Promise<BlackoutGameSnapshot> {
  try {
    await ensureAnonymousSession()
    const { data, error } = await getSupabaseClient().rpc('get_my_game')
    if (error) throw gameError(error)
    if (!isGameSnapshot(data)) throw new GameActionError('INVALID_RESPONSE', 'The game service returned an invalid game session.')
    return data
  } catch (error) {
    if (error instanceof GameActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw gameError(error)
    if (error instanceof Error && error.message.startsWith('Could not ')) throw new GameActionError('AUTH', error.message)
    throw gameError(error instanceof Error ? error : null)
  }
}

export async function performGameAction(gameId: string, action: GameActionType, sector?: FacilitySector): Promise<void> {
  const rpcByAction: Record<GameActionType, string> = {
    SCAN_SECURITY: 'blackout_scan_security',
    REPAIR_POWER: 'blackout_repair_power',
    INVESTIGATE: 'blackout_investigate',
    DISRUPT_POWER: 'blackout_disrupt_power',
    INCREASE_SECURITY: 'blackout_increase_security',
    TAMPER_RELAY: 'blackout_tamper_relay',
  }
  try {
    await ensureAnonymousSession()
    const args: Record<string, unknown> = { p_game_id: gameId }
    if (action === 'REPAIR_POWER' || action === 'INVESTIGATE' || action === 'TAMPER_RELAY') args.p_sector = sector
    const { error } = await getSupabaseClient().rpc(rpcByAction[action], args)
    if (error) throw gameError(error)
  } catch (error) {
    if (error instanceof GameActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw gameError(error)
    if (error instanceof Error && error.message.startsWith('Could not ')) throw new GameActionError('AUTH', error.message)
    throw gameError(error instanceof Error ? error : null)
  }
}

async function submitGameChoice(rpcName: 'blackout_accuse' | 'blackout_cast_vote', args: Record<string, unknown>) {
  try {
    await ensureAnonymousSession()
    const { error } = await getSupabaseClient().rpc(rpcName, args)
    if (error) throw gameError(error)
  } catch (error) {
    if (error instanceof GameActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw gameError(error)
    throw gameError(error instanceof Error ? error : null)
  }
}

export function accusePlayer(gameId: string, targetPlayerId: string, evidenceEventId?: string) {
  return submitGameChoice('blackout_accuse', {
    p_game_id: gameId,
    p_target_player_id: targetPlayerId,
    p_evidence_event_id: evidenceEventId || null,
  })
}

export function castGameVote(gameId: string, targetPlayerId: string) {
  return submitGameChoice('blackout_cast_vote', { p_game_id: gameId, p_target_player_id: targetPlayerId })
}

export async function performEscapeAction(gameId: string, action: EscapeActionType) {
  try {
    await ensureAnonymousSession()
    const { data, error } = await getSupabaseClient().rpc('blackout_escape_action', { p_game_id: gameId, p_action_type: action })
    if (error) throw gameError(error)
    if (!data?.ok) throw gameError({ message: String(data?.error ?? 'ESCAPE_NOT_ACTIVE') })
  } catch (error) {
    if (error instanceof GameActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw gameError(error)
    throw gameError(error instanceof Error ? error : null)
  }
}

export async function restartBlackoutGame(gameId: string) {
  try {
    await ensureAnonymousSession()
    const { error } = await getSupabaseClient().rpc('blackout_restart_game', { p_game_id: gameId })
    if (error) throw gameError(error)
  } catch (error) {
    if (error instanceof GameActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw gameError(error)
    throw gameError(error instanceof Error ? error : null)
  }
}

export async function subscribeToGame(
  snapshot: BlackoutGameSnapshot,
  onChange: () => void,
  onPresence: (playerIds: string[]) => void,
  onConnection: (connected: boolean) => void,
): Promise<() => void> {
  const supabase = getSupabaseClient()
  await supabase.realtime.setAuth()
  const channel: RealtimeChannel = supabase.channel(`blackout:game:${snapshot.game.id}`, {
    config: { private: true, presence: { key: snapshot.my_player.id } },
  })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'blackout_games', filter: `id=eq.${snapshot.game.id}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'blackout_players', filter: `game_id=eq.${snapshot.game.id}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'blackout_events', filter: `game_id=eq.${snapshot.game.id}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'blackout_accusations', filter: `game_id=eq.${snapshot.game.id}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'blackout_escape_state', filter: `game_id=eq.${snapshot.game.id}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'blackout_results', filter: `game_id=eq.${snapshot.game.id}` }, onChange)
    .on('presence', { event: 'sync' }, () => onPresence(Object.keys(channel.presenceState())))
    .subscribe(async status => {
      const connected = status === 'SUBSCRIBED'
      onConnection(connected)
      if (connected) {
        const result = await channel.track({ player_id: snapshot.my_player.id, joined_at: new Date().toISOString() })
        if (result !== 'ok') onConnection(false)
      }
    })
  return () => { void supabase.removeChannel(channel) }
}
