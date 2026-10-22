import Foundation

/// 手势引擎：稳定帧确认 → 冷却检查 → 执行脚本 → 记录事件 → 更新托盘。
final class GestureEngine {
    private let queue = DispatchQueue(label: "com.macgestures.engine")
    private let config: ConfigStore
    private let events: EventLog

    private var pendingKind: GestureKind?
    private var pendingCount = 0
    private var lastFiredAt: [GestureKind: Date] = [:]
    private var triggerCountToday = 0
    private var triggerDay: Date = Date()

    /// 识别/触发时通知托盘（主线程回调）
    var onGestureFired: ((GestureKind) -> Void)?
    var onTriggerCountChanged: (() -> Void)?

    init(config: ConfigStore, events: EventLog) {
        self.config = config
        self.events = events
    }

    var triggerCount: Int {
        queue.sync {
            resetDailyCounterIfNeeded(Date())
            return triggerCountToday
        }
    }

    // MARK: - 帧入口（CameraController 在视频队列上调用）

    func processHandPoints(_ points: HandPoints?) {
        guard let points = points else {
            queue.async { self.pendingKind = nil; self.pendingCount = 0 }
            return
        }
        let (kind, _) = GestureClassifier.classify(points)
        guard let kind = kind else {
            queue.async { self.pendingKind = nil; self.pendingCount = 0 }
            return
        }
        queue.async { self.handleStableCandidate(kind) }
    }

    private func handleStableCandidate(_ kind: GestureKind) {
        if pendingKind == kind {
            pendingCount += 1
        } else {
            pendingKind = kind
            pendingCount = 1
        }
        let required = max(config.currentSettings.stabilityFrames, 1)
        guard pendingCount >= required else { return }

        // 达到稳定帧数：尝试触发
        pendingKind = nil
        pendingCount = 0
        tryFire(kind)
    }

    private func tryFire(_ kind: GestureKind) {
        let gestureConfig = config.gestureConfig(kind)
        guard gestureConfig.enabled, !gestureConfig.script.isEmpty else { return }

        let now = Date()
        if let last = lastFiredAt[kind], now.timeIntervalSince(last) < gestureConfig.cooldown {
            return
        }
        lastFiredAt[kind] = now
        resetDailyCounterIfNeeded(now)
        triggerCountToday += 1

        runAndRecord(kind: kind, source: "recognition")
    }

    /// 执行脚本并记录事件（识别触发与 HTTP 手动测试共用）
    func runAndRecord(kind: GestureKind, source: String) {
        let gestureConfig = config.gestureConfig(kind)
        let firedAt = Date()
        DispatchQueue.main.async { [weak self] in
            self?.onGestureFired?(kind)
        }

        ScriptRunner.shared.run(scriptType: gestureConfig.scriptType, script: gestureConfig.script) { [weak self] result in
            guard let self = self else { return }
            let event = Self.makeEvent(kind: kind, source: source, at: firedAt,
                                       scriptType: gestureConfig.scriptType, result: result)
            self.events.append(event)
            DispatchQueue.main.async { [weak self] in
                self?.onTriggerCountChanged?()
            }
        }
    }

    private func resetDailyCounterIfNeeded(_ now: Date) {
        if !Calendar.current.isDate(triggerDay, inSameDayAs: now) {
            triggerDay = now
            triggerCountToday = 0
        }
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// 构造事件记录（识别触发与 HTTP 手动测试共用）
    static func makeEvent(kind: GestureKind, source: String, at date: Date,
                          scriptType: ScriptType, result: ScriptResult) -> GestureEvent {
        GestureEvent(
            id: UUID().uuidString,
            timestamp: rfc3339(date),
            source: source,
            gestureId: kind.rawValue,
            gestureName: kind.name,
            icon: kind.icon,
            scriptType: scriptType.rawValue,
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stdout: result.stdout,
            stderr: result.stderr,
            launchError: result.launchError,
            durationMs: (result.durationMs * 100).rounded() / 100
        )
    }
}
