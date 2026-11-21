# Lynx Reminders

Reminders for macOS, iPhone, iPad and Android, in the Lynx Battery style, with an account,
sync across devices, and sharing.

On top of what Apple Reminders does (dates, repeats, location, lists, subtasks, sharing):

- **Bluetooth triggers:** remind me when the AirPods or the car connect or disconnect.
- **App triggers:** remind me when I open Slack.
- **Repeats with any period:** every 45 minutes between 09:00 and 18:00, every 2 weeks on
  Mon and Thu, every 3 days after I complete it.
- **Alert again until done:** re-alert every N minutes until it's ticked off.
- **Shared tasks without a shared list:** share one reminder with someone.
- **Goals:** a reminder with subtasks gets a progress ring (3/5).

## Repository

| folder | what |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | the contract every client follows: data, sync, repeat rules, triggers, design |
| [shared/](shared) | repeat-rule reference (`reference/recurrence.py`), test vectors all clients must pass, fonts, mark |
| [backend/](backend) | Supabase schema, row-level security, sharing RPCs, tests |
| [apple/](apple) | SwiftUI app: macOS now, iOS/iPadOS from the same code |
| [android/](android) | Kotlin + Jetpack Compose app |

Changing a repeat rule: edit `shared/reference/recurrence.py`, run it to regenerate
`shared/vectors/recurrence.json`, then make both clients' tests pass again.

Designed and developed by [Etherlynx Studio](https://etherlynx.xyz/) and [Ihor Kharkholyuk](https://kharkholy.uk). Made with Claude.
