# Tactical Radio Software: Current Architecture

**Repository review date:** 2026-10-29  
**Scope:** Current implementation in this repository. This report describes code paths present here; it does not infer undocumented Roblox game scripts or the deployed bridge service configuration.

## Executive summary

TRS is currently a collection of cooperating processes, rather than a single desktop application. A Windows WinUI 3 launcher saves connection settings, copies the native plugin into Mumble's per-user plugin folder, and starts Mumble with environment variables. The Mumble plugin polls an HTTP bridge for Roblox state and performs per-remote-user audio routing and effects inside Mumble's audio callback. A Fastify service accepts Roblox state updates, stores them in memory, and returns snapshots. The repository does **not** contain an actual Roblox game-side sender; `fakeRobloxSender.ts` is a development simulator.

The effective runtime path is:

```text
Roblox game integration (external/not present)
  -- POST /v1/roblox/state --> bridge server (:3000)
  <-- GET /v1/plugin/snapshot, polled every 200 ms -- Mumble native plugin
Mumble voice transport -> plugin audio callback -> proximity/radio filtering
Windows launcher -> installs plugin, sets TRADIO_* environment, launches Mumble
```

## 1. Project structure and technologies

| Area | Current role and technology |
|---|---|
| `apps/mumble-plugin/` | C++17 shared library using the bundled Mumble C++ plugin wrapper, `cpp-httplib`, `nlohmann/json`, and OpenSSL. Main implementation is in `src/`; wrapper headers and source are under `external/mumble-plugin-cpp/`. Build definition: `CMakeLists.txt`. |
| `apps/bridge-server/` | TypeScript/Node.js service. Fastify 5, `@fastify/websocket`, Zod dependency, and workspace protocol package. Runtime entry is `src/index.ts`; `npm start` runs compiled `dist/index.js`. |
| `packages/protocol/` | Shared TypeScript protocol types used by server state/lock stores. It does not define a complete validation or generated cross-language contract for the C++ client. |
| `installer/launcher/` | C# .NET 8 Windows App SDK / WinUI 3 desktop launcher, with XAML UI. It installs/copies the plugin and starts Mumble. |
| `installer/` and root PowerShell scripts | Inno Setup definition, build/staging scripts, signing and GitHub release workflow. `installer/launcher_powershell/` and root `Old/`, `Extra/` contain alternate/legacy implementations. |
| `apps/bridge-server/src/dev/` | Fake Roblox state sender and plugin simulator for local development; neither is the Roblox game integration or a production runtime dependency. |

Root `package.json` declares workspaces for `apps/bridge-server` and `packages/protocol` and provides `dev:server`, `build:server`, `start:server`, and `installer` scripts (lines 1–13). The root README documents an older, partly aspirational layout and endpoint (`/snapshot`); current code uses `apps/...` and `/v1/plugin/snapshot` (`readme.md`, “Components” and “Expected Local Endpoint”). Treat implementation files as authoritative where docs differ.

### Entry points

- Launcher: `installer/launcher/Program.cs:14` (`Main`) initializes WinRT and starts WinUI; `App.xaml.cs:35` constructs and activates `MainWindow`.
- Bridge: `apps/bridge-server/src/index.ts:1` constructs Fastify, registers routes, and listens on `0.0.0.0` at `PORT` or 3000 near the end of the file.
- Plugin: Mumble loads the DLL through the wrapper's exported plugin entry. `apps/mumble-plugin/src/TacticalRadioPlugin.cpp` defines `TacticalRadioPlugin`; `apps/mumble-plugin/external/mumble-plugin-cpp/src/plugin.cpp` and the wrapper headers implement the ABI adapter.
- Roblox client: no production Roblox/Luau entry point is in the repository. The only sender-like executable source is `apps/bridge-server/src/dev/fakeRobloxSender.ts`.

## 2. Application lifecycle

### Install and launch

