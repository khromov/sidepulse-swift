import XCTest
@testable import SidePulseCore

final class StatusDisplayNamesTests: XCTestCase {
    func testFallbackProviderLabels() {
        let vectors: [(String, String)] = [
            ("codex", "Codex"), ("claude", "Claude"), ("opencode", "OpenCode"), ("grok", "Grok"), ("", ""),
        ]
        for (provider, label) in vectors {
            XCTAssertEqual(DisplayNames.fallbackProviderLabel(provider), label, provider)
        }
    }

    func testTruncateMatchesPython() {
        let vectors: [(String, Int, String)] = [
            ("hello world", 5, "hell..."), ("abcdefghij", 5, "abcd..."), ("one two three four five", 12, "one two..."),
            ("one, two; three", 10, "one, two..."), (String(repeating: "x", count: 100), 96, String(repeating: "x", count: 95) + "..."),
            ("short", 96, "short"), ("ab cdefghijkl", 8, "ab cdef..."), ("  padded   text here", 10, "  padded..."),
            ("exactly ten", 11, "exactly ten"),
        ]
        for (text, limit, expected) in vectors {
            XCTAssertEqual(DisplayNames.truncate(text, limit), expected, text)
        }
    }

    func testTruncateCountsCodePoints() {
        // "e" + U+0301 is one grapheme but two code points (Python counts two).
        let text = String(repeating: "e\u{301}", count: 6)
        XCTAssertEqual(DisplayNames.truncate(text, 12), text)
        XCTAssertEqual(DisplayNames.truncate(text, 11).unicodeScalars.count, 10 + 3)
    }

    func testSummarizePromptMatchesPython() {
        // Expected values produced by collector.summarize_prompt.
        let vectors: [(String, String?)] = [
            ("\n# Files mentioned by the user:\n\n## codex-clipboard.png: /var/folders/tmp/codex-clipboard.png\n\n## My request for Codex:\nteam id YOUR_TEAM_ID, push key '/path/to/AuthKey_YOUR_KEY_ID.p8'\n",
             "team id YOUR_TEAM_ID, push key '/path/to/AuthKey_YOUR_KEY_ID.p8'"),
            ("<user_query>\nWhat is here\n</user_query>", "What is here"),
            ("convert these videos to mp4", "convert these videos to mp4"),
            ("<task-notification><status>completed</status></task-notification>", nil),
            ("  ", nil),
            ("Fix `foo()` in /Users/k/Documents/GitHub/app/src/main.swift please", "Fix foo() in ... please"),
            ("Look at '/tmp/some dir/file.txt' and \"~/notes.md\"", "Look at '...' and \"...\""),
            ("```swift\nlet x = 1\n```\nExplain this code - it crashes: ", "Explain this code - it crashes"),
            ("## Heading\n### Sub heading text", "Heading Sub heading text"),
            ("Please refactor the entire networking layer so that every request goes through a single retry policy with exponential backoff",
             "Please refactor the entire networking layer so that every request..."),
            (String(repeating: "a,b;c ", count: 20), "a,b;c a,b;c a,b;c a,b;c a,b;c a,b;c a,b;c a,b;c a,b;c a,b;c a,b;c a,b..."),
            ("--- : leading junk", "leading junk"),
            ("Check ~/Library/Logs/x.log, and /private/var/tmp/y;z", "Check ..., and ...;z"),
            ("\u{C9}moji \u{1F389} test with \u{FC}n\u{EF}c\u{F6}d\u{E9} characters that goes on and on and on to exceed the seventy two limit",
             "\u{C9}moji \u{1F389} test with \u{FC}n\u{EF}c\u{F6}d\u{E9} characters that goes on and on and on to..."),
        ]
        for (prompt, expected) in vectors {
            XCTAssertEqual(DisplayNames.summarizePrompt(prompt), expected, prompt)
        }
        XCTAssertNil(DisplayNames.summarizePrompt(nil))
        XCTAssertEqual(DisplayNames.summarizePrompt("one two three four", limit: 10), "one two...")
    }

