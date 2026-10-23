import Foundation

struct StringError: Error { let message: String }

/// 全局服务容器：AppDelegate 启动时装配，HTTP CLI 命令树通过它访问各服务。
final class AppContext {
    static var shared: AppContext!

    let config: ConfigStore
    let events: EventLog
    let engine: GestureEngine
    let camera: CameraController
    let faceGate: FaceGate
    let presenceScreen: PresenceScreen
    let powerMonitor = PowerMonitor()
    let startedAt = Date()
    var router: CLIRouter!
    /// HTTP 实际监听端口（配置端口被占用时会顺延）
    var effectivePort: UInt16 = 8741

    /// 端口变更后重启 HTTP 服务（AppDelegate 注入）
    var onServerRestart: ((UInt16) -> Void)?
    /// 电池自动暂停/恢复后更新托盘提示（AppDelegate 注入）
    var onAutoPauseChange: ((String?) -> Void)?
    /// 因电池自动暂停过（插电后据此自动恢复；用户手动暂停不恢复）
    private(set) var autoPausedByBattery = false
    private var changingPowerState = false

    init(config: ConfigStore, events: EventLog, engine: GestureEngine,
         camera: CameraController, faceGate: FaceGate, presenceScreen: PresenceScreen) {
        self.config = config
        self.events = events
        self.engine = engine
        self.camera = camera
        self.faceGate = faceGate
        self.presenceScreen = presenceScreen
        // 相机帧 → 引擎（门控不通过时 points 为 nil，引擎自动复位稳定计数）
        camera.faceGate = faceGate
        camera.onHandPoints = { [weak engine] points, _ in
            engine?.processHandPoints(points)
        }
        // 人脸在场 → 变暗状态机
        faceGate.onFacePresence = { [weak presenceScreen] accepted in
            presenceScreen?.feed(faceAccepted: accepted)
        }
        presenceScreen.recognitionStillRunning = { [weak camera] in camera?.isRunning ?? false }
        presenceScreen.setEnrolled(faceGate.isEnrolled)
        // 电源变化 → 电池自动暂停 / 插电恢复
        powerMonitor.onPowerChange = { [weak self] source in
            self?.handlePowerChange(source)
        }
    }

    // MARK: - 电源

    var powerSource: String { powerMonitor.current }

    func startPowerMonitor() {
        powerMonitor.start()
        handlePowerChange(powerMonitor.current)
    }

    private func handlePowerChange(_ source: String) {
        guard !changingPowerState else { return }
        let pauseOnBattery = config.currentSettings.pauseOnBattery
        switch (source, pauseOnBattery) {
        case ("battery", true) where camera.isRunning:
            autoPausedByBattery = true
            stopRecognition()
            onAutoPauseChange?("已因使用电池暂停识别（插电自动恢复）")
        case ("ac", true) where autoPausedByBattery:
            autoPausedByBattery = false
            onAutoPauseChange?(nil)
            startRecognition { _ in }
        case (_, false) where autoPausedByBattery:
            autoPausedByBattery = false
            onAutoPauseChange?(nil)
        default:
            break
        }
    }

    /// 设置里切换 pause_on_battery 时调用：开启且当前在电池 → 立即暂停
    func applyPauseOnBatterySetting() {
        if config.currentSettings.pauseOnBattery, powerSource == "battery", camera.isRunning {
            handlePowerChange("battery")
        }
    }

    // MARK: - 识别控制

    var recognitionState: String {
        if CameraController.authorizationStatus == .denied { return "unauthorized" }
        return camera.isRunning ? "running" : "paused"
    }

    /// 开启识别。摄像头未授权时先请求权限（异步回调 completion）。
    func startRecognition(_ completion: @escaping (Result<Void, StringError>) -> Void) {
        changingPowerState = true
        switch CameraController.authorizationStatus {
        case .authorized:
            startCamera(completion)
        case .notDetermined:
            CameraController.requestAccess { [weak self] granted in
                if granted {
                    self?.startCamera(completion)
                } else {
                    self?.changingPowerState = false
                    completion(.failure(StringError(message: "摄像头权限被拒绝")))
                }
            }
        default:
            changingPowerState = false
            completion(.failure(StringError(message: "摄像头权限被拒绝，请到 系统设置 → 隐私与安全性 → 摄像头 中允许 MacGestures")))
        }
    }

    private func startCamera(_ completion: @escaping (Result<Void, StringError>) -> Void) {
        do {
            try camera.start()
            changingPowerState = false
            completion(.success(()))
        } catch {
            changingPowerState = false
            completion(.failure(StringError(message: error.localizedDescription)))
        }
    }

    func stopRecognition() {
        presenceScreen.ensureScreenOn()
        camera.stop()
    }
}
