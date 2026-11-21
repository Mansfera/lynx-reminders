# Lynx Reminders backend

Supabase: Postgres with row-level security for sharing, Auth for accounts, Realtime to tell
devices when to sync. All logic is in one migration,
[`supabase/migrations/20261114000000_init.sql`](supabase/migrations/20261114000000_init.sql);
the contract is [docs/SPEC.md](../docs/SPEC.md) §2–§4.

## Local development

Needs Docker (OrbStack is fine).

```sh
cd backend
bunx supabase@2 start -x studio,imgproxy,edge-runtime,logflare,vector,supavisor,storage-api,postgres-meta
```

API `http://127.0.0.1:54321` (the Android emulator reaches it at `http://10.0.2.2:54321`),
Postgres `postgresql://postgres:postgres@127.0.0.1:54322/postgres`, sign-in emails in Mailpit
at `http://127.0.0.1:54324`. Drop `studio` and `postgres-meta` from `-x` if you want the
dashboard at `http://127.0.0.1:54323`.

After editing the migration: `bunx supabase@2 db reset`.

## Tests

```sh
cd backend/tests && bun install && bun run test
```

15 cases with three throwaway users: private lists stay private, nobody can take over or move
someone else's data, list sharing, single-reminder sharing (recipient sees the goal and its
subtasks, nothing else), invites for emails without an account, unshare/leave and the sync
manifest, one-level subtasks, last-writer-wins and versions, soft-delete cascades, moving goals,
hard deletes refused, anonymous access refused, account deletion, realtime delivery under RLS.

## How it works

| piece | what it does |
|---|---|
| `sync_version` sequence | every write to lists, reminders, members, shares gets a new `version`; clients pull `version > cursor` |
| `*_before_write` triggers | last-writer-wins by the client's `updated_at`; server-owned columns (`owner_id`, `created_by`, `created_at`) can't be changed by an upsert; subtasks get their goal's list |
| `lists_after_insert` | the owner is always a member, so every access rule is one membership check |
| soft-delete cascades | deleting a list or a goal deletes what's inside; rows are purged after 30 days by `pg_cron` |
| `handle_new_user` | creates the profile and turns pending invites for that email into shares |
| RLS | see SPEC §3; helpers are `SECURITY DEFINER` so policies don't recurse |
| RPCs | `share_list`, `unshare_list`, `leave_list`, `share_reminder`, `unshare_reminder`, `cancel_invite`, `sync_manifest`, `delete_account` |

## Going live

Recommended: **Supabase Cloud**, EU (Frankfurt) region. The free tier (500 MB, 50k monthly
users) is far more than a reminders app needs, and it removes database backups, TLS and email
from your plate. Free projects pause after a week with no requests, which daily use prevents.

The hosted project is `tjpgpuhkxiqkwanulvmt` (Frankfurt); both apps point at it.

```sh
bunx supabase@2 login
bunx supabase@2 link --project-ref tjpgpuhkxiqkwanulvmt   # asks for the database password
bunx supabase@2 db push --linked
bunx supabase@2 config push                               # review the diff, answer y for auth
```

**Passkeys** (SPEC §9) are Supabase Auth's own: `[auth.passkey]` and `[auth.webauthn]` in
`config.toml`. CLI 2.122.1's `config push` doesn't send them ("Remote Auth config is up to date"),
so on the hosted project set the same values in the dashboard, **Authentication → Passkeys**:
enabled, display name `Lynx Reminders`, RP ID `reminders.etherlynx.xyz`, origins
`https://reminders.etherlynx.xyz,android:apk-key-hash:…` (copy from `config.toml`). Check with
`GET /auth/v1/settings` → `"passkeys_enabled": true`. The relying party must serve
[`web/`](../web/README.md). The local stack has the same settings, but its Auth server can't
see real passkeys for that domain, so local builds hide passkeys (no `passkey_page`).

`[remotes.production]` in `config.toml` holds what differs from local: the site URL and the
one-minute email resend floor. `pg_cron` works on the hosted project; the migration schedules
the nightly purge itself.

**Email.** The hosted project sends through Cloudflare Email Service over SMTP, as
`Lynx Reminders <no-reply@etherlynx.xyz>` (Email Sending is enabled on `etherlynx.xyz` in the
etherlynx Cloudflare account). The SMTP password is a Cloudflare API token with
"Email Sending: Edit"; `config.toml` reads it from `CLOUDFLARE_EMAIL_TOKEN`, so every
`config push` needs it in the environment:

```sh
read -rs CLOUDFLARE_EMAIL_TOKEN && export CLOUDFLARE_EMAIL_TOKEN
bunx supabase@2 config push
```

Supabase's own sender only reaches members of your Supabase organisation and refuses custom
templates on the free plan, which is why custom SMTP is required.

Run the tests against the hosted project with your secret key, typed so it stays out of history:

```sh
cd backend/tests
read -rs SUPABASE_SERVICE_ROLE_KEY && export SUPABASE_SERVICE_ROLE_KEY
SUPABASE_URL=https://tjpgpuhkxiqkwanulvmt.supabase.co SUPABASE_ANON_KEY=<publishable key> bun run test
```

They create confirmed users through the admin API (no email is sent) and delete them afterwards.

Alternative: self-host with the Supabase template in Coolify. It works with the same
migration, but then your server's uptime and backups are the app's.

Later, for "Ann shared a list with you" pushes when the app isn't running: a database webhook
→ Edge Function → APNs (needs the paid Apple account) and FCM (needs a Firebase project).
Until then, devices learn about changes when they open or via Realtime while running, and every
device schedules its own alerts.
