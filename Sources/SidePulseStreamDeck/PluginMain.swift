import Foundation
import SidePulseCore

public enum StreamDeckPluginMain {
    /// The build scripts run these to generate the manifest's and the Marketplace listing's images.
    public static let writeAssetsFlag = "--write-assets"
    public static let writeMarketplaceFlag = "--write-marketplace"

    /// `arguments` excludes the program name, like `SidePulseCLI.main`.
    public static func main(_ arguments: [String]) -> Int32 {
        let writers = [writeAssetsFlag: PluginAssets.write(to:), writeMarketplaceFlag: MarketplaceAssets.write(to:)]
        if let flag = arguments.first, let write = writers[flag] {
            guard arguments.count == 2 else { return usage() }
            do {
                try write(URL(fileURLWithPath: arguments[1], isDirectory: true))
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(ErrorText.describe(error))\n".utf8))
                return 1
            }
        }
        guard let parsed = StreamDeckArguments.parse(arguments) else { return usage() }
        run(parsed)
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
            usage: sidepulse-streamdeck -port PORT -pluginUUID UUID -registerEvent EVENT [-info JSON]
                   sidepulse-streamdeck \(writeAssetsFlag)|\(writeMarketplaceFlag) DIR
            Stream Deck starts this plugin itself; run it by hand only to generate the images.

            """.utf8))
        return 2
    }

    private static func run(_ arguments: StreamDeckArguments) -> Never {
        let paths = SidePulsePaths.current
        let socket = StreamDeckSocket(port: arguments.port)
        let plugin = StatusPlugin(output: socket, source: .live(paths: paths), opener: .live(paths: paths))
        socket.onEvent = { plugin.handle($0) }
        socket.onClose = { exit(0) }
        socket.connect(register: StreamDeckCommand.register(event: arguments.registerEvent, uuid: arguments.pluginUUID))
        dispatchMain()
    }
}