`build-installer.ps1` builds the plugin (unless skipped) and WinUI launcher, stages launcher files, a plugin DLL, native release DLLs, a Windows App Runtime installer, assets, and a default `config.json`, then invokes Inno Setup (`build-installer.ps1`, staging/build sections). The Inno definition installs under `%LOCALAPPDATA%\TacticalRadio`, adds shortcuts, puts the plugin in `%APPDATA%\Mumble\Mumble\Plugins`, creates app `bin`/`plugin` directories, runs the Windows App Runtime installer, unblocks files, and offers to launch the launcher (`installer/TacticalRadio.iss`, `[Setup]`, `[Files]`, `[Icons]`, `[Run]`).

On launcher startup, `Program.Main` initializes COM wrappers and creates `App`; `App.OnLaunched` creates `MainWindow` (`Program.cs:14–56`, `App.xaml.cs:35–56`). `MainWindow` loads `config.json` from the app directory and populates Base URL, Place ID, Job ID, and Mumble executable path (`MainWindow.xaml.cs`, `LoadConfigIntoUi` and `LoadLogo`). The app directory is resolved from `--app-dir`, `TRADIO_APP_DIR`, or the executable directory (`LauncherPaths.cs:6–25`).

“Save Settings” writes JSON. “Install / Repair” saves settings and copies the packaged plugin DLL(s) to the per-user Mumble plugin directory, removes named old DLL versions, and best-effort unblocks files (`MainWindow.xaml.cs`, click handlers; `LauncherService.cs:96–137`). “Launch Mumble” calls `SaveConfig`, `InstallPlugin`, checks the executable path, then starts Mumble with its own directory as working directory (`LauncherService.cs:139–178`). If app `bin` exists, it is prepended to the child process PATH. `TRADIO_BASE_URL`, `TRADIO_PLACE_ID`, and `TRADIO_JOB_ID` are passed to Mumble; the plugin reads these when Mumble loads it.

The launcher does **not** start or supervise the bridge server. It can launch Mumble while Base URL is empty (the UI explicitly defaults it empty; launcher validation accepts empty). In that case the plugin's own default URL is used.

### Mumble connection and shutdown

Mumble loads the plugin as a plugin DLL. Its `init()` loads environment configuration, configures logging, forms positional identity/context, starts the bridge polling thread and a cache-update thread (`TacticalRadioPlugin.cpp`, `init`). `onServerSynchronized` resolves and records the Mumble username; `onServerDisconnected` clears identity/cache state. The plugin stops the cache thread and bridge thread in `shutdown()` and clears username cache. The bridge client destructor also calls `stop()` (`BridgeClient.cpp`, constructor/destructor and `stop`).

The code shown does not establish Mumble auto-connect details, connection credentials, or server/channel selection; these are external Mumble configuration/user actions. The launcher starts Mumble only; it does not command a Mumble server connection or explicitly wait for plugin initialization. Closing Mumble causes the plugin shutdown callback; no coordinated bridge shutdown exists because the bridge is an independent process.

## 3. Mumble integration

### Plugin loading and configuration

The plugin reports name “Roblox Spatial Voice” and author “TacticalRadioSoftware”. It advertises `MUMBLE_FEATURE_AUDIO` only, with comments explaining that Mumble should transport voice while this plugin performs routing (`TacticalRadioPlugin.cpp`, constructor and `getFeatures`). Positional callback methods remain implemented, with context prefix `roblox-spatial`, context `roblox-spatial:<placeId>:<jobId>`, and identity `roblox-spatial-voice`; these provide Mumble's positional identity data, but positional feature advertisement is intentionally disabled.

`BridgeConfig.hpp` defaults to `http://127.0.0.1:3000`, PlaceId `16489784096`, JobId `studio-local`, local Roblox user ID `2026345646`, and 200 ms poll interval. It overrides URL, PlaceId, JobId, Roblox user ID and username from `TRADIO_*` variables. The launcher currently passes only URL, PlaceId and JobId. `localRobloxUserId` exists in config but the polling path does not append it to its request: `BridgeClient::makeSnapshotPath()` includes only PlaceId and JobId. The route accepts optional local identity query values, but the plugin does not send them in this path.

