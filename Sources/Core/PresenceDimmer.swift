import AppKit
import Darwin

/// 离开屏幕变暗：持续 N 秒检测不到本人人脸 → 内置屏调到最暗；人脸回归 → 立刻恢复原亮度。
///
/// 亮度执行器按可用性探测：
/// - CoreDisplay 私有 API（macOS 15 及以下可用）
/// - macOS 26 (Tahoe) 起该框架被移除、合成亮度键也被收紧（BetterDisplay 同步受影响），
///   此时 supported=false，功能不可用（状态如实上报，不假装生效）。
final class PresenceDimmer {
    private let config: ConfigStore
    private let lock = NSLock()

    private var lastFaceSeenAt: Date?
    private(set) var isDimmed = false
    private(set) var dimmedAt: Date?
    private var restoreBrightness: Double = -1   // 变暗前的原亮度（<0 表示读取失败，不变暗）
    private var tickTimer: Timer?

    private static let coreDisplayPath =
        "/System/Library/PrivateFrameworks/CoreDisplay.framework/Versions/A/CoreDisplay"

    private(set) var supported = false

    init(config: ConfigStore) {
        self.config = config
        if let handle = dlopen(Self.coreDisplayPath, RTLD_LAZY),
           let getSym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness"),
           let setSym = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") {
            let getFn = unsafeBitCast(getSym, to: GetFn.self)
            Self.getFn = getFn
            Self.setFn = unsafeBitCast(setSym, to: SetFn.self)
            supported = getFn(CGMainDisplayID()) >= 0
        } else {
            supported = false
        }
        if supported {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
    }

    private typealias GetFn = @convention(c) (UInt32) -> Double
    private typealias SetFn = @convention(c) (UInt32, Double) -> Bool

    private static var getFn: GetFn?
    private static var setFn: SetFn?

    private static func brightness() -> Double {
        guard let getFn = getFn else { return -1 }
        let value = getFn(CGMainDisplayID())
        return (0.0...1.0).contains(value) ? value : -1
    }

    @discardableResult
    private static func apply(_ value: Double) -> Bool {
        guard let setFn = setFn else { return false }
        return setFn(CGMainDisplayID(), value)
    }

    var isEnabled: Bool { config.currentSettings.presenceDimEnabled }
    var thresholdSeconds: Double { config.currentSettings.presenceDimSeconds }

    private var enrolledShown = false   // 由 AppContext 依据 FaceGate.isEnrolled 同步

    func setEnrolled(_ enrolled: Bool) {
        lock.lock(); enrolledShown = enrolled; lock.unlock()
        if !enrolled { ensureRestored() }
    }

    /// 是否参与工作（执行器可用 + 功能开启 + 已录入人脸）
    var isActive: Bool { supported && isEnabled && enrolledShown }

    /// 识别是否在跑（AppContext 注入，避免反向依赖）
    var recognitionStillRunning: () -> Bool = { false }

    // MARK: - 帧回调（视频队列线程）

    func feed(faceAccepted: Bool) {
        if faceAccepted {
            lock.lock(); lastFaceSeenAt = Date(); lock.unlock()
            // 人脸回归：立刻恢复（不等 1s tick）
            DispatchQueue.main.async { [weak self] in self?.ensureRestored() }
        }
        // 不在时由 tick 按 lastFaceSeenAt 判定超时
    }

    // MARK: - 状态机（主线程 tick）

    private func tick() {
        guard isActive, recognitionStillRunning() else {
            ensureRestored()
            return
        }
        let last: Date? = lock.withLock { lastFaceSeenAt }
        guard let last = last else { return }   // 还没见过人脸，先不动亮度
        if Date().timeIntervalSince(last) >= thresholdSeconds {
            if isDimmed {
                _ = Self.apply(0.0)   // 重申，顶住自动亮度可能的回拉
            } else {
                ensureDimmed()
            }
        } else {
            ensureRestored()
        }
    }

    private func ensureDimmed() {
        guard !isDimmed else { return }
        let current = Self.brightness()
        guard current >= 0 else { return }      // 亮度读取失败时不动
        if Self.apply(0.0) {
            restoreBrightness = current
            isDimmed = true
            dimmedAt = Date()
        }
    }

    func ensureRestored() {
        guard isDimmed else { return }
        let target = restoreBrightness
        if target >= 0 {
            _ = Self.apply(target)
        }
        isDimmed = false
        restoreBrightness = -1
    }
}
