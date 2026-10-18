import Foundation
import SidePulseCore

/// The arguments Stream Deck launches a plugin with: `-port P -pluginUUID U -registerEvent E -info JSON`.
public struct StreamDeckArguments: Sendable, Equatable {
    public var port: Int
    public var pluginUUID: String
    public var registerEvent: String
    public var info: JSONValue?

    public init(port: Int, pluginUUID: String, registerEvent: String, info: JSONValue? = nil) {
        self.port = port; self.pluginUUID = pluginUUID; self.registerEvent = registerEvent; self.info = info
    }

    public static func parse(_ arguments: [String]) -> StreamDeckArguments? {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let name = arguments[index]
            if name.hasPrefix("-"), arguments.index(after: index) < arguments.endIndex {
                values[String(name.drop { $0 == "-" })] = arguments[arguments.index(after: index)]
                index = arguments.index(index, offsetBy: 2)
            } else {
                index = arguments.index(after: index)
            }
        }
        guard let port = values["port"].flatMap(Int.init), (1...65535).contains(port),
              let uuid = values["pluginUUID"], !uuid.isEmpty,
              let event = values["registerEvent"], !event.isEmpty else { return nil }
        return StreamDeckArguments(port: port, pluginUUID: uuid, registerEvent: event,
                                   info: values["info"].flatMap { try? JSONValue.parse($0) })
    }
}

public struct StreamDeckEvent: Sendable, Equatable {
    public var event: String
    public var action: String?
    public var context: String?
    public var device: String?
    public var payload: JSONObject

    public init(event: String, action: String? = nil, context: String? = nil, device: String? = nil,
                payload: JSONObject = JSONObject()) {
        self.event = event; self.action = action; self.context = context; self.device = device; self.payload = payload
    }

    public static func parse(_ text: String) -> StreamDeckEvent? {
        guard let object = (try? JSONValue.parse(text))?.objectValue,
              let event = object["event"]?.stringValue else { return nil }
        return StreamDeckEvent(event: event, action: object["action"]?.stringValue,
                               context: object["context"]?.stringValue, device: object["device"]?.stringValue,
                               payload: object["payload"]?.objectValue ?? JSONObject())
    }

    public var settings: JSONObject { payload["settings"]?.objectValue ?? JSONObject() }
}

public enum StreamDeckCommand {
    public static func register(event: String, uuid: String) -> JSONObject {
        ["event": .string(event), "uuid": .string(uuid)]
    }

    /// Target 0 updates both the hardware key and the Stream Deck app's canvas.
    public static func setImage(context: String, image: String) -> JSONObject {
        ["event": .string("setImage"), "context": .string(context),
         "payload": .object(["image": .string(image), "target": JSONValue(0)])]
    }

    public static func showAlert(context: String) -> JSONObject {
        ["event": .string("showAlert"), "context": .string(context)]
    }

    public static func openURL(_ url: String) -> JSONObject {
        ["event": .string("openUrl"), "payload": .object(["url": .string(url)])]
    }

    public static func logMessage(_ message: String) -> JSONObject {
        ["event": .string("logMessage"), "payload": .object(["message": .string(message)])]
    }
}

public protocol StreamDeckOutput: AnyObject {
    func send(_ message: JSONObject)
}
