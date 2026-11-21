# Lynx Reminders — Android

Native Kotlin + Jetpack Compose client. The contract is `../docs/SPEC.md`; this file covers
building, testing and the Android-specific parts.

```
android/
  core/   pure Kotlin/JVM: models, repeat rules (§5), notification planner (§5.5),
          sync engine (§4), trigger matching (§6), smart lists + quick add (§7). JUnit tests.
  app/    Compose UI, local JSON store, Supabase (auth/postgrest/realtime), alarms,
          notifications, geofences, Bluetooth receiver, app-opened watcher, WorkManager sync.
  supabase.properties   backend URL + anon key → BuildConfig
  screenshots/          emulator screenshots (light, dark, tablet)
```

## Toolchain

| | version | why |
|---|---|---|
| Gradle | 9.6.1 (wrapper) | |
| AGP | 9.5.1 | built-in Kotlin support |
| Kotlin | 2.4.21 | supabase-kt 3.9 is built with 2.4 |
| Compose BOM | 2026.06.01 (UI 1.11, Material 3 1.4) | newer BOMs need compileSdk 37 |
| supabase-kt | 3.9.0 (Ktor 3.6 OkHttp engine, OkHttp pinned to 5.3.2) | OkHttp ≥ 5.4 needs compileSdk 37 |
| JDK | 21 (`org.gradle.java.home` in `gradle.properties`) | |
| compileSdk / targetSdk / minSdk | 36 / 36 / 29 | |

`gradle.properties` points at Homebrew's OpenJDK 21; change `org.gradle.java.home` on another
machine. `local.properties` holds `sdk.dir`.

**Which backend.** Builds use the hosted project in `supabase.properties`. To build against the
local stack, put `supabase.url=http://10.0.2.2:54321` and its key in `supabase.local.properties`
(git-ignored), which overrides it. A copy for the local stack is kept as `supabase.local.off.properties`.

## Build, test, run

```sh
cd android
./gradlew :core:test            # recurrence vectors, sync merge rules, triggers, smart lists, quick add
./gradlew :app:assembleDebug    # → app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`core` tests read `../shared/vectors/recurrence.json` (path passed as the `lynx.vectors` system
property), so every vector the reference implementation produces is checked: `next` (6 upcoming
occurrences each), `effective_due`, `complete` (completed flag, new due, new rule incl. anchor and
`completed_count`) and `nag`.

Backend: start the local stack in `../backend` (`bunx supabase@2 start`). The emulator reaches the
host at `10.0.2.2`, which is what `supabase.properties` uses. For a device or a hosted project,
edit `supabase.properties` (URL + anon key) and rebuild. Cleartext HTTP is allowed only for
`10.0.2.2`, `127.0.0.1` and `localhost` (`res/xml/network_security_config.xml`).

Without a reachable server the app works fully locally; edits are queued (dirty flags) and pushed
by the next sync.

## How it works

* **Local store**: `files/lynx-db.json` (rows keyed by id + dirty sets + sync cursors), exposed as a
  `StateFlow`, written debounced (300 ms) and atomically (temp file + rename). Device-only state
  (settings, snoozes, trigger cooldowns, scheduled alarm ids, registered geofences) lives in
  `files/device-state.json` and is never synced.
* **Accounts**: email + password, email one-time code, or no account. The session is encrypted with
  an AES-GCM key held in the Android Keystore (`files/session.bin`, excluded from backup). Signing in
  adopts local rows (owner/creator = the new user, marked dirty). Signing out offers
  *Keep a local copy* (rows become local-only) or *Remove from this device*. Delete account calls
  `rpc/delete_account`.
* **Sync** (`core/Sync.kt`, SPEC §4): pull by version cursor (pages of 500) → memberships + invites
  → manifest (on launch, on realtime reconnect, after a membership change, every 6 h) → push lists,
  then parent reminders, then subtasks (batches of 100, `on_conflict=id`, merge-duplicates). An RLS
  rejection drops the local change and re-fetches; a row missing from the upsert response (skipped
  by last-writer-wins) is marked clean and re-fetched. Runs are serialized. Triggers: edits (1 s
  debounce), realtime `postgres_changes` on the four tables (500 ms), connectivity regained, app
  foreground, and a WorkManager periodic job (15 min, network required) as a backstop.
* **Notifications** (§5.5): the core planner produces the soonest 60 alerts (due, early, nag, auto,
  snooze); `AlarmScheduler` diff-schedules them with `setExactAndAllowWhileIdle` (or inexact
  `setAndAllowWhileIdle` when exact alarms are not allowed). Rebuilt after every edit, every sync
  that changed rows, app start/foreground, boot, time/time-zone change, app update and exact-alarm
  permission change. One notification per reminder (tag = reminder id) with **Done**,
  **Snooze 10 min**, **Snooze 1 h**, handled by `ActionReceiver` without opening the UI (Done also
  enqueues a one-off WorkManager sync).
* **Context triggers** (§6): geofences (Play Services, ≤ 100, no initial trigger),
  `ACL_CONNECTED`/`ACL_DISCONNECTED` manifest receiver, and `AppWatchService` — a `specialUse`
  foreground service with a minimum-importance notification that polls
  `UsageStatsManager.queryEvents` every 3 s and runs only while open reminders with app triggers
  exist and Usage access is granted. Matching and the 15-minute cooldown are in `core/Triggers.kt`;
  a firing posts `<id>|ctx|0` and starts the nag.

## Permissions

| permission | used for | when asked |
|---|---|---|
| `POST_NOTIFICATIONS` | every alert | after the welcome screen; also Account → Permissions |
| `USE_EXACT_ALARM` (33+), `SCHEDULE_EXACT_ALARM` (≤ 32) | alerts at the exact minute | granted with install on 33+; on 31–32 a home banner opens the system screen; denied → inexact alarms |
| `RECEIVE_BOOT_COMPLETED` | rebuild alarms/geofences after reboot | install |
| `ACCESS_FINE_LOCATION` → `ACCESS_BACKGROUND_LOCATION` | arrive/leave geofences | in the location picker, two steps with an explanation ("Allow all the time" is a separate system screen on Android 11+) |
| `BLUETOOTH_CONNECT` | paired-device picker, device name in connect/disconnect broadcasts | in the Bluetooth picker |
| `PACKAGE_USAGE_STATS` (Usage access, special) | "when I open app X" | the app picker links to the Usage access screen |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE` | the app-opened watcher | install |
| `INTERNET`, `ACCESS_NETWORK_STATE` | sync | install |