### Snapshot polling and identity matching

`BridgeClient` builds `/v1/plugin/snapshot?placeId=...&jobId=...`, performs GET requests using cpp-httplib with 2-second connect/read/write timeouts, parses JSON, and publishes a snapshot into thread-safe `SharedState`; its loop sleeps `pollIntervalMs` (default 200 ms) (`BridgeClient.cpp`, `makeSnapshotPath`, `run`, `fetchOnce`). It keeps status/ever-connected state for diagnostics. There is no WebSocket subscription despite WebSocket registration in the server, and the active plugin client is polling HTTP.

The separate plugin cache thread runs every 50 ms. It refreshes Mumble identity, finds local player by Mumble username in the snapshot, and updates the positional cache; absent username/snapshot/player invalidates it (`TacticalRadioPlugin.cpp`, `runCacheUpdateOnce`, `startCacheThread`). Audio routing also resolves each remote Mumble user ID to a Mumble username, then finds both local and remote Roblox state by username (`onAudioSourceFetched`). Thus **Mumble username must match the Roblox username string** for each participant. Display names or Roblox numeric IDs are not used for this lookup. This is a key integration constraint and likely failure point if names differ, change, or are not present.

### Audio routing and processing

For each speech audio callback, the plugin returns false for non-speech/invalid buffers or unresolved identities/state. It first asks `RadioRouter::evaluate` whether a remote transmitting radio matches any local listening radio. Matching is case-insensitive and ignores whitespace; it requires remote transmitting, local listening, nonblank equal channel, and distance within the remote radio range (`RadioRouter.cpp`, `evaluate`). The best route is selected by effective volume × signal quality. A radio route applies radio filtering/degradation and local radio ear panning (`AudioRadioEffects::applyRadioEffect` and `applyHeadsetPan`) and allows audio.

If no radio route matches, it computes 3D distance and proximity gain from the remote speaker's speech min/max distance and volume. Hearing overrides are taken from the local player's state and keyed by the remote Roblox user ID; they can reduce max distance/volume and add obstruction/muffling. Stereo output is panned relative to local look direction; obstruction applies a simple low-pass blend. If gain is zero, the buffer is zeroed. These operations occur in `onAudioSourceFetched` on Mumble's audio path; design/performance constraints of allocations, locks, and processing in that callback should be reviewed for a unified client.

## 4. Roblox integration and state model

The bridge's `/v1/roblox/state` POST accepts a `placeId`, `jobId`, and array of player objects. Each normalized player includes Roblox user ID, username/display name, position/look vector, speech mode/volume/min/max range, hearing overrides, legacy `frequency`/`isPtt`, team/squad/radio ID, optional radio slots (`apps/bridge-server/src/index.ts`, route and `normalizePlayer`). Numeric/vector inputs are normalized and bounded; radio slots include channel, listening/transmitting, ear, volume, and range. Missing radio arrays remain undefined; `/v1/plugin/stereo` derives a default single radio from legacy frequency/PTT fields.

Every accepted update is timestamped by the server and stored keyed by `placeId:jobId:robloxUserId` (`playerStateStore.ts:3–32`). A 1-second timer prunes player records older than 5 seconds (`index.ts`, interval near listen). This means senders must refresh state regularly; server memory is volatile and restart loses all state. The code does not explicitly delete players missing from a later submitted batch; they remain until timeout.

PlaceId and JobId scope state and transmit locks. A Roblox game-side sender is expected to provide the correct pair for its live server; the plugin uses the launcher-configured pair to query its snapshot. A mismatch yields no matching players. The repository's fake sender demonstrates development payload shape, but there is no in-repository code reading Roblox `game.PlaceId`, `game.JobId`, players, character transforms, or radio state in production. Consequently the source, cadence, authentication, and correctness of real Roblox updates are unverified from this repository.

