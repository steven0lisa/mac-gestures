import AppKit
import AVFoundation
import Vision

/// 摄像头采集 + Vision 手部姿态识别帧处理。
/// 只负责"出帧"，几何分类与触发交给 GestureEngine。
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.macgestures.camera.frames")
    private var configured = false
    private var busy = false
    private var frameCounter = 0
    private var lastProcessAt: TimeInterval = 0
    private var fpsAverage: Double = 0

    private(set) var framesSeen = 0
    private(set) var framesProcessed = 0
    private(set) var handsDetected = 0
    private(set) var lastError: String?
    private(set) var latestPixelBuffer: CVPixelBuffer?   // 供人脸录入取当前帧

    /// 属主人脸门控（nil = 未启用门控检查）
    var faceGate: FaceGate?

    /// 每帧回调（在 videoQueue 上调用）：手部关键点 + 人脸验证结果
    var onHandPoints: ((HandPoints?, FaceVerifyOutcome) -> Void)?

    var isRunning: Bool { session.isRunning }

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    // MARK: - 启停

    func start() throws {
        if !configured {
            try configure()
        }
        guard !session.isRunning else { return }
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) } else { throw CameraError.cannotAddInput }
        if session.canAddOutput(output) { session.addOutput(output) } else { throw CameraError.cannotAddOutput }
        session.commitConfiguration()
        configured = true
    }

    enum CameraError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "未找到可用的摄像头"
            case .cannotAddInput: return "无法将摄像头添加为输入源"
            case .cannotAddOutput: return "无法添加视频输出"
            }
        }
    }

    // MARK: - 帧处理

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        framesSeen += 1
        frameCounter += 1
        guard !busy else { return }
        // 约 15fps 送去识别：隔帧处理，省电且足够
        guard frameCounter % 2 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        latestPixelBuffer = pixelBuffer

        // 人脸检查：门控开启时非本人/无人脸拦下手势；仅开"离开变暗"时只采集在场信息不拦手势
        var outcome = FaceVerifyOutcome.disabled
        if let faceGate = faceGate, faceGate.checkActive {
            outcome = faceGate.verify(pixelBuffer: pixelBuffer)
            if faceGate.gateEnabled && !outcome.allowsGesture {
                onHandPoints?(nil, outcome)
                return
            }
        }

        busy = true
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        Task.detached(priority: .userInitiated) { [weak self] in
            defer { self?.busy = false }
            // 同步 VN API（macOS 11+ 全 SDK 可用；新版 Swift Vision API 在 Xcode 16 SDK 缺 joint(for:)）
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
                self?.recordProcessing(timestamp: timestamp)
                guard let observation = (request.results ?? []).first as? VNHumanHandPoseObservation else {
                    self?.onHandPoints?(nil, outcome)
                    return
                }
                self?.handsDetected += 1
                self?.onHandPoints?(HandPoints(vnObservation: observation), outcome)
            } catch {
                self?.lastError = "\(error)"
            }
        }
    }

    private func recordProcessing(timestamp: TimeInterval) {
        framesProcessed += 1
        if lastProcessAt > 0 {
            let dt = timestamp - lastProcessAt
            if dt > 0 {
                let fps = 1.0 / dt
                fpsAverage = fpsAverage == 0 ? fps : fpsAverage * 0.9 + fps * 0.1
            }
        }
        lastProcessAt = timestamp
    }

    var approxFPS: Double { fpsAverage }
}
