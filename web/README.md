# reminders.etherlynx.xyz

Static files for passkey sign-in (SPEC §9). Passkeys are bound to the domain
`reminders.etherlynx.xyz` (the WebAuthn relying party, `rp_id` in
[`backend/supabase/config.toml`](../backend/supabase/config.toml)), so this domain has to serve:

| path | for | what |
|---|---|---|
| `/passkey/` (`public/passkey/index.html`, `public/passkey/etherlynx.svg`) | iOS, iPadOS, macOS | The passkey page. The apps open it in a browser sheet (`ASWebAuthenticationSession`), it runs the passkey prompt and returns the session to `lynxreminders://auth-callback`. |
| `/.well-known/assetlinks.json` (`public/.well-known/assetlinks.json`) | Android | Lets the app `xyz.etherlynx.reminders` (and `com.mansfera.lynxreminders`, the id up to 0.1.1) use passkeys for this domain (Credential Manager). |

## Hosting

An assets-only Cloudflare Worker, `lynx-reminders-web`, in the **etherlynx** account (which holds
the `etherlynx.xyz` zone), with `reminders.etherlynx.xyz` as its custom domain. Everything under
`public/` is uploaded; `public/_headers` sets the strict CSP for `/passkey/*` and the JSON content
type for `assetlinks.json`. `cloudflare.config.ts` holds the Worker name, account and domain.

```sh
cd web
bun install
bun run deploy          # cf deploy ./public; needs `cf auth login` (the cf CLI: bun add -g cf)
```

Requirements if it ever moves to another host: HTTPS on `reminders.etherlynx.xyz` itself, no
redirect for `/.well-known/assetlinks.json` (Google fetches it directly and doesn't follow
redirects), served as `application/json`, and the headers from `public/_headers`.

Check Android's view of the domain:
`https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://reminders.etherlynx.xyz&relation=delegate_permission/common.get_login_creds`

## Why the Apple apps use a web page

A native passkey prompt (`ASAuthorizationPlatformPublicKeyCredentialProvider`) needs the Associated
Domains entitlement `webcredentials:reminders.etherlynx.xyz`, which only a paid Apple developer team
can sign, plus `/.well-known/apple-app-site-association` naming that team. The apps are signed ad hoc,
so they show this page in Safari instead, where `reminders.etherlynx.xyz` is the page's own origin.
The passkeys are the same either way: with a team later, add the entitlement and the AASA file
below and switch the apps to the native prompt; nobody has to create a new passkey.

```json
{ "webcredentials": { "apps": ["<TEAMID>.xyz.etherlynx.reminders"] } }
```

## When something changes

* **Android signing key.** `assetlinks.json` lists the SHA-256 of the key the APK is signed with
  (today the debug key on the build Mac, see `release.sh`). A new key (release key, Play App Signing)
  needs its fingerprint added to `public/.well-known/assetlinks.json` **and** its `android:apk-key-hash:` origin added to `rp_origins`
  in `config.toml`, then `bunx supabase@2 config push` and `bun run deploy`. Get both with
  `keytool -list -v -keystore <keystore>`; the origin is the SHA-256 bytes in unpadded base64url.
* **Supabase project or anon key.** `SUPABASE_URL` / `ANON_KEY` at the top of the page script, and
  `connect-src` in `public/_headers`.
