-- Secrets a user syncs between their own devices, end-to-end encrypted on the device (SPEC §7b).
-- Today only the Anthropic API key for quick add, sealed with the user's sync PIN; the server stores
-- an opaque blob and never sees the PIN or the key. One row per user, deleted with the account.
create table public.user_secrets (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  claude_key jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.user_secrets enable row level security;

create policy user_secrets_own on public.user_secrets
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

revoke all on public.user_secrets from anon, public;
grant select, insert, update, delete on public.user_secrets to authenticated;
