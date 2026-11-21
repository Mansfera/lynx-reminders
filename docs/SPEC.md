# Lynx Reminders — product and engineering spec

One spec for three clients (macOS, iOS/iPadOS, Android) and one backend. When a client and this
file disagree, this file wins; change it first, then the clients.

Identifiers: bundle id / applicationId `com.mansfera.lynxreminders`; app data folder
`~/Library/Application Support/com.mansfera.lynxreminders`; keychain service
`com.mansfera.lynxreminders`; URL scheme `lynxreminders://`.

---

## 1. Architecture

```
            ┌────────────── Supabase (Postgres + Auth + Realtime) ──────────────┐
            │ tables + RLS + RPCs (backend/supabase/migrations)                 │
            └───────▲───────────────────────▲───────────────────────▲───────────┘
                    │ PostgREST / Realtime  │                       │
   macOS app (SwiftUI) ── iOS/iPadOS app (same SwiftUI code)    Android app (Compose)
          └─ LynxCore (Swift package)                              └─ core (Kotlin module)
```

* **Local-first.** Every client keeps the full data set it can see in a local store and works
  offline. Sync is a background reconciliation, never a blocker for UI.
* **No account needed to start.** The app works fully local. Signing in uploads local data
  (rows get the user's id) and turns sync on. Signing out offers "Keep a local copy" or
  "Remove from this device".
* **Triggers run on the device.** Time, location, Bluetooth and app triggers are evaluated by
  each client and turned into local notifications. The server stores rules, never fires them.
  Shared reminders therefore alert every participant on their own devices.
* **Backend:** Supabase (hosted or self-hosted; URL + anon key are config). Dev uses the
  local stack from `backend/` (`bunx supabase@2 start`, API at `http://127.0.0.1:54321`; Android
  emulator reaches it at `http://10.0.2.2:54321`).

## 2. Data model

All ids are UUID v4 generated on the client. Timestamps are ISO-8601 UTC instants
(`2026-11-14T08:00:00Z`; servers may return fractional seconds and `+00:00` — parse both).
Client JSON uses the same snake_case field names as the server columns.

### profiles
| column | type | notes |
|---|---|---|
| id | uuid PK | = auth.users.id |
| email | text | lowercased |
| display_name | text | defaults to the part of the email before `@` |
| created_at, updated_at | timestamptz | |

### lists
| column | type | notes |
|---|---|---|
| id | uuid PK | |
| owner_id | uuid | → profiles |
| name | text | |
| color | text | a token from §8 (`ink`, `slate`, `blue`, `green`, `yellow`, `orange`, `red`, `pink`, `brown`) |
| icon | text | a key from §8 icon set (`list`, `cart`, `house`, `briefcase`, `book`, `heart`, `star`, `flag`, `gift`, `plane`, `leaf`, `bolt`) |
| sort_order | double | fractional ordering |
| created_at, updated_at | timestamptz | `updated_at` set by the client on every edit |
| deleted_at | timestamptz null | soft delete |
| version | bigint | server-assigned, see §4 |

### list_members
`(list_id, user_id)` PK, `role` (`owner`|`editor`), `added_by`, `created_at`, `version`.
The owner always has a row (inserted by a trigger when a list is created).

### reminders
| column | type | notes |
|---|---|---|
| id | uuid PK | |
| list_id | uuid | → lists. Every reminder lives in a list. |
| parent_id | uuid null | → reminders. Subtask of a goal. One level deep only (a subtask cannot have subtasks). A subtask's `list_id` equals its parent's. |
| created_by | uuid | |
| assignee_id | uuid null | someone with access; shown as an avatar chip |
| title | text | |
| notes | text null | |
| url | text null | |
| priority | smallint | 0 none, 1 low, 2 medium, 3 high |
| flagged | bool | |
| completed_at | timestamptz null | not null ⇒ completed |
| completed_by | uuid null | |
| due_at | timestamptz null | instant of the current occurrence |
| all_day | bool | if true `due_at` is local midnight of the date in `time_zone`; the alert fires at the all-day alert time setting (default 09:00) |
| time_zone | text | IANA zone the reminder was scheduled in (e.g. `Europe/Bratislava`) |
| early_alert_minutes | int null | extra alert N minutes before due |
| repeat | jsonb null | §5 |
| nag | jsonb null | §5.4 |
| location | jsonb null | §6.2 |
| bluetooth | jsonb null | §6.3 |
| app_trigger | jsonb null | §6.4 |
| sort_order | double | |
| created_at, updated_at, deleted_at, version | | as lists |

**Goal** = any reminder that has at least one non-deleted subtask. Its progress is
`completed subtasks / subtasks`, shown as a ring (§8). Completing the last open subtask does
**not** auto-complete the goal; the ring is full and the goal's checkbox gets a subtle pulse.
Completing a goal asks "Complete all N open subtasks too?" (Complete all / Only the goal).

### reminder_shares
`(reminder_id, user_id)` PK, `added_by`, `created_at`, `version`. Shares one reminder (and its
subtasks) with a person **without** sharing the list. The recipient sees it in the
**Shared with me** smart list; it stays in the owner's list for the owner.

### invites
`id`, `email`, `list_id` null, `reminder_id` null, `invited_by`, `created_at`. Pending shares for
emails that have no account yet; converted into memberships/shares when that email signs up.
Visible to the inviter (shown as "Invited · pending").

## 3. Access rules (enforced by RLS — clients just query)

* A user can see a **list** if they are in `list_members` for it.
* A user can see a **reminder** if they can see its list, or it (or its parent) is in
  `reminder_shares` for them.
* Anyone who can see a reminder can edit it, complete it, add subtasks to it (if it is not
  itself a subtask), and soft-delete it. Members can create reminders in a list they can see.
* Any member can edit a list's name/color/icon; only the owner can soft-delete the list or
  remove other members. Members can leave.
* Only someone who can see a reminder can share it; only the list owner can share the list.
* Profiles are visible for yourself and for people you share any list or reminder with.

### RPCs (Postgres functions, `POST /rest/v1/rpc/<name>`)
| name | args | returns |
|---|---|---|
| `share_list` | `p_list uuid, p_email text` | `{"status":"added"\|"invited"\|"already", "user_id": uuid\|null}` |
| `unshare_list` | `p_list uuid, p_user uuid` | void (owner only; cannot remove the owner) |
| `leave_list` | `p_list uuid` | void (not the owner) |
| `share_reminder` | `p_reminder uuid, p_email text` | same shape as `share_list` |
| `unshare_reminder` | `p_reminder uuid, p_user uuid` | void (the sharer, the list owner, or the recipient themself) |
| `cancel_invite` | `p_invite uuid` | void |
| `sync_manifest` | — | `[{"t":"lists"\|"reminders", "id": uuid, "v": bigint}]` every row the caller can see, including soft-deleted |
| `delete_account` | — | void; deletes the caller and everything they own |

## 4. Sync protocol

Server side: every insert/update of `lists`, `reminders`, `list_members`, `reminder_shares`
sets `version = nextval('sync_version')`. Updates whose `updated_at` is **older** than the
stored row's are ignored (last-writer-wins by client `updated_at`). Hard deletes are never used
for lists/reminders; soft-deleted rows are purged by the server after 30 days.

Client side, per signed-in account:

* Local row = server row + local-only `dirty: Bool`. Every user edit sets `updated_at = now`,
  `dirty = true`, saves locally, and schedules a sync (debounce 1 s).
* State: `cursor_lists`, `cursor_reminders` (max `version` seen), `last_manifest_at`.
* **Sync run** (serialized; one at a time):
  1. **Pull** `GET /lists?version=gt.{cursor}&order=version.asc&limit=500` (repeat until
     fewer than 500), same for `reminders`. For each server row: if no local row, or local is
     clean, or `server.updated_at >= local.updated_at` → replace local (clean). Otherwise keep the
     local dirty row.
  2. **Memberships:** `GET /list_members?select=*,profile:profiles(*)` and
     `GET /reminder_shares?select=*,profile:profiles(*)` in full (small tables), plus
     `GET /invites`. Replace local copies. If the set of (list_id,user) or (reminder_id,user)
     involving the current user changed → run the manifest step.
  3. **Manifest** (also on launch, on realtime reconnect, and at least every 6 h):
     `rpc/sync_manifest`. For every id whose server `v` differs from the local `version` →
     fetch those rows by id (`id=in.(…)`, batches of 100) and merge as in step 1. Every local
     **clean** row whose id is missing from the manifest → remove locally (access lost).
  4. **Push** dirty rows: lists first, then reminders (parents before subtasks), via
     `POST /lists` with `Prefer: resolution=merge-duplicates,return=representation`
     (`on_conflict=id`), batches of 100. Mark clean with the returned `version`. A pushed row
     missing from the response was older than the server's copy (skipped by last-writer-wins):
     mark it clean and re-fetch that id.
     Note: an upsert is checked against the INSERT policy too, which the server allows for any
     row the caller can already see; clients don't need to special-case it.
     A row rejected by RLS (403/42501) → drop the local change, re-fetch that id.
* **Realtime:** subscribe to `postgres_changes` (`*`) on the four synced tables. Any event →
  schedule a sync (debounce 500 ms). Never apply realtime payloads directly.
* **Notifications are rebuilt** from the local store after every sync run that changed rows.
* Never sync local-only state: notification ids, trigger cooldowns, device-specific ids.

## 5. Repeat rules

Reference implementation: `shared/reference/recurrence.py`. Test vectors:
`shared/vectors/recurrence.json` — **every client must pass all vectors in its unit tests.**

```jsonc
"repeat": {
  "unit": "minute" | "hour" | "day" | "week" | "month" | "year",
  "interval": 1,                     // every N units, N ≥ 1 (custom period: e.g. 90 minutes, 3 days)
  "anchor": "2026-11-14T09:00",      // local wall time (in reminder.time_zone) the series counts from
  "weekdays": [1, 4],                // ISO 1=Mon..7=Sun. week: which days; minute/hour with window: which days
  "window": {"start": "09:00", "end": "18:00"}, // minute/hour only: restart each day at start, last slot <= end
  "end": {"type": "never"} | {"type": "on", "date": "2026-12-31"} | {"type": "after", "count": 10},
  "from": "due" | "completion",      // default "due"
  "advance": "complete" | "auto",    // default "complete"
  "completed_count": 0               // bumped on each completion
}
```

### 5.1 Occurrence generator (from `anchor`, ascending)
* `minute`/`hour` without window: `anchor + k·interval` in **absolute** time (DST does not shift
  the rhythm).
* `minute`/`hour` with window: each local day (only `weekdays` if set) from the anchor's date:
  `window.start + k·interval` while the local time is ≤ `window.end` and on the same day;
  skip slots before the anchor.
* `day`: anchor date + k·interval days at the anchor's local time.
* `week` without weekdays: + k·interval weeks. With weekdays: weeks start Monday; week index
  `w` counted from the anchor's week; in weeks where `w % interval == 0`, each listed weekday at
  the anchor's local time; skip slots before the anchor.
* `month`/`year`: anchor + k·interval months (years = 12 months), day clamped to month length,
  always computed from the anchor (Jan 31 → Feb 28 → Mar 31, never drifting).
* Local wall time → instant: gaps resolve forward, overlaps take the earlier offset
  (java.time `ZonedDateTime.of`, Foundation `Calendar` default).
* `end.on`: occurrences whose local date is after `end.date` don't exist.

### 5.2 Effective due
`advance: "complete"`: the current occurrence is `due_at`; it stays overdue until completed.
`advance: "auto"` (good for "drink water every 45 min"): the current slot is the latest
occurrence ≤ now that is ≥ `due_at`; nothing is ever overdue by more than one slot.
UI and planners use the effective due; the stored `due_at` changes only on completion.

### 5.3 Completing a repeating reminder
Bump `completed_count`. If `end.after` and `completed_count >= count` → completed for good.
`from: "due"`: `due_at = next occurrence after the effective due`; none → completed for good.
`from: "completion"`: minute/hour → `completed_at + interval`; day+ → completion's local date +
interval at the anchor's time of day; the new value also becomes the new `anchor`.
A repeating reminder that advances is **not** marked completed (`completed_at` stays null).

### 5.4 Nag (alert again until done)
```jsonc
"nag": {"every_minutes": 10, "max": 6}   // max null = as many as fit in 24 h, capped at 48
```
After an alert fires (time, early alert excluded, or a context trigger), alert again at
`fired + k·every` for k = 1…max while the reminder is not completed. Snoozing restarts the nag
from the snooze time.

### 5.5 Notification planner (time-based)
For each open reminder with a due date, schedule: the effective due (if in the future), the
early alert, the nag series after the effective due, and for `advance: auto` the next
occurrences. Budget: iOS allows 64 pending local notifications per app → plan the soonest 60
(keep 4 for snoozes); macOS/Android use the same 60 cap for parity. Rebuild after every change,
sync, app launch and every time the app becomes active. Notification id:
`<reminder_id>|<kind>|<n>` with kind `due`, `early`, `nag`, `auto`, `snooze`, `ctx`.

Notification actions: **Done**, **Snooze 10 min**, **Snooze 1 h** (and on tap: open the
reminder). Done from a notification must work without opening the UI (mark completed locally,
then sync in the background).

## 6. Context triggers

A context trigger fires when its condition happens, the reminder is open, and the same reminder
hasn't fired the same trigger in the last 15 min (cooldown, local-only). A context trigger
fires independently of the due date (a reminder can have both; each alerts on its own). Firing
posts a local notification `<id>|ctx|0` and starts the nag if set.

### 6.1 Platform matrix
| trigger | macOS | iOS / iPadOS | Android |
|---|---|---|---|
| time / repeat / nag | ✅ UNUserNotificationCenter | ✅ same | ✅ AlarmManager exact alarms + NotificationManager |
| location arrive/leave | ✅ CLMonitor (app running; launch at login) | ✅ CLMonitor (wakes the app; ≤ 20 regions → nearest 20) | ✅ Play Services Geofencing (≤ 100) |
| Bluetooth connect/disconnect | ✅ IOBluetooth connect/disconnect notifications (app running) | ⚠️ via Shortcuts automation "Bluetooth → Run *Fire Lynx trigger*" (App Intent) | ✅ manifest receiver `ACL_CONNECTED` / `ACL_DISCONNECTED` |
| app opened | ✅ NSWorkspace `didActivateApplication` | ⚠️ via Shortcuts automation "App is opened → Run *Fire Lynx trigger*" | ✅ UsageStatsManager polling in a foreground service while app triggers exist |

iOS cannot observe other apps or Bluetooth connections; the App Intent `FireTriggerIntent`
(`kind: bluetooth|app`, `name: String`, `event: connect|disconnect|open`) is the supported path,
and the trigger editor on iOS shows a one-tap guide for setting up the automation.

### 6.2 Location
```jsonc
"location": {"name": "Home", "address": "Obchodná 2, Bratislava", "lat": 48.1486, "lon": 17.1077,
             "radius": 150, "on": "arrive" | "leave"}
```
Radius 100–2000 m (default 150). Picker: search (MKLocalSearch / Android Geocoder), current
location, and a map with a draggable pin + radius ring.

### 6.3 Bluetooth
```jsonc
"bluetooth": {"name": "AirPods Pro", "on": "connect" | "disconnect",
              "ids": {"mac": "a4-c3-61-…", "android": "A4:C3:61:…"}}
```
Match by the platform id when this platform's id is present, otherwise by name
(case-insensitive, exact). The picker lists paired devices on platforms that can (macOS:
`IOBluetoothDevice.pairedDevices()`, Android: `bondedDevices`) and records this platform's id; a
free-text name is always allowed (needed on iOS).

### 6.4 App opened
```jsonc
"app_trigger": {"name": "Slack", "on": "open", "apple": "com.tinyspeck.slackmacgap", "android": "com.Slack"}
```
Match by this platform's identifier; if absent, by app display name (case-insensitive).
Picker: macOS lists `/Applications` + running apps; Android lists launchable apps.

## 7. Smart lists and views

Sidebar order: **Today**, **Scheduled**, **All**, **Flagged** (2×2 counts grid, like Lynx
Battery's stats panel), then **Goals**, **Shared with me**, **Assigned to me**, **Completed**,
then **My lists** (owned, unshared), **Shared lists** (with member avatars).

* Today: open reminders whose effective due is today or overdue.
* Scheduled: open with due date, grouped by day.
* All: open, grouped by list.
* Flagged: open & flagged.
* Goals: open reminders that have subtasks, with progress ring.
* Shared with me: reminders shared with me via `reminder_shares` (not via a list).
* Assigned to me: open with `assignee_id = me`.
* Completed: completed, newest first, grouped by day.

Search (⌘F on Mac) filters titles and notes across everything.

Quick add parses natural language lightly: "tomorrow", "today", "tonight", "mon"…"sun",
"at 9", "9:30", "in 2 hours", "every day/week/month", "every 45 min", "!" / "!!" / "!!!"
priority, "#list" picks a list. Parsing is optional sugar; the editor is the source of truth.

## 8. Design system (shared with Lynx Battery)

The Lynx Battery / etherlynx.xyz system. Monochrome Ink on white with the sky scene; color is
functional (list colors, overdue red), never decoration.

**Fonts:** Onest (all text and display), Geist Mono (times, counts, dates in rows). Bundle the
TTFs from `shared/fonts/`.

**Tokens**
| token | light | dark |
|---|---|---|
| bg | #FFFFFF | #101012 |
| panel | #FFFFFF | #1A1A1D |
| sunk | #F1F3F7 | #17171A |
| fg (ink) | #0E0E10 | #FFFFFF |
| ink2 | #3A3D45 | rgba(255,255,255,.78) |
| muted | #6A6F7C | rgba(255,255,255,.55) |
| line | rgba(14,14,16,.12) | rgba(255,255,255,.10) |
| mist | #B3BCCD | #B3BCCD |
| signal (overdue only) | #E8271E | #FF453A |
| stage | linear #A9B3C6 → #C9D0DC (45%) → #EEF0F3 | radial #2A2D35 → #0E0E10 from bottom |

**List colors:** ink #0E0E10 (dark: #FFFFFF), slate #5E6B85, blue #2F7CF6, green #30D158,
yellow #F5B400, orange #F07C2A, red #E8271E, pink #E0559A, brown #9A7B5B.

**Shapes:** stage radius 28 (one per screen, the hero), panels radius 20 with a hairline `line`
border and no shadow, rows inside panels separated by hairlines, pills fully rounded. Spacing
scale 4/6/10/12/14/18/24. Type scale: hero number 84 (tracking −4), stat 28 (tracking −0.8),
title 17 semibold, row 13.5, caption 10.5–11, mono 10–11.

**Signature components (reuse Lynx Battery's look):**
* **Capsule tabs**: selected = Ink capsule with white text, others muted text.
* **Ink pill**: Ink capsule, white text, white circle with a glyph on the right. Primary action.
* **Round icon button**: 30 pt Ink circle with a white SF Symbol / Material Symbol.
* **Today stage** (hero): sky gradient, big Onest number = open for today, caption
  "3 overdue · next at 14:30", and a **day ruler**: the Lynx tick ruler re-used as 24 h of today
  (major tick every 6 h, labels `00 06 12 18 24` in Geist Mono), each reminder a dot at its time,
  covered part (past) drawn as a line, overdue dots in signal red, a "now" marker.
* **Stats grid** (sidebar top): 2×2 panel with hairline dividers; each cell = 28 pt count +
  10.5 pt caption (Today / Scheduled / All / Flagged). Selected cell gets the `sunk` fill.
* **Checkbox**: 20 pt circle, 1.5 pt stroke in list color; completed = filled list color with a
  white check; overdue rows show the due time in signal red.
* **Goal ring**: 22 pt ring, 2.5 pt stroke, track = `line`, progress = list color, Geist Mono
  `3/5` to the right of the title. In the detail view a 64 pt ring with the fraction inside.
* **Trigger chips** under the title in Geist Mono 10.5 muted: `09:00 · ↻ 45 min · ⌖ Home ·
  ᛒ AirPods · ▣ Slack · ⟳ nag 10 min` — use SF Symbols / Material Symbols, not those glyphs:
  clock, arrow.clockwise, location, headphones (Bluetooth), app.badge, bell.badge.
* Empty states: a short sentence in muted text, no illustration.

No emoji anywhere in UI. No gradients other than the stage. No shadows except system popovers.

## 9. Accounts

* Supabase email + password, and email one-time code ("Email me a code") as a passwordless
  option. Sign in with Apple / Google come later (need a paid Apple account / OAuth clients).
* **Passkeys** (WebAuthn, Supabase Auth's own passkey support; no server code of ours). A passkey
  is added to an existing account from the Account screen ("Add a passkey", list with "Remove"),
  then used from the Sign in screen ("Use a passkey", secondary to the Ink pill; no email needed,
  the passkey names the account). Creating an account still starts with an email.
  * Relying party: `reminders.etherlynx.xyz` (`[auth.webauthn]` in `backend/supabase/config.toml`;
    changing it orphans every passkey). That domain serves `web/`: the passkey page at `/passkey/`
    and `/.well-known/assetlinks.json`.
  * **Android:** Credential Manager (`androidx.credentials`) with the options and results of
    `auth/v1/passkeys/{registration,authentication}/{options,verify}`. Needs `assetlinks.json`
    listing the APK's signing certificate and that certificate's `android:apk-key-hash:` origin in
    `rp_origins`.
  * **Apple (iOS, iPadOS, macOS):** native passkeys need the Associated Domains entitlement
    (`webcredentials:reminders.etherlynx.xyz`), which only a paid Apple developer team can sign.
    Until there is one, the apps open the passkey page in an ephemeral `ASWebAuthenticationSession`
    sheet: `/passkey/?mode=signin&state=S` or `?mode=add&state=S#access_token=T`. The page runs
    WebAuthn in the browser, where the domain is its own origin, and returns to
    `lynxreminders://auth-callback?state=S` with `#access_token=…&refresh_token=…` (sign in),
    `&added=1` (add) or `&error=…`. The app checks `state` before using the reply. The passkeys are
    the same ones a native prompt would use later, so moving to native needs no new passkeys.
    Builds without `passkey_page` in `Supabase.json` (e.g. the local stack) hide passkeys.
* Screens: Welcome (stage with mark, "Continue without account" link, Ink pill "Sign in"),
  Sign in / Create account (one screen with a capsule switch, plus "Use a passkey"), Account
  (name, email, passkeys, sign out, delete account).
* Session stored in Keychain (Apple) / EncryptedSharedPreferences or DataStore + Tink (Android).

## 10. Settings
Default list; all-day alert time (09:00); default early alert (none); default snooze (10 min);
launch at login + menu bar extra (macOS); show completed; first day of week follows system; app
icon variant (later).

## 11. Testing
* Each client: unit tests that load `shared/vectors/recurrence.json` and check every case
  (generator via `next`, `effective_due`, `complete`, `nag`); unit tests for the sync merge
  rules in §4 using a fake remote; unit tests for trigger matching (§6.3/§6.4 matching rules).
* Each client: unit tests that decode every row in `shared/vectors/server-rows.json` — real rows
  written by the other clients (Android writes absent optionals as explicit `null`, Apple omits
  them; both are valid and both must decode). Refresh it from the dev database when the schema
  changes.
* Backend: `backend/tests/` runs three users against the local stack and checks every rule in §3.
