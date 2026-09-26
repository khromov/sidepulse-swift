# SidePulse (Swift) — architecture

A lightweight Swift replacement for the Python `sidepulse` project
(`../sidepulse`). It is a CLI plus a small native macOS menu-bar app for
SidePulse Pro (8 LEDs, SD slot) and SidePulse Dot (2 LEDs, USB-C). Both devices
mount as FAT volumes and are driven by writing a small DSL to `LEDS.LED`
(see `../sidepulse/LEDS_FORMAT.md`).

## Scope

In scope:
- Agent status monitoring through hooks, for **Claude Code** and **Codex** only.
  - Hook install and uninstall, including Codex trust hashes.
  - Removal of Python-era hooks.
  - `doctor`.
- The full status state machine from the Python collector:
  - markers and question heuristics;
  - sticky permission prompts, settling, staleness and priority aggregation;
  - `latest.json`.
- LED output:
  - device discovery;
  - Dot vs Pro LED count;
  - built-in animations and the Cyan/Ember/Purple profiles;
  - per-device Agent/Manual mode and brightness;
  - keepalive touches (8-LED/SD devices only);
  - hot-plug.
- Keep-awake while agents work: an IOKit power assertion (PreventUserIdleSystemSleep) with the Never / When Agents Work / Always policy, plus a low-battery safeguard.
- Menu-bar app:
  - status icon;
  - recent sessions;
  - Devices, Keep Awake and Hooks menus;
  - launch at login;
  - a small SwiftUI Settings window (per-state animations, profiles, timeouts).
- CLI: `write`, `status`, `live`, `leds`, `run`, `install`, `uninstall`, `doctor`, `setup`, `app`, `settings`, `hook-log`, `version`, `help`.

Out of scope (dropped on purpose):
- iPhone link/push
- remote relay
- the headless service and Linux support
- battery LED mode
- the SD eject guard
- closed-lid helper and lid animations
- status history and charts
- audit export
- the virtual notch device
- WASM previews
- custom animation editor and profile import/export
- transcript fallback monitoring
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
                              ├─▶ KeepAwake (IOKit power assertion)
                              └─▶ UI (icon, menu, settings)

