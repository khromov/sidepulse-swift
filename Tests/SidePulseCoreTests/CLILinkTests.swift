import XCTest
@testable import SidePulseCore

final class CLILinkTests: XCTestCase {
    private var tmp: URL!
    private var home: URL!
    private var app: URL!
    private var helper: URL!
    private var link: URL!
    private var paths: SidePulsePaths!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-clilink-\(UUID().uuidString)")
        home = tmp.appendingPathComponent("home", isDirectory: true)
        app = tmp.appendingPathComponent("Applications/SidePulse.app/Contents/MacOS/SidePulse")
        helper = tmp.appendingPathComponent("Applications/SidePulse.app/Contents/Helpers/sidepulse")
        link = home.appendingPathComponent(".local/bin/sidepulse")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try makeExecutable(app)
        try makeExecutable(helper)
        paths = SidePulsePaths(environment: ["HOME": home.path, "SIDEPULSE_HOME": tmp.appendingPathComponent("root").path],
                               home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeExecutable(_ url: URL, _ text: String = "#!/bin/sh\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func symlink(_ destination: String) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    private func linkDestination() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    // MARK: state

    func testStateOfTheLink() throws {
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .missing)
        try symlink(helper.path)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .installed)
        // The CLI itself sees the same state as the app it belongs to.
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: helper.path), .installed)
    }

    func testLinkIntoAnotherAppOrAMissingTargetIsStale() throws {
        let other = tmp.appendingPathComponent("Old/SidePulse.app/Contents/Helpers/sidepulse")
        try makeExecutable(other)
        try symlink(other.path)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .otherApp(target: other.path))
        try FileManager.default.removeItem(at: other)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .broken(target: other.path))
    }

    func testRelativeTargetIsReportedAbsolute() throws {
        let other = home.appendingPathComponent("Apps/SidePulse.app/Contents/Helpers/sidepulse")
        try makeExecutable(other)
        try symlink("../../Apps/SidePulse.app/Contents/Helpers/sidepulse")
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .otherApp(target: other.path))
    }

    func testForeignCLIIsNeverStale() throws {
        let python = tmp.appendingPathComponent("venv/bin/sidepulse")
        try makeExecutable(python)
        try symlink(python.path)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .foreign(target: python.path))
        XCTAssertFalse(CLILink.state(paths: paths, runningExecutable: app.path).relinksAtLaunch)
        try FileManager.default.removeItem(at: link)
        try makeExecutable(link)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .foreign(target: nil))
    }

    func testUnavailableOutsideAStableApp() throws {
        let debug = tmp.appendingPathComponent(".build/debug/SidePulseApp")
        try makeExecutable(debug)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: debug.path),
                       .unavailable(reason: CLILink.notInAppMessage))
        let moved = tmp.appendingPathComponent("T/AppTranslocation/0A1B/d/SidePulse.app")
        try makeExecutable(moved.appendingPathComponent("Contents/MacOS/SidePulse"))
        try makeExecutable(moved.appendingPathComponent("Contents/Helpers/sidepulse"))
        let translocated = moved.appendingPathComponent("Contents/MacOS/SidePulse").path
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: translocated),
                       .unavailable(reason: HookCLIPath.translocatedMessage))
        XCTAssertThrowsError(try CLILink.install(paths: paths, runningExecutable: translocated)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, HookCLIPath.translocatedMessage)
        }
        XCTAssertNil(try CLILink.installAtLaunch(paths: paths, runningExecutable: translocated))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.deletingLastPathComponent().path))
    }

    func testAppWithoutABundledCLIIsUnavailable() throws {
        try FileManager.default.removeItem(at: helper)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path),
                       .unavailable(reason: CLILink.notInAppMessage))
    }

    // MARK: install

    func testInstallCreatesTheDirectoryAndLink() throws {
        let change = try CLILink.install(paths: paths, runningExecutable: app.path)
        XCTAssertEqual(change, CLILinkChange(link: link, target: helper.path))
        XCTAssertEqual(try linkDestination(), helper.path)
        XCTAssertEqual(CLILink.state(paths: paths, runningExecutable: app.path), .installed)
        XCTAssertEqual(HookCLIPath.resolve(paths: paths, runningExecutable: app.path), link.path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: link.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["sidepulse"])
    }

    func testInstallReplacesAForeignLinkAndMovesAFileAside() throws {
        try symlink("/nonexistent/venv/bin/sidepulse")
        XCTAssertEqual(try CLILink.install(paths: paths, runningExecutable: app.path).previousTarget,
                       "/nonexistent/venv/bin/sidepulse")
        XCTAssertEqual(try linkDestination(), helper.path)

        try FileManager.default.removeItem(at: link)
        try makeExecutable(link, "#!/bin/sh\necho mine\n")
        let change = try CLILink.install(paths: paths, runningExecutable: app.path)
        let aside = link.deletingLastPathComponent().appendingPathComponent("sidepulse.previous")
        XCTAssertEqual(change.movedAside, aside)
        XCTAssertNil(change.previousTarget)
        XCTAssertEqual(FileUtil.readText(aside), "#!/bin/sh\necho mine\n")
        XCTAssertEqual(try linkDestination(), helper.path)
    }

    func testLaunchRelinksOnlyStaleLinks() throws {
        XCTAssertEqual(try CLILink.installAtLaunch(paths: paths, runningExecutable: app.path)?.target, helper.path)
        XCTAssertNil(try CLILink.installAtLaunch(paths: paths, runningExecutable: app.path))

        let other = tmp.appendingPathComponent("Old/SidePulse.app/Contents/Helpers/sidepulse")
        try makeExecutable(other)
        try FileManager.default.removeItem(at: link)
        try symlink(other.path)
        let change = try XCTUnwrap(try CLILink.installAtLaunch(paths: paths, runningExecutable: app.path))
        XCTAssertEqual(change.previousTarget, other.path)
        XCTAssertEqual(try linkDestination(), helper.path)

        try FileManager.default.removeItem(at: link)
        try symlink("/gone/SidePulse.app/Contents/Helpers/sidepulse")
        XCTAssertNotNil(try CLILink.installAtLaunch(paths: paths, runningExecutable: app.path))
        XCTAssertEqual(try linkDestination(), helper.path)

        let python = tmp.appendingPathComponent("venv/bin/sidepulse")
        try makeExecutable(python)
        try FileManager.default.removeItem(at: link)
        try symlink(python.path)
        XCTAssertNil(try CLILink.installAtLaunch(paths: paths, runningExecutable: app.path))
        XCTAssertEqual(try linkDestination(), python.path)
    }

    func testInstallFailsWhenTheBinDirectoryIsAFile() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local"), withIntermediateDirectories: true)
        try Data().write(to: link.deletingLastPathComponent())
        XCTAssertThrowsError(try CLILink.install(paths: paths, runningExecutable: app.path))
    }

    // MARK: ShellPATH

    func testParseTakesTheLineAfterTheLastMarker() {
        XCTAssertEqual(ShellPATH.parse("welcome\n\(ShellPATH.marker)\n/a:/b\n"), ["/a", "/b"])
        XCTAssertEqual(ShellPATH.parse("\(ShellPATH.marker)\n/x\n\(ShellPATH.marker)\r\n/a:/b\r\n"), ["/a", "/b"])
        XCTAssertNil(ShellPATH.parse("/a:/b\n"))
        XCTAssertNil(ShellPATH.parse("\(ShellPATH.marker)\n"))
        XCTAssertNil(ShellPATH.parse("\(ShellPATH.marker)\n\n"))
    }

    func testCheckLooksUpTheCommandLikeAShell() throws {
        _ = try CLILink.install(paths: paths, runningExecutable: app.path)
        let bin = link.deletingLastPathComponent().path
        let other = tmp.appendingPathComponent("brew/bin")
        try makeExecutable(other.appendingPathComponent("sidepulse"))
        let empty = tmp.appendingPathComponent("empty/bin").path

        XCTAssertEqual(ShellPATH.check(searchPath: [empty, bin, other.path], link: link, home: home), .found)
        XCTAssertEqual(ShellPATH.check(searchPath: ["~/.local/bin"], link: link, home: home), .found)
        XCTAssertEqual(ShellPATH.check(searchPath: [bin + "/"], link: link, home: home), .found)
        XCTAssertEqual(ShellPATH.check(searchPath: [other.path, bin], link: link, home: home),
                       .shadowed(by: other.appendingPathComponent("sidepulse").path))
        XCTAssertEqual(ShellPATH.check(searchPath: ["/usr/bin", "", ".local/bin", empty], link: link, home: home), .notOnPath)
        XCTAssertEqual(ShellPATH.check(searchPath: nil, link: link, home: home), .unknown)
    }

    func testCheckSkipsADirectoryNamedSidepulse() throws {
        let dir = tmp.appendingPathComponent("odd/bin")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sidepulse"), withIntermediateDirectories: true)
        XCTAssertEqual(ShellPATH.check(searchPath: [dir.path], link: link, home: home), .notOnPath)
    }

    /// The fake shell prints startup noise, then runs the probe command it was given with `-c`.
    func testReadRunsTheShellWithTheProbeCommand() throws {
        let shell = tmp.appendingPathComponent("fakeshell")
        try makeExecutable(shell, "#!/bin/sh\necho 'Last login: today'\n[ \"$1 $2 $3\" = '-i -l -c' ] || exit 1\nPATH=/one:/two:/usr/bin exec /bin/sh -c \"$4\"\n")
        XCTAssertEqual(ShellPATH.read(shell: shell.path), ["/one", "/two", "/usr/bin"])
    }

    func testReadGivesUpOnASlowOrBrokenShell() throws {
        let slow = tmp.appendingPathComponent("slowshell")
        try makeExecutable(slow, "#!/bin/sh\nexec /bin/sleep 5\n")
        let start = Date()
        XCTAssertNil(ShellPATH.read(shell: slow.path, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertNil(ShellPATH.read(shell: tmp.appendingPathComponent("missing").path))
    }

    // MARK: ShellProfile

    func testProfileFileForEachShell() throws {
        XCTAssertEqual(ShellProfile.file(shell: "/bin/zsh", paths: paths), home.appendingPathComponent(".zprofile"))
        let zdot = SidePulsePaths(environment: ["HOME": home.path, "ZDOTDIR": tmp.appendingPathComponent("zdot").path],
                                  home: home)
        XCTAssertEqual(ShellProfile.file(shell: "/opt/homebrew/bin/zsh", paths: zdot)?.path,
                       tmp.appendingPathComponent("zdot/.zprofile").path)
        XCTAssertEqual(ShellProfile.file(shell: "/bin/bash", paths: paths), home.appendingPathComponent(".bash_profile"))
        try Data().write(to: home.appendingPathComponent(".profile"))
        XCTAssertEqual(ShellProfile.file(shell: "/bin/bash", paths: paths), home.appendingPathComponent(".profile"))
        XCTAssertNil(ShellProfile.file(shell: "/opt/homebrew/bin/fish", paths: paths))
    }

    func testAddLocalBinAppendsOnceAndBacksUp() throws {
        let profile = home.appendingPathComponent(".zprofile")
        XCTAssertTrue(try ShellProfile.addLocalBin(to: profile))
        XCTAssertEqual(FileUtil.readText(profile),
                       "# Added by SidePulse for the sidepulse command\nexport PATH=\"$HOME/.local/bin:$PATH\"\n")

        try Data("eval \"$(/opt/homebrew/bin/brew shellenv)\"".utf8).write(to: profile)
        XCTAssertTrue(try ShellProfile.addLocalBin(to: profile))
        XCTAssertEqual(FileUtil.readText(profile), "eval \"$(/opt/homebrew/bin/brew shellenv)\"\n\n"
                       + "# Added by SidePulse for the sidepulse command\nexport PATH=\"$HOME/.local/bin:$PATH\"\n")
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".zprofile.bak.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertFalse(try ShellProfile.addLocalBin(to: profile))
    }

    func testAddLocalBinKeepsADotfileLinkAndRefusesReadOnlyFiles() throws {
        let real = tmp.appendingPathComponent("dotfiles/zprofile")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# mine\n".utf8).write(to: real)
        let profile = home.appendingPathComponent(".zprofile")
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: real)
        XCTAssertTrue(try ShellProfile.addLocalBin(to: profile))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: profile.path), real.path)
        XCTAssertTrue(FileUtil.readText(real)?.hasSuffix("export PATH=\"$HOME/.local/bin:$PATH\"\n") ?? false)

        let locked = home.appendingPathComponent(".bash_profile")
        try Data("# mine\n".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        XCTAssertThrowsError(try ShellProfile.addLocalBin(to: locked))
        XCTAssertEqual(FileUtil.readText(locked), "# mine\n")
    }

    // MARK: Presentation

    func testSummaryShowsPathsRelativeToHome() {
        let summary = { CLILinkPresentation.summary($0, link: self.link, home: self.home) }
        XCTAssertEqual(summary(.installed), CLILinkSummary(status: "Installed",
            detail: "~/.local/bin/sidepulse runs this app's sidepulse command.", canInstall: false))
        XCTAssertEqual(summary(.missing).canInstall, true)
        XCTAssertEqual(summary(.otherApp(target: home.appendingPathComponent("Applications/SidePulse.app/Contents/Helpers/sidepulse").path)).detail,
                       "~/.local/bin/sidepulse runs ~/Applications/SidePulse.app/Contents/Helpers/sidepulse. Install links it to this app.")
        XCTAssertEqual(summary(.foreign(target: nil)).detail,
                       "~/.local/bin/sidepulse is a file SidePulse did not create. Install moves it to sidepulse.previous.")
        XCTAssertEqual(summary(.unavailable(reason: "why")), CLILinkSummary(status: "Unavailable", detail: "why", canInstall: false))
    }

    func testPathNoteOffersTheFixOnlyWithAKnownProfile() {
        let profile = home.appendingPathComponent(".zprofile")
        XCTAssertEqual(CLILinkPresentation.pathNote(.notOnPath, profile: profile, home: home),
                       CLIPathNote(text: "~/.local/bin is not on your shell's PATH. Add to PATH adds it in ~/.zprofile.",
                                   offersFix: true))
        XCTAssertFalse(CLILinkPresentation.pathNote(.notOnPath, profile: nil, home: home).offersFix)
        XCTAssertFalse(CLILinkPresentation.pathNote(nil, profile: profile, home: home).offersFix)
        XCTAssertFalse(CLILinkPresentation.pathNote(.found, profile: profile, home: home).offersFix)
        XCTAssertEqual(CLILinkPresentation.pathNote(.shadowed(by: "/opt/homebrew/bin/sidepulse"), profile: profile, home: home).text,
                       "Your shell runs /opt/homebrew/bin/sidepulse instead, because it comes first on PATH.")
    }

    func testTilde() {
        XCTAssertEqual(CLILinkPresentation.tilde(home.appendingPathComponent("a/b").path, home: home), "~/a/b")
        XCTAssertEqual(CLILinkPresentation.tilde(home.path + "other/x", home: home), home.path + "other/x")
        XCTAssertEqual(CLILinkPresentation.tilde("/Applications/SidePulse.app", home: home), "/Applications/SidePulse.app")
    }
}
