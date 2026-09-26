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
  - keepalive touches (8-LED/SD devices only);
  - hot-plug.
- SidePulse Pro Eject Prevention, in the app only: a DiskArbitration eject-approval callback vetoes ejects of
  cards in the built-in SD reader and retries their mount every 5 s (`SDEjectGuard`, ported from Python's
  `sd_eject_guard.c`). The hook CLI never links DiskArbitration.
- Keep-awake while agents work: a `ProcessInfo` activity (`.idleSystemSleepDisabled`, which holds PreventUserIdleSystemSleep) with the Never / When Agents Work / Always policy, plus a low-battery safeguard.
- Menu-bar app:
  - status icon;
  - recent sessions;
  - Devices menus and a one-row Keep Awake policy switch;
  - a small SwiftUI Settings window (per-state animations, profiles, timeouts, hooks, eject prevention, launch at login, logs folder).
- CLI: `write`, `status` (with `--watch`), `leds`, `run`, `install`, `uninstall`, `doctor`, `setup`, `app`, `settings`, `hook-log`, `version`, `help`.

Out of scope (dropped on purpose):
- iPhone link/push
- remote relay
- the headless service and Linux support
- battery LED mode
- closed-lid helper and lid animations
- status history and charts
- audit export
- the virtual notch device
- WASM previews
- custom animation editor and profile import/export
- transcript fallback monitoring
- reading state from message text: the Python question heuristic, notification
  phrases and `<!-- sidepulse:… -->` markers (state comes only from hook events)
- terminal resume/focus
- `update`
- Cursor, Grok and Junie

## Processes

```
agent (claude/codex) ──hook──▶ sidepulse hook-log --provider P ; true
                                  │ 1. append trimmed JSON line to logs/P.jsonl
                                  │ 2. send {"provider","line"} to events.sock (0.2 s timeout)
                                  ▼
SidePulse.app (menu bar)  = SidePulseRuntime + AppKit UI
   EventSocketServer ─▶ StatusEngine ─▶ latest.json (debounced)
                              │
                              ├─▶ LedSyncService ─▶ /Volumes/<device>/LEDS.LED (+ keepalive)
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
  for keepalive touches. LED work captures its generation when queued and
  re-checks it before writing and after `open()`, so a write still queued or
  stuck in `open()` is dropped and no LED write lands after `stop()` returns;
  only a keepalive touch already inside `open()` cannot be recalled. `start()`
  opens a new generation. The LEDs keep their last program.

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
`scripts/install.sh`. The CLI lives in `Helpers/` because APFS is usually
case-insensitive, so `MacOS/sidepulse` would collide with the app binary
`MacOS/SidePulse`.

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

## Module map (`Sources/`)

| Area | Files | Notes |
|---|---|---|
| Support | `SidePulseCore/Support/{Paths,JSON,FileUtil}.swift` | order-preserving `JSONValue`, `TimeFormat`, atomic writes, backups, `DiagnosticsLog` |
| Status | `SidePulseCore/Status/*` | models, `EventParser`, `ModeClassifier`, `DisplayNames`, `StatusEngine`, `SnapshotBuilder`, `LatestStore`, `LogScanner`, `CodexSessionIndex` |
| LED | `SidePulseCore/LED/*` | `LedText`, `DeviceDiscovery`, `LedWriter`, `KeepaliveToucher`, `AnimationLibrary`, `AnimationProfiles`, `LedProgram`, `AgentLedController` |
| Settings | `SidePulseCore/Settings/*` | `SidePulseSettings` (tolerant JSON), `SettingsStore` (locked update) |
| Hooks | `SidePulseCore/Hooks/*` | installers (Claude JSON, Codex TOML text, the OpenCode plugin generated from a JS template in `OpenCodePluginInstaller`), `HookInstaller.perform` (install/uninstall dispatch shared by the CLI and the app), `CodexTrust`, `HookDoctor`, `HookRuntime`, `OriginDetector`, `HookLogStore` |
| IPC | `SidePulseCore/IPC/*` | `IPCMessage`, `EventSocketClient`, `EventSocketServer` (accept-order delivery) |
| System | `SidePulseCore/System/{Power,LaunchAgent,SDEjectGuardRule}.swift` | battery, keep-awake policy and `ProcessInfo` activity (`KeepAwakeAssertion`), launchd, the eject guard's card match |
| Runtime | `SidePulseCore/Runtime/*` | `LedSyncService`, `SidePulseRuntime` |
| Presentation | `SidePulseCore/Presentation/*` | UI-agnostic menu/session-row/settings view models (unit-tested), `HookCLIPath`. The UI's hook state is `ProviderDoctorInfo` (`HookState` is a typealias) |
| CLI | `SidePulseCLI/*`, `sidepulse/main.swift` | argument parsing and commands; `SidePulseCLI.main(args) -> Int32` |
| App | `SidePulseApp/*` | NSStatusItem menu, SwiftUI settings and `SDEjectGuard` (DiskArbitration) |

`SidePulseCore` must not import AppKit or SwiftUI, so the hook process starts
fast.

## Conventions

- Swift 5 language mode, macOS 26+, no third-party dependencies.
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
- `LedWriter` (the write and the read-back) and the keepalive touch open with
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