sidepulse status     ─▶ asks the app over the socket ({"command":"status"}),
                        or falls back to scanning logs/*.jsonl when the app isn't running
sidepulse leds/run   ─▶ runs SidePulseRuntime headless in the foreground
```

The app is the only thing that owns monitor state and LED writes. The runtime
binds the socket before it writes anything, and refuses to start if another
process already listens on it.

`EventSocketServer` reads each connection on a concurrent queue but hands the
messages to the runtime in accept order, so a hook's `PreToolUse` is never
applied after its `PostToolUse`. A message waits at most 0.25 s behind an
unfinished earlier connection. The socket commands are `ping`, `status`,
`open-settings` and `reload-settings`. `reload-settings` waits up to 2 s for an
LED write that started with the old settings; if it is still running, the reply
is `{"ok":false,"error":"LED write in progress"}`.

## Runtime threading

`SidePulseRuntime` (`Runtime/Runtime.swift`) keeps its engine state on a private
serial state queue. Callers rely on these rules:
- UI reads (`snapshot()`, `settings`, `deviceInfos()`, `keepAwakeActive`) come
  from lock-protected caches and never wait for the state queue, device I/O or
  a settings write.
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
  never stalls events; `start()` waits at most `startupDiscoveryTimeout` (2 s)
  for the first discovery and lets a slow one finish in the background.
- `LedSyncService` keeps the device list and errors behind a lock. `requestSync`
  is coalesced but never drops the latest mode (the Python version could).
  Controller resets are applied on the I/O queue right before the next sync.
  Normal syncs wait while a preview plays.
- `stop()` ends a playing preview and waits (bounded) for queued LED writes and
  keepalive touches, so nothing is written after it returns. The LEDs keep
  their last program.

## Paths

All paths hang off `SidePulsePaths`. They are never taken from XDG variables,
so the hook, the CLI and the app launched by the LaunchAgent always agree.
`SIDEPULSE_HOME` overrides the root; tests use it.

Files under the root (`~/Library/Application Support/SidePulse/`):
- `settings.json`
- `latest.json`
- `logs/claude.jsonl` and `logs/codex.jsonl` (rotated at 8 MB to `.1`)
- `events.sock`
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
the menu-bar binary or the Python CLI. Doctor checks the CLI the installed
hooks call with the same rule (an explicit `$SIDEPULSE_CLI_PATH` only has to
exist).

LaunchAgent: `~/Library/LaunchAgents/io.sidepulse.swift.plist`. It runs the app
binary with `RunAtLoad`, `KeepAlive={SuccessfulExit:false}` and
`EnvironmentVariables` `PATH` (the installing process's `PATH` plus
`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`). Only `app install`,
`setup` and the Launch at Login toggle write it; `app start` and `settings`
open the app without it when it is missing, and every start path pings first.

Bundle: `Resources/Info.plist` is the template for
`SidePulse.app/Contents/Info.plist` (`LSUIElement`, bundle id
`io.sidepulse.swift`). Its `NSRemovableVolumesUsageDescription`, "SidePulse
writes LED programs to your SidePulse device.", is the reason macOS shows when
it asks for removable-volume access on the first device write. `build-app.sh`
signs ad hoc unless `SIDEPULSE_CODESIGN_IDENTITY` is set (`install.sh --sign`);
an ad-hoc grant does not survive a rebuild.

## Module map (`Sources/`)

| Area | Files | Notes |
|---|---|---|
| Support | `SidePulseCore/Support/{Paths,JSON,FileUtil}.swift` | order-preserving `JSONValue`, `TimeFormat`, atomic writes, backups, `DiagnosticsLog` |
| Status | `SidePulseCore/Status/*` | models, `EventParser`, `ModeClassifier`, `DisplayNames`, `StatusEngine`, `SnapshotBuilder`, `LatestStore`, `LogScanner`, `CodexSessionIndex` |
| LED | `SidePulseCore/LED/*` | `LedText`, `DeviceDiscovery`, `LedWriter`, `KeepaliveToucher`, `AnimationLibrary`, `AnimationProfiles`, `LedProgram`, `AgentLedController` |
| Settings | `SidePulseCore/Settings/*` | `SidePulseSettings` (tolerant JSON), `SettingsStore` (locked update) |
| Hooks | `SidePulseCore/Hooks/*` | installers (Claude JSON, Codex TOML text), `HookInstaller.perform` (install/uninstall dispatch shared by the CLI and the app), `CodexTrust`, `HookDoctor`, `HookRuntime`, `OriginDetector`, `HookLogStore` |
| IPC | `SidePulseCore/IPC/*` | `IPCMessage`, `EventSocketClient`, `EventSocketServer` (accept-order delivery) |
| System | `SidePulseCore/System/{Power,LaunchAgent}.swift` | battery, keep-awake policy and power assertion (`KeepAwakeAssertion`), launchd, legacy Python cleanup |
| Runtime | `SidePulseCore/Runtime/*` | `LedSyncService`, `SidePulseRuntime` |
| Presentation | `SidePulseCore/Presentation/*` | UI-agnostic menu/session-row/settings view models (unit-tested), `HookCLIPath`. The UI's hook state is `ProviderDoctorInfo` (`HookState` is a typealias) |
| CLI | `SidePulseCLI/*`, `sidepulse/main.swift` | argument parsing and commands; `SidePulseCLI.main(args) -> Int32` |
| App | `SidePulseApp/*` | NSStatusItem menu and SwiftUI settings |

`SidePulseCore` must not import AppKit or SwiftUI, so the hook process starts
fast.

## Conventions

- Swift 5 language mode, macOS 14+, no third-party dependencies.
- Tests use XCTest (`swift test`).
- Tests never modify the real `~/.claude`, `~/.codex`, `~/Library/LaunchAgents`
  or `~/Library/Application Support/SidePulse` (a few legacy-hook tests read
  copies of the real agent configs). Use a temporary directory with
  `SidePulsePaths(environment: [...], home: tmp)` and `SIDEPULSE_HOME`.
- The hook path never writes to stdout and always exits 0.
- Writes to user config and state files are atomic (`FileUtil.atomicWrite`).
  It resolves symlink chains the way the kernel does, so a dotfiles link stays
  and the real file is replaced. It refuses to rewrite a read-only file
  (`<path> is read-only; make it writable and try again`), which is what a
  read-only `~/.claude/settings.json` or `~/.codex/config.toml` gives on
  install.
- `LEDS.LED` is the exception: it is written in place (`LedWriter`), and is
  truncated only after the caller re-checks, once `open()` returns, that it
  still wants the write. The runtime checks there that the device is still in
  Agent mode with LED output on, because `open()` can wait on the macOS
  removable-volume prompt. An `open()` refused with EPERM/EACCES throws
  `LedError.accessDenied`, shown on the device as a permission notice.
- The diagnostics log (`DiagnosticsLog`, `app.log`) uses plain POSIX writes.
- Writes to third-party configs make a backup (`<file>.bak.<stamp>`) when they
  change an existing file.
- Hooks are identified by command markers (`HookCommand.isSidePulseCommand`),
  never by log paths.
- Prefer `\u{2028}` style escapes in Swift sources over literal invisible
  characters.

The porting reference (a detailed analysis of the Python code) was generated
during development. Where behaviour is unclear, the Python sources in
`../sidepulse/src/sidepulse/` are the ground truth.
