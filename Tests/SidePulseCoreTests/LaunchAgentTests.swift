import XCTest
@testable import SidePulseCore

final class LaunchAgentFakeLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var loaded: [String: Int] = [:]   // service target → pid
    private var nextPID = 1000
    var failBootstrapTimes = 0
    var bootoutIsIneffective = false

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func verbs() -> [String] { calls.map { $0.first ?? "" } }
    func isLoaded(_ target: String) -> Bool { lock.lock(); defer { lock.unlock() }; return loaded[target] != nil }
    func load(_ target: String) { lock.lock(); loaded[target] = nextPID; nextPID += 1; lock.unlock() }

    var runner: LaunchAgentManager.LaunchctlRunner { { [self] args in self.handle(args) } }

    private func handle(_ args: [String]) -> (status: Int32, output: String) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(args)
        switch args.first {
        case "print":
            guard let pid = loaded[args[1]] else { return (113, "Could not find service \"\(args[1])\" in domain for user gui: 501") }
            return (0, "\(args[1]) = {\n\tactive count = 1\n\tstate = running\n\tpid = \(pid)\n}\n")
        case "bootstrap":
            if failBootstrapTimes > 0 {
                failBootstrapTimes -= 1
                return (5, "Bootstrap failed: 5: Input/output error")
            }
            guard let data = FileManager.default.contents(atPath: args[2]),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { return (2, "no plist") }
            let target = "\(args[1])/\(label)"
            if loaded[target] != nil { return (5, "Bootstrap failed: 5: Input/output error") }
            loaded[target] = nextPID
            nextPID += 1
            return (0, "")
        case "bootout":
            guard loaded[args[1]] != nil else { return (3, "Boot-out failed: 3: No such process") }
            if !bootoutIsIneffective { loaded[args[1]] = nil }
            return (0, "")
        case "kickstart":
            let target = args.last!
            guard loaded[target] != nil else { return (113, "Could not find service") }
            if args.contains("-k") { loaded[target] = nextPID; nextPID += 1 }
            return (0, "")
        default:
            return (64, "unexpected \(args)")
        }
    }
}