The bridge also supports exclusive transmit locks per `(placeId, jobId, frequency)`. `/v1/tx/start` grants a random-token lease with 1200 ms TTL or reports its owner; `/v1/tx/heartbeat` renews only when user ID and token match; `/v1/tx/stop` releases on the same checks (`index.ts` routes, `txLockStore.ts`). This lock API is separate from radio state update and is not directly called by the Mumble plugin. The plugin snapshot includes live locks, though current `RadioRouter` uses radio `transmitting` flags and does not consult snapshot `txLocks`.

## 5. Bridge server

### Architecture and APIs

`apps/bridge-server/src/index.ts` creates a Fastify server with logging and registers `@fastify/websocket`; it maintains in-memory `PlayerStateStore` and `TxLockStore` instances. Routes:

| Route | Behavior |
|---|---|
| `GET /health` | Returns `ok` and current time. |
| `POST /v1/roblox/state` | Normalizes and upserts each valid player for the supplied PlaceId/JobId. |
| `POST /v1/tx/start` | Requests 1200 ms exclusive frequency lease. |
| `POST /v1/tx/heartbeat` | Renews lease by token and owner. |
| `POST /v1/tx/stop` | Releases lease by token and owner. |
| `GET /v1/plugin/snapshot?placeId=&jobId=` | Returns scoped players and transmit locks; optionally echoes local user ID/name query fields. This is the active plugin API. |
| `GET /v1/plugin/stereo?placeId=&jobId=` | Returns a transformed player/radio view with derived stereo flag. No active plugin call to this endpoint was found. |

It listens on all interfaces (`0.0.0.0`) at environment `PORT` or 3000. Although WebSocket support is registered, no WebSocket route/handler is defined in `index.ts`.

### Authentication, networking, data flow

No API key, bearer token, Roblox signature validation, origin check, or route authorization appears in the active bridge code. The tx lease token is a concurrency/ownership token, not general authentication. The server binds `0.0.0.0`, so the APIs are network-reachable according to host firewall/routing; they are not inherently localhost-only. HTTPS termination is not configured in this code. The plugin supports `http`/`https` via cpp-httplib/OpenSSL, but deployment TLS is outside the repository.

Data flow is request/response: Roblox-side sender POSTs snapshots; bridge normalizes and stores records; native plugin polls the scoped snapshot; plugin parses to C++ structs and updates shared snapshot state; audio callback reads it. No persistence, message queue, push subscription, schema version negotiation, backpressure, or per-client session registry is visible. Zod is listed as a dependency but route validation in `index.ts` uses TypeScript generics and hand-written normalization; no Zod schema is applied in these handlers. `packages/protocol` is used for store types, but server-local types and C++ parsing also encode the shape, so the contract is not single-source.

## 6. User interface, settings, and workflows

The current GUI is a WinUI 3 XAML desktop application (`MainWindow.xaml`) with C# event handlers (`MainWindow.xaml.cs`). It exposes Base URL, PlaceId, JobId and Mumble path, plus save settings, install/repair plugin, launch Mumble, and GitHub update-check/open-update actions. It has status/info messages and Mumble file picker. It is a launcher/configuration utility, not a bridge dashboard: it has no embedded bridge lifecycle/status, Roblox session discovery, voice controls, or direct Mumble connection UI.

`LauncherConfig` serializes `baseUrl`, `placeId`, `jobId`, and `mumblePath` (`LauncherConfig.cs`). Configuration lives beside the installed launcher at `config.json`, not in a shared user-data settings service. Mumble receives selected settings as process environment; its plugin separately contains compiled defaults and accepts environment overrides. PlaceId and JobId defaults are repeated in the launcher model, service, installer staging JSON, and native plugin config. The bridge's port default is separately set to 3000. Invalid launcher config JSON is silently ignored and defaults used; Base URL may remain empty.

