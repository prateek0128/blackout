import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { AnimatePresence, motion, useReducedMotion } from 'framer-motion'
import { Link, NavLink, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { createRoom as createRoomRequest, joinRoom as joinRoomRequest } from './lib/rooms'
import { useLobby } from './lib/useLobby'
import { useBlackoutGame } from './lib/useBlackoutGame'
import { accusePlayer, castGameVote, performGameAction, performEscapeAction, restartBlackoutGame, type EscapeActionType, type FacilitySector, type GameActionType, type GameState } from './lib/game'

type Tone = 'green' | 'amber' | 'red' | 'blue' | 'muted'
type MetricProps = { label: string; value: string; percent: number; tone?: Tone; detail?: string }

const routeNames = ['/','/create','/join','/lobby','/role','/facility','/game','/vote','/blackout','/escape','/results']

function Mark({ small = false }: { small?: boolean }) {
  return <span className={`brand-mark${small ? ' brand-mark--small' : ''}`} aria-hidden="true"><i /><i /><i /><i /></span>
}

function Brand({ compact = false }: { compact?: boolean }) {
  return <Link className="brand" to="/" aria-label="BLACKOUT home"><Mark small={compact} /><span className="brand-word">BLACK<span>OUT</span><small>THE LAST 5 MINUTES</small></span></Link>
}

function Icon({ name }: { name: 'arrow' | 'chevron' | 'lock' | 'signal' | 'copy' | 'back' | 'radio' | 'cross' | 'bolt' }) {
  const paths: Record<typeof name, ReactNode> = {
    arrow: <><path d="M4 12h15"/><path d="m13 6 6 6-6 6"/></>,
    chevron: <path d="m9 18 6-6-6-6"/>,
    lock: <><rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 1 1 8 0v3"/></>,
    signal: <><path d="M2 8a15 15 0 0 1 20 0"/><path d="M5 12a10 10 0 0 1 14 0"/><path d="M8.5 15.5a5 5 0 0 1 7 0"/><path d="M12 20h.01"/></>,
    copy: <><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/></>,
    back: <><path d="M19 12H5"/><path d="m12 19-7-7 7-7"/></>,
    radio: <><circle cx="12" cy="12" r="2"/><path d="M16.2 7.8a6 6 0 0 1 0 8.4"/><path d="M7.8 16.2a6 6 0 0 1 0-8.4"/><path d="M19 5a10 10 0 0 1 0 14"/><path d="M5 19A10 10 0 0 1 5 5"/></>,
    cross: <><path d="m18 6-12 12M6 6l12 12"/></>,
    bolt: <path d="m13 2-3 8h7l-6 12 2-9H6l7-11Z" />,
  }
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>
}

function Button({ children, to, variant = 'primary', onClick, type = 'button', disabled = false, className = '' }: {
  children: ReactNode; to?: string; variant?: 'primary' | 'secondary' | 'quiet' | 'danger'; onClick?: () => void; type?: 'button' | 'submit'; disabled?: boolean; className?: string
}) {
  const content = <>{children}</>
  const classes = `button button--${variant} ${className}`
  if (to) return <Link className={classes} to={to}>{content}</Link>
  return <button className={classes} type={type} onClick={onClick} disabled={disabled}>{content}</button>
}

function Badge({ children, tone = 'muted', dot = false }: { children: ReactNode; tone?: Tone; dot?: boolean }) {
  return <span className={`badge badge--${tone}`}>{dot && <i className="badge-dot" />}{children}</span>
}

function Panel({ children, className = '', label }: { children: ReactNode; className?: string; label?: string }) {
  return <section className={`panel ${className}`}>{label && <div className="panel-label">{label}</div>}{children}</section>
}

function Metric({ label, value, percent, tone = 'green', detail }: MetricProps) {
  return <div className="metric">
    <div className="metric-top"><span>{label}</span><strong className={`text-${tone}`}>{value}</strong></div>
    <div className="meter" role="img" aria-label={`${label}: ${value}`}><span className={`meter-fill meter-fill--${tone}`} style={{ width: `${percent}%` }} /></div>
    {detail && <small>{detail}</small>}
  </div>
}

function GameTimer({ time = '04:58', critical = false }: { time?: string; critical?: boolean }) {
  return <div className={`timer${critical ? ' timer--critical' : ''}`}><span className="timer-kicker">TIME REMAINING</span><strong>{time}</strong></div>
}

function PageTransition({ children }: { children: ReactNode }) {
  const reduceMotion = useReducedMotion()
  return <motion.div className="route-view" initial={reduceMotion ? false : { opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={reduceMotion ? undefined : { opacity: 0, y: -6 }} transition={{ duration: 0.24, ease: 'easeOut' }}>{children}</motion.div>
}

function AppFrame({ children, showNav = true }: { children: ReactNode; showNav?: boolean }) {
  return <div className="app-frame"><div className="grain" />{showNav && <Header />}{children}<footer className="footer"><span>BLACKOUT<span className="footer-mark"> / </span>THE LAST 5 MINUTES</span><span>PHASE 3D <i className="footer-dot" /> FINAL ESCAPE</span></footer></div>
}

function Header() {
  return <header className="topbar"><Brand compact /><nav className="topnav" aria-label="Main navigation"><NavLink to="/" end>OVERVIEW</NavLink><NavLink to="/create">CREATE ROOM</NavLink><NavLink to="/join">JOIN ROOM</NavLink></nav><div className="topbar-right"><Badge tone="amber" dot>PHASE 3D FINAL ESCAPE</Badge><span className="topbar-version">03.D</span></div></header>
}

function Eyebrow({ children, icon = false }: { children: ReactNode; icon?: boolean }) {
  return <div className="eyebrow">{icon && <span className="eyebrow-line" />}{children}</div>
}

function SectionTitle({ eyebrow, title, children, right }: { eyebrow: string; title: string; children?: ReactNode; right?: ReactNode }) {
  return <div className="section-title"><div><Eyebrow icon>{eyebrow}</Eyebrow><h1>{title}</h1>{children && <p>{children}</p>}</div>{right}</div>
}

function Landing() {
  return <main className="landing page-wrap">
    <div className="landing-copy"><Eyebrow icon>FACILITY CONTROL // 09.18.27</Eyebrow>
      <h1 className="hero-title">BLACK<span>OUT</span><em>THE LAST 5 MINUTES</em></h1>
      <p className="hero-lede">One facility. Different information.<br /><strong>One hidden saboteur.</strong></p>
      <p className="hero-description">The emergency systems are failing. Trust is a resource. Escape is a team decision.</p>
      <div className="hero-actions"><Button to="/create">CREATE ROOM <Icon name="arrow" /></Button><Button to="/join" variant="secondary">JOIN ROOM <Icon name="chevron" /></Button></div>
      <div className="game-facts"><span><b>03—06</b> PLAYERS</span><i /><span><b>REALTIME</b> CO-OP</span><i /><span><b>HIDDEN</b> ROLE</span></div>
    </div>
    <div className="facility-art" aria-label="Illustrated emergency facility schematic">
      <div className="art-topline"><span>SECTOR 04 — NORTH ANNEX</span><span className="rec"><i /> LIVE FEED</span></div>
      <div className="schematic">
        <div className="scanline" />
        <svg className="facility-svg" viewBox="0 0 620 430" role="img" aria-label="Facility map schematic with a failing power core">
          <defs><pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse"><path d="M32 0H0V32" fill="none" stroke="#a7b2a5" strokeOpacity=".11" strokeWidth="1"/></pattern><radialGradient id="core"><stop stopColor="#df9d57" stopOpacity=".32"/><stop offset="1" stopColor="#df9d57" stopOpacity="0"/></radialGradient></defs>
          <rect width="620" height="430" fill="url(#grid)"/>
          <path d="M83 84H226V142H304V84H495V166H552V316H455V357H300V304H217V357H83V264H49V156H83Z" fill="#171b1a" stroke="#788179" strokeOpacity=".62" strokeWidth="2"/>
          <path d="M226 84V196H305M304 142H393V221H495M83 156H179V264M217 264H352V357M352 264H455V316M179 196V264M393 221H455V264" fill="none" stroke="#59645d" strokeWidth="2"/>
          <path d="M83 107H158M83 129H158M410 84V129M432 84V129M495 190H541M495 212H541M105 303H174M105 325H174" stroke="#858e83" strokeOpacity=".48" strokeWidth="4"/>
          <circle cx="350" cy="221" r="90" fill="url(#core)"/><circle cx="350" cy="221" r="28" fill="#d68b49" fillOpacity=".1" stroke="#d68b49" strokeWidth="1.5"/><circle cx="350" cy="221" r="8" fill="#f3b267"/>
          <path d="M350 207V222L363 230" stroke="#f5d0a5" strokeWidth="2" fill="none"/>
          <circle cx="132" cy="198" r="6" fill="#8fb6a1"/><circle cx="459" cy="280" r="6" fill="#8fb6a1"/>
          <circle cx="514" cy="130" r="7" fill="#cf765c"/><path d="M514 130h58M520 124v12" stroke="#cf765c"/>
          <path d="M350 112V151M350 291V330M241 221H310M390 221H463" stroke="#d4975c" strokeDasharray="4 5" strokeOpacity=".72"/>
          <text x="99" y="111" className="map-label">MED BAY</text><text x="250" y="106" className="map-label">SECURITY</text><text x="316" y="274" className="map-label map-label--alert">POWER CORE</text><text x="426" y="108" className="map-label">OPERATIONS</text><text x="455" y="303" className="map-label">LOADING BAY</text><text x="97" y="286" className="map-label">MAINTENANCE</text>
        </svg>
        <div className="art-coordinate coord-one">31° 46' N<br />035° 12' E</div><div className="art-coordinate coord-two">MAP DATA // RESTRICTED</div>
        <div className="art-alert"><span className="alert-icon"><Icon name="bolt" /></span><span><small>CRITICAL SYSTEM</small><b>POWER GRID UNSTABLE</b></span><span className="alert-arrow">↗</span></div>
      </div>
      <div className="art-bottomline"><span><i className="status-led" /> SYSTEMS RESPONDING</span><span>SCHEMATIC 04-A <b>•••</b></span></div>
    </div>
    <div className="landing-bottom"><span>COOPERATE / INVESTIGATE / SURVIVE</span><span className="landing-scroll">SCROLL TO BRIEFING <b>↓</b></span><span>NO ONE HAS THE FULL PICTURE</span></div>
    <div className="landing-brief"><div><Eyebrow icon>THE PREMISE</Eyebrow><p>Six people. One failing facility. Somewhere in the group, someone is working against the clock.</p></div><div className="brief-stat"><strong>05:00</strong><span>ONE LAST WINDOW</span></div><div className="brief-stat"><strong>01</strong><span>HIDDEN SABOTEUR</span></div></div>
  </main>
}

function FormPage({ mode }: { mode: 'create' | 'join' }) {
  const isCreate = mode === 'create'
  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [working, setWorking] = useState(false)
  const [attempted, setAttempted] = useState(false)
  const [formError, setFormError] = useState('')
  const navigate = useNavigate()
  const validName = name.trim().length >= 2
  const validCode = !isCreate && /^[A-HJ-NP-Z2-9]{5}$/.test(code.trim().toUpperCase())
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setAttempted(true)
    if (!validName || (!isCreate && !validCode)) return
    setWorking(true); setFormError('')
    try {
      const snapshot = isCreate
        ? await createRoomRequest(name)
        : await joinRoomRequest(code, name)
      navigate(`/lobby?room=${snapshot.room.room_code}`)
    } catch (error) {
      setFormError(error instanceof Error ? error.message : 'The room request could not be completed.')
    } finally { setWorking(false) }
  }
  return <main className="page-wrap form-layout"><div className="form-aside"><Eyebrow icon>SECURE ACCESS TERMINAL</Eyebrow><h1>{isCreate ? <>START A<br /><span>NEW SESSION</span></> : <>REJOIN THE<br /><span>OPERATION</span></>}</h1><p>{isCreate ? 'Establish a facility channel. Invite your crew when your room is ready.' : 'Enter the room code shared by your host to connect to the facility.'}</p><div className="terminal-art"><div className="terminal-circle"><span>BLACKOUT</span><b>⌁</b><small>FACILITY NETWORK</small></div><span className="terminal-caption">ENCRYPTED CHANNEL <i /> STANDING BY</span></div><div className="aside-code">AUTHENTICATION / GUEST SESSION<br />PROTOCOL 0x04 // PREVIEW MODE</div></div>
    <Panel className="form-panel"><Link to="/" className="back-link"><Icon name="back" /> BACK TO BRIEFING</Link><div className="form-heading"><Badge tone="blue" dot>PHASE 01 / UI PREVIEW</Badge><h2>{isCreate ? 'Create a room' : 'Join a room'}</h2><p>{isCreate ? 'Your display name is how your crew will know you.' : 'Your crew is waiting. Connect with a room code.'}</p></div>
      <form onSubmit={submit} noValidate>
        <label className="field-label" htmlFor="display-name">DISPLAY NAME <span>REQUIRED</span></label>
        <input id="display-name" value={name} onChange={e => { setName(e.target.value.slice(0, 18)); setFormError('') }} placeholder="e.g. SIGNAL_04" autoComplete="nickname" aria-invalid={attempted && !validName} aria-describedby="name-help name-error" />
        <div className="field-hint" id="name-help">2–18 characters. This is the name shown to your crew.</div>
        {attempted && !validName && <div className="field-error" id="name-error">Enter a display name with at least 2 characters.</div>}
        {!isCreate && <><label className="field-label field-label--spaced" htmlFor="room-code">ROOM CODE <span>5 CHARACTERS</span></label><input id="room-code" className="code-input" value={code} onChange={e => { setCode(e.target.value.replace(/[^a-z0-9]/gi, '').slice(0, 5).toUpperCase()); setFormError('') }} placeholder="A7K2M" autoCapitalize="characters" autoComplete="off" aria-invalid={attempted && !validCode} aria-describedby="code-help code-error" /><div className="field-hint" id="code-help">Ask your host for the five character access code.</div>{attempted && !validCode && <div className="field-error" id="code-error">Enter 5 letters or numbers, excluding I, O, 0 and 1.</div>}</>}
        <Button type="submit" className="form-submit" disabled={working}>{working ? 'CONNECTING…' : isCreate ? 'CREATE ROOM' : 'JOIN ROOM'} <Icon name="arrow" /></Button>
      </form>
      {formError && <div className="action-error" role="alert"><Icon name="cross" /><span>{formError}</span></div>}
      <div className="form-foot"><Icon name="lock" /> ANONYMOUS PLAYER SESSION <i /> DISPLAY NAME SHARED WITH ROOM MEMBERS</div>
    </Panel>
  </main>
}

function DemoNotice({ children = 'STATIC DESIGN PREVIEW · NO LIVE GAME DATA' }: { children?: ReactNode }) {
  return <div className="demo-notice"><span className="demo-square">i</span><span>{children}</span><Badge tone="amber">DESIGN STATE</Badge></div>
}

function GameNav({ active = 'lobby', live = false }: { active?: string; live?: boolean }) {
  return <aside className="game-nav"><Brand compact /><div className="game-nav-tag">FACILITY LINK <span><i /></span></div><nav aria-label="Game preview navigation">{routeNames.slice(3).map(path => {
    const name = path.slice(1).toUpperCase()
    return <NavLink key={path} to={path} className={({ isActive }) => `game-nav-item${(isActive || active === path.slice(1)) ? ' is-active' : ''}`}><span className="nav-index">0{routeNames.indexOf(path) - 2}</span>{name}<Icon name="chevron" /></NavLink>
  })}</nav><div className="nav-bottom"><span className="nav-operator"><b>OP</b><span><strong>OPERATOR</strong><small>{live ? 'ANONYMOUS SESSION' : 'LOCAL PREVIEW'}</small></span></span><Badge tone={live ? 'green' : 'muted'} dot>{live ? 'SERVER LINK' : 'NOT CONNECTED'}</Badge></div></aside>
}

function GameLayout({ children, active, live = false }: { children: ReactNode; active?: string; live?: boolean }) {
  return <main className="game-layout page-wrap"><GameNav active={active} live={live} /><div className="game-content">{live ? <DemoNotice>LIVE SERVER STATE · PRIVATE PLAYER CHANNEL</DemoNotice> : <DemoNotice />}<div className="game-content-inner">{children}</div></div></main>
}

function PlayerSeat({ name, role, host = false, state = 'AWAITING SIGNAL', tone = 'muted' }: { name: string; role?: string; host?: boolean; state?: string; tone?: Tone }) {
  return <div className="player-row"><div className="player-avatar">{name === 'OPEN SEAT' ? '+' : name.slice(0, 2)}</div><div className="player-ident"><strong>{name}</strong>{host && <Badge tone="amber">HOST</Badge>}{role && <small>{role}</small>}</div><Badge tone={tone} dot>{state}</Badge></div>
}

function Lobby() {
  const navigate = useNavigate()
  const lobby = useLobby(() => navigate('/role', { replace: true }))
  const [copied, setCopied] = useState(false)
  if (lobby.loading) return <GameLayout active="lobby"><div className="lobby-state"><div className="loading-orbit" /><h1>Establishing room link</h1><p>Restoring your anonymous player session…</p></div></GameLayout>
  if (!lobby.snapshot) return <GameLayout active="lobby"><div className="lobby-state lobby-state--error"><Badge tone="red" dot>ROOM LINK UNAVAILABLE</Badge><h1>Connection lost</h1><p>{lobby.error || 'This browser session is not connected to a room.'}</p><div className="state-actions"><Button to="/create">CREATE A ROOM <Icon name="arrow" /></Button><Button to="/join" variant="secondary">JOIN WITH CODE</Button></div></div></GameLayout>
  const { snapshot } = lobby
  const current = snapshot.players.find(player => player.id === snapshot.current_player_id)
  const connected = snapshot.players.filter(player => player.connection_state === 'connected')
  const allReady = connected.length >= 3 && connected.every(player => player.ready)
  const canStart = current?.is_host && allReady && snapshot.room.status === 'LOBBY'
  const isStarting = snapshot.room.status === 'STARTING'
  const copyCode = async () => {
    try { await navigator.clipboard.writeText(snapshot.room.room_code); setCopied(true); window.setTimeout(() => setCopied(false), 1800) }
    catch { lobby.setNotice('Room code: ' + snapshot.room.room_code) }
  }
  async function exitRoom() { if (await lobby.leave()) navigate('/') }
  async function startOperation() {
    const gameId = await lobby.start()
    if (gameId) navigate('/role')
  }
  return <GameLayout active="lobby"><SectionTitle eyebrow="ROOM // LOBBY" title="Crew assembly" right={<Badge tone={isStarting ? 'amber' : 'green'} dot>{isStarting ? 'STARTING' : 'LOBBY OPEN'}</Badge>}>Your operation begins when your crew is ready.</SectionTitle>
    {lobby.error && <div className="action-error lobby-error" role="alert"><Icon name="cross" /><span>{lobby.error}</span></div>}
    {lobby.notice && <div className="action-notice" role="status"><span className="badge-dot" />{lobby.notice}<button aria-label="Dismiss message" onClick={() => lobby.setNotice('')}><Icon name="cross" /></button></div>}
    {isStarting && <div className="starting-banner"><Badge tone="amber" dot>SERVER CONFIRMED</Badge><span>Operation launch is being synchronized across the crew.</span></div>}
    <div className="lobby-grid"><Panel className="room-panel" label="ACCESS CHANNEL"><div className="room-code"><div><span>ROOM CODE</span><strong>{snapshot.room.room_code}</strong></div><button className="icon-button" aria-label="Copy room code" onClick={() => void copyCode()}><Icon name="copy" /></button></div><p className="muted-copy">Share this code with the rest of your crew. It is case-insensitive.</p><div className="room-rule"><span>ROOM STATUS</span><b>{snapshot.room.status.replace('_', ' ')}</b></div><div className="room-rule"><span>MINIMUM TO START</span><b>03 OPERATORS</b></div><div className="room-rule"><span>ROOM EXPIRY</span><b>{new Date(snapshot.room.expires_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</b></div><div className="panel-divider" /><Metric label="FACILITY LINK" value={lobby.connection === 'connected' ? 'CONNECTED' : 'RECONNECTING'} percent={lobby.connection === 'connected' ? 100 : 32} tone={lobby.connection === 'connected' ? 'green' : 'amber'} detail="DURABLE ROOM STATE SYNCED BY SERVER" /><div className="lobby-room-actions"><Button onClick={() => void exitRoom()} variant="quiet" disabled={lobby.busy}>LEAVE ROOM <Icon name="back" /></Button><span>{copied ? 'CODE COPIED' : 'HOST MIGRATION ENABLED'}</span></div></Panel>
      <Panel className="crew-panel" label="OPERATORS"><div className="crew-heading"><strong>CREW MANIFEST</strong><Badge tone={connected.length >= 3 ? 'green' : 'amber'}>{snapshot.players.length} / {snapshot.room.max_players}</Badge></div><div className="live-roster">{snapshot.players.map(player => {
        const online = player.connection_state === 'connected' && lobby.livePlayerIds.includes(player.id)
        const tone = player.connection_state === 'disconnected' ? 'red' : player.ready ? 'green' : 'amber'
        const state = player.connection_state === 'disconnected' ? 'OFFLINE' : online ? (player.ready ? 'READY' : 'CONNECTED') : player.ready ? 'READY · SYNCING' : 'WAITING · SYNCING'
        return <PlayerSeat key={player.id} name={player.display_name} host={player.is_host} state={state} tone={tone} />
      })}</div><div className="lobby-ready-row"><div><strong>{current?.ready ? 'YOU ARE READY' : 'YOUR STATUS: NOT READY'}</strong><small>{current?.is_host ? 'HOST · YOU CONTROL THE START' : 'WAITING FOR THE HOST TO START'}</small></div>{!isStarting && <Button onClick={() => void lobby.toggleReady()} variant={current?.ready ? 'secondary' : 'primary'} disabled={lobby.busy}>{current?.ready ? 'NOT READY' : 'READY'} <Icon name={current?.ready ? 'cross' : 'arrow'} /></Button>}</div>{current?.is_host ? <><Button onClick={() => void startOperation()} className="full-width" disabled={!canStart || lobby.busy || isStarting}>{lobby.busy ? 'SYNCING…' : isStarting ? 'OPERATION STARTED' : 'START OPERATION'} <Icon name="arrow" /></Button><p className="disabled-hint">{connected.length < 3 ? `Need ${3 - connected.length} more connected player${3 - connected.length === 1 ? '' : 's'}.` : !allReady ? 'Every connected operator must be ready.' : 'All start conditions met. The server will validate again.'}</p></> : <div className="host-waiting"><Icon name="radio" /><span><strong>WAITING ON HOST</strong><small>The host can start when 3–6 players are connected and ready.</small></span></div>}</Panel>
    </div>
  </GameLayout>
}

const roleInfo: Record<string, { tone: Tone; descriptor: string; copy: string; tag: string }> = {
  HACKER: { tone: 'blue', descriptor: 'SYSTEMS SPECIALIST', copy: 'Read the facility through its network. Doors, cameras, and access logs leave traces only you can decode.', tag: 'CREW SPECIALIZATION' },
  SCOUT: { tone: 'green', descriptor: 'FIELD RECON', copy: 'Spot movement, damaged routes, and inconsistencies across the facility.', tag: 'CREW SPECIALIZATION' },
  ENGINEER: { tone: 'amber', descriptor: 'FACILITY SYSTEMS', copy: 'You know which systems can be brought back online and what it costs to keep them running.', tag: 'CREW SPECIALIZATION' },
  SABOTEUR: { tone: 'red', descriptor: 'HOSTILE INSIDER', copy: 'Blend in with the crew and keep the facility from stabilizing.', tag: 'CLASSIFIED ASSIGNMENT' },
}

function formatClock(milliseconds: number) {
  const totalSeconds = Math.max(0, Math.ceil(milliseconds / 1000))
  return String(Math.floor(totalSeconds / 60)).padStart(2, '0') + ':' + String(totalSeconds % 60).padStart(2, '0')
}

function useGameRoute() {
  const game = useBlackoutGame()
  const navigate = useNavigate()
  const location = useLocation()
  useEffect(() => {
    if (!game.snapshot) return
    const destination: Record<GameState, string> = {
      STARTING: '/role', ROLE_REVEAL: '/role', FACILITY_INTRO: '/facility', ACTIVE: '/game',
      DISCUSSION: '/game', VOTING: '/game', VOTE_RESULT: '/game', FINAL_BLACKOUT: '/blackout', ESCAPE: '/escape', RESULTS: '/results',
    }
    const target = destination[game.snapshot.game.state]
    if (location.pathname !== target) navigate(target, { replace: true })
  }, [game.snapshot, location.pathname, navigate])
  return game
}

function GameLoadingState({ error }: { error?: string }) {
  return <GameLayout active="game"><div className={'lobby-state' + (error ? ' lobby-state--error' : '')}>
    {error ? <><Badge tone="red" dot>GAME LINK UNAVAILABLE</Badge><h1>Operation not found</h1><p>{error}</p><div className="state-actions"><Button to="/lobby">RETURN TO LOBBY</Button></div></> : <><div className="loading-orbit" /><h1>Securing personnel channel</h1><p>Recovering your private assignment and current facility state…</p></>}
  </div></GameLayout>
}

function RoleReveal() {
  const game = useGameRoute()
  if (game.loading || !game.snapshot) return <GameLoadingState error={game.loading ? undefined : game.error} />
  const role = roleInfo[game.snapshot.my_player.secret_role]
  const saboteur = game.snapshot.my_player.secret_role === 'SABOTEUR'
  return <GameLayout active="role" live><div className="role-screen live-role-screen"><Eyebrow icon>PERSONNEL FILE // ENCRYPTED</Eyebrow>
    <div className="role-classified"><Icon name="lock" /> PRIVATE TO YOU <Badge tone={game.connection === 'connected' ? 'green' : 'amber'} dot>{game.connection === 'connected' ? 'SECURE LINK' : 'RECONNECTING'}</Badge></div>
    <div className={'role-card live-role-card' + (saboteur ? ' live-role-card--saboteur' : '')}><div className="role-sigil"><div className="sigil-ring"><span>{saboteur ? '!' : '◈'}</span><i /><i /><i /></div><small>IDENTITY SEALED</small></div>
      <div className="role-text"><Badge tone={role.tone} dot>{role.tag}</Badge><p className="role-descriptor">{role.descriptor}</p><h1>YOUR ROLE<br /><span>{saboteur ? 'SABOTEUR' : 'CREW'}</span></h1><p>{role.copy}</p>
        <Panel className="objective-panel" label="PRIVATE OBJECTIVE"><p>{game.snapshot.my_player.objective}</p></Panel>
        <div className="role-transition"><span><i className="inline-led" /> TEAM BRIEFING STARTS IN</span><strong>{formatClock(game.getRemainingMs('ROLE_REVEAL'))}</strong></div>
      </div></div>
    <div className="privacy-warning"><Icon name="lock" /><span><strong>THIS ASSIGNMENT IS PRIVATE</strong><small>The server returned only your role and objective to this player session.</small></span><Badge tone={saboteur ? 'red' : 'green'}>{saboteur ? 'SABOTEUR' : 'CREW'}</Badge></div>
  </div></GameLayout>
}

function FacilityIntro() {
  const reduceMotion = useReducedMotion()
  const game = useGameRoute()
  if (game.loading || !game.snapshot) return <GameLoadingState error={game.loading ? undefined : game.error} />
  const { game: state } = game.snapshot
  return <GameLayout active="facility" live><div className="intro-screen live-intro-screen"><Eyebrow icon>OPERATION BRIEF // FACILITY LINKED</Eyebrow>
    <div className="intro-head"><div><p className="facility-kicker">BLACKOUT FACILITY · SECURE CHANNEL</p><h1>BLACKOUT<br /><span>FACILITY</span></h1></div><div className="intro-seal"><motion.div animate={reduceMotion ? undefined : { rotate: 360 }} transition={{ duration: 50, repeat: Infinity, ease: 'linear' }}>B</motion.div><span>CREW<br />BRIEFING</span></div></div>
    <p className="intro-lede">The containment failure has triggered a facility-wide lockdown. Five minutes begin when the active operation starts.</p>
    <div className="intro-metrics"><Metric label="POWER" value={state.power + '%'} percent={state.power} tone="amber" detail="AUXILIARY GRID" /><Metric label="SECURITY" value={state.security + '%'} percent={state.security} tone="green" detail="LOCKDOWN SYSTEM" /><Metric label="INTEGRITY" value={state.facility_integrity + '%'} percent={state.facility_integrity} tone="blue" detail="FACILITY STATUS" /></div>
    <Panel className="mission-panel" label="PRIMARY DIRECTIVE"><div><span className="directive-mark">01</span><p>Stabilize critical systems. Investigate the facility. Get the crew to safety.</p></div><Badge tone="red" dot>THREAT UNCONFIRMED</Badge></Panel>
    <div className="intro-actions"><div className="countdown-display"><span>TIME REMAINING</span><strong>05:00</strong><small>SERVER STARTS THE ACTIVE CLOCK</small></div><div className="briefing-countdown"><span>ACTIVE PHASE IN</span><strong>{formatClock(game.getRemainingMs('FACILITY_INTRO'))}</strong></div></div>
  </div></GameLayout>
}

function FacilityMap() {
  return <div className="map-panel"><div className="map-panel-head"><span>FACILITY SCHEMATIC <b> / </b> SUBLEVEL 04</span><Badge tone="amber" dot>SCHEMATIC ONLY</Badge></div><div className="map-canvas"><div className="map-grid" /><svg viewBox="0 0 720 420" role="img" aria-label="Facility schematic showing the compact facility layout"><path className="map-outline" d="M85 73h188v60h85V73h175v70h88v206H494v36H275v-48h-92v48H85v-97H47V134h38z"/><path className="map-walls" d="M273 73v131h85m0-71h116v82h62M85 134h111v140M183 274h160v-70m0 70h151v65m-151-65V328M474 215v59h70m-274-70h85"/><path className="map-route" d="M136 178h91v-65h91m0 0v98h119v102h104"/><g className="map-rooms"><text x="110" y="112">MEDICAL</text><text x="281" y="102">SECURITY</text><text x="444" y="110">OPERATIONS</text><text x="297" y="246">POWER CORE</text><text x="101" y="315">MAINTENANCE</text><text x="457" y="323">LOADING BAY</text></g><g className="map-nodes"><circle cx="139" cy="178" r="6"/><circle cx="236" cy="138" r="6"/><circle cx="352" cy="202" r="8" /><circle cx="482" cy="273" r="7" /><circle cx="213" cy="315" r="6"/></g></svg><span className="map-label-chip chip-reactor">POWER RELAY</span><span className="map-label-chip chip-bay">MAINTENANCE LINK</span></div><div className="map-legend"><span><i className="legend-green" /> STABLE</span><span><i className="legend-amber" /> DEGRADED</span><span><i className="legend-red" /> CRITICAL</span><span className="map-scale">MAP NOT TO SCALE</span></div></div>
}

function Game() {
  const live = useGameRoute()
  const [sector, setSector] = useState<FacilitySector>('OPERATIONS')
  const [pendingAction, setPendingAction] = useState<GameActionType | null>(null)
  const [actionError, setActionError] = useState('')
  const [actionNotice, setActionNotice] = useState('')
  if (live.loading || !live.snapshot) return <GameLoadingState error={live.loading ? undefined : live.error} />
  const snapshot = live.snapshot
  if (snapshot.game.state === 'DISCUSSION' || snapshot.game.state === 'VOTING' || snapshot.game.state === 'VOTE_RESULT') return <DiscussionRoom game={live} />
  const role = snapshot.my_player.secret_role
  const remaining = formatClock(live.getRemainingMs('ACTIVE'))
  const remainingMs = live.getRemainingMs('ACTIVE')
  const critical = remainingMs <= 60_000
  const connected = snapshot.players.filter(player => player.connection_state === 'connected').length
  const player = snapshot.players.find(candidate => candidate.is_current_player)
  const actionAllowed = snapshot.game.state === 'ACTIVE' && remainingMs > 0 && player?.is_alive && player.is_active && live.connection === 'connected'
  const sectors: Array<{ id: FacilitySector; detail: string }> = [
    { id: 'SECURITY', detail: 'Access logs · locks' },
    { id: 'POWER', detail: 'Relay · grid' },
    { id: 'MEDICAL', detail: 'Triage · life support' },
    { id: 'OPERATIONS', detail: 'Control · telemetry' },
    { id: 'MAINTENANCE', detail: 'Service routes · machinery' },
  ]
  const cooldownMs = (action: GameActionType) => {
    const next = snapshot.my_cooldowns.find(cooldown => cooldown.action === action)?.next_available_at
    return next ? Math.max(0, Date.parse(next) - Date.now()) : 0
  }
  async function runAction(action: GameActionType) {
    setPendingAction(action)
    setActionError('')
    setActionNotice('')
    try {
      await performGameAction(snapshot.game.id, action, sector)
      await live.refresh()
      setActionNotice('Action accepted by facility control.')
    } catch (error) {
      setActionError(error instanceof Error ? error.message : 'The action could not be completed.')
    } finally {
      setPendingAction(null)
    }
  }
  const actionButton = (action: GameActionType, title: string, description: string, disabled = false) => {
    const cooldown = cooldownMs(action)
    const waiting = pendingAction === action
    return <button key={action} type="button" className="facility-action" onClick={() => void runAction(action)} disabled={!actionAllowed || disabled || cooldown > 0 || pendingAction !== null}>
      <span className="facility-action-mark">{waiting ? '…' : cooldown > 0 ? formatClock(cooldown) : '↗'}</span>
      <span className="facility-action-copy"><strong>{waiting ? 'TRANSMITTING' : title}</strong><small>{cooldown > 0 ? `COOLDOWN · ${formatClock(cooldown)}` : description}</small></span>
    </button>
  }
  const actionControls = role === 'HACKER' ? <>{actionButton('SCAN_SECURITY', 'SCAN SECURITY', 'Read incomplete access intelligence.')}</>
    : role === 'ENGINEER' ? <>{actionButton('REPAIR_POWER', `REPAIR POWER · ${sector}`, 'Restore power and a small amount of integrity.')}</>
      : role === 'SCOUT' ? <>{actionButton('INVESTIGATE', `INVESTIGATE · ${sector}`, 'Collect private, incomplete sector intelligence.')}</>
        : <>{actionButton('DISRUPT_POWER', 'DISRUPT POWER', 'Reduce power. The public event hides its source.')}{actionButton('INCREASE_SECURITY', 'INCREASE SECURITY', 'Raise the facility lockdown level.')}{actionButton('TAMPER_RELAY', `TAMPER RELAY · ${sector}`, 'Damage integrity from Power or Maintenance.', sector !== 'POWER' && sector !== 'MAINTENANCE')}</>
  return <GameLayout active="game" live><div className="game-topline"><div><Eyebrow icon>LIVE OPERATION // SERVER SYNCHRONIZED</Eyebrow><h1>Facility overview</h1></div><div className="game-clock"><span>OPERATION WINDOW</span><strong className={critical ? 'timer--critical' : ''}>{remaining}</strong><Badge tone={live.connection === 'connected' ? 'green' : 'amber'} dot>{live.connection === 'connected' ? 'LIVE' : 'SYNCING'}</Badge></div></div>
    <div className="status-strip"><div><span>PHASE</span><strong>{snapshot.game.state.replaceAll('_', ' ')}</strong></div><div><span>FACILITY LINK</span><strong className={live.connection === 'connected' ? 'text-green' : 'text-amber'}><i className="inline-led" /> {live.connection === 'connected' ? 'CONNECTED' : 'RECONNECTING'}</strong></div><div><span>OPERATORS</span><strong>{connected} / {snapshot.players.length} CONNECTED</strong></div></div>
    {live.error && <div className="action-error" role="status"><Icon name="cross" /><span>{live.error}</span></div>}
    {actionError && <div className="action-error" role="alert"><Icon name="cross" /><span>{actionError}</span></div>}
    {actionNotice && <div className="action-notice" role="status"><span className="badge-dot" />{actionNotice}<button aria-label="Dismiss action message" onClick={() => setActionNotice('')}><Icon name="cross" /></button></div>}
    {remainingMs <= 0 && snapshot.game.state === 'ACTIVE' && <div className="action-notice" role="status">The active window has expired. Facility actions are locked.</div>}
    {snapshot.discussion?.result && <Panel className="vote-result-return" label="LAST CREW VOTE"><strong>{snapshot.discussion.result.tied ? 'NO CONSENSUS' : `${snapshot.discussion.result.votes.find(vote => vote.player_id === snapshot.discussion?.result?.winner_player_id)?.display_name ?? 'Operator'} received the most votes`}</strong><span>The crew returned to the operation. No operator was removed.</span></Panel>}
    <div className="main-game-grid"><div className="main-map-column"><MapPanel />
      <Panel className="sector-panel" label="SELECT A FACILITY SECTOR"><div className="facility-sectors">{sectors.map(item => <button type="button" key={item.id} aria-pressed={sector === item.id} className={`facility-sector${sector === item.id ? ' is-selected' : ''}`} onClick={() => setSector(item.id)}><span className="sector-node" /><strong>{item.id}</strong><small>{item.detail}</small></button>)}</div></Panel>
      <div className="metric-trio"><Metric label="POWER" value={`${snapshot.game.power}%`} percent={snapshot.game.power} tone="amber" /><Metric label="SECURITY" value={`${snapshot.game.security}%`} percent={snapshot.game.security} tone="green" /><Metric label="INTEGRITY" value={`${snapshot.game.facility_integrity}%`} percent={snapshot.game.facility_integrity} tone="blue" /></div>
      <Panel className="event-feed-panel" label="PUBLIC FACILITY EVENTS"><div className="event-feed">{snapshot.public_events.length ? snapshot.public_events.map(event => <div className="event-feed-item" key={event.id}><span className="event-feed-time">{new Date(event.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span><span className="event-feed-beacon" /><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')}{event.sector ? ` · ${event.sector}` : ''}</small></div></div>) : <div className="event-feed-empty"><Icon name="radio" /><span>No public facility events yet. The control feed is listening.</span></div>}</div></Panel>
    </div>
    <div className="game-side-column"><Panel className="private-objective" label="PLAYER FILE // PRIVATE"><div className="private-head"><span className="role-mini">{role === 'SABOTEUR' ? '!' : '◈'}</span><span><small>{snapshot.my_player.display_name}</small><strong>{role.replaceAll('_', ' ')}</strong></span><Icon name="lock" /></div><div className="panel-divider" /><span className="private-label">PERSONAL OBJECTIVE</span><p>{snapshot.my_player.objective}</p><Badge tone="blue">ONLY YOU CAN SEE THIS</Badge></Panel>
      <Panel className="action-console" label="AVAILABLE ROLE ACTIONS"><div className="action-console-head"><Badge tone={role === 'SABOTEUR' ? 'red' : 'amber'} dot>{role}</Badge><span>{actionAllowed ? 'ACTIVE WINDOW' : 'ACTIONS LOCKED'}</span></div>{actionControls}<small className="cooldown-foot">ACTIONS HAVE SERVER-ENFORCED 10 SECOND COOLDOWNS</small></Panel>
      <Panel className="intel-panel" label="PRIVATE INTELLIGENCE"><div className="intel-feed">{snapshot.my_intel.length ? snapshot.my_intel.map(event => <div className="intel-note" key={event.id}><span><Icon name="lock" /></span><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')} · INCOMPLETE INTELLIGENCE</small></div></div>) : <div className="evidence-empty"><span><Icon name="lock" /></span><p>No private intelligence yet</p><small>Your role actions will add discoveries here.</small></div>}</div></Panel>
      <Panel label="CREW STATUS" className="crew-status"><div className="crew-status-live">{snapshot.players.map(member => <div className="live-player" key={member.id}><span className={'live-player-avatar' + (member.is_current_player ? ' is-you' : '')}>{member.display_name.slice(0, 2).toUpperCase()}</span><span className="live-player-name"><strong>{member.display_name}{member.is_current_player ? ' · YOU' : ''}</strong><small>{member.is_alive ? 'ACTIVE OPERATOR' : 'INACTIVE'}</small></span><Badge tone={member.connection_state === 'connected' ? 'green' : 'amber'} dot>{member.connection_state.toUpperCase()}</Badge></div>)}</div><div className="presence-foot"><i className="inline-led" /> {live.livePlayerIds.length} LIVE PRESENCE SESSIONS</div></Panel>
    </div></div>
  </GameLayout>
}

function DiscussionRoom({ game }: { game: ReturnType<typeof useBlackoutGame> }) {
  const [targetId, setTargetId] = useState('')
  const [evidenceId, setEvidenceId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const snapshot = game.snapshot!
  const state = snapshot.game.state
  const discussion = snapshot.discussion
  const deadline = state === 'VOTE_RESULT' ? undefined : state
  const remaining = deadline ? game.getRemainingMs(deadline) : game.getRemainingMs('VOTE_RESULT')
  const activeTime = state === 'ACTIVE'
    ? game.getRemainingMs('ACTIVE')
    : snapshot.game.active_remaining_ms ?? 0
  const others = snapshot.players.filter(player => player.is_active && player.is_alive && !player.is_current_player)
  const nameFor = (id: string) => snapshot.players.find(player => player.id === id)?.display_name ?? 'Unknown operator'
  const trigger = snapshot.public_events.find(event => event.id === discussion?.triggering_event_id)
  const result = discussion?.result

  async function submitAccusation() {
    if (!targetId) return
    setBusy(true); setError('')
    try { await accusePlayer(snapshot.game.id, targetId, evidenceId || undefined); await game.refresh() }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'The accusation could not be recorded.') }
    finally { setBusy(false) }
  }
  async function submitVote() {
    if (!targetId) return
    setBusy(true); setError('')
    try { await castGameVote(snapshot.game.id, targetId); await game.refresh() }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'The ballot could not be sealed.') }
    finally { setBusy(false) }
  }

  return <GameLayout active="game" live><div className="discussion-room">
    <div className="discussion-hero"><div><Eyebrow icon>BLACKOUT // CREW ASSEMBLY</Eyebrow><p className="facility-kicker">EMERGENCY CONFERENCE · SECTOR {discussion?.sector ?? 'UNKNOWN'}</p><h1>{state === 'VOTE_RESULT' ? <>VOTE<br /><span>RESULT</span></> : <>BLACKOUT<br /><span>{state === 'VOTING' ? 'VOTING' : 'DISCUSSION'}</span></>}</h1><p className="discussion-lede">The facility lights pulse against the observation glass. Every operator has a different piece of the story.</p></div>
      <div className="discussion-clock"><span>{state === 'DISCUSSION' ? 'DISCUSSION ENDS IN' : state === 'VOTING' ? 'BALLOTS CLOSE IN' : 'RESULTS CLEAR IN'}</span><strong className={remaining < 10000 ? 'timer--critical' : ''}>{formatClock(remaining)}</strong><small>OPERATION CLOCK PAUSED · {formatClock(activeTime)} REMAINING</small></div></div>
    <div className="discussion-status"><span><i className="inline-led" /> {game.connection === 'connected' ? 'FACILITY LINK CONNECTED' : 'RECONNECTING · RECOVERING PHASE'}</span><span>{snapshot.players.filter(player => player.connection_state === 'connected').length} / {snapshot.players.length} OPERATORS PRESENT</span><span>POWER {snapshot.game.power}% · SECURITY {snapshot.game.security}% · INTEGRITY {snapshot.game.facility_integrity}%</span></div>
    {error && <div className="action-error" role="alert"><Icon name="cross" /><span>{error}</span></div>}
    <div className="discussion-grid"><div className="discussion-main-column">
      <MapPanel />
      <div className="metric-trio"><Metric label="POWER" value={`${snapshot.game.power}%`} percent={snapshot.game.power} tone="amber" /><Metric label="SECURITY" value={`${snapshot.game.security}%`} percent={snapshot.game.security} tone="green" /><Metric label="INTEGRITY" value={`${snapshot.game.facility_integrity}%`} percent={snapshot.game.facility_integrity} tone="blue" /></div>
      <Panel className="discussion-evidence-panel" label="PUBLIC EVIDENCE // FACILITY FEED"><div className="event-feed">{snapshot.public_events.length ? snapshot.public_events.map(event => <div className="event-feed-item" key={event.id}><span className="event-feed-time">{new Date(event.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span><span className="event-feed-beacon" /><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')}{event.sector ? ` · ${event.sector}` : ''}</small></div></div>) : <div className="event-feed-empty">No public evidence recorded.</div>}</div></Panel>
      <Panel className="private-evidence-panel" label="YOUR PRIVATE EVIDENCE // DO NOT ASSUME OTHERS KNOW"><div className="intel-feed">{snapshot.my_intel.length ? snapshot.my_intel.map(event => <div className="intel-note" key={event.id}><span><Icon name="lock" /></span><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')} · PRIVATE TO YOU</small></div></div>) : <div className="evidence-empty"><span><Icon name="lock" /></span><p>No private evidence.</p><small>Share only what you choose during discussion.</small></div>}</div></Panel>
    </div><div className="discussion-side-column">
      <Panel className="trigger-panel" label="WHY THE CREW ASSEMBLED"><Badge tone="amber" dot>SERVER CALLED DISCUSSION</Badge><p>{trigger?.message ?? `Evidence was recovered near ${discussion?.sector ?? 'the facility'}.`}</p><small>{discussion?.started_at ? `STARTED ${new Date(discussion.started_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}` : ''}</small></Panel>
      <Panel className="crew-status" label="OPERATORS // SECURE CHANNEL"><div className="crew-status-live">{snapshot.players.map(member => <div className="live-player" key={member.id}><span className={'live-player-avatar' + (member.is_current_player ? ' is-you' : '')}>{member.display_name.slice(0, 2).toUpperCase()}</span><span className="live-player-name"><strong>{member.display_name}{member.is_current_player ? ' · YOU' : ''}</strong><small>{member.is_alive && member.is_active ? 'ACTIVE OPERATOR' : 'INACTIVE'}</small></span><Badge tone={member.connection_state === 'connected' ? 'green' : 'amber'} dot>{member.connection_state.toUpperCase()}</Badge></div>)}</div></Panel>
      {state === 'DISCUSSION' && <Panel className="accusation-panel" label="PLACE A PUBLIC ACCUSATION"><p>Select an operator and, if useful, attach evidence you can access. An accusation is not a verdict.</p><div className="discussion-targets">{others.map(player => <button key={player.id} className={`vote-option${targetId === player.id ? ' is-selected' : ''}`} onClick={() => setTargetId(player.id)}><span className="vote-avatar">{player.display_name.slice(0, 2).toUpperCase()}</span><span><strong>{player.display_name}</strong><small>{player.connection_state.toUpperCase()}</small></span><span className="radio-check" /></button>)}</div><label className="evidence-select-label">ATTACH ACCESSIBLE EVIDENCE (OPTIONAL)<select value={evidenceId} onChange={event => setEvidenceId(event.target.value)}><option value="">No evidence attached</option>{snapshot.public_events.map(event => <option value={event.id} key={event.id}>PUBLIC · {event.message}</option>)}{snapshot.my_intel.map(event => <option value={event.id} key={event.id}>PRIVATE · {event.message}</option>)}</select></label><Button className="full-width" onClick={() => void submitAccusation()} disabled={!targetId || busy}>{busy ? 'TRANSMITTING…' : 'RECORD ACCUSATION'} <Icon name="arrow" /></Button></Panel>}
      {state === 'VOTING' && <Panel className="accusation-panel" label="CAST ONE SEALED BALLOT"><p>Choose one active operator. Your target stays sealed until the server resolves the round.</p>{discussion?.my_vote ? <div className="vote-sealed"><Icon name="lock" /><span><strong>BALLOT SEALED</strong><small>Your vote has been recorded. Target: {nameFor(discussion.my_vote.target_player_id)}</small></span></div> : <><div className="discussion-targets">{others.map(player => <button key={player.id} className={`vote-option${targetId === player.id ? ' is-selected' : ''}`} onClick={() => setTargetId(player.id)}><span className="vote-avatar">{player.display_name.slice(0, 2).toUpperCase()}</span><span><strong>{player.display_name}</strong><small>ACTIVE OPERATOR</small></span><span className="radio-check" /></button>)}</div><Button className="full-width" onClick={() => void submitVote()} disabled={!targetId || busy}>{busy ? 'SEALING BALLOT…' : 'SEAL MY VOTE'} <Icon name="lock" /></Button></>}<div className="vote-progress"><strong>{discussion?.votes_cast ?? 0} / {discussion?.eligible_voters ?? 0}</strong><span>BALLOTS SEALED · TARGETS HIDDEN</span></div></Panel>}
      {state === 'VOTE_RESULT' && <Panel className="vote-result-panel" label="VOTE RESULT // SERVER RESOLVED">{result?.tied ? <div className="no-consensus"><span>—</span><strong>NO CONSENSUS</strong><small>No operator is removed. The facility operation resumes.</small></div> : <><p className="result-callout">{result?.votes.find(vote => vote.player_id === result.winner_player_id)?.display_name} received the highest vote count.</p><div className="result-votes">{result?.votes.map(vote => <div key={vote.player_id}><span>{vote.display_name}</span><strong>{vote.votes} {vote.votes === 1 ? 'VOTE' : 'VOTES'}</strong></div>)}</div><small className="no-elimination-note">NO PLAYER IS REMOVED IN THIS PHASE.</small></>}</Panel>}
      {discussion?.accusations.length ? <Panel className="public-accusations" label="PUBLIC ACCUSATIONS"><div className="result-votes">{discussion.accusations.map(accusation => <div key={accusation.id}><span><strong>{nameFor(accusation.accuser_player_id)}</strong> accused <strong>{nameFor(accusation.accused_player_id)}</strong></span><small>{accusation.evidence_event_id ? 'EVIDENCE REFERENCE ATTACHED' : 'NO EVIDENCE ATTACHED'}</small></div>)}</div></Panel> : null}
    </div></div>
    <div className="discussion-bottomline"><span>THE CREW SHARES THE SAME PUBLIC RECORD.</span><span>PRIVATE INTELLIGENCE STAYS WITH ITS OPERATOR.</span></div>
  </div></GameLayout>
}

function MapPanel() { return <MapComponent /> }
function MapComponent() { return <div className="map-wrap"><FacilityMap /></div> }

function Vote() {
  const [selected, setSelected] = useState('')
  return <GameLayout active="vote"><SectionTitle eyebrow="CREW ASSEMBLY // PRIVATE BALLOTS" title="Discussion & vote" right={<GameTimer time="00:42" />}>Share what you know. Decide who you trust.</SectionTitle><div className="vote-grid"><div className="vote-main"><Panel label="CAST YOUR VOTE" className="vote-panel"><div className="vote-warning"><span>!</span><p><strong>One vote. No takebacks.</strong><small>Your ballot is private until the vote resolves.</small></p><Badge tone="amber">PREVIEW</Badge></div><div className="vote-options">{['OPERATOR 01','OPERATOR 02','OPERATOR 03','ABSTAIN'].map((person, i) => <button type="button" key={person} onClick={() => setSelected(person)} className={`vote-option${selected === person ? ' is-selected' : ''}`}><span className="vote-avatar">{i === 3 ? '—' : `0${i + 1}`}</span><span><strong>{person}</strong><small>{i === 3 ? 'WITHHOLD YOUR VOTE' : 'PLAYER IDENTITY HIDDEN'}</small></span><span className="radio-check" /></button>)}</div><Button disabled={!selected} className="full-width">{selected ? `CONFIRM: ${selected}` : 'SELECT AN OPERATOR'} <Icon name="arrow" /></Button><p className="disabled-hint">Ballot controls are visual only in this preview.</p></Panel><Panel className="discussion-panel" label="DISCUSSION PROMPT"><strong>What did you see?</strong><p>Compare clues, verify timelines, and watch for details that don’t fit.</p><div className="prompt-chips"><Badge tone="muted">WHO HAD ACCESS?</Badge><Badge tone="muted">WHAT CHANGED?</Badge><Badge tone="muted">WHO BENEFITS?</Badge></div></Panel></div><div className="vote-side"><Panel label="DISCUSSION WINDOW" className="discussion-timer"><GameTimer time="00:42" /><span>STATIC DESIGN STATE · TIMER NOT RUNNING</span><div className="meter"><span className="meter-fill meter-fill--amber" style={{ width: '42%' }} /></div></Panel><Panel label="EVIDENCE BOARD" className="evidence-board"><div className="evidence-note"><span>01</span><p><strong>ACCESS LOG GAP</strong><small>One record is missing from the security archive.</small></p><Badge tone="blue">PRIVATE</Badge></div><div className="evidence-note"><span>02</span><p><strong>POWER ROUTE</strong><small>Manual override found near the reactor.</small></p><Badge tone="muted">UNVERIFIED</Badge></div><div className="evidence-note evidence-note--empty"><span>+</span><p><strong>MORE EVIDENCE</strong><small>Clues appear here during a live game.</small></p></div></Panel><Panel label="VOTE TALLY" className="vote-tally"><strong>— <small>VOTES CAST</small></strong><span>RESULTS LOCKED UNTIL EVERYONE HAS VOTED</span></Panel></div></div></GameLayout>
}

const escapeActionLabels: Record<EscapeActionType, { title: string; detail: string }> = {
  LOCATE_ESCAPE_ROUTE: { title: 'LOCATE ESCAPE ROUTE', detail: 'Scout identifies the maintenance corridor.' },
  UNLOCK_EMERGENCY_ROUTE: { title: 'UNLOCK EMERGENCY ROUTE', detail: 'Hacker releases the route locks.' },
  POWER_ESCAPE_DOOR: { title: 'POWER ESCAPE DOOR', detail: 'Engineer restores emergency door power.' },
  OPEN_ESCAPE_DOOR: { title: 'OPEN ESCAPE DOOR', detail: 'Crew opens the powered exit.' },
  JAM_ESCAPE: { title: 'JAM ESCAPE SYSTEMS', detail: 'Saboteur disrupts the latest completed step.' },
}

function useEscapeControls() {
  const live = useGameRoute()
  const [pending, setPending] = useState<EscapeActionType | null>(null)
  const [error, setError] = useState('')
  async function act(action: EscapeActionType) {
    if (!live.snapshot) return
    setPending(action); setError('')
    try { await performEscapeAction(live.snapshot.game.id, action); await live.refresh() }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'The escape action could not be completed.') }
    finally { setPending(null) }
  }
  return { live, pending, error, act }
}

function EscapeActionPanel({ live, pending, error, onAction }: {
  live: ReturnType<typeof useBlackoutGame>; pending: EscapeActionType | null; error: string; onAction: (action: EscapeActionType) => void
}) {
  const snapshot = live.snapshot!
  const escape = snapshot.escape
  const remaining = live.getRemainingMs()
  const allowed = snapshot.game.state === 'FINAL_BLACKOUT' || snapshot.game.state === 'ESCAPE'
  const cooldownFor = (action: EscapeActionType) => escape?.my_cooldowns.find(item => item.action === action)?.next_available_at
  const steps: Array<[string, boolean]> = [
    ['Route located', !!escape?.route_located], ['Route unlocked', !!escape?.route_unlocked],
    ['Door powered', !!escape?.door_powered], ['Emergency door opened', !!escape?.door_opened],
  ]
  return <>
    {error && <div className="action-error" role="alert"><Icon name="cross" /><span>{error}</span></div>}
    <div className="escape-live-grid">
      <Panel className="escape-progress-panel" label="SHARED ESCAPE SEQUENCE"><div className="escape-progress-top"><strong>{escape?.progress ?? 0} / 4 STEPS</strong><Badge tone={live.connection === 'connected' ? 'green' : 'amber'} dot>{live.connection === 'connected' ? 'LIVE' : 'RECONNECTING'}</Badge></div><div className="escape-progress-track"><span style={{ width: `${(escape?.progress ?? 0) * 25}%` }} /></div><div className="escape-steps">{steps.map(([label, done], index) => <div className={done ? 'is-complete' : ''} key={label}><span>{done ? '✓' : `0${index + 1}`}</span><strong>{label}</strong><Badge tone={done ? 'green' : 'muted'}>{done ? 'CONFIRMED' : 'PENDING'}</Badge></div>)}</div></Panel>
      <Panel className="escape-controls-panel" label="YOUR EMERGENCY CONTROLS"><p className="muted-copy">Role-specific access is validated by facility control. Saboteur interference is hidden until it occurs.</p>{escape?.my_available_actions.length ? escape.my_available_actions.map(action => {
        const cooldown = cooldownFor(action)
        const cooling = cooldown ? Date.parse(cooldown) > Date.parse(snapshot.server_now) : false
        const enabled = allowed && remaining > 0 && !cooling && pending === null
        return <button key={action} type="button" className={`facility-action${action === 'JAM_ESCAPE' ? ' facility-action--danger' : ''}`} onClick={() => onAction(action)} disabled={!enabled}><span className="facility-action-mark">{pending === action ? '…' : action === 'JAM_ESCAPE' ? '!' : '↗'}</span><span className="facility-action-copy"><strong>{pending === action ? 'TRANSMITTING' : escapeActionLabels[action].title}</strong><small>{cooling ? 'CONTROL RESETTING · 00:05' : escapeActionLabels[action].detail}</small></span></button>
      }) : <div className="evidence-empty"><span><Icon name="lock" /></span><p>No emergency control assigned</p><small>Stay with the crew and watch the shared status.</small></div>}</Panel>
    </div>
  </>
}

function Blackout() {
  const controls = useEscapeControls()
  const { live } = controls
  if (live.loading || !live.snapshot) return <GameLoadingState error={live.loading ? undefined : live.error} />
  const snapshot = live.snapshot
  const remaining = live.getRemainingMs()
  return <GameLayout active="blackout" live><div className="blackout-screen"><div className="blackout-scan" /><Eyebrow icon>EMERGENCY PROTOCOL // FINAL PHASE</Eyebrow><div className="blackout-header"><div><span className="warning-kicker"><i /> FACILITY FAILURE CASCADE</span><h1>BLACKOUT<br /><span>{snapshot.game.state === 'FINAL_BLACKOUT' ? 'IMMINENT' : 'IN PROGRESS'}</span></h1></div><GameTimer time={formatClock(remaining)} critical /></div><div className="blackout-rule" />
    <div className="blackout-grid"><Panel className="critical-panel" label="CRITICAL SYSTEMS"><Metric label="POWER" value={`${snapshot.game.power}%`} percent={snapshot.game.power} tone="red" detail="AUXILIARY POWER" /><Metric label="SECURITY" value={`${snapshot.game.security}%`} percent={snapshot.game.security} tone="red" detail="LOCKDOWN STATUS" /><Metric label="INTEGRITY" value={`${snapshot.game.facility_integrity}%`} percent={snapshot.game.facility_integrity} tone="amber" detail="STRUCTURAL STATUS" /></Panel>
      <div className="blackout-center"><div className="warning-diamond">!</div><h2>THE GRID IS FAILING</h2><p>The five-minute operation window is over. The crew has 45 seconds from final blackout to complete the shared escape sequence.</p><div className="warning-list"><span><i /> SCOUT · LOCATE THE ROUTE</span><span><i /> HACKER · RELEASE THE LOCKS</span><span><i /> ENGINEER · RESTORE DOOR POWER</span><span><i /> CREW · OPEN THE EXIT</span></div><Button to="/escape" variant="danger">OPEN EVACUATION CONTROLS <Icon name="arrow" /></Button></div>
      <Panel className="last-orders" label="FINAL OBJECTIVE"><Badge tone="red" dot>45 SECOND WINDOW</Badge><h3>GET THE CREW OUT</h3><p>Compare what each operator can do. Saboteur interference may roll back the shared sequence.</p><div className="panel-divider" /><span className="private-label">STATUS</span><p>{snapshot.escape?.progress ?? 0} of 4 escape steps confirmed.</p></Panel>
    </div><EscapeActionPanel live={live} pending={controls.pending} error={controls.error} onAction={action => void controls.act(action)} />
    <Panel className="event-feed-panel" label="PUBLIC FACILITY EVENTS"><div className="event-feed">{snapshot.public_events.filter(event => event.event_type.startsWith('ESCAPE_') || event.event_type === 'FINAL_BLACKOUT_BEGAN').map(event => <div className="event-feed-item" key={event.id}><span className="event-feed-time">{new Date(event.created_at).toLocaleTimeString([], { minute: '2-digit', second: '2-digit' })}</span><span className="event-feed-beacon" /><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')}</small></div></div>)}</div></Panel>
    <div className="blackout-foot"><span>EMERGENCY LIGHTING <b>ACTIVE</b></span><span>ESCAPE DEADLINE {snapshot.game.final_deadline_at ? new Date(snapshot.game.final_deadline_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : 'SYNCHRONIZING'}</span><span>SERVER AUTHORITY ACTIVE</span></div></div></GameLayout>
}

function Escape() {
  const controls = useEscapeControls()
  const { live } = controls
  if (live.loading || !live.snapshot) return <GameLoadingState error={live.loading ? undefined : live.error} />
  const snapshot = live.snapshot
  const remaining = live.getRemainingMs()
  const escape = snapshot.escape
  const steps = [
    ['Locate route', escape?.route_located], ['Unlock route', escape?.route_unlocked],
    ['Power exit', escape?.door_powered], ['Open door', escape?.door_opened],
  ] as const
  return <GameLayout active="escape" live><div className="escape-live-screen"><SectionTitle eyebrow="EVACUATION // COOPERATIVE SEQUENCE" title="The last exit" right={<GameTimer time={formatClock(remaining)} critical={remaining < 15_000} />}>The facility’s emergency route requires coordinated role actions. Every player sees shared progress; each operator receives only their own available controls.</SectionTitle>
    <div className="escape-status-strip"><span><i className="inline-led" /> {snapshot.game.state.replaceAll('_', ' ')}</span><span>{snapshot.players.filter(player => player.connection_state === 'connected').length} / {snapshot.players.length} OPERATORS CONNECTED</span><span>INTEGRITY {snapshot.game.facility_integrity}%</span></div>
    <div className="escape-stage-grid">{steps.map(([label, complete], index) => <Panel key={label} className={`escape-stage${complete ? ' is-complete' : ''}`} label={`STEP 0${index + 1}`}><span className="escape-stage-symbol">{complete ? '✓' : `0${index + 1}`}</span><strong>{label}</strong><Badge tone={complete ? 'green' : 'muted'}>{complete ? 'COMPLETE' : 'AWAITING CREW'}</Badge></Panel>)}</div>
    <EscapeActionPanel live={live} pending={controls.pending} error={controls.error} onAction={action => void controls.act(action)} />
    <div className="escape-detail-grid"><Panel label="CREW MANIFEST" className="crew-status"><div className="crew-status-live">{snapshot.players.map(player => <div className="live-player" key={player.id}><span className={'live-player-avatar' + (player.is_current_player ? ' is-you' : '')}>{player.display_name.slice(0, 2).toUpperCase()}</span><span className="live-player-name"><strong>{player.display_name}{player.is_current_player ? ' · YOU' : ''}</strong><small>{player.is_alive && player.is_active ? 'ACTIVE OPERATOR' : 'INACTIVE'}</small></span><Badge tone={player.connection_state === 'connected' ? 'green' : 'amber'} dot>{player.connection_state.toUpperCase()}</Badge></div>)}</div></Panel>
      <Panel label="PUBLIC ESCAPE LOG" className="event-feed-panel"><div className="event-feed">{snapshot.public_events.filter(event => event.event_type.startsWith('ESCAPE_') || event.event_type === 'FINAL_BLACKOUT_BEGAN').map(event => <div className="event-feed-item" key={event.id}><span className="event-feed-time">{new Date(event.created_at).toLocaleTimeString([], { minute: '2-digit', second: '2-digit' })}</span><span className="event-feed-beacon" /><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')}</small></div></div>)}</div></Panel></div>
    <div className="discussion-bottomline"><span>SHARED FACILITY STATUS · PRIVATE ROLE ACTIONS</span><span>{escape?.jam_count ?? 0} SABOTAGE EVENTS RECORDED</span></div>
  </div></GameLayout>
}

function Results() {
  const live = useGameRoute()
  const navigate = useNavigate()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  if (live.loading || !live.snapshot) return <GameLoadingState error={live.loading ? undefined : live.error} />
  const snapshot = live.snapshot
  const result = snapshot.results
  if (!result) return <GameLoadingState error="The final outcome is still being recorded. Reconnecting to the result ledger…" />
  const victory = result.outcome === 'CREW_ESCAPED'
  const outcomeLabel = result.outcome.replaceAll('_', ' ')
  async function playAgain() {
    setBusy(true); setError('')
    try { await restartBlackoutGame(snapshot.game.id); navigate('/lobby', { replace: true }) }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'The room could not be reset.') }
    finally { setBusy(false) }
  }
  return <GameLayout active="results" live><div className="results-screen"><div className="results-top"><Eyebrow icon>OPERATION REPORT // FINAL</Eyebrow><Badge tone={victory ? 'green' : result.outcome === 'FACILITY_FAILURE' ? 'red' : 'amber'} dot>{outcomeLabel.toUpperCase()}</Badge></div>
    <div className={`results-hero results-hero--${victory ? 'crew' : result.outcome === 'FACILITY_FAILURE' ? 'failure' : 'saboteur'}`}><span className="result-symbol">{victory ? '✓' : result.outcome === 'FACILITY_FAILURE' ? '!' : '×'}</span><div><span className="facility-kicker">BLACKOUT FACILITY · {new Date(result.resolved_at).toLocaleString()}</span><h1>{victory ? <>CREW<br /><span>ESCAPED</span></> : result.outcome === 'FACILITY_FAILURE' ? <>FACILITY<br /><span>FAILURE</span></> : <>SABOTEUR<br /><span>PREVAILED</span></>}</h1><p>{result.summary}</p></div></div>
    {error && <div className="action-error" role="alert"><Icon name="cross" /><span>{error}</span></div>}
    <div className="results-grid"><Panel label="FINAL FACILITY STATUS" className="performance-panel"><div className="result-row"><span>POWER</span><strong>{result.final_facility.power}%</strong></div><div className="result-row"><span>SECURITY</span><strong>{result.final_facility.security}%</strong></div><div className="result-row"><span>FACILITY INTEGRITY</span><strong>{result.final_facility.facility_integrity}%</strong></div><div className="result-row"><span>ESCAPE SEQUENCE</span><strong>{result.final_escape_state.door_opened ? 'EXIT OPEN' : `${snapshot.escape?.progress ?? 0} / 4 STEPS`}</strong></div></Panel>
      <Panel label="IDENTITY REVEAL // ROLES NOW PUBLIC" className="identity-panel"><div className="result-identities">{result.role_reveal.map(player => <div className="identity-row" key={player.player_id}><span><strong>{player.display_name}</strong><small>{player.outcome}</small></span><Badge tone={player.role === 'SABOTEUR' ? 'red' : 'green'}>{player.role}</Badge></div>)}</div></Panel></div>
    {snapshot.discussion?.result && <Panel label="LAST CREW VOTE" className="vote-result-return"><strong>{snapshot.discussion.result.tied ? 'NO CONSENSUS' : `${result.role_reveal.find(player => player.player_id === snapshot.discussion?.result?.winner_player_id)?.display_name ?? 'Operator'} received the highest vote`}</strong><span>Vote records remain attached to this completed operation.</span></Panel>}
    <Panel label="FINAL PUBLIC EVENTS" className="event-feed-panel"><div className="event-feed">{snapshot.public_events.map(event => <div className="event-feed-item" key={event.id}><span className="event-feed-time">{new Date(event.created_at).toLocaleTimeString([], { minute: '2-digit', second: '2-digit' })}</span><span className="event-feed-beacon" /><div><strong>{event.message}</strong><small>{event.event_type.replaceAll('_', ' ')}</small></div></div>)}</div></Panel>
    <div className="results-actions">{snapshot.can_restart ? <Button onClick={() => void playAgain()} disabled={busy}>{busy ? 'RESETTING ROOM…' : 'PLAY AGAIN'} <Icon name="arrow" /></Button> : <div className="host-waiting"><Icon name="radio" /><span><strong>WAITING FOR THE HOST</strong><small>The host can return everyone to the lobby and start a fresh operation.</small></span></div>}<Button to="/" variant="secondary">EXIT TO MAIN MENU</Button></div><p className="results-foot">ROLES WERE REVEALED ONLY AFTER THE SERVER RECORDED THIS RESULT.</p>
  </div></GameLayout>
}

function NotFound() { return <main className="not-found"><Eyebrow icon>ROUTE NOT FOUND</Eyebrow><h1>WRONG<br />SECTOR</h1><p>This part of the facility is not on the map.</p><Button to="/">RETURN TO ENTRY <Icon name="arrow" /></Button></main> }

export default function App() {
  const location = useLocation()
  const isLanding = location.pathname === '/'
  const isForm = location.pathname === '/create' || location.pathname === '/join'
  return <AppFrame showNav={isLanding || isForm}><AnimatePresence mode="wait"><Routes location={location} key={location.pathname}>
    <Route path="/" element={<PageTransition><Landing /></PageTransition>} />
    <Route path="/create" element={<PageTransition><FormPage mode="create" /></PageTransition>} />
    <Route path="/join" element={<PageTransition><FormPage mode="join" /></PageTransition>} />
    <Route path="/lobby" element={<PageTransition><Lobby /></PageTransition>} />
    <Route path="/role" element={<PageTransition><RoleReveal /></PageTransition>} />
    <Route path="/facility" element={<PageTransition><FacilityIntro /></PageTransition>} />
    <Route path="/game" element={<PageTransition><Game /></PageTransition>} />
    <Route path="/vote" element={<PageTransition><Vote /></PageTransition>} />
    <Route path="/blackout" element={<PageTransition><Blackout /></PageTransition>} />
    <Route path="/escape" element={<PageTransition><Escape /></PageTransition>} />
    <Route path="/results" element={<PageTransition><Results /></PageTransition>} />
    <Route path="*" element={<PageTransition><NotFound /></PageTransition>} />
  </Routes></AnimatePresence></AppFrame>
}
