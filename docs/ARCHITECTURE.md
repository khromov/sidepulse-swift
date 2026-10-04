# SidePulse (Swift) — architecture

A lightweight Swift replacement for the Python `sidepulse` project
(`../sidepulse`). It is a CLI plus a small native macOS menu-bar app for
SidePulse Pro (8 LEDs, SD slot) and SidePulse Dot (2 LEDs, USB-C). Both devices
mount as FAT volumes and are driven by writing a small DSL to `LEDS.LED`
(see `../sidepulse/LEDS_FORMAT.md`).

## Scope

In scope:
- Agent status monitoring through hooks, for **Claude Code**, **Codex** and **OpenCode**.
  - Hook install and uninstall, including Codex trust hashes and the OpenCode
    plugin (OpenCode has no hook settings).
  - Removal of Python-era hooks.
  - `doctor`.
- The full status state machine from the Python collector:
  - sticky permission prompts, settling, staleness and priority aggregation;
  - `latest.json`.
- LED output:
  - device discovery;
  - Dot vs Pro LED count;
  - built-in animations and the Cyan/Ember/Purple/Signal profiles;
  - per-device Agent/Manual mode and brightness;
  - keepalive reads of `STATUS.TXT`, past the macOS cache (8-LED/SD devices only);
  - each device's model and firmware version from `STATUS.TXT`;
  - hot-plug.
- `sidepulse firmware version|upgrade`: lists firmware, and installs a verified package from the
  Python repo's `firmware/` folder by copying its `FIRMWARE.BIN` to the volume.
- SidePulse Pro Eject Prevention, in the app only: a DiskArbitration eject-approval callback vetoes ejects of
  cards in the built-in SD reader and retries their mount every 5 s (`SDEjectGuard`, ported from Python's
  `sd_eject_guard.c`). The hook CLI never links DiskArbitration.
- LEDs off while the Mac sleeps: `SystemSleepWatcher` (IOKit system-power and lid notifications) plays the chosen off animation (Fade Off, Lid Closed Sweep, Slow Off or Immediate Off) on Agent Status devices before a sleep with the lid closed, or any sleep with the opt-in setting, and lights them again once the Mac is in use. Python did this by polling `ioreg` for the lid every second.
- Keep-awake while agents work: a `ProcessInfo` activity (`.idleSystemSleepDisabled`, which holds PreventUserIdleSystemSleep) with the Never / When Agents Work / Always policy, plus a low-battery safeguard.
- Menu-bar app:
  - status icon;
  - recent sessions;
  - Devices menus and a one-row Keep Awake policy switch;
  - a small SwiftUI Settings window (per-state animations, profiles, timeouts, hooks, the sleep animation and LEDs off on any sleep, eject prevention, launch at login, logs folder, command-line tool, updates).
- The `~/.local/bin/sidepulse` link, which the app keeps pointed at its own CLI, and a check that the user's shell finds it.
- Updates of release builds with Sparkle 2, from a feed published with each GitHub release.
- CLI: `write`, `status` (with `--watch`), `leds`, `run`, `install`, `uninstall`, `doctor`, `setup`, `app`, `settings`, `hook-log`, `version`, `help`.

Out of scope (dropped on purpose):
- iPhone link/push
- remote relay
- the headless service and Linux support
- battery LED mode
- closed-lid helper and the Lid Open animations
- status history and charts
- audit export
- the virtual notch device
- WASM previews
- custom animation editor and profile import/export
- transcript fallback monitoring
- reading state from message text: the Python question heuristic, notification
  phrases and `<!-- sidepulse:… -->` markers (state comes only from hook events)
- terminal resume/focus
- a `sidepulse update` command (release apps update themselves with Sparkle)
- Cursor, Grok and Junie
- the read-only-mount LED transports of firmware 1.1 (READ2ME reads of `setup.html` on the Pro, USB
  control requests on the Dot), not ported yet

## Processes

