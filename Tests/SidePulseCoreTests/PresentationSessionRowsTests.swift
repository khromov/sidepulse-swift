import XCTest
@testable import SidePulseCore

/// Session-row selection, titles and detail text. Vectors ported from the Python
/// tests `test_status_bar_*` in tests/test_sidepulse.py.
final class PresentationSessionRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Resolver that never touches the filesystem: plain cwd basename.
    private let basename: SessionRows.ProjectResolver = { cwd in
        cwd.map { ($0 as NSString).lastPathComponent }
    }

    private func status(_ provider: String, _ agentID: String, _ name: String, _ mode: AgentMode,
                        age: TimeInterval = 0, event: String = "Stop", session: String? = nil,
                        cwd: String? = nil, tool: String? = nil, origin: String? = nil,
                        stale: Bool = false) -> AgentStatus {
        AgentStatus(provider: provider, agentID: agentID, displayName: name, mode: mode,
                    updatedAt: now.addingTimeInterval(-age), eventName: event, sessionID: session,
                    cwd: cwd, toolName: tool, origin: origin, stale: stale)
    }

    private func snapshot(_ statuses: [AgentStatus], stale: [AgentStatus] = [],
                          mode: AgentMode = .completed) -> MonitorSnapshot {
        MonitorSnapshot(collectedAt: now, sources: [],
                        aggregate: AggregateStatus(mode: mode, activeCount: 0, staleCount: stale.count,
                                                   representative: statuses.first),
                        statuses: statuses, staleStatuses: stale)
    }

    // MARK: Titles

    func testMenuTitleIsTaskAndProject() {
        let s = status("codex", "codex:session:019ee395", "sidepulse: Refine README agent status modes (019ee395)",
                       .completed, session: "019ee395", cwd: "/Users/pero/pgit/sidepulse")
        let row = SessionRows.rows(for: [s], now: now, projectName: basename)[0]
        XCTAssertEqual(row.title, "Refine README agent status modes")
        XCTAssertEqual(row.project, "sidepulse")
        XCTAssertEqual(row.menuTitle, "Refine README agent status modes  sidepulse")
        XCTAssertEqual(row.detail.components(separatedBy: " · ").first, "Done")
        XCTAssertEqual(row.displayState, .done)
    }

    func testDuplicateProjectIsSuppressed() {
        let s = status("grok", "grok:session:019f7724", "ai_food (019f7724)", .waitingForInput,
                       event: "Notification", session: "019f7724", cwd: "/Users/pero/git/ai_food")
        let parts = SessionRows.titleParts(s, project: basename(s.cwd))
        XCTAssertEqual(parts.title, "ai_food")
        XCTAssertNil(parts.project)
        XCTAssertEqual(SessionRows.rows(for: [s], now: now, projectName: basename)[0].menuTitle, "ai_food")
    }

    func testProjectComesFromGitRootAndDisplayPrefixIsDropped() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-presentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = tmp.appendingPathComponent("peterkuhar.com")
        let cwd = project.appendingPathComponent("functions")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let s = status("claude", "claude:session:b64a0d4b",
                       "functions: allow me to chose timeframe http://localhost:5001/pkuhar-com/us-central... (b64a0d4b)",
                       .working, event: "PostToolUse", session: "b64a0d4b-d828-4133-abb3-bdb4fafa7719",
                       cwd: cwd.path, origin: "Claude in VS Code")
        let title = SessionRows.rows(for: [s], now: now)[0].menuTitle
        XCTAssertEqual(title, "allow me to chose timeframe http://localhost:5001/pkuhar-com/us-central...  peterkuhar.com")
        XCTAssertFalse(title.contains("Working"))
        XCTAssertFalse(title.contains("Claude in VS Code"))
    }

    func testDisplayPrefixBecomesProjectWithoutCwd() {
        let s = status("codex", "codex:session:x", "tmp: Greet user (01a0b075)", .completed, session: "01a0b075-aaaa")
        let parts = SessionRows.titleParts(s, project: nil)
        XCTAssertEqual(parts.title, "Greet user")
        XCTAssertEqual(parts.project, "tmp")
    }

    func testCwdProjectWinsOverDisplayPrefix() {
        let s = status("codex", "codex:session:x", "other: Fix bug", .completed)
        let parts = SessionRows.titleParts(s, project: "repo")
        XCTAssertEqual(parts.title, "Fix bug")
        XCTAssertEqual(parts.project, "repo")
    }

    func testEmptyTitleFallsBackToDisplayName() {
        let blank = status("codex", "codex:session:x", "   ", .completed)
        let parts = SessionRows.titleParts(blank, project: nil)
        XCTAssertEqual(parts.title, "   ")
        XCTAssertNil(parts.project)
        // Trailing whitespace is stripped first, so "repo: " never yields an empty title.
        let trailing = SessionRows.titleParts(status("codex", "codex:session:y", "repo: ", .completed), project: "repo")
        XCTAssertEqual(trailing.title, "repo:")
        XCTAssertEqual(trailing.project, "repo")
        // An empty resolved project counts as none, so the display prefix is used.
        let emptyProject = SessionRows.titleParts(status("codex", "codex:session:z", "x: y", .completed), project: "")
        XCTAssertEqual(emptyProject.title, "y")
        XCTAssertEqual(emptyProject.project, "x")
    }

    func testStripShortID() {
        XCTAssertEqual(SessionRows.stripShortID("  Claude abc  ", sessionID: nil), "Claude abc")
        XCTAssertEqual(SessionRows.stripShortID("Task (019ee395)", sessionID: "019ee395-2f64-7cc3"), "Task")
        XCTAssertEqual(SessionRows.stripShortID("Task (abcdef)", sessionID: nil), "Task")
        XCTAssertEqual(SessionRows.stripShortID("Task (recent-d)", sessionID: "recent-done"), "Task")
        XCTAssertEqual(SessionRows.stripShortID("Task (abcdefghijkl)", sessionID: nil), "Task")
        XCTAssertEqual(SessionRows.stripShortID("Task (abcde)", sessionID: nil), "Task (abcde)")
        XCTAssertEqual(SessionRows.stripShortID("Task (abcdefghijklm)", sessionID: nil), "Task (abcdefghijklm)")
        XCTAssertEqual(SessionRows.stripShortID("Task (ab_cdef)", sessionID: nil), "Task (ab_cdef)")
        XCTAssertEqual(SessionRows.stripShortID("x: what is this? (agent ac7f1721)", sessionID: "f9ccc24e"),
                       "x: what is this? (agent ac7f1721)")
        XCTAssertEqual(SessionRows.stripShortID(" ()", sessionID: nil), "()")
    }

    /// Regression: the menu had its own project lookup, which kept a trailing `.`
    /// as the project while the display name was built with the real one.
    func testDefaultResolverIsTheDisplayNameLookup() {
        let s = status("claude", "claude:session:abcdef12", "proj: Fix it (abcdef12)", .completed,
                       session: "abcdef12-0000", cwd: "/nonexistent-sidepulse-test/proj/.")
        let row = SessionRows.rows(for: [s], now: now)[0]
        XCTAssertEqual(row.title, "Fix it")
        XCTAssertEqual(row.project, "proj")
        XCTAssertEqual(SessionRows.projectName(cwd: "/nonexistent-sidepulse-test/proj/."), "proj")
    }

    /// Regression: titles were compared with a grapheme-based `-` replacement, which
    /// misses a `-` followed by a combining mark (Python replaces code points).
    func testCollisionKeyNormalizesCodePoints() {
        let a = status("codex", "codex:session:aaaaaaaa1", "Fix my-\u{301}app", .completed, age: 1, session: "aaaaaaaa1")
        let b = status("codex", "codex:session:bbbbbbbb1", "Fix my_\u{301}app", .completed, age: 2, session: "bbbbbbbb1")
        XCTAssertEqual(SessionRows.rows(for: [a, b], now: now, projectName: basename).map(\.title),
                       ["Fix my-\u{301}app (aaaaaaaa)", "Fix my_\u{301}app (bbbbbbbb)"])
        // Casefolding and whitespace collapsing, as in Python `normalized_menu_part`.
        let parts = SessionRows.titleParts(status("codex", "codex:session:c", "Ai_Food-App \t X", .completed),
                                           project: "  ai food app x ")
        XCTAssertNil(parts.project)
    }

    // MARK: Selection

    func testDistinctSessionsWithSameTitleAreKeptAndSorted() {
        let older = status("grok", "grok:session:019ffd2e-2060-7ff2-842f-761cb458ccf4", "msdosfs: What is here (019ffd2e)",
                           .completed, age: 20, session: "019ffd2e-2060-7ff2-842f-761cb458ccf4",
                           cwd: "/Users/pero/temp/msdosfs", origin: "Grok CLI")
        let newer = status("grok", "grok:session:019ffd37-1458-7d92-b077-3d0f92aedde4", "msdosfs: What is here (019ffd37)",
                           .completed, age: 4, session: "019ffd37-1458-7d92-b077-3d0f92aedde4",
                           cwd: "/Users/pero/temp/msdosfs", origin: "Grok CLI")
        let other = status("grok", "grok:session:other", "other: What is here (019ffd99)", .completed, age: 2,
                           session: "019ffd99-0000-0000-0000-000000000000", cwd: "/Users/pero/temp/other",
                           origin: "Grok CLI")
        let snap = snapshot([older, newer, other])
        XCTAssertEqual(SessionRows.recent(snapshot: snap, retention: 172_800).map(\.agentID),
                       ["grok:session:other", newer.agentID, older.agentID])

        let titles = SessionRows.rows(snapshot: snap, retention: 172_800, projectName: basename).map(\.menuTitle)
        XCTAssertEqual(titles, ["What is here  other", "What is here (019ffd37)  msdosfs",
                                "What is here (019ffd2e)  msdosfs"])
    }

    func testCollisionsAreScopedByProvider() {
        let a = status("codex", "codex:session:aaaaaaaa1", "repo: Same (aaaaaaaa)", .completed, age: 1,
                       session: "aaaaaaaa1", cwd: "/x/repo")
        let b = status("claude", "claude:session:bbbbbbbb1", "repo: Same (bbbbbbbb)", .completed, age: 2,
                       session: "bbbbbbbb1", cwd: "/x/repo")
        let c = status("codex", "codex:session:cccccccc1", "repo: SAME (cccccccc)", .completed, age: 3,
                       session: "cccccccc1", cwd: "/y/Repo")
        let titles = SessionRows.rows(for: [a, b, c], now: now, projectName: basename).map(\.menuTitle)
        XCTAssertEqual(titles, ["Same (aaaaaaaa)  repo", "Same  repo", "SAME (cccccccc)  Repo"])
    }

    func testCollidingRowWithoutSessionIDKeepsTitle() {
        let a = status("codex", "codex:unknown", "Same", .completed, age: 1)
        let b = status("codex", "codex:session:s2", "Same", .completed, age: 2, session: "s2")
        let titles = SessionRows.rows(for: [a, b], now: now, projectName: basename).map(\.title)
        XCTAssertEqual(titles, ["Same", "Same (s2)"])
    }

    func testSubagentsCoalesceIntoTheirSession() {
        let sessionID = "f9ccc24e-3dad-4607-95e6-4142428a93cc"
        let main = status("claude", "claude:session:\(sessionID)", "peterkuhar.com: so all good? (f9ccc24e)",
                          .completed, age: 40, event: "SessionEnd", session: sessionID,
                          cwd: "/Users/pero/pgit/peterkuhar.com", origin: "Claude Code CLI")
        let sub = status("claude", "claude:agent:ac7f1721ec697b403", "peterkuhar.com: what is this repo about? (agent ac7f1721)",
                         .completed, age: 4, event: "SubagentStop", session: sessionID,
                         cwd: "/Users/pero/pgit/peterkuhar.com", origin: "Claude Code CLI")
        XCTAssertEqual(SessionRows.recent(snapshot: snapshot([main, sub]), retention: 172_800).map(\.agentID),
                       [main.agentID])
    }

    func testCoalesceKeepsHigherPrioritySubagentAndMatchesProviderCaseInsensitively() {
        let main = status("Claude", "claude:session:s", "Main", .completed, age: 1, session: "s")
        let sub = status("claude", "claude:agent:a1", "Sub", .toolRunning, age: 30, event: "PreToolUse", session: "s")
        let otherProvider = status("codex", "codex:session:s", "Codex", .completed, age: 2, session: "s")
        let result = SessionRows.coalesce([main, sub, otherProvider])
        XCTAssertEqual(result.map(\.agentID), ["claude:agent:a1", "codex:session:s"])
    }

    func testCoalesceTieKeepsFirstAndPassthroughComesLast() {
        let first = status("codex", "codex:session:s#1", "First", .completed, age: 5, session: "s")
        let second = status("codex", "codex:session:s#2", "Second", .completed, age: 5, session: "s")
        let loose = status("codex", "codex:unknown", "Loose", .working, age: 1, event: "UserPromptSubmit")
        let later = status("claude", "claude:session:t", "Later", .completed, age: 9, session: "t")
        XCTAssertEqual(SessionRows.coalesce([loose, first, second, later]).map(\.displayName),
                       ["First", "Later", "Loose"])
        let emptySession = status("codex", "codex:session:", "Empty", .completed, session: "")
        XCTAssertEqual(SessionRows.coalesce([emptySession, emptySession]).count, 2)
    }

    func testRecentIncludesRecentDoneWhileActive() {
        let working = status("codex", "codex:session:working", "project: Working session (working)", .toolRunning,
                             event: "PreToolUse", session: "working", cwd: "/Users/pero/pgit/project")
        let recentDone = status("grok", "grok:session:recent-done", "other: Recent done (recent-d)", .completed,
                                age: 8 * 60, session: "recent-done", cwd: "/Users/pero/pgit/other", stale: true)
        let oldDone = status("claude", "claude:session:old-done", "old: Old done (old-done)", .completed,
                             age: 49 * 3600, session: "old-done", cwd: "/Users/pero/pgit/old", stale: true)
        let staleWorking = status("codex", "codex:session:stuck", "Stuck", .toolRunning, age: 60,
                                  event: "PreToolUse", session: "stuck", stale: true)
        let snap = snapshot([working], stale: [recentDone, oldDone, staleWorking], mode: .toolRunning)
        XCTAssertEqual(SessionRows.recent(snapshot: snap, retention: 172_800).compactMap(\.sessionID),
                       ["working", "recent-done"])
    }

    func testRecentKeepsLastTenWithinRetention() {
        let done = (1...12).map { i in
            status("codex", "codex:session:done-\(i)", "project: Done \(i) (done-\(i))", .completed,
                   age: TimeInterval(i) * 3600, session: "done-\(i)", cwd: "/Users/pero/pgit/project", stale: true)
        }
        let tooOld = status("claude", "claude:session:too-old", "old: Too old (too-old)", .completed,
                            age: 50 * 3600, session: "too-old", cwd: "/Users/pero/pgit/old", stale: true)
        let snap = snapshot([], stale: done + [tooOld], mode: .idleReady)

        let recent = SessionRows.recent(snapshot: snap, retention: 48 * 3600)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.sessionID, "done-1")
        XCTAssertEqual(recent.last?.sessionID, "done-10")
        XCTAssertFalse(recent.contains { $0.sessionID == "too-old" })

        XCTAssertEqual(SessionRows.recent(snapshot: snap, retention: 2.5 * 3600).compactMap(\.sessionID),
                       ["done-1", "done-2"])
        XCTAssertEqual(SessionRows.rows(snapshot: snap, retention: 48 * 3600, limit: 3, projectName: basename).count, 3)
    }

    func testRecentSortsByPriorityThenNewest() {
        let done = status("codex", "codex:session:d", "Done", .completed, age: 1, session: "d")
        let ask = status("claude", "claude:session:a", "Ask", .waitingForInput, age: 100, event: "Notification", session: "a")
        let blocked = status("codex", "codex:session:b", "Blocked", .blockedError, age: 500, event: "StopFailure", session: "b")
        let workNew = status("codex", "codex:session:w1", "W1", .working, age: 5, event: "UserPromptSubmit", session: "w1")
        let workOld = status("codex", "codex:session:w2", "W2", .working, age: 50, event: "UserPromptSubmit", session: "w2")
        let snap = snapshot([done, workOld, ask, workNew, blocked])
        XCTAssertEqual(SessionRows.recent(snapshot: snap, retention: 60).map(\.displayName),
                       ["Blocked", "Ask", "W1", "W2", "Done"])
    }

    // MARK: Detail

    func testDetailText() {
        let s = status("claude", "claude:session:s", "repo: Task", .toolRunning, age: 125, event: "PreToolUse",
                       session: "s", tool: "Bash", origin: "Claude Code CLI")
        XCTAssertEqual(SessionRows.detail(for: s, now: now), "Working · PreToolUse · Bash · 2m ago · Claude Code CLI")

        let noOrigin = status("codex", "codex:session:t", "Task", .completed, age: 5, event: "Stop", session: "t",
                              tool: "  ", origin: " ")
        XCTAssertEqual(SessionRows.detail(for: noOrigin, now: now), "Done · Stop · 5s ago · Codex")

        let vscode = status("claude", "claude:session:abc", "Claude abc", .waitingForInput, event: "Notification",
                            session: "1ca4348e-2aec-4147-9e81-d7d56364d257", origin: "Claude in VS Code")
        XCTAssertEqual(SessionRows.detail(for: vscode, now: now), "Ask · Notification · 0s ago · Claude in VS Code")

        let future = status("grok", "grok:session:g", "G", .idleReady, age: -30, event: "", session: "g")
        XCTAssertEqual(SessionRows.detail(for: future, now: now), "Idle · 0s ago · Grok")
    }

    func testMenuProviderLabel() {
        XCTAssertEqual(SessionRows.menuProviderLabel("claude"), "Claude Code")
        XCTAssertEqual(SessionRows.menuProviderLabel("Codex"), "Codex")
        XCTAssertEqual(SessionRows.menuProviderLabel("opencode"), "Opencode")
        XCTAssertEqual(SessionRows.menuProviderLabel(""), "Agent")
    }

    func testAgeFormats() {
        let relative: [(TimeInterval, String)] = [
            (-5, "0s ago"), (0, "0s ago"), (59.9, "59s ago"), (60, "1m ago"), (125, "2m ago"),
            (3599, "59m ago"), (3600, "1h ago"), (86_399, "23h ago"), (86_400, "1d ago"),
            (9 * 86_400 + 5, "9d ago"), (.nan, "0s ago"), (.infinity, "0s ago"),
        ]
        for (seconds, expected) in relative {
            XCTAssertEqual(AgeFormat.relative(seconds), expected, "\(seconds)")
        }
        XCTAssertEqual(AgeFormat.wholeSeconds(1e300), Int(Int32.max))
    }
}
