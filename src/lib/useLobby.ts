import { useCallback, useEffect, useRef, useState } from 'react'
import { getMyLobby, heartbeatRoom, leaveRoom, RoomActionError, setReady, startRoom, subscribeToLobby, type LobbySnapshot } from './rooms'
import { getMyGame } from './game'

export type LobbyConnection = 'connecting' | 'connected' | 'disconnected'

export function useLobby(onGameStarted?: (gameId: string) => void) {
  const [snapshot, setSnapshot] = useState<LobbySnapshot | null>(null)
  const [connection, setConnection] = useState<LobbyConnection>('connecting')
  const [livePlayerIds, setLivePlayerIds] = useState<string[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const snapshotRef = useRef<LobbySnapshot | null>(null)
  const onGameStartedRef = useRef(onGameStarted)
  onGameStartedRef.current = onGameStarted

  const applySnapshot = useCallback((next: LobbySnapshot) => {
    const current = snapshotRef.current
    if (current && current.room.id === next.room.id) {
      const previousById = new Map(current.players.map(player => [player.id, player]))
      const joined = next.players.find(player => !previousById.has(player.id))
      const left = current.players.find(player => !next.players.some(candidate => candidate.id === player.id))
      const newHost = next.players.find(player => player.is_host)
      const oldHost = current.players.find(player => player.is_host)
      if (joined) setNotice(`${joined.display_name} joined the crew.`)
      else if (left) setNotice(`${left.display_name} left the crew.`)
      else if (newHost && oldHost && newHost.id !== oldHost.id) setNotice(`${newHost.display_name} is now the host.`)
      else {
        const readyChanged = next.players.find(player => previousById.has(player.id) && previousById.get(player.id)?.ready !== player.ready)
        if (readyChanged) setNotice(`${readyChanged.display_name} ${readyChanged.ready ? 'is ready' : 'is not ready'}.`)
      }
    }
    snapshotRef.current = next
    setSnapshot(next)
  }, [])

  const refresh = useCallback(async () => {
    const next = await getMyLobby()
    if (next) applySnapshot(next)
    else {
      snapshotRef.current = null
      setSnapshot(null)
      try {
        const game = await getMyGame()
        onGameStartedRef.current?.(game.game.id)
      } catch { /* No active game is linked to this player session. */ }
    }
    setError('')
    return next
  }, [applySnapshot])

  useEffect(() => {
    let alive = true
    let removeChannel: (() => void) | undefined
    let heartbeatTimer: number | undefined
    let lastRoomId = ''
    let refreshQueue = Promise.resolve()

    const handleChange = () => {
      refreshQueue = refreshQueue.then(async () => {
        if (!alive) return
        const next = await refresh()
        if (alive && next && next.room.id !== lastRoomId) {
          lastRoomId = next.room.id
        }
      }).catch(() => { if (alive) setConnection('disconnected') })
    }

    async function connect() {
      try {
        const initial = await getMyLobby()
        if (!alive) return
        if (!initial) {
          try {
            const game = await getMyGame()
            if (alive) onGameStartedRef.current?.(game.game.id)
          } catch {
            if (alive) {
              setError('No active room is linked to this browser session. Create a room or join with a code.')
              setConnection('disconnected')
            }
          }
          return
        }
        lastRoomId = initial.room.id
        snapshotRef.current = initial
        setSnapshot(initial)
        setError('')
        setLoading(false)
        const unsubscribe = await subscribeToLobby(initial, handleChange, setLivePlayerIds, connected => setConnection(connected ? 'connected' : 'disconnected'))
        if (alive) removeChannel = unsubscribe
        else unsubscribe()
        heartbeatTimer = window.setInterval(async () => {
          if (document.visibilityState === 'hidden') return
          try {
            const latest = await heartbeatRoom(initial.room.id)
            if (alive) {
              applySnapshot(latest)
              setConnection('connected')
              setError('')
            }
          } catch (heartbeatError) {
            if (alive) {
              setConnection('disconnected')
              if (heartbeatError instanceof RoomActionError) setError(heartbeatError.message)
            }
          }
        }, 12_000)
      } catch (loadError) {
        if (!alive) return
        setError(loadError instanceof Error ? loadError.message : 'Could not connect to the lobby.')
        setConnection('disconnected')
      } finally {
        if (alive) setLoading(false)
      }
    }
    void connect()
    const onVisible = () => { if (document.visibilityState === 'visible') handleChange() }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive = false
      if (heartbeatTimer !== undefined) window.clearInterval(heartbeatTimer)
      document.removeEventListener('visibilitychange', onVisible)
      removeChannel?.()
    }
  }, [applySnapshot, refresh])

  const perform = useCallback(async (action: () => Promise<LobbySnapshot | void>, success?: string) => {
    setBusy(true); setError(''); setNotice('')
    try {
      const result = await action()
      if (result && 'room' in result) applySnapshot(result)
      if (success) setNotice(success)
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'The room action could not be completed.')
    } finally { setBusy(false) }
  }, [applySnapshot])

  const toggleReady = useCallback(() => {
    if (!snapshot) return
    const current = snapshot.players.find(player => player.id === snapshot.current_player_id)
    return perform(() => setReady(snapshot.room.id, !current?.ready))
  }, [perform, snapshot])

  const start = useCallback(async (): Promise<string | null> => {
    if (!snapshot) return null
    setBusy(true); setError(''); setNotice('')
    try {
      return await startRoom(snapshot.room.id)
    } catch (actionError) {
      setError(actionError instanceof Error ? actionError.message : 'The operation could not be started.')
      return null
    } finally { setBusy(false) }
  }, [snapshot])
  const leave = useCallback(async (): Promise<boolean> => {
    if (!snapshot) return false
    setBusy(true); setError(''); setNotice('')
    try {
      await leaveRoom(snapshot.room.id)
      snapshotRef.current = null
      setSnapshot(null)
      setNotice('You left the room.')
      return true
    } catch (leaveError) {
      setError(leaveError instanceof Error ? leaveError.message : 'Could not leave the room.')
      return false
    } finally { setBusy(false) }
  }, [snapshot])

  return { snapshot, connection, livePlayerIds, error, loading, busy, notice, setNotice, refresh, toggleReady, start, leave }
}
