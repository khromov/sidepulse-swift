// Generated from the Python implementation (sidepulse.cli render_snapshot,
// describe_status, render_watch_dashboard; TZ=UTC, COLUMNS=120) for differential
// tests. Paths: "/state/logs/claude.jsonl" exists, "/nonexistent/codex.jsonl" does not.
// The dashboard goldens are the Python output verbatim; the tests apply the
// documented deviations (title, source=, marker padding) before comparing.

enum CLIPythonGolden {
    static let describeA = "proj: task (abc12345): Tool Running event=PreToolUse origin=Claude Code CLI tool=Bash age=5s cwd=/tmp/proj"
    static let describeB = "A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project"
    static let describeC = "Done thing: Completed event=Stop age=4000s stale"
    static let describeD = "Sub agent: Working event=PostToolUse age=30s"
    static let render = """
        Aggregate: Waiting for Input (3 active, 1 stale)
        Reason: A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project
        
        Sources:
          claude: /state/logs/claude.jsonl [ok]
          codex: /nonexistent/codex.jsonl [missing]
        
        Agents:
          A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project
          proj: task (abc12345): Tool Running event=PreToolUse origin=Claude Code CLI tool=Bash age=5s cwd=/tmp/proj
          Sub agent: Working event=PostToolUse age=30s
        """
    static let renderAll = """
        Aggregate: Waiting for Input (3 active, 1 stale)
        Reason: A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project
        
        Sources:
          claude: /state/logs/claude.jsonl [ok]
          codex: /nonexistent/codex.jsonl [missing]
        
        Agents:
          A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project
          proj: task (abc12345): Tool Running event=PreToolUse origin=Claude Code CLI tool=Bash age=5s cwd=/tmp/proj
          Sub agent: Working event=PostToolUse age=30s
          Done thing: Completed event=Stop age=4000s stale
        """
    static let renderEmpty = """
        Aggregate: Idle / Ready (0 active, 0 stale)
        
        Sources:
          claude: /state/logs/claude.jsonl [ok]
          codex: /nonexistent/codex.jsonl [missing]
        
        Agents:
          none
        """
    static let dashboard = """
        Agent Monitor  aggregate=Waiting for Input  agents=3  updated=2026-09-26 10:00:00
        refresh=1s  showing=last 1h00m  active=3  stale=1  quit=Ctrl-C
        ========================================================================================================================
        reason: A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project
        
        Sources
          OK   claude  /state/logs/claude.jsonl
          MISS codex   /nonexistent/codex.jsonl
        
        Recently Active Agents
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        | Provider  | Agent                  | Origin             | Mode                 | Age      | Event              | Tool             | Cwd                |
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        | codex     | A very long display n. | -                  | Waiting for Input    | 2m05s    | PermissionRequest  | -                | /Users/someone/Do. |
        | claude    | proj: task (abc12345)  | Claude Code CLI    | Tool Running         | 5s       | PreToolUse         | Bash             | /tmp/proj          |
        | codex     | Sub agent              | -                  | Working              | 30s      | PostToolUse        | -                | -                  |
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        """
    static let dashboardAllColor = """
        \u{1B}[1mAgent Monitor\u{1B}[0m  aggregate=\u{1B}[33;1mWaiting for Input\u{1B}[0m  agents=4  updated=2026-09-26 10:00:00
        refresh=0.5s  showing=all known agents  active=3  stale=1  quit=Ctrl-C
        ========================================================================================================================
        reason: \u{1B}[33;1mA very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project\u{1B}[0m
        
        Sources
          \u{1B}[32mOK\u{1B}[0m claude  /state/logs/claude.jsonl
          \u{1B}[31mMISS\u{1B}[0m codex   /nonexistent/codex.jsonl
        
        Recently Active Agents
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        | Provider  | Agent                  | Origin             | Mode                 | Age      | Event              | Tool             | Cwd                |
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        | codex     | A very long display n. | -                  | \u{1B}[33;1mWaiting for Input   \u{1B}[0m | 2m05s    | PermissionRequest  | -                | /Users/someone/Do. |
        | claude    | proj: task (abc12345)  | Claude Code CLI    | \u{1B}[36;1mTool Running        \u{1B}[0m | 5s       | PreToolUse         | Bash             | /tmp/proj          |
        | codex     | Sub agent              | -                  | \u{1B}[34;1mWorking             \u{1B}[0m | 30s      | PostToolUse        | -                | -                  |
        | claude    | Done thing             | -                  | \u{1B}[32;1mCompleted           \u{1B}[0m | 1h06m    | Stop               | -                | -                  |
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        """
    static let dashboardRecent = """
        Agent Monitor  aggregate=Waiting for Input  agents=2  updated=2026-09-26 10:00:00
        refresh=2s  showing=last 1m00s  active=3  stale=1  quit=Ctrl-C
        ========================================================================================================================
        reason: A very long display name that will certainly be truncated here: Waiting for Input event=PermissionRequest age=125s cwd=/Users/someone/Documents/GitHub/some-really-long-project
        
        Sources
          OK   claude  /state/logs/claude.jsonl
          MISS codex   /nonexistent/codex.jsonl
        
        Recently Active Agents
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        | Provider  | Agent                  | Origin             | Mode                 | Age      | Event              | Tool             | Cwd                |
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        | claude    | proj: task (abc12345)  | Claude Code CLI    | Tool Running         | 5s       | PreToolUse         | Bash             | /tmp/proj          |
        | codex     | Sub agent              | -                  | Working              | 30s      | PostToolUse        | -                | -                  |
        +-----------+------------------------+--------------------+----------------------+----------+--------------------+------------------+--------------------+
        """
    static let dashboardEmpty = """
        Agent Monitor  aggregate=Idle / Ready  agents=0  updated=2026-09-26 10:00:00
        refresh=1s  showing=last 0s  active=0  stale=0  quit=Ctrl-C
        ========================================================================================================================
        reason: no recent agent status
        
        Sources
          OK   claude  /state/logs/claude.jsonl
          MISS codex   /nonexistent/codex.jsonl
        
        Recently Active Agents
          none
        """
}
