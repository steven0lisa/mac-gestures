import AppKit
import CoreVideo
import Vision

// MARK: - 验证结果

enum FaceVerifyOutcome: Equatable {
    case disabled                 // 未录入人脸或未开启门控
    case noFace                   // 画面中没有人脸
    case rejected(distance: Double)
    case accepted(distance: Double)

    /// 是否放行进入手势识别
    var allowsGesture: Bool {
        switch self {
        case .disabled, .accepted: return true
        case .noFace, .rejected: return false
        }
    }
}

// MARK: - 属主人脸门控

/// 录入本人基准人脸后，仅当画面人脸与基准匹配（特征距离 ≤ 阈值）时手势才触发。
/// 特征比对用 Vision GenerateImageFeaturePrintRequest（本地 ANE 计算，不联网）。
final class FaceGate {
    private let config: ConfigStore
    private let directory: URL
    private let faceImageURL: URL
    private let metaURL: URL
    private let ciContext = CIContext()

    private var baseFeature: VNFeaturePrintObservation?
    private(set) var enrolledAt: Date?
    private(set) var lastDistance: Double?
    private(set) var lastVerifyAt: Date?
    private(set) var lastOutcome: FaceVerifyOutcome = .disabled

    init(config: ConfigStore, directory: URL? = nil) {
        self.config = config
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGestures", isDirectory: true)
        self.directory = dir
        faceImageURL = dir.appendingPathComponent("owner-face.jpg")
        metaURL = dir.appendingPathComponent("owner-face.json")
        loadEnrollment()
    }

    var isEnrolled: Bool { baseFeature != nil && FileManager.default.fileExists(atPath: faceImageURL.path) }

    var gateEnabled: Bool { config.currentSettings.ownerGateEnabled }
    var threshold: Double { config.currentSettings.faceMatchMaxDistance }

    /// 离开变暗（presence）功能是否开启
    var presenceEnabled: Bool { config.currentSettings.presenceDimEnabled }

    /// 本帧是否需要跑人脸检测：录入了人脸，且属主门控或离开变暗任一开启
    var checkActive: Bool {
        isEnrolled && (gateEnabled || presenceEnabled)
    }

    /// 每帧人脸在/不在回调（PresenceScreen 消费；视频队列线程调用）
    var onFacePresence: ((Bool) -> Void)?

    // MARK: - 录入管理

    private func loadEnrollment() {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(EnrollMeta.self, from: data),
              let image = NSImage(contentsOf: faceImageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        guard let feature = Self.featurePrint(of: cgImage, region: nil) else {
            NSLog("MacGestures: 基准人脸特征生成失败")
            return
        }
        baseFeature = feature
        enrolledAt = meta.enrolledAt
    }

    /// 从一帧画面录入人脸。返回 (裁剪的预览图, 自检距离)。要求画面里有清晰人脸。
    func enroll(pixelBuffer: CVPixelBuffer) throws -> (previewImage: CGImage, distance: Double) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let faceRect = Self.detectFace(pixelBuffer: pixelBuffer) else {
            throw FaceGateError.noFace
        }

        // 像素缓冲 → CGImage → 按人脸框裁剪（Vision 归一化框原点在左下）
        guard let fullImage = Self.cgImage(from: pixelBuffer) else {
            throw FaceGateError.captureFailed
        }
        let cropRect = CGRect(x: faceRect.origin.x * CGFloat(width),
                              y: (1 - faceRect.origin.y - faceRect.height) * CGFloat(height),
                              width: faceRect.width * CGFloat(width),
                              height: faceRect.height * CGFloat(height))
        guard let cropped = fullImage.cropping(to: cropRect.integral) else {
            throw FaceGateError.captureFailed
        }

        guard let feature = Self.featurePrint(of: cropped, region: nil) else {
            throw FaceGateError.featureFailed
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let jpeg = cgImageToJPEG(cropped) else { throw FaceGateError.captureFailed }
        try jpeg.write(to: faceImageURL, options: .atomic)
        let meta = EnrollMeta(enrolledAt: Date())
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)

        baseFeature = feature
        enrolledAt = meta.enrolledAt
        lastDistance = nil

        // 自检：特征与自身的距离（应为 0；顺带验证 computeDistance 可用）
        var selfDistance: Float = 0
        try? feature.computeDistance(&selfDistance, to: feature)
        return (cropped, Double(selfDistance))
    }

    func deleteEnrollment() {
        baseFeature = nil
        enrolledAt = nil
        lastDistance = nil
        lastOutcome = .disabled
        try? FileManager.default.removeItem(at: faceImageURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    // MARK: - 逐帧验证

    /// 对一帧做脸检：属主门控开启时结果用于放行手势；离开变暗开启时结果喂给 presence 回调。
    /// 两者独立——只开变暗不开门控时，别人的脸不会拦手势，但会计入「我不在」。
    func verify(pixelBuffer: CVPixelBuffer) -> FaceVerifyOutcome {
        guard isEnrolled, checkActive, let base = baseFeature else {
            lastOutcome = .disabled
            return .disabled
        }
        guard let faceRect = Self.detectFace(pixelBuffer: pixelBuffer),
              let feature = Self.featurePrint(of: nil, pixelBuffer: pixelBuffer, region: faceRect)
        else {
            lastOutcome = .noFace
            onFacePresence?(false)
            return .noFace
        }
        var distance = Float(0)
        do {
            try feature.computeDistance(&distance, to: base)
        } catch {
            lastOutcome = .noFace
            onFacePresence?(false)
            return .noFace
        }
        let distanceValue = Double(distance)
        lastDistance = distanceValue
        lastVerifyAt = Date()
        let outcome: FaceVerifyOutcome = distanceValue <= threshold ? .accepted(distance: distanceValue) : .rejected(distance: distanceValue)
        lastOutcome = outcome
        if case .accepted = outcome {
            onFacePresence?(true)
        } else {
            onFacePresence?(false)
        }
        return outcome
    }

    // MARK: - Vision 基础设施

    enum FaceGateError: LocalizedError {
        case noFace, captureFailed, featureFailed

        var errorDescription: String? {
            switch self {
            case .noFace: return "画面中未检测到人脸，请正对摄像头后重试"
            case .captureFailed: return "画面捕获失败"
            case .featureFailed: return "人脸特征生成失败"
            }
        }
    }

    private struct EnrollMeta: Codable {
        let enrolledAt: Date
    }

    /// 返回归一化人脸框（原点左下，与 VN API 的 regionOfInterest 同一坐标系），取画面中最大的人脸
    static func detectFace(pixelBuffer: CVPixelBuffer) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = (request.results ?? []).compactMap({ $0 as? VNFaceObservation }).max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return nil }
        return face.boundingBox
    }

    /// region 为 nil 时对整张 cgImage 计算；提供 pixelBuffer+region 时按区域计算（同步 VN API）
    static func featurePrint(of cgImage: CGImage?, pixelBuffer: CVPixelBuffer? = nil,
                             region: CGRect? = nil) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        if let region = region { request.regionOfInterest = region }
        let handler: VNImageRequestHandler
        if let pixelBuffer = pixelBuffer {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        } else if let cgImage = cgImage {
            handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        } else { return nil }
        guard (try? handler.perform([request])) != nil else { return nil }
        return (request.results ?? []).compactMap { $0 as? VNFeaturePrintObservation }.first
    }

    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    private func cgImageToJPEG(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