    func testDisplayNameFromPartsMatchesPython() {
        XCTAssertEqual(DisplayNames.displayName(project: "sidepulse", title: "fix the test", short: "1ca4348e", fallback: "fb"),
                       "sidepulse: fix the test (1ca4348e)")
        XCTAssertEqual(DisplayNames.displayName(project: "ai_food", title: "ai_food", short: "019f7724", fallback: "fb"), "ai_food (019f7724)")
        XCTAssertEqual(DisplayNames.displayName(project: "ai-food", title: "AI Food", short: "019f7724", fallback: "fb"), "AI Food (019f7724)")
        XCTAssertEqual(DisplayNames.displayName(project: nil, title: "t", short: "s", fallback: "fb"), "t (s)")
        XCTAssertEqual(DisplayNames.displayName(project: "p", title: nil, short: "s", fallback: "fb"), "p (s)")
        XCTAssertEqual(DisplayNames.displayName(project: "", title: "", short: "s", fallback: "Claude session s"), "Claude session s")
        XCTAssertEqual(DisplayNames.displayName(project: "proj", title: String(repeating: "x", count: 120), short: "abcd1234", fallback: "fb"),
                       "proj: " + String(repeating: "x", count: 89) + "...")
    }

    func testNormalizeForComparison() {
        XCTAssertEqual(DisplayNames.normalizeForComparison("  AI_food--App \t x"), "ai food app x")
        // Python casefold(), not lower(): ß folds to "ss".
        XCTAssertEqual(DisplayNames.normalizeForComparison("  Stra\u{DF}e_X  "), "strasse x")
        XCTAssertEqual(DisplayNames.displayName(project: "strasse", title: "Stra\u{DF}e", short: "s", fallback: "fb"), "Stra\u{DF}e (s)")
        XCTAssertEqual(DisplayNames.displayName(project: "MASSE", title: "Ma\u{DF}e", short: "s", fallback: "fb"), "Ma\u{DF}e (s)")
        // `-`/`_` followed by a combining mark are still replaced (code points, not graphemes).
        XCTAssertEqual(DisplayNames.normalizeForComparison("a-\u{301}b_\u{301}c"), "a \u{301}b \u{301}c")
        XCTAssertEqual(DisplayNames.displayName(project: "my-\u{301}app", title: "My \u{301}App", short: "s", fallback: "fb"),
                       "My \u{301}App (s)")
    }

    func testProjectNameWalksUpToGitRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusDisplayNames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("my_repo")
        let nested = repo.appendingPathComponent("packages/site/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(DisplayNames.projectName(cwd: nested.path), "my_repo")
        XCTAssertEqual(DisplayNames.projectName(cwd: repo.path + "/"), "my_repo")

        // A `.git` file (worktrees, submodules) counts too.
        let worktree = root.appendingPathComponent("worktree/sub")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: x".utf8).write(to: root.appendingPathComponent("worktree/.git"))
        XCTAssertEqual(DisplayNames.resolveProjectName(cwd: worktree.path), "worktree")

        XCTAssertEqual(DisplayNames.resolveProjectName(cwd: root.appendingPathComponent("plain/dir").path), "dir")
        XCTAssertEqual(DisplayNames.resolveProjectName(cwd: "/Users/pero/git/ai_food/"), "ai_food")
        // A combining mark right after a slash must not hide the separator.
        XCTAssertEqual(DisplayNames.resolveProjectName(cwd: root.appendingPathComponent("x").path + "/\u{301}proj"), "\u{301}proj")
        XCTAssertEqual(DisplayNames.resolveProjectName(cwd: "/"), "/")
        XCTAssertNil(DisplayNames.projectName(cwd: nil))
        XCTAssertNil(DisplayNames.projectName(cwd: ""))
    }

    func testCachedProjectNameNeverTouchesTheFilesystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusDisplayNames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("cached_repo/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cached_repo/.git"), withIntermediateDirectories: true)

        XCTAssertNil(DisplayNames.cachedProjectName(cwd: nested.path), "a miss resolves nothing")
        XCTAssertEqual(DisplayNames.projectName(cwd: nested.path), "cached_repo")
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(DisplayNames.cachedProjectName(cwd: nested.path), "cached_repo")
        XCTAssertNil(DisplayNames.cachedProjectName(cwd: nil))
        XCTAssertNil(DisplayNames.cachedProjectName(cwd: ""))
    }

    func testShortIDUsesTheTailOfOpenCodeIDs() {
        XCTAssertEqual(DisplayNames.shortID("019ee395-2f64-7cc3"), "019ee395")
        XCTAssertEqual(DisplayNames.shortID("a72ce317aff816536"), "a72ce317")
        XCTAssertEqual(DisplayNames.shortID("ses_f212d491cffeAbCdEfGh12"), "CdEfGh12")
        XCTAssertEqual(DisplayNames.shortID("ses_f212ee51affeZyXwVuTs34"), "XwVuTs34")
        XCTAssertEqual(DisplayNames.shortID("ses_y"), "ses_y")
        XCTAssertEqual(DisplayNames.shortID("abc"), "abc")
    }
}