Update checking uses GitHub Releases via `GithubUpdateService.cs`; the Update action opens the selected release/download URL in the shell. The visible flow does not silently install an update; user downloads/runs the installer.

## 7. Build and distribution

- Bridge/protocol: npm workspaces, TypeScript 5.6, `tsx` dev runner, `tsc` build, Node start (`package.json`, `apps/bridge-server/package.json`, `tsconfig.json`).
- Plugin: CMake/C++17; bundled Mumble wrapper, fetched `cpp-httplib` (declared `master`, thus mutable) and pinned `nlohmann_json` 3.11.3 archive; requires OpenSSL and links Windows crypto/network libraries (`apps/mumble-plugin/CMakeLists.txt`). `build-plugin.ps1` handles the native build and release DLL staging. README also describes vcpkg/Visual Studio setup and manual plugin/dependency placement.
- Launcher: .NET 8, Windows x64, WinUI 3 / Windows App SDK 2.2.0, self-contained and Windows App SDK self-contained (`TacticalRadioLauncher.csproj`). Build helper: `installer/launcher/build-launcher.ps1`.
- Installer: `build-installer.ps1` stages and invokes Inno Setup `ISCC.exe`; requires a separately supplied `installer/prereqs/WindowsAppRuntimeInstall-x64.exe` and icon/logo assets. It can optionally sign staged binaries and installer through `sign-installer.ps1`.
- Release: `publish-release.ps1` coordinates installer build, optional git commit/push/tag, and GitHub CLI release creation/upload. This script can mutate repository history and publish externally; it was inspected, not run.

There are legacy installer scripts (`build-installer-legacy.ps1`, `build-installer-modern.ps1`) and PowerShell launcher copies, alongside active C# launcher and root `Old/`/`Extra/` C++ plugin versions. These increase ambiguity about the supported path. `readme.md` still describes manual plugin installation and an obsolete `/snapshot` endpoint, while current package/build scripts point to newer paths.

## 8. Current limitations and integration challenges

1. **Not unified at runtime.** Launcher, Mumble, bridge and Roblox game code are separate. Launcher does not manage bridge lifetime or diagnose end-to-end connectivity; Mumble is an external required host and voice transport.
2. **Roblox integration is absent.** No production Luau uploader is shipped. How PlaceId/JobId, positions, user names, radio state, hearing overrides, and leases are sourced and secured depends on external code.
3. **Username coupling.** Plugin joins Mumble and Roblox identities by username, although snapshots carry Roblox user IDs and bridge can echo optional local identity. The polling request does not pass configured local user ID/name; numeric identity is not used for routing. Renames/case differences or Mumble naming conventions can break matching.
4. **Duplicated configuration.** URL/port, PlaceId/JobId and defaults exist independently in installer JSON, C# types/service, C++ config and server. Launcher passes only three values; plugin-only Roblox identity settings are not exposed in UI. Separate changes can produce silent session mismatch.
5. **Unauthenticated service surface.** State ingestion and snapshots are unauthenticated, while the server binds every interface. No TLS setup or origin policy is included. A production deployment must provide network controls and a trusted auth model.
6. **Ephemeral state and simple freshness.** In-memory maps, 5-second stale pruning, and whole-state polling have no persistence or explicit deletion. Server restart empties sessions; sender delays cause transient disappearance. Accepted count reports submitted array size rather than confirmed upserts.
7. **Protocol drift risk.** Local TypeScript server types, shared protocol types, and C++ JSON parser are parallel definitions. Endpoint/query behavior and docs already diverge; `GET /v1/plugin/stereo` appears unused by the active plugin.
8. **Audio identity/context risks.** The plugin advertises audio-only while retaining positional methods, so the intended Mumble interaction needs validation against the target Mumble version. The main routing is performed in an audio callback and relies on username resolution/cache. Radio routing uses remote radio range and local listening settings; locks are returned but not enforced by this router.
9. **Manual setup and external dependencies.** User must install/run a compatible Mumble client and configure its server connection; a live bridge and Roblox sender must exist separately. Installer build needs Windows SDK/.NET, CMake/native compiler, OpenSSL/vcpkg dependencies, Inno Setup, and a separately sourced Windows App Runtime installer. Manual README instructions can be stale.
10. **Operational gaps.** No bridge process supervisor, service install, persistent logs/metrics endpoint beyond health, end-to-end readiness check, reconnect UI, or coordinated shutdown is implemented. Plugin logs and launcher logs are separate; bridge logs use Fastify logger.
11. **Distribution/update boundaries.** Release helper is a manually invoked GitHub CLI workflow; launcher update check opens the release asset/page but does not apply updates itself. Optional signing depends on operator-provided certificate configuration.