`<queries>` declares the launcher intent so the app picker can list launchable apps.

## Platform limits (SPEC §6.1)

* Time, repeat and nag alerts: AlarmManager exact alarms, capped at the 60 soonest (same cap as iOS
  for parity); later ones are scheduled as earlier ones fire or the app runs again.
* Location: Play Services Geofencing, at most 100 regions (the nearest 100 when there are more —
  selection in `TriggerMatching.geofenceSelection`), radius 100–2000 m. Needs Google Play services
  and "Improve location accuracy" (network location) on the device; on the stock emulator image
  geofencing returns `GEOFENCE_NOT_AVAILABLE` (1000) until that is enabled in Settings → Location.
  Geofence transitions can arrive a few minutes late (Android batches them to save battery).
* Bluetooth: works while the app is not running (manifest receiver). Matching uses the stored
  Android MAC when present, otherwise the device name; names need `BLUETOOTH_CONNECT`.
* App opened: needs Usage access and a running foreground service, so a small persistent
  notification is shown while app-trigger reminders exist. Android may still stop the service
  under memory pressure; it is restarted on app start and on boot.
* Starting a foreground service from the background is restricted on Android 12+; boot and the app
  coming to the foreground start the watcher.

## Before a Play release

* **Remote push (FCM)**: shared-list changes reach a closed app only on the next periodic sync
  (≥ 15 min). For instant delivery add Firebase Cloud Messaging: a server-side trigger/edge function
  sends a data message on row changes, the app runs a sync and rebuilds alerts.
* **Background location declaration**: Play requires the background-location permission form and a
  video showing the in-app explanation (the location picker panel) before the permission prompt.
* **Usage access / specialUse FGS**: declare the special-use foreground service type in the Play
  Console with the same justification as `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` in the manifest.
* **Exact alarms**: `USE_EXACT_ALARM` is restricted to alarm/reminder apps — declare the app as
  a reminders app in the Play policy declaration.
* Release signing config, a hosted Supabase URL/anon key in `supabase.properties` (HTTPS), R8
  keep rules for kotlinx.serialization models if minification strips them (test the release build),
  and a privacy policy (location, usage stats, account email).
* Sign in with Google (Credential Manager) needs an OAuth client; not implemented yet (SPEC §9).
