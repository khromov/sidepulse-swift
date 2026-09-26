# SidePulse (Swift)

A lightweight Swift replacement for the Python
[`sidepulse`](https://github.com/inteliwear/sidepulse) project: a `sidepulse`
CLI plus a native macOS menu-bar app that show Claude Code and Codex agent
status on SidePulse LEDs.

- **SidePulse Pro**: an 8-LED device for the MacBook Pro SD card slot.
- **SidePulse Dot**: a 2-LED USB-C device.

Both mount as FAT volumes. You drive the LEDs by writing a small program to
`LEDS.LED` on the volume. The DSL is documented in the Python repo's
[`LEDS_FORMAT.md`](https://github.com/inteliwear/sidepulse/blob/main/LEDS_FORMAT.md).

### Differences from the Python version

- **Claude Code and Codex only.** Hooks are installed into
  `~/.claude/settings.json` and `~/.codex/config.toml`, and Codex hooks are
  marked trusted automatically.
- **No Python.** It ships as one app bundle containing the menu-bar app and the
  CLI, and uses no third-party dependencies. The agent hook runs the native CLI
  directly, so no Python interpreter starts on every tool call.
- **New data paths.** Everything lives under
  `~/Library/Application Support/SidePulse`. XDG variables are never read, and
  Python-era state in `~/.local/state/sidepulse` or `~/.config/sidepulse` is
  neither read nor removed.
- **Flat CLI.** The command is `sidepulse status`, not
  `sidepulse agent-monitor status`. A leading `agent-monitor` is still accepted
  and ignored.
- **Separate LaunchAgent.** The app runs from `io.sidepulse.swift`.
  `sidepulse setup` removes the Python install's LaunchAgents and replaces its
  hooks.

**Intentionally dropped:** iPhone link and push, the remote relay, the headless
service and Linux support, battery LED mode, the SD eject guard, the closed-lid
sleep helper and lid animations, status history and charts, audit and
decision-log export, the virtual SidePulse Notch device, WASM previews, the
custom animation editor and profile import/export, transcript fallback
monitoring, terminal resume/focus from session rows, `sidepulse update`, and
Cursor, Grok and Junie support.

## Requirements

- macOS 14 or later.
- A Swift 6 toolchain: Xcode 16 or later. The package uses swift-tools-version
  6.0 and compiles in Swift 5 language mode.
- The scripts use the standard macOS tools `codesign`, `plutil`, `ditto` and
  `launchctl`.
- The app is signed ad hoc unless you install with
  `scripts/install.sh --sign IDENTITY` (or set `SIDEPULSE_CODESIGN_IDENTITY`
  for `scripts/build-app.sh`), using a code-signing identity from
  `security find-identity -v -p codesigning`, for example
  "Developer ID Application: …" or a self-signed code-signing certificate.
  With an ad-hoc signature, macOS asks again for access to removable volumes
  (needed to write to the SidePulse device) after every update, and LED output
  waits until you answer.

## Install

From a checkout of this repository, run:

```sh
scripts/install.sh                          # build, install to ~/Applications, run setup
scripts/install.sh --no-setup               # install only; leave hooks and login item alone
scripts/install.sh --app-dir /Applications  # install somewhere else
scripts/install.sh --sign "Developer ID Application: …"   # sign with your certificate
```

`scripts/install.sh` runs these steps:

1. **Builds** `build/SidePulse.app` with `scripts/build-app.sh` (release),
   signed with `--sign` / `$SIDEPULSE_CODESIGN_IDENTITY` when given, else ad
   hoc. The bundle holds the menu-bar app at `Contents/MacOS/SidePulse` and the
   CLI at `Contents/Helpers/sidepulse`.
2. **Stops** a running SidePulse: it boots out the `io.sidepulse.swift`
   LaunchAgent and kills any copy started by hand from the install location,
   waiting up to 10 s. Then it replaces `DIR/SidePulse.app` (default
   `~/Applications`). It never replaces another app's bundle: if
   `DIR/SidePulse.app` has a bundle id other than `io.sidepulse.swift` (for
   example the Python app), the script stops before building.
3. **Links** `~/.local/bin/sidepulse` to
   `DIR/SidePulse.app/Contents/Helpers/sidepulse`. An existing symlink, such as
   the Python install's, is replaced. A regular file is moved to
   `~/.local/bin/sidepulse.previous`.
4. **Runs `sidepulse setup`**, unless you pass `--no-setup`. With `--no-setup`,
   an app that was running under launchd before is started again.

If `~/.local/bin` is not on your `PATH`, the script prints a note. After an
ad-hoc install it also prints a note about the removable-volume prompt. If
setup fails, the script still prints its notes and exits with setup's status.
To upgrade, re-run `scripts/install.sh`. The hook commands point at the stable
`~/.local/bin/sidepulse` link, so they keep working across rebuilds. This
matters for Codex, whose trust hashes bind to the exact command string.

The first time the app writes to the device after installing (and after each
ad-hoc-signed update), macOS asks "SidePulse would like to access files on a
removable volume", with the reason "SidePulse writes LED programs to your
SidePulse device." Answer the prompt. Until you do, LED output waits and the
device's submenu under **Devices** shows the waiting notice (see
[Menu-bar app](#menu-bar-app)). If you denied it, allow SidePulse under
System Settings › Privacy & Security › Files and Folders (Removable Volumes).
Installing with `--sign IDENTITY` avoids the prompt after updates.

### What `sidepulse setup` does

```sh
sidepulse setup [claude|codex|all]... [--no-app] [--dry-run] [--no-migrate] [--no-trust]
```

1. **Migrates away from the Python install** (skip with `--no-migrate`). It
   boots out and deletes these LaunchAgents: `io.sidepulse.agentstatus`,
   `io.sidepulse.service`, `com.sidepulse.agentstatus` and
   `com.pixiepulse.agentstatus`. It leaves `io.sidepulse.sdejectguard` alone.
2. **Installs hooks** for every agent whose config directory exists
   (`~/.claude`, `~/.codex`), or only for the providers you name. The same edit
   removes Python-era SidePulse hooks: those that call `hook_entry.py`,
   `agent-monitor hook-log` or `sidepulse hook-log`, plus Codex
   `# >>> agent-monitor hooks >>>` blocks. It also marks the Codex hooks trusted
   (skip with `--no-trust`).
3. **Installs and starts the app's LaunchAgent**, so the app also starts at
   login (skip with `--no-app`). If `SidePulse.app` is not found, this step is
   skipped and setup prints instructions. If SidePulse already runs outside
   launchd, only the plist is written and the LaunchAgent takes over at the
   next login. If the LaunchAgent's own instance is running and nothing
   changed, it is left running.

`--dry-run` shows what would change without changing anything. The last line
says what was set up (without an agent config: "SidePulse is not set up yet").
Setup exits with 1 if a hook installer or launchd fails, or when nothing was
installed at all.

## Quick start

```sh
# Write an LED program. \n, \r, \t and \\ are decoded.
sidepulse write 'off\n#FF3A00 pulse\nrepeat'
sidepulse write --dry-run '#00FF66'                      # validate and print only
printf 'off\n#00FF66 pulse\nrepeat' | sidepulse write    # program from stdin
sidepulse write '#FF00FF' --device /Volumes/SidePulseDot --manual

sidepulse status        # one-shot aggregate and per-agent status
sidepulse live          # full-screen dashboard, Ctrl-C to quit
sidepulse doctor        # hooks, app, socket and CLI path check
```

Programs are limited to 512 bytes and 20 lines, the controller's limits.
Without `--device`, `write` auto-discovers the SidePulse volume in `/Volumes`.
A volume counts if it contains `LEDS.LED` or its name matches SidePulse Pro,
SidePulse Dot or PulseDot. If several are mounted, pass `--device`.

The app shows agent status on every device in Agent mode, so it overwrites a
manual write at its next update. Pass `--manual` to switch that device to
Manual first. The device then stays yours until you switch it back under
**Devices** in the menu. With the app running, `--manual` asks it to reload its
settings and waits up to 3 s for the reply. If the app is still writing to the
device, `write` prints a warning that the app may overwrite the program, then
writes anyway.

## CLI reference

Exit codes: `0` ok, `1` error, `2` usage error, invalid LED program, or no
device / ambiguous device. `sidepulse -V` (or `--version`) prints the version,
and `sidepulse <command> --help` shows a command's options. Aliases:
`status-bar` = `app`, `watch` = `live`, and `run` = `leds` without `--once`.

| Command | Purpose |
| --- | --- |
| `setup` | Install agent hooks and start the menu-bar app |
| `status` | Show the current agent status |
| `live` | Live full-screen dashboard of agent status |
| `write` | Write an LED program to a SidePulse device |
| `leds` | Mirror agent status to the LEDs (headless) |
| `run` | Run the headless SidePulse runtime in the foreground (`leds` without `--once`) |
| `install` | Install agent hooks (Claude Code, Codex) |
| `uninstall` | Remove agent hooks |
| `doctor` | Check hook installation and the app |
| `app` | Start, stop or inspect the menu-bar app |
| `settings` | Open the SidePulse settings window (starts the app if needed) |
| `version` | Print the version |
| `help` | Show help for sidepulse or one command |

**`sidepulse setup [claude|codex|all]... [--no-app] [--dry-run] [--no-migrate] [--no-trust]`**
- `--no-app`: only install hooks. Do not install or start the menu-bar app.
- `--dry-run`: show what would change without changing anything.
- `--no-migrate`: leave the Python SidePulse LaunchAgents alone.
- `--no-trust`: do not mark the Codex hooks trusted.

**`sidepulse status [--json] [--all] [--offline]`**
Asks the running app. If the app is not running, or with `--offline`, the
status is rebuilt from the hook logs with the same state machine.
- `--json`: print the snapshot as JSON.
- `--all`: also list stale agents.
- `--offline`: read the hook logs instead of asking the app.

**`sidepulse live [--interval 1] [--recent-seconds 3600] [--all] [--no-color] [--offline]`**
- `--interval SECONDS`: refresh interval (default 1).
- `--recent-seconds SECONDS`: hide agents idle longer than this (default 3600;
  0 shows all).
- `--all`: show every known agent, including stale ones.
- `--no-color`: disable ANSI colors. Colors are also off when `NO_COLOR` is set
  or stdout is not a terminal.
- `--offline`: read the hook logs instead of asking the app.

The table fits the terminal. Below 154 columns it drops Origin, Event and Tool
as needed, in that order, then narrows the other columns (the smallest table is
62 columns). The reason and source lines are cut to the width, and on narrow
terminals the header leaves out `updated=` and `quit=Ctrl-C` and cuts the
refresh/source line. From 154 columns up the layout is Python's, with Cwd
taking any extra room.

**`sidepulse write [PROGRAM|-] [--device PATH] [--file-name NAME] [--dry-run] [--manual]`**
`-` reads the program from stdin. Piped stdin is also read when no program
argument is given.
- `--device PATH`: device volume or its `LEDS.LED` (default: auto-discover).
- `--file-name NAME`: file to write on the volume (default `LEDS.LED`).
- `--dry-run`: validate and print the program without writing.
- `--manual`: switch the device to Manual so the app leaves it alone. A running
  app is asked to reload its settings (up to 3 s); if it is still writing to
  the device, a warning is printed and the write goes ahead.

**`sidepulse leds [--once] [--dry-run] [--device PATH] [--interval SECONDS]`**
Without `--once`, runs the SidePulse runtime in the foreground until Ctrl-C.
This is the menu-bar app without UI. It refuses to start while the app is
running.
- `--once`: sync once and exit. Every connected Agent-mode device is synced.
  Exits 2 on error.
- `--device PATH`: requires `--once`. Syncs only this device, whatever its
  display mode. To limit discovery in the foreground runtime, use
  `SIDEPULSE_MOUNT_ROOTS` instead.
- `--dry-run`: compute programs but never write them.
- `--interval SECONDS`: status refresh interval in the foreground (default 15).

**`sidepulse run [--dry-run] [--interval SECONDS]`**
The same as `sidepulse leds` without `--once`.

**`sidepulse install [claude|codex|all]... [--dry-run] [--no-trust]`**
With no provider named, installs hooks for each agent whose config directory
exists. Python-era SidePulse hooks are replaced. Hook commands call
`~/.local/bin/sidepulse` when it links to the CLI inside a `SidePulse.app`,
else that bundled CLI directly (or the running CLI for a development build).
A `~/.local/bin/sidepulse` that is anything else, such as the Python install's,
is ignored with a note. `$SIDEPULSE_CLI_PATH` overrides all of this.
- `--dry-run`: show what would change without writing.
- `--no-trust`: do not mark the Codex hooks trusted. Install then reminds you to
  approve them with `/hooks` in Codex.

**`sidepulse uninstall [claude|codex|all]... [--dry-run]`**
Removes SidePulse hooks, current and Python-era, from both providers by
default. Other hooks are left untouched.
- `--dry-run`: show what would change without writing.

**`sidepulse doctor [--json]`**
For each provider, reports: config path, installed and missing events,
`hook cli` (the CLI the installed hook commands call, and whether it exists and
is the SidePulse CLI, for example
`… (missing); run 'sidepulse install claude' to repair`), leftover Python
hooks, and the log file. A hook CLI equal to `$SIDEPULSE_CLI_PATH` is only
checked for existence. For Codex it also reports `trust: n/11 hooks trusted`,
with advice to approve them with `/hooks` or run `sidepulse install codex` when
entries are missing and the hooks feature is on. When the feature is off it
reports `hooks feature: disabled ([features] hooks is not true, so Codex runs
no hooks)`. The app block reports the app binary, the LaunchAgent plist,
whether the app is running (pid and version) and the socket path. It ends with
`cli: <path> (written by install)` (or `not found`), plus a note when
`~/.local/bin/sidepulse` is not the SidePulse CLI.
- `--json`: print the report as JSON. Each provider adds `hook_cli_paths`,
  `hook_cli_problems` and `untrusted_events`. `app` adds `cli_note`, and its
  `cli_path` may be null.

**`sidepulse app [start|stop|restart|status|install|uninstall] [--foreground]`**

| Action | Effect |
| --- | --- |
| `start` (default) | Starts the app: through the LaunchAgent when its plist exists (a plist that runs another binary is started as is, with a note to run `sidepulse app install`), otherwise opens `SidePulse.app` for this session only, without turning on launch at login. A running app is left alone ("already running (pid N)") |
| `stop` | Boots the app out. The plist stays, so the app returns at next login. An app running outside launchd must be quit from the menu bar |
| `restart` | `launchctl kickstart -k` of the LaunchAgent's instance. Fails when the app runs outside launchd |
| `status` | Shows plist, launchd and socket state. Exits 0 only when the app answers |
| `install` | Writes the LaunchAgent and starts it. If SidePulse already runs outside launchd, only writes the plist |
| `uninstall` | Boots the LaunchAgent out and deletes the plist |

- `--foreground`: only with `start`. Runs the app in this terminal instead of
  via launchd.

**`sidepulse settings`** asks the running app to open its Settings window, and
starts the app if needed: through its LaunchAgent when launch at login is on,
otherwise for this session only. It never changes the login item. If a headless
`sidepulse run` or `sidepulse leds` owns the socket, it says so instead.

**`sidepulse version`** and **`sidepulse help [COMMAND]`** print the version
and the help text.

`sidepulse hook-log --provider <claude|codex>` is the internal entry point that
agent hooks call. See [How hooks work](#how-hooks-work).

## Agent status

Every hook event maps to a mode. The mode decides the menu-bar icon and the LED
animation.

| Mode | Priority | Menu bar | Default LED (Cyan profile) | Set by |
| --- | --- | --- | --- | --- |
| Blocked / Error | 1 | Ask | `amber-pulse` | `PostToolUseFailure`, `PermissionDenied`, `StopFailure`, `PostToolUse` with a failed tool response |
| Waiting for Input | 2 | Ask | `amber-pulse` | `PermissionRequest`, a Notification that needs input, `Stop`/`SubagentStop` whose final message asks a question |
| Tool Running | 3 | Working | `cyan-roll` | `PreToolUse` |
| Long Task Progress | 4 | Working | `cyan-roll` | Explicit marker only (`progress`) |
| Working | 5 | Working | `cyan-roll` | `UserPromptSubmit`, `PreCompact`, `PostCompact`, `SubagentStart`, a successful `PostToolUse`, other Notifications |
| Completed | 6 | Done | `cyan-complete` | `Stop`/`SubagentStop` without a question, `SessionEnd`, a completion Notification, a subagent whose session ended (`SessionEnd`) or that the parent `Stop` no longer lists as running |
| Idle / Ready | 7 | Idle | `idle-pulse` | `SessionStart`, Codex `Interrupt` |

How the global display state is chosen:

- **Aggregation.** The display shows the highest-priority mode (lowest number)
  across all fresh agents. If any agent is blocked or waiting, the LEDs show
  that, not every agent separately. With no fresh agent, the display is Idle.
- **Staleness.** A row goes stale once it is older than the **Idle timeout**
  (default 1 hour, set in Settings > General). Stale rows drop out of the
  aggregate. `status --all` and `live --all` still list them. Tool Running has
  no separate time limit.
- **Done window.** A Completed row stays visible for 20 minutes, then drops
  out, and the LEDs return to the dim idle pattern. Completed and Idle rows are
  set aside while any other agent is active, so Done only shows when nothing
  else is running. Idle rows are hidden right away.
- **Idle prompts.** A Completed row ignores every Notification. Claude's
  `idle_prompt` Notification ("Claude is waiting for your input") is also
  ignored while the row is Idle, and for a session with no row yet (for
  example when the startup log scan begins after that session's `Stop`). So it
  never turns Done, a fresh session nobody has typed into, or a session whose
  history was not seen, into Ask. Other Notifications, such as permission
  prompts, still ask on a row that is not Completed.
- **Settling.** `PostToolUse` means the tool returned, not that the turn has
  finished. If no newer event arrives, the Working row settles to Completed
  after 2 minutes. This way a missed `Stop` cannot leave the display stuck on
  Working.
- **Sticky permissions.** A `PermissionRequest` for a command stays Ask until
  the matching `PostToolUse` or `PostToolUseFailure` (the approved command
  finished or failed), `Stop`, `Interrupt`, `SessionEnd`, the subagent's own
  `SubagentStop`, or the next prompt. Unrelated events from the same session
  cannot hide it. A denied command runs nothing, so it stays Ask until the turn
  ends or the next prompt.
- **Subagents.** Claude sends no `SubagentStop` for a subagent killed with its
  session. So `SessionEnd`, or a parent `Stop`'s list of running background
  tasks, closes those rows instead of leaving them active (and holding
  keep-awake) until the idle timeout.
- **Interrupt.** Codex `Interrupt` returns the session to Idle without marking
  it Completed.

### Explicit markers

The agent can state its hand-off state directly with a hidden line in its final
message:

```text
<!-- sidepulse:ask -->
<!-- sidepulse:done -->
<!-- sidepulse:working -->
<!-- sidepulse:blocked -->
<!-- sidepulse:idle -->
```

- A marker overrides the event rules for every event except `Interrupt`.
- A marker must be a whole line and is case-insensitive.
  `<!-- sidepulse status: ask -->` and `[sidepulse status: ask]` also work, and
  so does `agent-monitor` in place of `sidepulse`.
- Markers inside fenced code blocks are ignored.
- Accepted values:
  - `ask`, `question`, `waiting`, `input`: Waiting for Input
  - `blocked`, `error`: Blocked / Error
  - `working`: Working
  - `tool_running`: Tool Running
  - `progress`: Long Task Progress
  - `done`, `complete`, `completed`: Completed
  - `idle`, `ready`: Idle / Ready

Without a marker, a final message counts as a question only if one of its last
lines asks something concrete. "Want me to push?" counts as Ask, while casual
closers such as "Anything else?" count as Done. Questions inside code spans or
fenced blocks are ignored.

To make status reliable, add guidance like this to your agent instructions
(`CLAUDE.md`, `AGENTS.md`):

```text
When your final response needs user input, approval, or a decision, include
`<!-- sidepulse:ask -->` as a final hidden marker line. When the work is complete
and no user response is needed, include `<!-- sidepulse:done -->`.
```

## Menu-bar app

`SidePulse.app` is a menu-bar-only app with no Dock icon. The icon is an SF
Symbol for the aggregate state: Idle, Working, Done or Ask. Working rotates and
Ask pulses at 8 frames per second. The animation stops while the displays
sleep, while another user's session is in front, and when Reduce Motion is on.
The tooltip reads `SidePulse Agent Monitor: <state>`. If you open the app again
while it is running, for example from Finder, it shows Settings. A second copy
asks the running one to show Settings and exits. Only when the socket belongs
to a headless `sidepulse run` or `sidepulse leds` does it show an alert. A copy
started by the LaunchAgent exits quietly (see `app.log`).

| Menu item | What it does |
| --- | --- |
| `SidePulse — Working (2 active)` | Header: aggregate state and number of active agents |
| **Agents** | Up to 10 recent sessions (subagents fold into their session), by priority then recency. Includes Completed sessions from the last 48 hours by default. The tooltip shows state, event, tool, age and origin (for example "Claude Code CLI"). Click a session to open its working directory in Finder |
| **Devices** | One submenu per connected or remembered device: **Agent Status** / **Manual**, a **Brightness** slider, the last write error or permission notice (see **Permission** below), and **Remove** for devices that are not connected |
| **Keep Awake** | **Never** / **When Agents Work** / **Always**. "Keeping Mac awake" appears while the Mac is held awake |
| **Hooks** | One item per provider, for example `Claude Code — Installed`. Statuses: Installed; Needs repair (the hooks call a missing or non-SidePulse CLI); Installed, not trusted (Codex has no trust entry: approve with `/hooks` in Codex, or click to reinstall); Disabled; Partial; Not installed; Error. An agent whose config directory does not exist shows a disabled item (Not detected). Clicking uninstalls a complete install (after confirmation), and otherwise installs or repairs |
| **Open Logs Folder** | Reveals `logs/` in Finder |
| **Settings...** (⌘,) | Opens the settings window |
| **Launch at Login** | Adds or removes the LaunchAgent plist |
| **Quit SidePulse** (⌘Q) | Quits the app |

The Settings window has four tabs:

| Tab | Contents |
| --- | --- |
| General | **Idle timeout** (15 min to 4 hours, default 1 hour). **Keep recent sessions for** (12 hours to 7 days, default 48 hours). The Keep Awake policy. **Let Mac sleep on battery below** (0 to 100 % in steps of 5, default 20 %, 0 = off). **Launch at Login** |
| Animations | Profile picker: **Cyan** (the default), **Ember** or **Purple**. It shows **Current** when your picks match no profile. Per-state pickers for Idle / Ready, Working / Tool / Long Task (shared), Waiting for Input, Blocked / Error, Completed and Unknown. **Show** plays a pick on connected Agent-mode devices for 3 seconds, then restores live status |
| Devices | For each device: connection state, LED count, path, a **Display** switch (Agent Status / Manual), a **Brightness** slider, the last error or permission notice, and **Remove** when not connected |
| Hooks | For each provider: status, config path, the CLI its hooks call (**Hooks call**), leftover Python hooks, and **Install** / **Uninstall**. **Install writes** shows the command new hooks get, with **Refresh** |

The built-in animations are Slow Off, Immediate Off, Idle Pulse, Cyan Roll,
Cyan Complete, Amber Pulse, Solid Green, KITT Scanner, KITT Scanner Red, Night
Rider, and the Ember and Purple families (Idle, Tide, Attention, Complete).
Animations that depend on the LED layout have separate 2-LED and 8-LED
variants.

- **Devices.** The app polls `/Volumes` every 2 seconds, so devices can be
  plugged in and out at any time. Network filesystems mounted under `/Volumes`
  are skipped without being accessed. Dot and PulseDot volume names get the
  2-LED programs, and everything else gets the 8-LED ones. The app touches
  `keepalive` on each connected 8-LED volume (SidePulse Pro, including Manual
  ones) at most once a minute, which stops the MacBook SD reader from powering
  it off. Dots (USB) are never touched. A device that has
  never been seen before starts in Agent mode.
- **Manual mode.** In Manual mode, SidePulse never writes `LEDS.LED` on that
  device (a Pro still gets keepalive touches). Switching a connected device to
  Manual writes `off` once. `sidepulse write --manual` switches a device to
  Manual from the CLI.
- **Permission.** A device whose write or keepalive touch has been stuck for
  over 2 s, normally on the macOS removable-volume prompt, shows
  `Error: Waiting for macOS permission to access this device — check for a
  system prompt`. If macOS refuses to open `LEDS.LED`, it shows
  `Error: macOS denied access. Allow SidePulse in System Settings › Privacy &
  Security › Files and Folders (Removable Volumes)`. The Settings window's
  Devices tab shows the same text. A write that was waiting is skipped if the
  device became Manual in the meantime.
- **Brightness.** Each device has its own brightness, 0 to 255 (shown as a
  percentage). It scales any `brightness N` lines in the animation, or adds a
  `brightness` line when the program has none.
- **Keep awake.** The app holds a macOS power assertion
  (PreventUserIdleSystemSleep, listed by `pmset -g assertions` as "SidePulse
  keep awake"). The Mac does not idle-sleep, but the display may still sleep.
  The assertion goes away when the app quits. It is held while the policy asks
  for it:
  - **Always**: while the app runs.
  - **When Agents Work**: while any agent is Working, Tool Running or Long Task
    Progress, plus 5 minutes after a Completed, Ask or Blocked state.
  - **Never**: off.
  - **Low-battery safeguard**: on battery below the threshold (default 20 %),
    the Mac is always allowed to sleep.
- **Launch at login.** This is the LaunchAgent
  `~/Library/LaunchAgents/io.sidepulse.swift.plist`, with `RunAtLoad` and
  `KeepAlive = {SuccessfulExit: false}`. It also sets `PATH` (the installing
  shell's `PATH` plus `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`)
  so the app finds `codex` and `node`. launchd restarts the app after a crash,
  but it stays quit after **Quit**. Only `sidepulse app install`,
  `sidepulse setup` and the toggle write the plist. Turning the toggle on
  writes the plist for the running binary without starting a second copy.
  `sidepulse app uninstall` removes the plist.

## Files & paths

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/SidePulse/settings.json` | Settings: devices, animations, timeouts, keep-awake. Hand edits are picked up at the next refresh. An unreadable file is backed up before it is replaced |
| `…/SidePulse/latest.json` | Restart snapshot of agent rows, written with a short delay |
| `…/SidePulse/logs/claude.jsonl`, `logs/codex.jsonl` | Trimmed hook records, mode 0600. Rotated to `.1` at 8 MB |
| `…/SidePulse/events.sock` | Unix socket served by the app. Falls back to `/tmp/sidepulse-<uid>/events.sock` if the path is too long |
| `…/SidePulse/app.log`, `app.out.log`, `app.err.log` | App diagnostics, and the LaunchAgent's stdout and stderr |
| `~/Library/LaunchAgents/io.sidepulse.swift.plist` | Launch at login |
| `~/Applications/SidePulse.app` | The app (`--app-dir` changes the location). `sidepulse` also finds it in `/Applications` |
| `~/.local/bin/sidepulse` | Symlink to `SidePulse.app/Contents/Helpers/sidepulse`. This is the path written into hook commands when it links into a `SidePulse.app`; otherwise hooks call the bundled CLI directly |
| `~/.claude/settings.json`, `~/.codex/config.toml` | Agent configs. `$CODEX_HOME` is honored. Every change backs up the old file as `<file>.bak.<stamp>`. A symlinked config (dotfiles) keeps its link, and the real file behind it is updated. A read-only config is never rewritten: install and uninstall fail with `<path> is read-only; make it writable and try again` |
| `/Volumes/<device>/LEDS.LED`, `/Volumes/<device>/keepalive` | Device files (`keepalive` on 8-LED devices only) |

Environment overrides:

| Variable | Effect |
| --- | --- |
| `SIDEPULSE_HOME` | Replaces the data root (`~/Library/Application Support/SidePulse`) |
| `SIDEPULSE_MOUNT_ROOTS` | Colon-separated directories to scan for devices, instead of `/Volumes` |
| `SIDEPULSE_CLI_PATH` | CLI path to write into hook commands, taken as is (doctor only checks that it exists) |
| `SIDEPULSE_APP_PATH` | App bundle or binary used by `app`, `setup`, `settings` and `doctor` |
| `SIDEPULSE_DISABLE_EVENT_SOCKET=1` | The hook only logs and does not notify the app |
| `SIDEPULSE_AGENT_ORIGIN`, `SIDEPULSE_AGENT_ORIGIN_KIND` | Override the detected origin label, for example "Claude in VS Code" |
| `CODEX_HOME`, `CODEX_CLI_PATH` | Codex config directory, and the `codex` binary used for hook trust |
| `SIDEPULSE_CODESIGN_IDENTITY` | Code-signing identity for `scripts/build-app.sh` and `scripts/install.sh` (default: ad hoc) |

The app started by the LaunchAgent does not see variables exported in your
shell, except `PATH`, which is copied into the plist at install time.

## How hooks work

`sidepulse install` (or `setup`) writes one command per provider:

```text
/Users/you/.local/bin/sidepulse hook-log --provider claude ; true
```

The trailing `; true` makes a hook fail open: whatever happens, the agent sees
success. Each handler also gets a 10 s timeout.

- **Claude Code.** For each of `SessionStart`, `UserPromptSubmit`,
  `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
  `Notification`, `PreCompact`, `PostCompact`, `SubagentStop`, `Stop` and
  `SessionEnd`, the installer adds this entry to `hooks.<Event>`:
  `{"matcher": "*", "hooks": [{"type": "command", "command": "…", "timeout": 10}]}`.
  The rest of the file is preserved, and it is not rewritten when nothing
  changes.
- **Codex.** The installer writes one managed block between
  `# >>> sidepulse hooks >>>` and `# <<< sidepulse hooks <<<`. The block has
  one `[[hooks.<Event>]]` group each for `SessionStart`, `UserPromptSubmit`,
  `PreToolUse`, `PostToolUse`, `PermissionRequest`, `PreCompact`,
  `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop` and `Interrupt`. The
  installer adds `[features] hooks = true` when it is missing. An explicit
  `hooks = false` is left alone; install notes it, and Codex runs no hooks
  until you set it to true. Uninstall leaves `[features]` as it is.
- **Codex trust.** After writing the block, the installer finds `codex` in
  `$CODEX_CLI_PATH`, `ChatGPT.app` or `Codex.app`, `PATH`, then
  `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`,
  `~/.npm-global/bin`, `~/.volta/bin` and the newest
  `~/.nvm/versions/node/*/bin`. It asks `codex app-server --stdio` for the
  current hook hashes (`hooks/list`) and writes a
  `[hooks.state."<key>"] trusted_hash = "…"` table for each SidePulse hook.
  Trust entries for your own hooks are kept in step when their positions shift.
  If Codex is not found, or you pass `--no-trust`, approve the hooks with
  `/hooks` in Codex. With `hooks = false`, trust is skipped. Doctor, the menu
  and Settings report hooks without trust entries.
- **Identification.** SidePulse finds its own hooks, current and Python-era,
  by command markers such as `hook-log --provider`. It never goes by log
  paths, so your other hooks are never touched.

On every event, `sidepulse hook-log`:

1. Reads the JSON payload from stdin, up to 16 MiB and 3 s (nothing when stdin
   is a terminal).
2. Builds a **trimmed record**. The record keeps:
   - the event name, session, turn and agent ids, cwd and tool name;
   - `tool_input.command` (up to 2000 characters);
   - the `interrupted`, `success` and `exit_code` fields of the tool response,
     plus a `tool_response_failed` flag;
   - `prompt` (up to 4000 characters);
   - `last_assistant_message` (fenced code blocks removed, then up to 16000:
     the first 4000 plus the last 12000);
   - `message`, and notification and error fields;
   - `background_task_ids`: the ids of the tasks Claude lists as still running
     on `Stop`/`SubagentStop` (up to 32 ids of up to 128 characters; omitted
     when the list does not fit);
   - the detected origin.

   Invalid JSON becomes a `ParseError` record.
3. Appends the record as one line to `logs/<provider>.jsonl`.
4. Sends `{"provider": …, "line": {…}}` to `events.sock` with a 0.2 s timeout.

Each step is independent, so a dead socket never loses the log line. The hook
never writes to stdout and always exits 0. Python-era hook commands of the form
`sidepulse agent-monitor hook-log …` are still accepted.

### The runtime

The app owns the monitor state and all LED writes. `sidepulse run` runs the
same runtime without UI. The runtime does the following, per
`docs/ARCHITECTURE.md` and its doc comments:

- **Start.** It binds `events.sock` before writing anything, and refuses to
  start if another process already listens there. It then applies
  `settings.json`, loads `latest.json`, and reconciles the rows with the tail
  of the provider logs (the last 2000 lines of each). Finally it starts a 15 s
  status refresh and a 2 s device poll, and syncs the LEDs.
- **Event order.** Connections are read in parallel, but events are applied in
  the order the connections were accepted, so a hook's `PreToolUse` is never
  applied after its `PostToolUse`. A message waits at most 0.25 s behind an
  unfinished earlier connection.
- **LED sync.** Each event updates the status engine and triggers a coalesced
  LED sync, so the latest mode is never dropped. Each Agent-mode device is
  rewritten only when its state, brightness or animation changes, or when its
  `LEDS.LED` no longer holds the last program.
- **Settings.** It re-reads settings on a `reload-settings` socket command, or
  when the file's modification time changes.
- **Stop.** It flushes `latest.json` and releases the keep-awake assertion. The
  LEDs keep their last program.

The socket answers `ping`, `status`, `open-settings` and `reload-settings`, all
used by the CLI. `reload-settings` replies
`{"ok":false,"error":"LED write in progress"}` if a write that started with the
old settings is still running after 2 s. When the app is not running,
`sidepulse status` and `sidepulse live` rebuild the status from the logs.

## Known limitations

- Per-device settings are keyed by mount path, so a volume remounted as
  "PulseDot 1" is treated as a new device.
- A Codex `[[hooks.<Event>]]` group that mixes a user handler with a SidePulse
  handler is removed as a whole on install and uninstall.
- A failed tool call (any non-zero exit, for example `grep` with no match)
  briefly shows Blocked / Error. This is the same as the Python version.

## Development

```sh
swift build                                   # CLI, app and core library
swift test                                    # XCTest suites
swift run sidepulse --help
scripts/build-app.sh [--debug]                # build/SidePulse.app
SIDEPULSE_CODESIGN_IDENTITY="…" scripts/build-app.sh   # sign with a certificate
SIDEPULSE_HOME=/tmp/sp swift run sidepulse status --offline
```

For the layout, the module map and the project conventions, see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). `SidePulseCore` does not import
AppKit, so the hook process starts fast. An app run from a SwiftPM build
(`.build/debug/SidePulseApp`) installs hooks only when `~/.local/bin/sidepulse`
links into a `SidePulse.app` (or `$SIDEPULSE_CLI_PATH` is set), never with the
sibling `.build` CLI.

The tests use temporary homes and `SIDEPULSE_HOME`. They never modify your real
`~/.claude`, `~/.codex`, `~/Library/LaunchAgents` or data directory (a few
legacy-hook tests read copies of your agent configs).
`PowerKeepAwakeAssertionTests` always run and hold a real power assertion in the
test process for a moment.

Opt-in and environment-dependent tests:

| Variable | Test | What it does |
| --- | --- | --- |
| `SIDEPULSE_INTEGRATION=1` | `CLIIntegrationTests` | End-to-end CLI against the real core. `swift build` first for the hook-binary test. Run with `SIDEPULSE_INTEGRATION=1 swift test --filter CLIIntegration` |
| `SIDEPULSE_LAUNCHCTL_TESTS=1` | `LaunchAgentLaunchctlTests` | Real launchd round trip with a throwaway `/bin/sleep` agent |
| `SIDEPULSE_PYTHON_REPO=<path>` | LED animation and profile tests | Compares the embedded animations and profiles byte for byte with the Python checkout. The default path is `../sidepulse`, and the tests are skipped if it is absent |
| `SIDEPULSE_REGENERATE_BUILTINS=1` | `LEDBuiltInProgramsSourceTests` | Regenerates `Sources/SidePulseCore/LED/BuiltInPrograms.swift` from the Python checkout |
| `SIDEPULSE_STATUS_DIFF_DIR=<dir>` | `StatusDifferentialTests` | Scans copies of the provider logs in `<dir>/logs/` and writes `swift.json` for comparison with the Python collector. `SIDEPULSE_STATUS_DIFF_MAX_LINES` sets the scan depth (default 5000) |
| `SIDEPULSE_SKIP_CODEX_TESTS=1` | `HookInstallRealCodexTests` | Skips the trust check against a real `codex` binary, which otherwise runs whenever Codex is installed |

## Uninstall

```sh
scripts/uninstall.sh                 # remove hooks, LaunchAgent, app and CLI link
scripts/uninstall.sh --purge         # also delete ~/Library/Application Support/SidePulse
scripts/uninstall.sh --app-dir DIR   # only if neither the CLI link nor the LaunchAgent is left
```

`scripts/uninstall.sh` runs these steps:

1. Runs the app's own CLI: `sidepulse uninstall` removes the agent hooks and
   `sidepulse app uninstall` removes the LaunchAgent. It then boots out and
   deletes the plist in any case.
2. Stops a copy started by hand and removes the installed `SidePulse.app`: the
   one `~/.local/bin/sidepulse` points into, else the one the LaunchAgent runs,
   else `DIR/SidePulse.app` (`--app-dir` always wins). A bundle whose
   identifier is not `io.sidepulse.swift` is left alone with a warning. It
   removes `~/.local/bin/sidepulse` only if the link points into a
   `SidePulse.app`. A CLI that was moved aside during install stays at
   `sidepulse.previous`.
3. Keeps settings and logs unless you pass `--purge`.

To remove only parts of the install, use `sidepulse uninstall [claude|codex]`
for the hooks, and `sidepulse app uninstall` for launch at login.

## License

MIT. See [LICENSE](LICENSE). The built-in LED animations, animation profiles and
agent status rules are derived from the MIT-licensed Python
[sidepulse](https://github.com/inteliwear/sidepulse) by Peter Kuhar.
