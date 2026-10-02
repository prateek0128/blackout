import { createClient, type SupabaseClient } from '@supabase/supabase-js'

let client: SupabaseClient | undefined

export class SupabaseConfigurationError extends Error {
  constructor() {
    super('Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to .env.local, then restart the development server.')
    this.name = 'SupabaseConfigurationError'
  }
}

export class SupabaseRequestError extends Error {
  readonly stage: 'session' | 'anonymous sign-in'
  readonly status?: number
  readonly code?: string

  constructor(stage: 'session' | 'anonymous sign-in', error: { message?: string; status?: number; code?: string }) {
    super(error.message || 'The request failed without an error message.')
    this.name = 'SupabaseRequestError'
    this.stage = stage
    this.status = error.status
    this.code = error.code
  }
}

export function getSupabaseClient(): SupabaseClient {
  if (client) return client
  const url = import.meta.env.VITE_SUPABASE_URL?.trim()
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()
  if (!url || !anonKey) throw new SupabaseConfigurationError()
  client = createClient(url, anonKey, {
    auth: {
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: true,
    },
    realtime: { params: { eventsPerSecond: 5 } },
  })
  return client
}

export async function ensureAnonymousSession() {
  const supabase = getSupabaseClient()
  const { data, error } = await supabase.auth.getSession()
  if (error) throw new SupabaseRequestError('session', error)
  if (data.session?.user) return data.session

  const { data: signedIn, error: signInError } = await supabase.auth.signInAnonymously()
  if (signInError || !signedIn.session) {
    throw new SupabaseRequestError('anonymous sign-in', signInError ?? { message: 'Supabase returned no session.' })
  }
  return signedIn.session
}
