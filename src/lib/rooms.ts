import type { RealtimeChannel } from '@supabase/supabase-js'
import { ensureAnonymousSession, getSupabaseClient, SupabaseConfigurationError, SupabaseRequestError } from './supabase'

export type RoomStatus = 'LOBBY' | 'STARTING' | 'IN_GAME' | 'COMPLETED' | 'EXPIRED'
export type PlayerConnection = 'connected' | 'disconnected' | 'left'

export type LobbyPlayer = {
  id: string
  display_name: string
  joined_at: string
  last_seen_at: string
  ready: boolean
  connection_state: PlayerConnection
  is_host: boolean
  is_current_player: boolean
}

export type LobbySnapshot = {
  room: {
    id: string
    room_code: string
    host_player_id: string | null
    status: RoomStatus
    max_players: number
    created_at: string
    updated_at: string
    expires_at: string
  }
  players: LobbyPlayer[]
  current_player_id: string
}

export class RoomActionError extends Error {
  readonly code: string
  constructor(code: string, message: string) {
    super(message)
    this.name = 'RoomActionError'
    this.code = code
  }
}

const messages: Record<string, string> = {
  AUTH_REQUIRED: 'Your player session expired. Refresh the page and try again.',
  INVALID_DISPLAY_NAME: 'Display names must be 2 to 18 characters.',
  INVALID_ROOM_CODE: 'Enter a valid 5-character room code.',
  ROOM_NOT_FOUND: 'No room was found with that code. Check the code and try again.',
  ROOM_EXPIRED: 'This room has expired. Ask the host to create a new room.',
  ROOM_FULL: 'This room already has 6 players.',
  ROOM_NOT_JOINABLE: 'This room has already started and is no longer accepting players.',
  ROOM_NOT_LOBBY: 'This lobby is no longer open for changes.',
  ROOM_MEMBERSHIP_REQUIRED: 'Your player session is no longer in this room. Rejoin with the room code.',
  ALREADY_IN_ROOM: 'This browser session is already in another room. Leave it before joining a new room.',
  ROOM_CODE_GENERATION_FAILED: 'A room code could not be reserved. Please try again.',
  NOT_ENOUGH_PLAYERS: 'At least 3 connected players are needed to start.',
  PLAYERS_NOT_READY: 'Every connected player must be ready before the host can start.',
  HOST_REQUIRED: 'Only the current host can start this room.',
}

