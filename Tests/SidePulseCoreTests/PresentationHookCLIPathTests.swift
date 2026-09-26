import XCTest
@testable import SidePulseCore

final class PresentationHookCLIPathTests: XCTestCase {
    private var tmp: URL!
    private var home: URL!
    private var bundle: URL!
    private var app: URL!
    private var helper: URL!
    private var link: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-hookcli-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("home", isDirectory: true)
        bundle = tmp.appendingPathComponent("Apps/SidePulse.app")
        app = bundle.appendingPathComponent("Contents/MacOS/SidePulse")
        helper = bundle.appendingPathComponent("Contents/Helpers/sidepulse")
        link = home.appendingPathComponent(".local/bin/sidepulse")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeExecutable(app)
        try makeExecutable(helper)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func paths(_ environment: [String: String] = [:]) -> SidePulsePaths {
        var env = environment
        env["SIDEPULSE_HOME"] = tmp.appendingPathComponent("root").path
        env["HOME"] = home.path
        return SidePulsePaths(environment: env, home: home)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: resolve

    func testAppUsesTheStableLinkWhenItPointsAtAHelper() throws {
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: app.path), helper.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: app.path), link.path)
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(["SIDEPULSE_CLI_PATH": "/opt/sp"]), runningExecutable: app.path),
                       "/opt/sp")
    }

    /// Regression: any executable at ~/.local/bin/sidepulse was written into hooks,
    /// including the Python CLI, whose `hook-log` needs `--log` and exits 2.
    func testForeignStableLinkIsIgnoredAndReported() throws {
        let python = tmp.appendingPathComponent("venv/bin/sidepulse")
        try makeExecutable(python)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: python)
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: app.path), helper.path)
        XCTAssertEqual(HookCLIPath.problem(with: link.path, runningExecutable: app.path), "not the SidePulse CLI")
        let note = try XCTUnwrap(HookCLIPath.foreignLinkNote(paths: paths(), runningExecutable: app.path))
        XCTAssertTrue(note.contains(python.path) && note.contains("is not the SidePulse CLI"), note)
        XCTAssertNil(HookCLIPath.foreignLinkNote(paths: paths(["SIDEPULSE_CLI_PATH": "/opt/sp"]), runningExecutable: app.path))
    }

    func testDanglingStableLinkIsSkippedAndReported() throws {
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/sidepulse")
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: app.path), helper.path)
        XCTAssertTrue(HookCLIPath.foreignLinkNote(paths: paths(), runningExecutable: app.path)?
            .contains("/nonexistent/sidepulse, which does not exist") ?? false)
        try FileManager.default.removeItem(at: link)
        XCTAssertNil(HookCLIPath.foreignLinkNote(paths: paths(), runningExecutable: app.path))
    }

    func testNeverReturnsTheAppBinary() throws {
        try FileManager.default.removeItem(at: helper)
        XCTAssertNil(HookCLIPath.resolve(paths: paths(), runningExecutable: app.path))
        XCTAssertNil(HookCLIPath.resolve(paths: paths(), runningExecutable: tmp.appendingPathComponent("debug/SidePulseApp").path))
        XCTAssertFalse(HookCLIPath.notFoundMessage.isEmpty)
    }

    func testRunningCLIIsTheLastResort() throws {
        let cli = tmp.appendingPathComponent("debug/sidepulse")
        try makeExecutable(cli)
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: cli.path), cli.path)
        XCTAssertNil(HookCLIPath.problem(with: cli.path, runningExecutable: cli.path))
        XCTAssertEqual(HookCLIPath.problem(with: cli.path, runningExecutable: app.path), "not the SidePulse CLI")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: cli.path), link.path)
        // The bundled CLI does not take a link to some other CLI; it writes its own path.
        XCTAssertEqual(HookCLIPath.resolve(paths: paths(), runningExecutable: helper.path), helper.path)
    }

    func testProblemWithMissingPath() {
        XCTAssertEqual(HookCLIPath.problem(with: tmp.appendingPathComponent("gone").path, runningExecutable: app.path), "missing")
        XCTAssertNil(HookCLIPath.problem(with: helper.path, runningExecutable: app.path))
    }

    func testEnclosingBundle() {
        XCTAssertEqual(HookCLIPath.enclosingBundle(of: "/Applications/SidePulse.app/Contents/Helpers/sidepulse")?.path,
                       "/Applications/SidePulse.app")
        XCTAssertEqual(HookCLIPath.enclosingBundle(of: "/Users/x/Apps/Other Name.app/Contents/MacOS/SidePulse")?.path,
                       "/Users/x/Apps/Other Name.app")
        XCTAssertNil(HookCLIPath.enclosingBundle(of: "/usr/local/bin/sidepulse"))
        XCTAssertNil(HookCLIPath.enclosingBundle(of: "/Applications/SidePulse.app/Contents/Resources/sidepulse"))
        XCTAssertNil(HookCLIPath.enclosingBundle(of: "/Applications/SidePulse/Contents/Helpers/sidepulse"))
        XCTAssertNil(HookCLIPath.enclosingBundle(of: "/Applications/SidePulse.app/Contents/Helpers/other"))
    }

    func testSameFile() throws {
        let symlink = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: helper)
        XCTAssertTrue(HookCLIPath.sameFile(helper.path, helper.path))
        XCTAssertTrue(HookCLIPath.sameFile(symlink.path, helper.path))
        XCTAssertFalse(HookCLIPath.sameFile(helper.path, app.path))
        XCTAssertFalse(HookCLIPath.sameFile(helper.path, tmp.appendingPathComponent("missing").path))
    }
}