```
agent (claude/codex) ──hook──▶ sidepulse hook-log --provider P ; true
                                  │ 1. append trimmed JSON line to logs/P.jsonl
                                  │ 2. send {"provider","line"} to events.sock (0.2 s timeout)
                                  ▼
SidePulse.app (menu bar)  = SidePulseRuntime + AppKit UI
   EventSocketServer ─▶ StatusEngine ─▶ latest.json (debounced)
                              │
                              ├─▶ LedSyncService ─▶ /Volumes/<device>/LEDS.LED (+ STATUS.TXT reads)
                              ├─▶ KeepAwake (ProcessInfo activity)
                              └─▶ UI (icon, menu, settings)

sidepulse status     ─▶ asks the app over the socket ({"command":"status"}),
                        or falls back to scanning logs/*.jsonl when the app isn't running
sidepulse leds/run   ─▶ runs SidePulseRuntime headless in the foreground
```

OpenCode has no hook settings. Its SidePulse plugin (`plugins/sidepulse.js` in
OpenCode's config directory) reads OpenCode's event stream inside OpenCode's
background service and runs the same `hook-log --provider opencode` command for
each event, one CLI at a time so records keep their order. A CLI still running
after 2 s is killed with its process group before the next one starts; past 200
waiting records, tool records are dropped first. The plugin subscribes again,
with a growing pause, when the event stream ends or fails.

The app is the only thing that owns monitor state and LED writes. The runtime
binds the socket before it writes anything. It holds an `flock` on
`events.sock.lock` for as long as it serves, and only while holding it probes,
replaces a stale socket file and binds, so two instances starting together
cannot both win. It refuses to start if another process holds the lock or
already listens on the socket. Clients only connect to a socket file owned by
the current user, and then check with `getpeereid` that the process serving it
is too.

`EventSocketServer` reads each connection on a concurrent queue but hands the
messages to the runtime in accept order, waiting about 0.25 s behind an
unfinished earlier connection. A message that still arrives late is ignored by
`StatusEngine` if it was logged up to 5 s before its row's last update, so a
hook's `PreToolUse` is not applied after its `PostToolUse`. The socket commands
are `ping`, `status`, `open-settings` and `reload-settings`. `ping` answers
`{"ok","pid","version","kind"}`: `kind` is `headless` when the runtime has no
`onOpenSettings` handler (`sidepulse run`/`leds`), else `app`, and the CLI reads
a missing `kind` as `app`. `reload-settings` takes an optional `device` id (the
CLI sends it; without one, every device counts) and waits up to 2 s for an LED
write to that device that already passed its settings check; if it is still
running, the reply is `{"ok":false,"error":"LED write in progress"}`.

## Runtime threading

`SidePulseRuntime` (`Runtime/Runtime.swift`) keeps its engine state on a private
serial state queue. Callers rely on these rules:
- UI reads (`snapshot()`, `settings`, `deviceInfos()`, `keepAwakeActive`) come
  from lock-protected caches and never wait for the state queue, device I/O or
  a settings write.
- The menu gets project names from `DisplayNames.cachedProjectName`, which
  never touches the filesystem. The engine resolves each row's cwd on the state
  queue when it applies an event or restores a row, and the menu falls back to
  the row's label on a miss.
- `updateSettings`, `setDeviceDisplay`, `setDeviceBrightness`, `removeDevice`
  and `refresh` return at once. `settings` shows the change immediately; the
  save and its effects run on the state queue, then `onUpdate` fires.
- `ingest`, `reloadSettings`, `start` and `stop` run synchronously on the state
  queue, so a `status` reply includes an event once `ingest` returns.
- `onUpdate` and `onOpenSettings` are called on the main queue. `onUpdate` is
  coalesced: changes made while a delivery is pending ride along, and it gets
  the snapshot current at delivery time.
- LED writes run on `LedSyncService`'s serial I/O queue and `latest.json` writes
  on their own queue. Device discovery runs on a device queue, so a hung mount
  never stalls events; `start()` does not wait for the first discovery, so the
  first LED write lands a few milliseconds after it returns.
- `LedSyncService` keeps the device list and errors behind a lock. `requestSync`
  is coalesced but never drops the latest mode (the Python version could).
  The only controller reset, for a hot-plugged volume, is applied on the I/O
  queue right before the next sync.
  Normal syncs wait while a preview plays.
- `stop()` ends a playing preview and waits (bounded, 2 s) for queued LED
  writes, then closes `LedSyncService`'s current generation, and waits (1 s)
  for keepalive reads. LED work captures its generation when queued and
  re-checks it before writing and after `open()`, so a write still queued or
  stuck in `open()` is dropped and no LED write lands after `stop()` returns.
  `start()` opens a new generation. The LEDs keep their last program.
- `pollDevices` starts a firmware read of `STATUS.TXT` for each newly mounted
  card (dev:ino of the volume root) on a concurrent queue, at most one per card
  at a time, and retries a failed one after 60 s. `deviceInfos` reports the
  result, and `checkDeviceStatus` reports a new one so an open menu refreshes.
- `SystemSleepWatcher` delivers sleep, wake and lid events on its own queue.
  macOS waits for the `.willSleep` handler before it sleeps, so the handler
  never waits for the state queue: it reads the applied settings from the cache
  and waits (bounded, 2 s) only for the `off` writes. While the LEDs are off for
  sleep, every other LED write is skipped, including one that was stuck in
  `open()`, and a late `off` from an earlier sleep is skipped once they are back
  on. They come back on only after a wake event, once the Mac is in use
  (`SleepState.inUse`). The device poll re-checks every 2 s, because a dark
  wake that turns into a full wake sends no event. `start()` and `stop()` start
  and stop the watcher on the state queue, so a `start()` racing a `stop()`
  keeps it running, and `start()` also ends an earlier sleep.

## Paths

All paths hang off `SidePulsePaths`. SidePulse's own paths are never taken from
XDG variables, so the hook, the CLI and the app launched by the LaunchAgent
always agree. `SIDEPULSE_HOME` overrides the root; tests use it. A relative
`SIDEPULSE_HOME` resolves against `HOME`, because hooks run in each project's
working directory. Agent config locations follow the agent's own overrides:
`CLAUDE_CONFIG_DIR` for Claude Code, `CODEX_HOME` for Codex, and
`OPENCODE_CONFIG_DIR`, then `XDG_CONFIG_HOME/opencode`, then
`~/.config/opencode` for OpenCode (plugin: `plugins/sidepulse.js`). An app
started by launchd does not see a variable exported only in a shell, so it then
uses the default location.

Files under the root (`~/Library/Application Support/SidePulse/`):
- `settings.json`
- `latest.json`
- `logs/claude.jsonl`, `logs/codex.jsonl` and `logs/opencode.jsonl` (rotated at
  8 MB to `.1`). The hook's append never blocks: it refuses anything but a
  regular file, skips a rotation when another process holds the log's `flock`,
  and starts on a new line when an interrupted write left the last one
  unfinished.
- `events.sock` and its instance lock `events.sock.lock`. When the root is too
  long for the 104-byte socket path limit, the socket moves to
  `/tmp/sidepulse-<uid>/events-<hash>.sock`, where the hash is the 64-bit
  FNV-1a of the root path, so each root keeps its own runtime. The server
  creates that directory with `mkdir` and refuses it unless it is a real
  directory (not a symlink) owned by the user with mode 0700 or stricter.
- `app.log` (rotated at 2 MB), plus the LaunchAgent's `app.out.log` and
  `app.err.log`

Stable CLI path: `~/.local/bin/sidepulse` (`SidePulsePaths.defaultCLILink`). It
is a symlink to `SidePulse.app/Contents/Helpers/sidepulse`, created by
`scripts/install.sh` and by the app. The CLI lives in `Helpers/` because APFS is usually
case-insensitive, so `MacOS/sidepulse` would collide with the app binary
`MacOS/SidePulse`.

`CLILink` (`System/CLILink.swift`) maintains the link from the app. At launch
(`installAtLaunch`) it links the running bundle's `Helpers/sidepulse` when the
link is missing, dangling or points into another `.app`'s `Helpers/sidepulse`,
so the command and the hooks that call the link follow the running app.
Anything else there (the Python CLI, a plain file) is replaced only by the
Settings **Install** button, which moves a non-symlink to `sidepulse.previous`.
The new link is created under a temporary name and renamed over the old one,
because hooks may run it at any moment. A SwiftPM build or a translocated app
never links. `ShellPATH` reads the login shell's `PATH` (`$SHELL -i -l -c`,
output through a temporary file, 5 s timeout, off the main thread and only when
Settings opens) and looks `sidepulse` up in it. `ShellProfile` appends the
`~/.local/bin` `PATH` line to `~/.zprofile` (or bash's first existing profile)
with `FileUtil.atomicWrite` and a backup.

`HookCLIPath` (`Presentation/HookCLIPath.swift`) is the one resolver for the
hook CLI (install, setup, doctor and the app). Order: `$SIDEPULSE_CLI_PATH` as
is, the stable link when it is a SidePulse CLI, the `Helpers/sidepulse` of the
bundle the running binary lives in, then the running CLI itself. It accepts
only a `sidepulse` inside `<X>.app/Contents/Helpers/` or the running CLI, never
the menu-bar binary or the Python CLI. A running binary under an
`/AppTranslocation/` path (an app opened in place from a download) gets no
bundled or running-CLI fallback, and `unresolvedMessage()` then asks the user
to move the app to Applications. Doctor checks the CLI the installed
hooks call with the same rule (an explicit `$SIDEPULSE_CLI_PATH` only has to
exist).

LaunchAgent: `~/Library/LaunchAgents/io.sidepulse.swift.plist`. It runs the app
binary with `RunAtLoad`, `KeepAlive={SuccessfulExit:false}` and
`EnvironmentVariables` `PATH` (the installing process's `PATH` plus
`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`). Only `app install`,
`setup` and the Launch at Login toggle write it (the toggle throws
`AppTranslocated` rather than write a translocated path); `app start` and
`settings` open the app without it when it is missing, and every start path pings first.

Bundle: `Resources/Info.plist` is the template for
`SidePulse.app/Contents/Info.plist` (`LSUIElement`, bundle id
`io.sidepulse.swift`). Its `NSRemovableVolumesUsageDescription`, "SidePulse
writes LED programs to your SidePulse device.", is the reason macOS shows when
it asks for removable-volume access on the first device write. `build-app.sh`
signs ad hoc unless `SIDEPULSE_CODESIGN_IDENTITY` is set (`install.sh --sign`);
an ad-hoc grant does not survive a rebuild. `release.sh` uses
`build-app.sh --distribution` (arm64 binaries only, hardened runtime, secure
timestamp) with a Developer ID identity. It then notarizes and staples the app
and zips it to `dist/SidePulse-VERSION.zip`.

`build-app.sh` also copies `Sparkle.framework` from the SwiftPM build into
`Contents/Frameworks` (the app links it through the
`@executable_path/../Frameworks` rpath in `Package.swift`). It deletes the
framework's XPC services, which only sandboxed apps use, and its headers. A
`--distribution` build thins Sparkle's three binaries to arm64. Sparkle's
`Autoupdate` and `Updater.app` are signed one by one, then the framework and
then the app, without `--deep`, as Sparkle's docs require.

## Updates

Only a `--distribution` build keeps `SUFeedURL` in its `Info.plist`.
`build-app.sh` deletes it from every other build, and
`AppUpdater.startIfConfigured()` creates no updater without it. So a build from
source (which might be for Intel) never replaces itself with a release, and its
menu and Settings show no update controls.

- **Feed.** `SUFeedURL` is `https://github.com/khromov/sidepulse-swift/releases/latest/download/appcast.xml`.
  GitHub redirects it to the `appcast.xml` asset of the release marked latest.
  `scripts/appcast.sh` writes a feed with one item for the new zip (`generate_appcast`,
  no deltas) whose Markdown release notes are embedded. The zip's
  `LSMinimumSystemVersion` and slices give it `sparkle:minimumSystemVersion` and
  `sparkle:hardwareRequirements` `arm64`.
- **Trust.** `SUPublicEDKey` in `Resources/Info.plist` is the public half of the
  EdDSA key in the release machine's login keychain. `appcast.sh` refuses to
  sign when the zip's key and the keychain's key differ. Sparkle also checks the
  new app's code signature.
- **Behavior.** `SUEnableAutomaticChecks` skips Sparkle's permission prompt.
  Checks run every 24 hours, and downloading automatically is off by default.
  Sparkle's own defaults (`io.sidepulse.swift` domain) hold those preferences,
  and the Settings toggles set them through `SPUUpdater`.
- **Gentle reminders.** A menu-bar app's scheduled alert would open behind other
  windows. So `AppUpdater` lets Sparkle show a scheduled update only when Sparkle
  offers immediate focus (right after launch). Otherwise it keeps
  `pendingVersion`, and the menu shows **Update Available: X.Y.Z...** until the
  update session ends. That item, **Check for Updates...** and **Check Now** all
  call `checkForUpdates`, which also brings back a pending alert.
- **Install.** Sparkle terminates the app normally (exit 0, so the LaunchAgent's
  `KeepAlive` does not restart it), replaces the bundle at the same path and
  relaunches it through LaunchServices. The relaunched copy runs outside
  launchd until the next login, like an app opened by hand. The
  `~/.local/bin/sidepulse` link, hook commands and LaunchAgent path point into
  the bundle, so they stay valid. The removable-volume grant is tied to the
  Developer ID designated requirement, so it survives too.

## Module map (`Sources/`)

| Area | Files | Notes |
|---|---|---|
| Support | `SidePulseCore/Support/{Paths,JSON,FileUtil}.swift` | order-preserving `JSONValue`, `TimeFormat`, atomic writes, backups, `DiagnosticsLog` |
| Status | `SidePulseCore/Status/*` | models, `EventParser`, `ModeClassifier`, `DisplayNames`, `StatusEngine`, `SnapshotBuilder`, `LatestStore`, `LogScanner`, `CodexSessionIndex` |
| LED | `SidePulseCore/LED/*` | `LedText`, `DeviceDiscovery`, `LedWriter`, `KeepaliveReader`, `AnimationLibrary`, `AnimationProfiles`, `LedProgram`, `AgentLedController`; `Firmware.swift`: `DeviceStatusFile` (uncached `STATUS.TXT` reads), `FirmwareInfo`, `FirmwareWriter` |
| Settings | `SidePulseCore/Settings/*` | `SidePulseSettings` (tolerant JSON), `SettingsStore` (locked update) |
| Hooks | `SidePulseCore/Hooks/*` | installers (Claude JSON, Codex TOML text, the OpenCode plugin generated from a JS template in `OpenCodePluginInstaller`), `HookInstaller.perform` (install/uninstall dispatch shared by the CLI and the app), `CodexTrust`, `HookDoctor`, `HookRuntime`, `OriginDetector`, `HookLogStore` |
| IPC | `SidePulseCore/IPC/*` | `IPCMessage`, `EventSocketClient`, `EventSocketServer` (accept-order delivery) |
| System | `SidePulseCore/System/{Power,SleepWatcher,LaunchAgent,SDEjectGuardRule,CLILink}.swift` | battery, keep-awake policy and `ProcessInfo` activity (`KeepAwakeAssertion`), sleep, wake and lid notifications (`SystemSleepWatcher`), launchd, the eject guard's card match, the `~/.local/bin/sidepulse` link (`CLILink`, `ShellPATH`, `ShellProfile`) |
| Runtime | `SidePulseCore/Runtime/*` | `LedSyncService`, `SidePulseRuntime` |
| Presentation | `SidePulseCore/Presentation/*` | UI-agnostic menu/session-row/settings view models (unit-tested, including `CLILinkPresentation`), `HookCLIPath`. The UI's hook state is `ProviderDoctorInfo` (`HookState` is a typealias) |
| CLI | `SidePulseCLI/*`, `sidepulse/main.swift` | argument parsing and commands; `SidePulseCLI.main(args) -> Int32`. `Support/FirmwareUpdate.swift` (release lookup, package and checksum checks), `ZipArchive` (stored/deflate reader whose inflate never exceeds the declared size), `HTTPDownload` (capped GET, injected as `CLIEnvironment.download`) |
| App | `SidePulseApp/*` | NSStatusItem menu, SwiftUI settings, `SDEjectGuard` (DiskArbitration) and `AppUpdater`, the only file that imports Sparkle |

`SidePulseCore` must not import AppKit or SwiftUI, so the hook process starts
fast.

## Conventions

- Swift 5 language mode, macOS 26+. Sparkle is the only third-party dependency,
  and only `SidePulseApp` links it; the CLI and `SidePulseCore` have none.
- Tests use XCTest (`swift test`).
- Tests never modify the real `~/.claude`, `~/.codex`, `~/.config/opencode`,
  `~/Library/LaunchAgents` or `~/Library/Application Support/SidePulse` (a few legacy-hook tests read
  copies of the real agent configs). Use a temporary directory with
  `SidePulsePaths(environment: [...], home: tmp)` and `SIDEPULSE_HOME`.
- The hook path never writes to stdout and always exits 0.
- Writes to user config and state files are atomic (`FileUtil.atomicWrite`).
  It resolves symlinks with `realpath` (following one hop for a dangling link),
  so a dotfiles link stays and the real file is replaced. It refuses to rewrite a read-only file
  (`<path> is read-only; make it writable and try again`), which is what a
  read-only `~/.claude/settings.json` or `~/.codex/config.toml` gives on
  install.
- `LEDS.LED` is the exception: it is written in place (`LedWriter`), and is
  truncated only after the caller re-checks, once `open()` returns, that it
  still wants the write, because `open()` can wait on the macOS
  removable-volume prompt. The runtime checks there that its generation is
  still open and that the device is still in the mode the write was made for:
  Agent for syncs and previews, Manual for the one-time `off` clear. The clear
  also goes ahead only if the file still holds exactly what the app last wrote
  to that device, so it never overwrites a program written meanwhile.
- `LedWriter` (the write and the read-back), `DeviceStatusFile` and `FirmwareWriter` open with
  `O_NOFOLLOW | O_NONBLOCK` and accept only a regular file, so a symlink or
  FIFO planted on a volume can neither redirect nor block them. Discovery
  examines a mount point under a root only if it is a local `msdos` or `exfat`
  volume, and counts a `LEDS.LED` only if it is a regular file. Only an `open()` refused with EPERM
  (and not a Finder-locked file) throws `LedError.accessDenied`, shown on the
  device as the privacy notice; EACCES is a plain write error.
- Writes from separate processes (the app and `sidepulse write`) are not locked
  against each other, so their truncate-then-write can interleave; Agent mode's
  read-back rewrites a garbled file at the next sync.
- The diagnostics log (`DiagnosticsLog`, `app.log`) uses plain POSIX writes.
- Writes to third-party configs make a backup (`<file>.bak.<stamp>`) when they
  change an existing file. The OpenCode plugin is SidePulse's own file: install
  backs up a changed older copy, and uninstall deletes it without a backup.
- Hooks are identified by command markers (`HookCommand.isSidePulseCommand`),
  never by log paths. The OpenCode plugin counts as ours only with the marker
  line `OpenCodePluginInstaller.marker`; any other `sidepulse.js` is never
  replaced or deleted.
- The Codex installer edits `config.toml` as text and throws
  `HookInstallError.invalidStructure` rather than lose data: for hook tables it
  cannot extend (`staticHookDefinitionProblem`, install only), and for a key
  SidePulse did not write in one of its own groups or trust tables
  (`managedTableProblem`), which is where TOML puts a key appended after the
  block.
- Prefer `\u{2028}` style escapes in Swift sources over literal invisible
  characters.

The porting reference (a detailed analysis of the Python code) was generated
during development. Where behaviour is unclear, the Python sources in
`../sidepulse/src/sidepulse/` are the ground truth.
