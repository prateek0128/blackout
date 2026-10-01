import { useCallback, useEffect, useRef, useState } from 'react'
import { getMyGame, subscribeToGame, type BlackoutGameSnapshot, type GameState } from './game'

export type GameConnection = 'connecting' | 'connected' | 'disconnected'

export function useBlackoutGame() {
  const [snapshot, setSnapshot] = useState<BlackoutGameSnapshot | null>(null)
  const [connection, setConnection] = useState<GameConnection>('connecting')
  const [livePlayerIds, setLivePlayerIds] = useState<string[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [, setClock] = useState(0)
  const snapshotRef = useRef<BlackoutGameSnapshot | null>(null)
  const receivedAtRef = useRef(0)

  const applySnapshot = useCallback((next: BlackoutGameSnapshot) => {
    snapshotRef.current = next
    receivedAtRef.current = performance.now()
    setSnapshot(next)
    setError('')
  }, [])

  const refresh = useCallback(async () => {
    const next = await getMyGame()
    applySnapshot(next)
    return next
  }, [applySnapshot])

  useEffect(() => {
    let alive = true
    let removeChannel: (() => void) | undefined
    let phasePollTimer: number | undefined
    let heartbeatTimer: number | undefined
    let refreshQueue = Promise.resolve()

    const schedulePhasePoll = (current: BlackoutGameSnapshot) => {
      if (phasePollTimer !== undefined) window.clearTimeout(phasePollTimer)
      const state = current.game.state
      const deadline = state === 'ACTIVE' ? current.game.active_deadline_at
        : state === 'FINAL_BLACKOUT' || state === 'ESCAPE'
          ? [current.game.state_deadline_at, current.game.final_deadline_at].filter(Boolean).sort()[0]
          : ['STARTING', 'ROLE_REVEAL', 'FACILITY_INTRO', 'DISCUSSION', 'VOTING', 'VOTE_RESULT'].includes(state)
            ? current.game.state_deadline_at : null
      if (!deadline) return
      const delay = Math.max(0, Date.parse(deadline) - Date.parse(current.server_now)) + 100
      phasePollTimer = window.setTimeout(handleChange, delay)
    }

    const handleChange = () => {
      refreshQueue = refreshQueue.then(async () => {
        if (!alive) return
        const next = await getMyGame()
        if (alive) {
          applySnapshot(next)
          schedulePhasePoll(next)
        }
      }).catch(error => {
        if (alive) {
          setConnection('disconnected')
          setError(error instanceof Error ? error.message : 'Could not refresh the game state.')
        }
      })
    }

    async function connect() {
      try {
        const initial = await getMyGame()
        if (!alive) return
        applySnapshot(initial)
        schedulePhasePoll(initial)
        const unsubscribe = await subscribeToGame(initial, handleChange, setLivePlayerIds, connected => setConnection(connected ? 'connected' : 'disconnected'))
        if (!alive) {
          unsubscribe()
          return
        }
        removeChannel = unsubscribe
        heartbeatTimer = window.setInterval(handleChange, 12_000)
      } catch (loadError) {
        if (alive) {
          setConnection('disconnected')
          setError(loadError instanceof Error ? loadError.message : 'Could not connect to the game.')
        }
      } finally {
        if (alive) setLoading(false)
      }
    }

    void connect()
    const onVisible = () => { if (document.visibilityState === 'visible') handleChange() }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive = false
      if (phasePollTimer !== undefined) window.clearTimeout(phasePollTimer)
      if (heartbeatTimer !== undefined) window.clearInterval(heartbeatTimer)
      document.removeEventListener('visibilitychange', onVisible)
      removeChannel?.()
    }
  }, [applySnapshot])

  useEffect(() => {
    const timer = window.setInterval(() => setClock(performance.now()), 250)
    return () => window.clearInterval(timer)
  }, [])

  const getRemainingMs = useCallback((state?: GameState) => {
    const current = snapshotRef.current
    if (!current) return 0
    const selectedState = state ?? current.game.state
    const deadline = selectedState === 'ACTIVE'
      ? current.game.active_deadline_at
      : selectedState === 'FINAL_BLACKOUT' || selectedState === 'ESCAPE'
        ? current.game.final_deadline_at
        : current.game.state_deadline_at
    if (!deadline) return 0
    const serverRemaining = Date.parse(deadline) - Date.parse(current.server_now)
    return Math.max(0, serverRemaining - (performance.now() - receivedAtRef.current))
  }, [])

  return { snapshot, connection, livePlayerIds, error, loading, refresh, getRemainingMs }
}
