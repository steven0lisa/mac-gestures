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
    let startedAt = Date()
    var router: CLIRouter!
    /// HTTP 实际监听端口（配置端口被占用时会顺延）
    var effectivePort: UInt16 = 8741

    init(config: ConfigStore, events: EventLog, engine: GestureEngine,
         camera: CameraController, faceGate: FaceGate) {
        self.config = config
        self.events = events
        self.engine = engine
        self.camera = camera
        self.faceGate = faceGate
        // 相机帧 → 引擎（门控不通过时 points 为 nil，引擎自动复位稳定计数）
        camera.faceGate = faceGate
        camera.onHandPoints = { [weak engine] points, _ in
            engine?.processHandPoints(points)
        }
    }

    // MARK: - 识别控制

    var recognitionState: String {
        if CameraController.authorizationStatus == .denied { return "unauthorized" }
        return camera.isRunning ? "running" : "paused"
    }

    /// 开启识别。摄像头未授权时先请求权限（异步回调 completion）。
    func startRecognition(_ completion: @escaping (Result<Void, StringError>) -> Void) {
        switch CameraController.authorizationStatus {
        case .authorized:
            startCamera(completion)
        case .notDetermined:
            CameraController.requestAccess { [weak self] granted in
                if granted {
                    self?.startCamera(completion)
                } else {
                    completion(.failure(StringError(message: "摄像头权限被拒绝")))
                }
            }
        default:
            completion(.failure(StringError(message: "摄像头权限被拒绝，请到 系统设置 → 隐私与安全性 → 摄像头 中允许 MacGestures")))
        }
    }

    private func startCamera(_ completion: @escaping (Result<Void, StringError>) -> Void) {
        do {
            try camera.start()
            completion(.success(()))
        } catch {
            completion(.failure(StringError(message: error.localizedDescription)))
        }
    }

    func stopRecognition() {
        camera.stop()
    }
}
