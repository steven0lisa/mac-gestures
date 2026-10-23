import AppKit
import Darwin

/// 离开熄屏：持续 N 秒检测不到本人人脸 → 直接熄灭显示器（主机不休眠）；人脸回归 → 立刻唤醒。
///
/// 执行器是 Apple 自带的公开工具，全 macOS 版本稳定可用：
/// - 熄屏：`pmset displaysleepnow`（关闭显示器背光，不睡眠系统）
/// - 唤醒：`caffeinate -u -t 1`（模拟一次用户活动，把已睡眠的显示器唤醒）
///
/// 防误熄保护：3 秒内有键鼠输入（说明人正在操作电脑，只是不在摄像头视角）不熄屏。
final class PresenceScreen {
    private let config: ConfigStore
    private let lock = NSLock()

    private var lastFaceSeenAt: Date?
    private(set) var isScreenOff = false
    private(set) var screenOffAt: Date?
    private var tickTimer: Timer?

    /// 用户仍在操作电脑的保护窗（秒）：有输入就视为在场，不熄屏
    private static let recentInputWindow: TimeInterval = 3

    private(set) var supported = false

    init(config: ConfigStore) {
        self.config = config
        supported = FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset")
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/caffeinate")
        if supported {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
    }

    var isEnabled: Bool { config.currentSettings.presenceDimEnabled }
    var thresholdSeconds: Double { config.currentSettings.presenceDimSeconds }

    private var enrolledShown = false   // 由 AppContext 依据 FaceGate.isEnrolled 同步

    func setEnrolled(_ enrolled: Bool) {
        lock.lock(); enrolledShown = enrolled; lock.unlock()
        if !enrolled { ensureScreenOn() }
    }

    /// 是否参与工作（工具可用 + 功能开启 + 已录入人脸）
    var isActive: Bool { supported && isEnabled && enrolledShown }

    /// 识别是否在跑（AppContext 注入，避免反向依赖）
    var recognitionStillRunning: () -> Bool = { false }

    // MARK: - 帧回调（视频队列线程）

    func feed(faceAccepted: Bool) {
        if faceAccepted {
            lock.lock(); lastFaceSeenAt = Date(); lock.unlock()
            // 人脸回归：立刻唤醒（不等 1s tick）
            DispatchQueue.main.async { [weak self] in self?.ensureScreenOn() }
        }
        // 不在时由 tick 按 lastFaceSeenAt 判定超时
    }

    // MARK: - 状态机（主线程 tick）

    private func tick() {
        guard isActive, recognitionStillRunning() else {
            ensureScreenOn()
            return
        }
        let last: Date? = lock.withLock { lastFaceSeenAt }
        guard let last = last else { return }   // 还没见过人脸，先不动屏幕
        let inputIdle = Self.secondsSinceLastUserInput()

        if isScreenOff {
            if inputIdle < Self.recentInputWindow {
                // 屏幕已被键鼠输入点亮且用户在操作：放弃熄屏状态，等人脸回帧后重新计时
                isScreenOff = false
            }
            // 无人唤醒则保持熄屏（稳定状态，无需重申）
            return
        }

        if Date().timeIntervalSince(last) >= thresholdSeconds {
            // 无脸超时，且用户确实没在操作电脑（否则视为在场，不熄屏）
            if inputIdle >= Self.recentInputWindow {
                turnScreenOff()
            }
        } else {
            ensureScreenOn()
        }
    }

    private func turnScreenOff() {
        guard !isScreenOff else { return }
        if Self.runTool("/usr/bin/pmset", ["displaysleepnow"]) {
            isScreenOff = true
            screenOffAt = Date()
        }
    }

    func ensureScreenOn() {
        guard isScreenOff else { return }
        // caffeinate -u 模拟一次用户活动，点亮已睡眠的显示器；屏幕已亮时执行无副作用
        Self.runTool("/usr/bin/caffeinate", ["-u", "-t", "1"])
        isScreenOff = false
    }

    // MARK: - 执行器

    @discardableResult
    private static func runTool(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // caffeinate -u -t 1 会等 1 秒，放到后台等，不阻塞状态机
            if path.hasSuffix("caffeinate") {
                DispatchQueue.global().async {
                    process.waitUntilExit()
                }
            } else {
                process.waitUntilExit()
            }
            return process.terminationStatus == 0
        } catch {
            NSLog("MacGestures: presence screen 执行 \(path) 失败 \(error)")
            return false
        }
    }

    /// 距上次键鼠输入的秒数（combined session）
    static func secondsSinceLastUserInput() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}
