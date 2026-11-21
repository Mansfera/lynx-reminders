# reminders.etherlynx.xyz

Static files for passkey sign-in (SPEC §9). Passkeys are bound to the domain
`reminders.etherlynx.xyz` (the WebAuthn relying party, `rp_id` in
[`backend/supabase/config.toml`](../backend/supabase/config.toml)), so this domain has to serve:

| path | for | what |
|---|---|---|
| `/passkey/` (`passkey/index.html`, `passkey/etherlynx.svg`) | iOS, iPadOS, macOS | The passkey page. The apps open it in a browser sheet (`ASWebAuthenticationSession`), it runs the passkey prompt and returns the session to `lynxreminders://auth-callback`. |
| `/.well-known/assetlinks.json` | Android | Lets the app `com.mansfera.lynxreminders` use passkeys for this domain (Credential Manager). |

Any static host with HTTPS works (Cloudflare Pages, Netlify, Caddy/nginx). Requirements:

* HTTPS on `reminders.etherlynx.xyz` itself, with no redirect for `/.well-known/assetlinks.json`
  (Google fetches it directly and doesn't follow redirects), served as `application/json`.
* `/passkey/` serves `passkey/index.html`. `_headers` sets a strict CSP for it on Cloudflare Pages
  or Netlify; copy those headers to other hosts.

Cloudflare Pages, for example: `bunx wrangler pages deploy web --project-name lynx-reminders`,
then add `reminders.etherlynx.xyz` as a custom domain on that project.

## Why the Apple apps use a web page

A native passkey prompt (`ASAuthorizationPlatformPublicKeyCredentialProvider`) needs the Associated
Domains entitlement `webcredentials:reminders.etherlynx.xyz`, which only a paid Apple developer team
can sign, plus `/.well-known/apple-app-site-association` naming that team. The apps are signed ad hoc,
so they show this page in Safari instead, where `reminders.etherlynx.xyz` is the page's own origin.
The passkeys are the same either way: with a team later, add the entitlement and the AASA file
below and switch the apps to the native prompt; nobody has to create a new passkey.

```json
{ "webcredentials": { "apps": ["<TEAMID>.com.mansfera.lynxreminders"] } }
```

## When something changes

* **Android signing key.** `assetlinks.json` lists the SHA-256 of the key the APK is signed with
  (today the debug key on the build Mac, see `release.sh`). A new key (release key, Play App Signing)
  needs its fingerprint added here **and** its `android:apk-key-hash:` origin added to `rp_origins`
  in `config.toml`, then `bunx supabase@2 config push`. Get both with
  `keytool -list -v -keystore <keystore>`; the origin is the SHA-256 bytes in unpadded base64url.
* **Supabase project or anon key.** `SUPABASE_URL` / `ANON_KEY` at the top of the page script, and
  `connect-src` in `_headers`.
