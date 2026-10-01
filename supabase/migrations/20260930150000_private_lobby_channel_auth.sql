-- A private channel join is authorized through SELECT on realtime.messages.
-- Supabase evaluates a broadcast-extension read when checking channel access,
-- even when the channel currently uses Presence and Postgres Changes only.
-- Keep the grant limited to authenticated members of this room's lobby topic.

drop policy if exists "Room members can receive private lobby presence"
  on realtime.messages;

create policy "Room members can receive private lobby channel messages"
  on realtime.messages for select to authenticated
  using (
    extension in ('broadcast', 'presence')
    and public.is_current_user_lobby_channel_member()
  );
