# Fleet for iOS

A native SwiftUI client for Agent Fleet. It covers runs grouped by machine, a live chat for each run (streamed over SSE, with subagents nested under their Agent calls), a composer, and a new-run sheet. It talks to the same HTTP API as the web app and has no third-party dependencies.

The source lives in `ios/` of Agent Fleet's own repo. `ios/scripts/publish-github.sh` copies it to the public [Porter-smith/fleet-ios](https://github.com/Porter-smith/fleet-ios), where GitHub's macOS runners build it. Make changes in agent-fleet, not in the GitHub copy.

- `FleetKit/`: a Swift package with the API models, the client, the SSE line splitter and parser, transcript building, composer controls (ported from the web app's) and the demo mode. The unit tests decode fixtures captured from the Fleet dev server.
- `Fleet/`: the SwiftUI app (iOS 17+, Observation, async/await).
- `FleetUITests/`: a UI test that walks the app in demo mode and saves screenshots.
- `project.yml`: the XcodeGen spec. The `.xcodeproj` is generated and not committed.

## Build

You need a Mac with Xcode 16 or newer, plus `brew install xcodegen`.

From this folder (`ios/` in agent-fleet, the root of fleet-ios):

```sh
xcodegen generate
open Fleet.xcodeproj        # run the Fleet scheme on a simulator
(cd FleetKit && swift test) # unit tests, no simulator needed
```

### Demo mode

Launch with the argument `-FleetDemo`, or tap **Try the demo** on the pairing screen, and the app runs on the fixtures bundled in `FleetKit/Sources/FleetKit/Demo/` through a stand-in `URLProtocol`. No server or token is needed, and nothing is saved. The fixtures are real responses from the Fleet dev server, with their times moved to now.

To use a real server instead, run agent-fleet's dev server from that repo's root with `bun scripts/dev-fleet.ts`. It serves fixture runs on http://127.0.0.1:8793 with the admin token `dev`, and needs tmux. Pair the simulator with that URL and token. Or set `FLEET_URL` and `FLEET_TOKEN` in the scheme's environment and the app pairs itself.

### UI tests and screenshots

The same way CI runs them, in demo mode:

```sh
TEST_RUNNER_SCREENSHOT_DIR=$PWD/screenshots \
xcodebuild test -project Fleet.xcodeproj -scheme Fleet \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

Add `TEST_RUNNER_FLEET_URL=http://127.0.0.1:8793 TEST_RUNNER_FLEET_TOKEN=dev` to walk the dev server instead.

CI (`.github/workflows/ios.yml`) runs on GitHub's macOS runners in fleet-ios, on each push to main and on pull requests. It needs no secrets and no server. It uploads the screenshots as the `screenshots` artifact.

A second workflow, `.github/workflows/adhoc.yml`, builds a signed ipa for your iPhone. See [Install on an iPhone](#install-on-an-iphone).

### Publishing to GitHub

From agent-fleet, after committing changes to `ios/`:

```sh
ios/scripts/publish-github.sh --dry-run   # export and scan only
ios/scripts/publish-github.sh             # then commit and push to fleet-ios main
```

The script exports the committed `ios/` tree (without `scripts/`), scans it for tokens, keys, email addresses, private IPs and private host names, and stops if anything turns up. It then commits on top of fleet-ios's own history as the GitHub noreply address, so agent-fleet's own history stays private.

## Pairing

1. Make a Fleet token with the scopes **`runs:read`**, **`runs:control`** and **`runs:spawn`**. Create it in the web app under **Settings > API tokens** (`POST /api/tokens`, admin only). The secret is shown once. An admin token also works, but a scoped token is safer on a phone.
   - `runs:read` covers the runs list, transcripts, the live stream and subagents.
   - `runs:control` covers send, queue, interrupt, stop, restart and permission answers.
   - `runs:spawn` covers new runs.
2. In the app, enter the server URL. Use the Tailscale name or a LAN address, for example `https://fleet.example.ts.net`. Then paste the token.
3. The app checks the token against `GET /api/me` before saving. The token goes in the Keychain (this device only, readable after first unlock) and the URL in the app's settings. Settings lists any missing scopes and has **Unpair**.

## Trusting Caddy's private CA

The server sits behind Caddy with its internal CA, so iOS rejects the certificate until you trust that root:

1. Get Caddy's root certificate, `root.crt`, from Caddy's data dir under `pki/authorities/local/`. AirDrop or email it to the phone, or serve it once.
2. Open it, then go to **Settings > General > VPN & Device Management** and install the profile.
3. Go to **Settings > General > About > Certificate Trust Settings** and turn on full trust for that root.

If the certificate isn't trusted, the app says so when you pair. Plain `http://` works only for local addresses (127.0.0.1, `.local` and LAN or Tailscale IPs), which App Transport Security allows through `NSAllowsLocalNetworking`.

## How it behaves

- **Runs list:** there is no list-wide stream, so the list polls `GET /api/runs` every 4 s while it's on screen. Pull to refresh. Active/All filter.
- **Chat:** `GET /api/runs/:id/stream` replays recent events, then streams live events and text deltas. On a dropped connection the app reconnects with backoff and resumes after the last seq it has. **Load earlier** pages back through the transcript. Each Agent/Task call expands to show its subagent's own tool calls and messages. **Agents** lists the session's background subagents.
- **Composer:** each button follows the harness's capabilities from `GET /api/runs/:id`. Anything the harness can't do, or the run's state forbids, is disabled, with the reason shown in the actions menu.
  - **Queue** waits for the end of the turn.
  - **Send now** goes into the live turn, only where the harness supports mid-turn input.
  - **Interrupt** ends the current turn but keeps the session.
  - **Stop** ends the process.
  - **Restart** resumes the session as a new run.

## Install on an iPhone

Open **https://porter-smith.github.io/fleet-ios/** in Safari on the iPhone and tap **Install Fleet**. This works like Expo's internal distribution: an ad hoc signed build, installed from an `itms-services://` link. It installs only on iPhones registered on the Apple developer team (team `GDTA3U9KK4`).

- The first time, iOS asks for **Developer Mode**: **Settings > Privacy & Security > Developer Mode**, then restart. iOS shows that switch only after you've tried to install an ad hoc app once.
- To update, open the page and tap **Install** again. Each build has a higher `CFBundleVersion` (the workflow's run number), so the new one replaces the old and keeps the app's data and the Keychain token.

`.github/workflows/adhoc.yml` makes the build on each push to main of fleet-ios, and on demand from **Actions > Ad hoc install > Run workflow**. It never runs on pull requests. Without the signing secrets it skips the build and still passes. Each run:

1. `ci/asc.py` registers the bundle ID `dev.portersmith.fleet` and any devices in `IOS_DEVICE_UDIDS` through the App Store Connect API. It then reuses the ad hoc profile **Fleet Ad Hoc CI**, or remakes it when a device was added, the certificate changed, or it expires within 14 days. The profile covers every enabled iOS device on the team.
2. It imports the Apple Distribution certificate into a throwaway keychain, archives with manual signing, and exports with `method: release-testing` (ad hoc).
3. It checks the signature, then publishes `Fleet-<version>-<build>.ipa`, `manifest-<build>.plist` (also copied to `manifest.plist`) and `index.html` to GitHub Pages. The install link carries the manifest URL percent-encoded, with no query strings anywhere: iOS answers a raw or query-string manifest URL with "Open in iTunes?" and then does nothing. Pages has a valid HTTPS certificate, which `itms-services` requires, so you don't need to trust Caddy's CA for this.

### What's public

The repo, the Pages site and its artifacts are public. Nothing secret goes in them. The signing keys stay in Actions secrets, they're used only on the macOS runner, and the runner deletes the keychain afterwards. Logs show counts, never UDIDs. Like any ad hoc ipa, though, the one on the page carries its provisioning profile. Anyone who downloads it can read the team ID, the name on the certificate (Porter Smith) and the **UDIDs of the registered devices**. Without a device being registered on your team, nobody can install the app, and a UDID alone gives no access to the phone.

### One-time setup

You don't need a Mac for any of this. It was done on 2026-10-14. Repeat it when the certificate expires (2027-10-14) or if you move to a new team.

1. **API key.** Go to App Store Connect, then **Users and Access > Integrations > App Store Connect API > Team Keys**, and generate a key with the **Admin** role. Admin can create the distribution certificate. Each build afterwards only manages bundle IDs, devices and profiles, so you can swap in an **App Manager** key for `ASC_KEY_*`. If builds then fail with a 403, go back to Admin. Note the **Key ID** and the **Issuer ID** (above the keys table), and download the `.p8` file. Apple lets you download it only once.
2. **Team ID.** Find it at developer.apple.com, under **Account > Membership details**. For this team it's `GDTA3U9KK4`.
3. **iPhone UDID.** It's only needed if the phone isn't registered yet. Check under **Certificates, Identifiers & Profiles > Devices** on developer.apple.com: an iPhone added for Expo builds is already there. Without a Mac, you can get it in any of these ways:
   - On Windows, plug the phone in, open iTunes or Apple Devices, and click the serial number until it shows the UDID.
   - On Linux, plug the phone in and run `idevice_id -l` (libimobiledevice).
   - On the phone, open a UDID site such as udid.tech in Safari and install its profile. That site sees the UDID.

   Put it in the `IOS_DEVICE_UDIDS` secret (comma-separate several). Or add it on developer.apple.com. The next build includes it.
4. **Certificate and secrets.** Run this on any Linux or macOS box with `openssl`, `python3` and an authenticated `gh`:

   ```sh
   export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/private/AuthKey_XXXX.p8 APPLE_TEAM_ID=GDTA3U9KK4
   ci/setup-signing.sh ~/private/fleet-ios     # a 0700 folder outside any repo
   ```

   It makes an RSA key and CSR, creates an **Apple Distribution** certificate from them through the API, and packs both into `dist.p12` in that folder. Then it sets these Actions secrets on fleet-ios:

   | Secret | What |
   | --- | --- |
   | `APPLE_TEAM_ID` | Team ID |
   | `ASC_KEY_ID`, `ASC_ISSUER_ID` | API key ID and issuer ID |
   | `ASC_KEY_P8` | Contents of the `.p8` |
   | `DIST_CERT_P12`, `DIST_CERT_PASSWORD` | The distribution certificate and key (base64 p12), and its password |
   | `IOS_DEVICE_UDIDS` | Optional: devices to register |

   Keep that folder. It holds the certificate's only private key. If you lose it, run the script again with an empty folder. That makes a new certificate (a team can hold 3 distribution certificates). Revoking a certificate stops every app signed with it from opening.
5. **Pages.** Under the repo's **Settings > Pages**, set the source to **GitHub Actions** (already done).

## Still to do

- TestFlight or the App Store: an App Store export plus an upload step, using the same API key.
- Push notifications (APNs) for "needs you" alerts: the push entitlement and a server-side sender. Live Activities come after that.
