import Foundation
import IOKit
import IOKit.pwr_mgt
import Synchronization

/// What the root power domain reports about the lid and the displays.
public struct SleepState: Sendable, Equatable {
    /// nil on a Mac without a lid.
    public var lidClosed: Bool?
    /// False while a closed lid does not sleep the Mac, usually because an external display is in use.
    public var lidClosedSleeps: Bool?
    /// False during a dark wake (Power Nap), nil when macOS does not say.
    public var graphics: Bool?

    public init(lidClosed: Bool? = nil, lidClosedSleeps: Bool? = nil, graphics: Bool? = nil) {
        self.lidClosed = lidClosed; self.lidClosedSleeps = lidClosedSleeps; self.graphics = graphics
    }

    /// Fully awake with the lid open, or closed on an external display.
    public var inUse: Bool {
        graphics != false && !(lidClosed == true && lidClosedSleeps != false)
    }

    public static func read() -> SleepState {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return SleepState() }
        defer { IOObjectRelease(root) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // "System Capabilities" is not in the public headers, so a macOS without it counts as fully awake.
        let capabilities = (property("System Capabilities") as? NSNumber)?.uint32Value
        return SleepState(lidClosed: property(kAppleClamshellStateKey) as? Bool,
                          lidClosedSleeps: property(kAppleClamshellCausesSleepKey) as? Bool,
                          graphics: capabilities.map { $0 & UInt32(kIOPMSystemCapabilityGraphics) != 0 })
    }
}

public enum SleepEvent: Sendable {
    case willSleep
    case didWake
    case lidChanged
}

public protocol SleepWatching: AnyObject, Sendable {
    /// `handler` runs on one private queue, and the Mac waits for `.willSleep`'s handler before it sleeps.
    func start(_ handler: @escaping @Sendable (SleepEvent) -> Void) -> Bool
    func stop()
    var state: SleepState { get }
}

public final class SystemSleepWatcher: SleepWatching, @unchecked Sendable {
    // Swift cannot import the iokit_common_msg/iokit_family_msg macros these come from.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
    static let clamshellStateChange: UInt32 = 0xE003_4100

    private struct Registration {
        var port: IONotificationPortRef
        var rootPort: io_connect_t
        var notifier: io_object_t
        var rootDomain: io_service_t
        var interest: io_object_t
        var handler: @Sendable (SleepEvent) -> Void
    }

    private let queue = DispatchQueue(label: "sidepulse.sleep", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    /// Only touched on `queue`.
    private var registration: Registration?

    public init() {
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    public var state: SleepState { SleepState.read() }

    public func start(_ handler: @escaping @Sendable (SleepEvent) -> Void) -> Bool {
        onQueue {
            if registration != nil { return true }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var port: IONotificationPortRef?
            var notifier: io_object_t = IO_OBJECT_NULL
            let rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, message, argument in
                guard let refcon else { return }
                Unmanaged<SystemSleepWatcher>.fromOpaque(refcon).takeUnretainedValue().power(message, argument)
            }, &notifier)
            guard rootPort != IO_OBJECT_NULL, let port else { return false }
            IONotificationPortSetDispatchQueue(port, queue)

            var interest: io_object_t = IO_OBJECT_NULL
            let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            if rootDomain != IO_OBJECT_NULL {
                _ = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { refcon, _, message, _ in
                    guard let refcon, message == SystemSleepWatcher.clamshellStateChange else { return }
                    Unmanaged<SystemSleepWatcher>.fromOpaque(refcon).takeUnretainedValue().registration?.handler(.lidChanged)
                }, refcon, &interest)
            }
            registration = Registration(port: port, rootPort: rootPort, notifier: notifier, rootDomain: rootDomain,
                                        interest: interest, handler: handler)
            return true
        }
    }

    /// Waits for a running handler, so none runs once this returns.
    public func stop() {
        onQueue {
            guard var current = registration else { return }
            registration = nil
            IODeregisterForSystemPower(&current.notifier)
            IOServiceClose(current.rootPort)
            if current.interest != IO_OBJECT_NULL { IOObjectRelease(current.interest) }
            if current.rootDomain != IO_OBJECT_NULL { IOObjectRelease(current.rootDomain) }
            IONotificationPortDestroy(current.port)
        }
    }

    /// The last release of the runtime can come from inside a handler, and `deinit` stops the watcher.
    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
    }

    private func power(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        guard let registration else { return }
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(registration.rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            registration.handler(.willSleep)
            IOAllowPowerChange(registration.rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            registration.handler(.didWake)
        default:
            break
        }
    }
}
