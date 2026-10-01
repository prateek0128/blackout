# BLACKOUT: The Last 5 Minutes

Phase 2 implements anonymous player sessions, room creation and joining, a realtime lobby, ready state, host migration, and server-validated room start. The actual game, roles, and scoring are not implemented.

## Configure Supabase

1. Create a dedicated Supabase project for BLACKOUT. Do not reuse another game's project.
2. Enable **Anonymous Sign-Ins** in the project's Auth settings.
3. Copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. The anon/publishable key is intended for the browser; never put a service-role key in a `VITE_` variable.
4. In Realtime Settings, disable **Allow public access to channels** so clients must use the member-checked private lobby channel.
5. Apply `supabase/migrations/20260930120000_room_lobby.sql` to the BLACKOUT project with the Supabase CLI after linking this folder to that project.
6. Start the app with `npm run dev`.

No real environment file or project credentials are included in this repository.

## Local database development

Docker must be running before the local Supabase stack can start. Run `supabase start`, then `supabase db reset` to apply migrations and `npm run test:db` to run the pgTAP lifecycle and RLS checks. Local Auth is configured for anonymous sign-ins in `supabase/config.toml`.

## Room lifecycle

- The browser keeps a persistent Supabase anonymous session.
- Room creation, joining, ready changes, leaving, heartbeats, and start requests use PostgreSQL RPCs.
- Room codes are five characters, case-insensitive, and avoid ambiguous characters.
- RLS permits authenticated room members to read their room and roster. Browser roles cannot write either table directly.
- Realtime Postgres Changes refresh the server-built lobby snapshot; Realtime Presence reports ephemeral channel connections. A 12-second database heartbeat supplies durable connection state and triggers deterministic host migration after a 45-second timeout.
- Start is accepted only by the current host when at least three players are recently connected and every connected player is ready. The server moves the room to `STARTING`; Phase 2 does not launch gameplay.

## Commands

```sh
npm run dev
npm run build
npm run test:db
```
