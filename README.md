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

## Not yet: needs an Apple Developer account

CI builds for the simulator without signing. Installing on a real iPhone, TestFlight, push notifications (APNs) and Live Activities all need a paid Apple Developer Program membership, which you need to sign up for first. After that:

- Set a team and signing in `project.yml` (`DEVELOPMENT_TEAM`, an App ID for `dev.portersmith.fleet`).
- Add a signing step to CI, with fastlane `match` or Xcode Cloud, for TestFlight uploads.
- Add the push entitlement and a server-side APNs sender for "needs you" alerts.