## Verified behavior vs. assumptions

**Verified in repository:** the routes and payload normalization above; in-memory stores and expiry; plugin's 200 ms polling and 50 ms cache loop; Mumble username lookup and username-based state matching; launcher configuration, plugin copy, environment setup, process launch; build/staging/installer scripts.

**Not verified / outside repository:** any Roblox game-side sender or its use of PlaceId/JobId; whether production bridge is local or hosted and how it is protected; Mumble server setup and auto-connect behavior; target Mumble version compatibility and actual runtime audio callback ordering; release artifacts currently published or the build having succeeded in a specific environment. The `readme.md` describes intended/expected workflows, not proof they are currently deployed.

## Useful trace index

- Launcher entry/UI/service: `installer/launcher/Program.cs`, `App.xaml.cs`, `MainWindow.xaml`, `MainWindow.xaml.cs`, `LauncherService.cs`, `LauncherConfig.cs`, `LauncherPaths.cs`.
- Plugin runtime/config/audio: `apps/mumble-plugin/src/TacticalRadioPlugin.cpp`, `BridgeConfig.hpp`, `BridgeClient.cpp`, `SharedState.hpp`, `PositionalCache.cpp`, `MumbleIdentity.cpp`, `RadioRouter.cpp`, `AudioRadioEffects.cpp`.
- Bridge/API/stores: `apps/bridge-server/src/index.ts`, `playerStateStore.ts`, `txLockStore.ts`; development sender `src/dev/fakeRobloxSender.ts`.
- Build/release: `apps/mumble-plugin/CMakeLists.txt`, `apps/bridge-server/package.json`, root `package.json`, `build-plugin.ps1`, `build-installer.ps1`, `installer/TacticalRadio.iss`, `publish-release.ps1`.

### Key line ranges for the main execution paths

- Installer build/staging/compile: `build-installer.ps1:217–310` builds components; `316–382` stages launcher/plugin/DLLs/default config and runtime prerequisite; `404+` invokes Inno Setup. Inno installation and post-install actions are in `installer/TacticalRadio.iss:18–82`.
- Launcher boot: `Program.cs:14–56`, `App.xaml.cs:35–56`; settings load into UI: `MainWindow.xaml.cs:198–207`; actions: `242–278`; GitHub update workflow: `326–383`.
- Launcher process behavior: `LauncherService.cs:44–103` loads/saves config; `105–137` plugin install/repair; `139–178` Mumble launch and environment setup; `201–213` URL validation.
- Plugin initialization/shutdown/features: `TacticalRadioPlugin.cpp:245–289`; audio routing: `368–545`; Mumble server identity events: `547–561`; cache lookup/update and 50 ms thread: `610–672`.
- Bridge poll request and decode: `BridgeClient.cpp:260–315` constructs path and loops; `317–390` HTTP request, JSON parse and snapshot publication. Config defaults/env reads: `BridgeConfig.hpp:8–17, 37–60`.
- Bridge normalization and routes: `index.ts:111–210` normalizes state; lines `213–244` health and Roblox ingest; `246–297` transmit lock endpoints; `295–361` plugin reads; `364–374` pruning and listener.
- In-memory lifecycle: `playerStateStore.ts:3–33`; transmit token lease: `txLockStore.ts:11–110`.
