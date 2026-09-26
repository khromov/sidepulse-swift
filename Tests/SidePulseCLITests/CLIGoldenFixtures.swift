// Python output (render_snapshot, describe_status, render_watch_dashboard; TZ=UTC, COLUMNS=120)
// where only "/state/logs/claude.jsonl" exists.
// The dashboard goldens are verbatim, so the tests apply the documented deviations (title, source=,
// marker padding) before comparing.

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
}
