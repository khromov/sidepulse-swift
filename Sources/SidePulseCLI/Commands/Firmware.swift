import Foundation
import SidePulseCore

enum FirmwareCommand: CLICommand {
    static let actions = ["version", "upgrade"]

    static let spec = CommandSpec(
        name: "firmware",
        synopsis: "version|upgrade [--device PATH] [--json] [--version VERSION | --file ZIP] [--dry-run]",
        summary: "Show or upgrade the firmware of a SidePulse device",
        details: "'version' prints each connected device's model and firmware. 'upgrade' installs the latest\n"
            + "firmware published for the device's model on GitHub (or --version / --file), after verifying the\n"
            + "package; it refuses other models and older versions.",
        positionals: PositionalSpec(name: "action", choices: actions),
        options: [
            OptionSpec("device", value: "PATH", help: "device volume (default: auto-discover)"),
            OptionSpec("json", help: "version: print the devices as JSON"),
            OptionSpec("version", value: "VERSION", help: "upgrade: install this release, such as 1.1.0"),
            OptionSpec("file", value: "ZIP", help: "upgrade: install a downloaded sidepulse-MODEL-VERSION-ota.zip"),
            OptionSpec("dry-run", help: "upgrade: download and verify the package without writing it"),
        ]
    )

    struct Device: Equatable {
        var root: URL
        var info: FirmwareInfo
    }

    static func run(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        guard let action = arguments.positionals.first else {
            throw UsageError("the following arguments are required: action")
        }
        let upgradeOnly = ["version", "file", "dry-run"].filter { arguments.has($0) || arguments.value($0) != nil }
        if action == "version" {
            if let option = upgradeOnly.first { throw UsageError("--\(option) can only be combined with upgrade") }
            return try printVersions(arguments, env)
        }
        if arguments.has("json") { throw UsageError("--json can only be combined with version") }
        if arguments.value("version") != nil, arguments.value("file") != nil {
            throw UsageError("argument --file: not allowed with argument --version")
        }
        return try upgrade(arguments, env)
    }

    static func printVersions(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let devices = try findDevices(arguments.value("device"), env)
        if arguments.has("json") {
            let rows = devices.map { device -> JSONValue in
                .object([
                    "model": .string(device.info.model.productName),
                    "version": .string(device.info.version),
                    "serial": .string(device.info.serial),
                    "device": .string(device.root.path),
                ])
            }
            env.stdout.line(JSONValue.array(rows).serialized(pretty: true))
        } else {
            for device in devices {
                env.stdout.line("\(device.info.model.productName): \(device.info.version)  "
                    + "(\(device.root.path), serial \(device.info.serial))")
            }
        }
        return ExitCode.ok
    }

    static func upgrade(_ arguments: ParsedArguments, _ env: CLIEnvironment) throws -> Int32 {
        let devices = try findDevices(arguments.value("device"), env)
        guard devices.count == 1, let device = devices.first else {
            throw CommandFailure(message: "Multiple SidePulse devices found. Select one with --device:\n"
                + devices.map { "  \($0.root.path)" }.joined(separator: "\n"))
        }
        let name = device.info.model.productName
        env.stdout.line("\(name): firmware \(device.info.version) (\(device.root.path))")

        let file = arguments.value("file").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let package = try FirmwareReleases(download: env.download)
            .loadPackage(model: device.info.model, version: arguments.value("version"), file: file)
        guard package.model == device.info.model else {
            throw FirmwareError("This ZIP is for \(package.model.productName), but the device is \(name).")
        }
        let installed = try? FirmwareVersion.key(device.info.version)
        let offered = try FirmwareVersion.key(package.version)
        if installed == offered {
            env.stdout.line("\(name) is already on firmware \(package.version).")
            return ExitCode.ok
        }
        if let installed, offered.lexicographicallyPrecedes(installed) {
            throw FirmwareError("Firmware \(package.version) is older than installed version \(device.info.version); "
                + "downgrade refused.")
        }
        if arguments.has("dry-run") {
            env.stdout.line("Would upgrade \(name) from \(device.info.version) to \(package.version). "
                + "Package verified; no files written.")
            return ExitCode.ok
        }

        // The download can take a while; a different card in the same slot must not get this image.
        guard try FirmwareInfo.read(volume: device.root) == device.info else {
            throw FirmwareError("The connected device changed. Run the upgrade again.")
        }
        env.stdout.line("Sending firmware \(package.version). Keep the device connected.")
        try FirmwareWriter.write(package.payload, toVolume: device.root)
        env.stdout.line("Firmware \(package.version) transferred. Leave the device connected for at least 10 seconds "
            + "while it applies the update and restarts, then reconnect it and run `sidepulse firmware version` "
            + "to confirm the installation.")
        return ExitCode.ok
    }

    /// Discovered volumes whose STATUS.TXT names no SidePulse model are skipped; an explicit `--device` is not.
    static func findDevices(_ devicePath: String?, _ env: CLIEnvironment) throws -> [Device] {
        if let devicePath {
            let root = volume(forDevicePath: devicePath)
            return [Device(root: root, info: try FirmwareInfo.read(volume: root))]
        }
        let devices = DeviceDiscovery.discover(roots: env.mountRoots, fileName: DeviceStatusFile.fileName)
            .compactMap { candidate in
                (try? FirmwareInfo.read(volume: candidate.root)).map { Device(root: candidate.root, info: $0) }
            }
        guard !devices.isEmpty else {
            throw CommandFailure(message: "No mounted SidePulse device found. Connect it or pass --device /path/to/drive.")
        }
        return devices
    }

    static func volume(forDevicePath path: String) -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let deviceFiles = [DeviceDiscovery.fileName, DeviceStatusFile.fileName, FirmwareWriter.fileName]
        return deviceFiles.contains(url.lastPathComponent.uppercased()) ? url.deletingLastPathComponent() : url
    }
}
