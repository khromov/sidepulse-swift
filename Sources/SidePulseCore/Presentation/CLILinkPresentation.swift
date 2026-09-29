import Foundation

public struct CLILinkSummary: Sendable, Equatable {
    public var status: String
    public var detail: String
    public var canInstall: Bool
}

public struct CLIPathNote: Sendable, Equatable {
    public var text: String
    public var offersFix: Bool
}

public enum CLILinkPresentation {
    public static let title = "Command-line tool"
    public static let addToPath = "Add to PATH"

    public static func summary(_ state: CLILinkState, link: URL, home: URL) -> CLILinkSummary {
        let path = tilde(link.path, home: home)
        switch state {
        case .installed:
            return CLILinkSummary(status: "Installed", detail: "\(path) runs this app's sidepulse command.",
                                  canInstall: false)
        case .missing:
            return CLILinkSummary(status: "Not installed", detail: "Install links \(path) to this app.",
                                  canInstall: true)
        case .otherApp(let target):
            return CLILinkSummary(status: "Another copy",
                                  detail: "\(path) runs \(tilde(target, home: home)). Install links it to this app.",
                                  canInstall: true)
        case .broken(let target):
            return CLILinkSummary(status: "Broken",
                                  detail: "\(path) links to \(tilde(target, home: home)), which does not exist.",
                                  canInstall: true)
        case .foreign(let target?):
            return CLILinkSummary(status: "Not SidePulse",
                                  detail: "\(path) links to \(tilde(target, home: home)). Install replaces the link.",
                                  canInstall: true)
        case .foreign(nil):
            return CLILinkSummary(status: "Not SidePulse",
                                  detail: "\(path) is a file SidePulse did not create. Install moves it to sidepulse.previous.",
                                  canInstall: true)
        case .unavailable(let reason):
            return CLILinkSummary(status: "Unavailable", detail: reason, canInstall: false)
        }
    }

    /// `check` is nil until the shell's PATH has been read once.
    public static func pathNote(_ check: CLIPathCheck?, profile: URL?, home: URL) -> CLIPathNote {
        switch check {
        case nil:
            return CLIPathNote(text: "Checking your shell's PATH\u{2026}", offersFix: false)
        case .found:
            return CLIPathNote(text: "Your shell finds it. Try sidepulse status in a terminal.", offersFix: false)
        case .notOnPath:
            guard let profile else {
                return CLIPathNote(text: "~/.local/bin is not on your shell's PATH. Add it in your shell's startup file.",
                                   offersFix: false)
            }
            return CLIPathNote(text: "~/.local/bin is not on your shell's PATH. \(addToPath) adds it in "
                                   + "\(tilde(profile.path, home: home)).", offersFix: true)
        case .shadowed(let other):
            return CLIPathNote(text: "Your shell runs \(tilde(other, home: home)) instead, because it comes first on PATH.",
                               offersFix: false)
        case .unknown:
            return CLIPathNote(text: "Could not read your shell's PATH. Make sure ~/.local/bin is on it.", offersFix: false)
        }
    }

    public static func installedMessage(_ change: CLILinkChange, home: URL) -> String {
        var text = "Linked \(tilde(change.link.path, home: home)) to \(tilde(change.target, home: home))."
        if let aside = change.movedAside { text += " The old file is now \(tilde(aside.path, home: home))." }
        return text
    }

    public static func addedToPathMessage(profile: URL, changed: Bool, home: URL) -> String {
        let file = tilde(profile.path, home: home)
        return changed
            ? "Added ~/.local/bin to PATH in \(file). Open a new terminal window to use sidepulse."
            : "\(file) already adds ~/.local/bin to PATH; another startup file may reset PATH after it."
    }

    public static func failureMessage(_ error: Error) -> String {
        "Could not install the sidepulse command: \(ErrorText.describe(error))"
    }

    public static func pathFailureMessage(_ error: Error) -> String {
        "Could not add ~/.local/bin to PATH: \(ErrorText.describe(error))"
    }

    static func tilde(_ path: String, home: URL) -> String {
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}