function safeDiagnostic(value: string): string {
  return value
    .replace(/https?:\/\/[^\s"'<>]+/gi, '[endpoint]')
    .replace(/\b(?:sb_publishable|sb_secret|sbp)_[A-Za-z0-9_-]+/g, '[credential]')
    .replace(/\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, '[credential]')
    .replace(/[\r\n\t]+/g, ' ')
    .slice(0, 300)
}

function translateError(error: { message?: string; code?: string; status?: number } | null, operation = 'Room request'): RoomActionError {
  if (!error) return new RoomActionError('UNKNOWN', 'Something went wrong. Please try again.')
  const diagnostic = error as { message?: string; code?: string; status?: number }
  const match = Object.keys(messages).find(code => diagnostic.message?.includes(code))
  if (match) return new RoomActionError(match, messages[match])
  if (error instanceof Error && error.message.includes('Supabase is not configured')) {
    return new RoomActionError('SUPABASE_NOT_CONFIGURED', error.message)
  }
  if (error instanceof SupabaseRequestError) operation = `${error.stage} request`
  const status = diagnostic.status ? ` (HTTP ${diagnostic.status})` : ''
  const code = diagnostic.code ? ` [${safeDiagnostic(diagnostic.code)}]` : ''
  const detail = safeDiagnostic(diagnostic.message || 'No error message was returned.')
  return new RoomActionError('SUPABASE_REQUEST_FAILED', `${operation}${status}${code}: ${detail}`)
}

function ensureSnapshot(value: unknown): LobbySnapshot {
  if (!value || typeof value !== 'object' || !('room' in value) || !('players' in value)) {
    throw new RoomActionError('INVALID_RESPONSE', 'The room service returned an invalid response. Please refresh.')
  }
  return value as LobbySnapshot
}

async function rpcSnapshot(name: string, args: Record<string, unknown> = {}): Promise<LobbySnapshot> {
  try {
    await ensureAnonymousSession()
    const { data, error } = await getSupabaseClient().rpc(name, args)
    if (error) throw translateError(error, `${name} RPC`)
    return ensureSnapshot(data)
  } catch (error) {
    if (error instanceof RoomActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw translateError(error)
    throw translateError(error instanceof Error ? error : null)
  }
}

export async function createRoom(displayName: string) {
  return rpcSnapshot('create_room', { p_display_name: displayName.trim() })
}

export async function joinRoom(roomCode: string, displayName: string) {
  return rpcSnapshot('join_room', { p_room_code: roomCode.trim().toUpperCase(), p_display_name: displayName.trim() })
}

export async function getMyLobby(): Promise<LobbySnapshot | null> {
  try {
    await ensureAnonymousSession()
    const { data, error } = await getSupabaseClient().rpc('get_my_lobby')
    if (error) throw translateError(error)
    return data ? ensureSnapshot(data) : null
  } catch (error) {
    if (error instanceof RoomActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw translateError(error)
    throw translateError(error instanceof Error ? error : null)
  }
}

export async function heartbeatRoom(roomId: string) {
  return rpcSnapshot('heartbeat_room', { p_room_id: roomId })
}

export async function setReady(roomId: string, ready: boolean) {
  return rpcSnapshot('set_player_ready', { p_room_id: roomId, p_ready: ready })
}

export async function startRoom(roomId: string): Promise<string> {
  try {
    await ensureAnonymousSession()
    const { data, error } = await getSupabaseClient().rpc('start_room', { p_room_id: roomId })
    if (error) throw translateError(error, 'start_room RPC')
    if (!data || typeof data !== 'object' || !('game' in data) || typeof data.game !== 'object' || !data.game || !('id' in data.game) || typeof data.game.id !== 'string') {
      throw new RoomActionError('INVALID_RESPONSE', 'The game service returned an invalid session. Please refresh.')
    }
    return data.game.id
  } catch (error) {
    if (error instanceof RoomActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw translateError(error)
    throw translateError(error instanceof Error ? error : null)
  }
}

export async function leaveRoom(roomId: string) {
  try {
    await ensureAnonymousSession()
    const { error } = await getSupabaseClient().rpc('leave_room', { p_room_id: roomId })
    if (error) throw translateError(error)
  } catch (error) {
    if (error instanceof RoomActionError) throw error
    if (error instanceof SupabaseConfigurationError) throw translateError(error)
    throw translateError(error instanceof Error ? error : null)
  }
}

export async function subscribeToLobby(
  snapshot: LobbySnapshot,
  onChange: () => void,
  onPresence: (playerIds: string[]) => void,
  onConnection: (connected: boolean) => void,
): Promise<() => void> {
  const supabase = getSupabaseClient()
  await supabase.realtime.setAuth()
  const channel: RealtimeChannel = supabase.channel(`blackout:lobby:${snapshot.room.id}`, {
    config: { private: true, presence: { key: snapshot.current_player_id } },
  })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${snapshot.room.id}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players', filter: `room_id=eq.${snapshot.room.id}` }, onChange)
    .on('presence', { event: 'sync' }, () => {
      const ids = Object.keys(channel.presenceState())
      onPresence(ids)
    })
    .subscribe(async status => {
      const isConnected = status === 'SUBSCRIBED'
      onConnection(isConnected)
      if (isConnected) {
        const presenceStatus = await channel.track({ player_id: snapshot.current_player_id, joined_at: new Date().toISOString() })
        if (presenceStatus !== 'ok') onConnection(false)
      }
    })

  return () => { void supabase.removeChannel(channel) }
}