final class LaunchAgentManagerTests: XCTestCase {
    func testPlistContentsAreValidAndComplete() throws {
        let box = try HookInstallSandbox()
        let manager = LaunchAgentManager(paths: box.paths)
        let args = ["/Applications/SidePulse & Co.app/Contents/MacOS/SidePulseApp", "--flag=<\"quoted\">'s"]
        let xml = manager.plistContents(programArguments: args)
        let file = box.root.appendingPathComponent("test.plist")
        try box.write(xml, to: file)

        let lint = Process()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lint.arguments = ["-lint", file.path]
        lint.standardOutput = FileHandle.nullDevice
        try lint.run()
        lint.waitUntilExit()
        XCTAssertEqual(lint.terminationStatus, 0, "plutil -lint")

        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "io.sidepulse.swift")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], args)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["StandardOutPath"] as? String, box.paths.root.appendingPathComponent("app.out.log").path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, box.paths.root.appendingPathComponent("app.err.log").path)
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["PATH"],
                       "/usr/bin:/bin:/usr/sbin:/sbin:\(box.home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(plist.count, 8)
        let order = ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ProcessType", "EnvironmentVariables",
                     "StandardOutPath", "StandardErrorPath"]
            .map { xml.range(of: "<key>\($0)</key>")!.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(manager.plistURL, box.home.appendingPathComponent("Library/LaunchAgents/io.sidepulse.swift.plist"))
    }

    /// Regression: launchd's minimal PATH kept an npm-installed codex (`#!/usr/bin/env node`) from
    /// starting, so Codex trust failed from the menu.
    func testPlistCarriesTheInstallingPath() throws {
        let box = try HookInstallSandbox(extraEnvironment: ["PATH": "/opt/node/bin:relative/bin:/usr/local/bin:/usr/bin"])
        let manager = LaunchAgentManager(paths: box.paths)
        XCTAssertEqual(manager.launchPath,
                       "/opt/node/bin:/usr/local/bin:/usr/bin:\(box.home.path)/.local/bin:/opt/homebrew/bin")
    }

    func testInstalledProgramArguments() throws {
        let box = try HookInstallSandbox()
        let manager = LaunchAgentManager(paths: box.paths, runner: LaunchAgentFakeLaunchd().runner)
        XCTAssertNil(manager.installedProgramArguments())
        try manager.install(programArguments: ["/Apps/SidePulse.app/Contents/MacOS/SidePulse"], start: false)
        XCTAssertEqual(manager.installedProgramArguments(), ["/Apps/SidePulse.app/Contents/MacOS/SidePulse"])
        try box.write("not a plist", to: manager.plistURL)
        XCTAssertNil(manager.installedProgramArguments())
    }

    func testInstallWritesOnlyWhenChangedAndStarts() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        let manager = LaunchAgentManager(paths: box.paths, runner: fake.runner)
        XCTAssertTrue(try manager.install(programArguments: ["/bin/app"], start: false))
        XCTAssertEqual(fake.calls, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.paths.root.path), "log directory is created")
        let attributes = try FileManager.default.attributesOfItem(atPath: manager.plistURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertFalse(try manager.install(programArguments: ["/bin/app"], start: false))
        XCTAssertTrue(try manager.install(programArguments: ["/bin/app2"], start: false))

        XCTAssertFalse(try manager.install(programArguments: ["/bin/app2"], start: true))
        XCTAssertEqual(fake.verbs().filter { $0 != "print" }, ["bootout", "bootstrap", "kickstart"])
        XCTAssertEqual(fake.calls.first { $0.first == "bootstrap" }, ["bootstrap", LaunchAgentManager.domain, manager.plistURL.path])
        XCTAssertEqual(fake.calls.last, ["kickstart", "gui/\(getuid())/io.sidepulse.swift"])
        XCTAssertTrue(manager.status().loaded)
    }

    func testInstallRestartsRunningAgent() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        let manager = LaunchAgentManager(paths: box.paths, runner: fake.runner)
        try manager.install(programArguments: ["/bin/app"], start: true)
        let firstPID = manager.status().pid
        try manager.install(programArguments: ["/bin/app"], start: true)
        XCTAssertNotNil(firstPID)
        XCTAssertNotEqual(manager.status().pid, firstPID)
    }

    func testBootstrapIsRetriedAfterTransientFailure() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        fake.failBootstrapTimes = 2
        let manager = LaunchAgentManager(paths: box.paths, runner: fake.runner)
        try manager.install(programArguments: ["/bin/app"], start: true)
        XCTAssertEqual(fake.verbs().filter { $0 == "bootstrap" }.count, 3)
        XCTAssertTrue(manager.status().loaded)

        fake.failBootstrapTimes = 10
        try manager.stop()
        XCTAssertThrowsError(try manager.start()) { error in
            XCTAssertTrue(String(describing: error).contains("Input/output error"), "\(error)")
        }
    }

    func testStartStopStatusUninstall() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        let manager = LaunchAgentManager(paths: box.paths, label: "io.sidepulse.test", runner: fake.runner)
        XCTAssertEqual(manager.status(), LaunchAgentStatus(installed: false, loaded: false))
        XCTAssertThrowsError(try manager.start(), "no plist yet")

        try manager.install(programArguments: ["/bin/app"], start: false)
        XCTAssertEqual(manager.status(), LaunchAgentStatus(installed: true, loaded: false))
        try manager.start()
        let started = manager.status()
        XCTAssertTrue(started.loaded)
        XCTAssertNotNil(started.pid)
        XCTAssertFalse(fake.calls.contains { $0.contains("-k") }, "a fresh bootstrap is not restarted")

        try manager.start()
        XCTAssertEqual(manager.status().pid, started.pid, "plain kickstart leaves a running agent alone")
        try manager.start(restart: true)
        XCTAssertEqual(fake.calls.last, ["kickstart", "-k", "gui/\(getuid())/io.sidepulse.test"])
        XCTAssertNotEqual(manager.status().pid, started.pid)

        try manager.stop()
        XCTAssertEqual(manager.status(), LaunchAgentStatus(installed: true, loaded: false))
        let before = fake.calls.count
        try manager.stop()
        XCTAssertEqual(fake.calls.count - before, 1, "stopping a stopped agent only checks its state")

        try manager.start()
        try manager.uninstall()
        XCTAssertEqual(manager.status(), LaunchAgentStatus(installed: false, loaded: false))
        XCTAssertNoThrow(try manager.uninstall(), "uninstalling twice is fine")
    }

    func testStopReportsFailure() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        var manager = LaunchAgentManager(paths: box.paths, runner: fake.runner)
        manager.unloadTimeout = 0.2
        try manager.install(programArguments: ["/bin/app"], start: true)
        fake.bootoutIsIneffective = true
        XCTAssertThrowsError(try manager.stop())
    }

    func testParsePID() {
        XCTAssertEqual(LaunchAgentManager.parsePID("gui/501/x = {\n\tstate = running\n\n\tpid = 4242\n\timmediate reason = x\n}"), 4242)
        XCTAssertNil(LaunchAgentManager.parsePID("gui/501/x = {\n\tstate = not running\n}"))
    }

    func testRealLaunchctlWrapperRunsReadOnlyCommand() {
        // `launchctl version` is read-only.
        let result = LaunchAgentManager.launchctl(["version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.output.isEmpty)
        XCTAssertNotEqual(LaunchAgentManager.launchctl(["print", "gui/\(getuid())/io.sidepulse.swift.selftest.missing"]).status, 0)
    }
}

final class LaunchAgentMigrationTests: XCTestCase {
    private func makePlists(_ box: HookInstallSandbox, _ labels: [String]) throws -> [String: URL] {
        var out: [String: URL] = [:]
        for label in labels {
            let url = box.paths.launchAgentsDir.appendingPathComponent("\(label).plist")
            try box.write(LaunchAgentManager(paths: box.paths, label: label).plistContents(programArguments: ["/bin/true"]), to: url)
            out[label] = url
        }
        return out
    }

    func testScratchHomeOnlyDeletesPlists() throws {
        let box = try HookInstallSandbox()
        XCTAssertNil(LegacyPythonMigration.defaultRunner(for: box.paths), "launchctl is never used for a scratch home")
        XCTAssertEqual(LegacyPythonMigration.plan(paths: box.paths), [])
        let plists = try makePlists(box, ["io.sidepulse.service", "com.pixiepulse.agentstatus", "io.sidepulse.sdejectguard", "io.sidepulse.swift"])
        let service = plists["io.sidepulse.service"]!.path
        let pixie = plists["com.pixiepulse.agentstatus"]!.path

        XCTAssertEqual(LegacyPythonMigration.plan(paths: box.paths), ["remove \(service)", "remove \(pixie)"])
        XCTAssertEqual(LegacyPythonMigration.run(paths: box.paths, dryRun: true), ["would remove \(service)", "would remove \(pixie)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: service))
        XCTAssertEqual(LegacyPythonMigration.run(paths: box.paths, dryRun: false), ["removed \(service)", "removed \(pixie)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: service))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pixie))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plists["io.sidepulse.sdejectguard"]!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plists["io.sidepulse.swift"]!.path))
        XCTAssertEqual(LegacyPythonMigration.run(paths: box.paths, dryRun: false), [])
    }

    func testLoadedAgentsAreBootedOut() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        let domain = LaunchAgentManager.domain
        fake.load("\(domain)/io.sidepulse.agentstatus")   // loaded, plist already gone
        fake.load("\(domain)/io.sidepulse.service")
        fake.load("\(domain)/io.sidepulse.sdejectguard")
        let service = try makePlists(box, ["io.sidepulse.service"])["io.sidepulse.service"]!.path

        XCTAssertEqual(LegacyPythonMigration.plan(paths: box.paths, launchctl: fake.runner), [
            "stop io.sidepulse.agentstatus (loaded in launchd)",
            "stop io.sidepulse.service (loaded in launchd)",
            "remove \(service)",
        ])
        XCTAssertEqual(LegacyPythonMigration.run(paths: box.paths, dryRun: true, launchctl: fake.runner), [
            "would stop io.sidepulse.agentstatus", "would stop io.sidepulse.service", "would remove \(service)",
        ])
        XCTAssertFalse(fake.verbs().contains("bootout"))
        XCTAssertEqual(LegacyPythonMigration.run(paths: box.paths, dryRun: false, launchctl: fake.runner), [
            "stopped io.sidepulse.agentstatus", "stopped io.sidepulse.service", "removed \(service)",
        ])
        XCTAssertFalse(fake.isLoaded("\(domain)/io.sidepulse.service"))
        XCTAssertTrue(fake.isLoaded("\(domain)/io.sidepulse.sdejectguard"), "the eject guard is left alone")
        XCTAssertEqual(fake.calls.filter { $0.first == "bootout" }.map { $0[1] },
                       ["\(domain)/io.sidepulse.agentstatus", "\(domain)/io.sidepulse.service"])
    }

    func testFailedBootoutIsReported() throws {
        let box = try HookInstallSandbox()
        let fake = LaunchAgentFakeLaunchd()
        fake.load("\(LaunchAgentManager.domain)/com.sidepulse.agentstatus")
        fake.bootoutIsIneffective = true
        let messages = LegacyPythonMigration.run(paths: box.paths, dryRun: false, launchctl: fake.runner)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("could not stop com.sidepulse.agentstatus"), messages[0])
    }

    func testDefaultRunnerOnlyForTheRealHome() throws {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { throw XCTSkip("no passwd entry") }
        let real = SidePulsePaths(environment: [:], home: URL(fileURLWithPath: String(cString: dir)))
        XCTAssertNotNil(LegacyPythonMigration.defaultRunner(for: real))
    }
}

/// Opt-in with `SIDEPULSE_LAUNCHCTL_TESTS=1` because it round-trips a throwaway `/bin/sleep` agent
/// through the real launchd.
final class LaunchAgentLaunchctlTests: XCTestCase {
    func testRealLaunchdRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["SIDEPULSE_LAUNCHCTL_TESTS"] == "1" else {
            throw XCTSkip("set SIDEPULSE_LAUNCHCTL_TESTS=1 to run against the real launchd")
        }
        let box = try HookInstallSandbox()
        let label = "io.sidepulse.swift.selftest.\(UInt32.random(in: 0...UInt32.max))"
        let manager = LaunchAgentManager(paths: box.paths, label: label)
        addTeardownBlock {
            _ = LaunchAgentManager.launchctl(["bootout", manager.serviceTarget])
            try? FileManager.default.removeItem(at: manager.plistURL)
            box.cleanup()
        }

        XCTAssertTrue(try manager.install(programArguments: ["/bin/sleep", "600"], start: true))
        let started = manager.status()
        XCTAssertTrue(started.installed)
        XCTAssertTrue(started.loaded)
        XCTAssertNotNil(started.pid)

        try manager.start(restart: true)
        var restarted = manager.status()
        for _ in 0..<20 where restarted.pid == nil || restarted.pid == started.pid {
            usleep(100_000)
            restarted = manager.status()
        }
        XCTAssertTrue(restarted.loaded)
        XCTAssertNotEqual(restarted.pid, started.pid)

        try manager.stop()
        XCTAssertEqual(manager.status(), LaunchAgentStatus(installed: true, loaded: false))
        try manager.start()
        XCTAssertTrue(manager.status().loaded)
        XCTAssertFalse(try manager.install(programArguments: ["/bin/sleep", "600"], start: true), "unchanged plist")
        XCTAssertTrue(manager.status().loaded)

        try manager.uninstall()
        XCTAssertEqual(manager.status(), LaunchAgentStatus(installed: false, loaded: false))
    }
}
