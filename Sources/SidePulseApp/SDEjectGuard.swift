import DiskArbitration
import Foundation
import SidePulseCore

/// Vetoes ejects of cards in the built-in SD reader, then retries the mount every few seconds: the retries are
/// refused while the screen is locked and succeed after unlock.
final class SDEjectGuard: @unchecked Sendable {
    // DiskArbitration calls back on this queue too, so all state below is only touched on it.
    private let queue = DispatchQueue(label: "io.sidepulse.sd-eject-guard")
    private var session: DASession?
    private var retries: [String: DispatchSourceTimer] = [:]

    func setEnabled(_ enabled: Bool) {
        queue.async { enabled ? self.start() : self.stop() }
    }

    private static let ejectApproval: DADiskEjectApprovalCallback = { disk, context in
        guard let context else { return nil }
        return Unmanaged<SDEjectGuard>.fromOpaque(context).takeUnretainedValue().approveEject(disk)
    }

    private static let diskDisappeared: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<SDEjectGuard>.fromOpaque(context).takeUnretainedValue().forget(disk)
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        DARegisterDiskEjectApprovalCallback(session, nil, Self.ejectApproval, context)
        DARegisterDiskDisappearedCallback(session, nil, Self.diskDisappeared, context)
        DASessionSetDispatchQueue(session, queue)
        self.session = session
        DiagnosticsLog.shared.log("sd-eject-guard: on")
    }

    private func stop() {
        guard let session else { return }
        DAUnregisterCallback(session, unsafeBitCast(Self.ejectApproval, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(Self.diskDisappeared, to: UnsafeMutableRawPointer.self), context)
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        retries.values.forEach { $0.cancel() }
        retries.removeAll()
        DiagnosticsLog.shared.log("sd-eject-guard: off")
    }

    private func approveEject(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        let info = DiskInfo(disk)
        guard SDEjectGuardRule.isBuiltInSDReader(deviceProtocol: info.deviceProtocol, model: info.model) else { return nil }
        DiagnosticsLog.shared.log("sd-eject-guard: prevented eject of \(info.name) (volume: \(info.volumeName ?? "?"))")
        startMountRetries(name: info.name)
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(truncatingIfNeeded: kDAReturnNotPermitted),
                                          SDEjectGuardRule.dissentMessage as CFString)
        return Unmanaged.passRetained(dissenter)
    }

    private func startMountRetries(name: String) {
        guard retries[name] == nil else { return }
        let interval = SDEjectGuardRule.mountRetryInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.retryMount(name: name) }
        retries[name] = timer
        timer.resume()
    }

    /// Looks the disk up again each time, because the one from the approval callback never sees the remount.
    private func retryMount(name: String) {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name) else { return }
        guard !DiskInfo(disk).isMounted else {
            retries.removeValue(forKey: name)?.cancel()
            DiagnosticsLog.shared.log("sd-eject-guard: \(name) is mounted again")
            return
        }
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), nil, nil)
    }

    /// A card pulled out of the slot never mounts again, so its retries stop with it.
    private func forget(_ disk: DADisk) {
        retries.removeValue(forKey: DiskInfo.name(of: disk))?.cancel()
    }
}

private struct DiskInfo {
    let name: String
    let deviceProtocol: String?
    let model: String?
    let volumeName: String?
    let isMounted: Bool

    init(_ disk: DADisk) {
        let description = DADiskCopyDescription(disk) as NSDictionary?
        name = Self.name(of: disk)
        deviceProtocol = description?[kDADiskDescriptionDeviceProtocolKey] as? String
        model = description?[kDADiskDescriptionDeviceModelKey] as? String
        volumeName = description?[kDADiskDescriptionVolumeNameKey] as? String
        isMounted = description?[kDADiskDescriptionVolumePathKey] != nil
    }

    static func name(of disk: DADisk) -> String {
        DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
    }
}
