import Foundation
import IOKit.ps

/// 电源状态监控：轮询 IOPS（10 秒），回调 "ac" / "battery" / "unknown"
final class PowerMonitor {
    private(set) var current = "unknown"
    private var timer: Timer?

    /// 电源状态变化时回调（主线程）
    var onPowerChange: ((String) -> Void)?

    func start() {
        current = Self.readPowerSource()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let source = Self.readPowerSource()
        guard source != current else { return }
        current = source
        let handler = onPowerChange
        DispatchQueue.main.async { handler?(source) }
    }

    /// "ac"（外接电源）| "battery"（电池供电）| "unknown"
    static func readPowerSource() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return "unknown"
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSACPowerValue { return "ac" }
            if state == kIOPSBatteryPowerValue { return "battery" }
        }
        return "unknown"
    }
}
