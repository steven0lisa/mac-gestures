import Foundation

// MARK: - 脚本类型

enum ScriptType: String, Codable, CaseIterable {
    case applescript
    case shell

    var displayName: String {
        switch self {
        case .applescript: return "AppleScript"
        case .shell: return "Shell"
        }
    }
}

// MARK: - 内置手势

/// 8 种内置手势。rawValue 同时用作 JSON / HTTP CLI / 配置文件里的 id（snake_case）。
enum GestureKind: String, Codable, CaseIterable, Identifiable {
    case ok
    case victory
    case thumbsUp = "thumbs_up"
    case thumbsDown = "thumbs_down"
    case fist
    case openPalm = "open_palm"
    case indexPoint = "index_point"
    case callMe = "call_me"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ok: return "OK"
        case .victory: return "Victory"
        case .thumbsUp: return "Thumbs Up"
        case .thumbsDown: return "Thumbs Down"
        case .fist: return "Fist"
        case .openPalm: return "Open Palm"
        case .indexPoint: return "Point"
        case .callMe: return "Call Me"
        }
    }

    /// 示意图标（emoji，设置页大图 + 托盘识别提示）
    var icon: String {
        switch self {
        case .ok: return "👌"
        case .victory: return "✌️"
        case .thumbsUp: return "👍"
        case .thumbsDown: return "👎"
        case .fist: return "✊"
        case .openPalm: return "🖐️"
        case .indexPoint: return "☝️"
        case .callMe: return "🤙"
        }
    }

    var howTo: String {
        switch self {
        case .ok: return "拇指与食指圈成 O 形，中指/无名指/小指张开"
        case .victory: return "食指与中指张开伸出，其余手指收拢"
        case .thumbsUp: return "竖起大拇指，其余四指握拳，手背朝向摄像头"
        case .thumbsDown: return "大拇指向下，其余四指握拳，手背朝向摄像头"
        case .fist: return "四指握拳（拇指方向不限）"
        case .openPalm: return "五指全部张开，掌心朝向摄像头"
        case .indexPoint: return "只伸出食指，其余手指收拢"
        case .callMe: return "伸出拇指和小指，其余三指收拢（六 / 打电话）"
        }
    }

    /// 开箱即用的默认脚本：macOS 通知报告识别到的手势
    var defaultScript: String {
        "display notification \"\(icon) 识别到 \(name) 手势\" with title \"MacGestures\" sound name \"Glass\""
    }
}

// MARK: - 单个手势的配置

struct GestureConfig: Codable, Equatable {
    var enabled: Bool = false
    var scriptType: ScriptType = .applescript
    var script: String = ""
    var cooldown: Double = 3.0

    private enum CodingKeys: String, CodingKey {
        case enabled
        case scriptType = "script_type"
        case script
        case cooldown
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        scriptType = try c.decodeIfPresent(ScriptType.self, forKey: .scriptType) ?? .applescript
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldown) ?? 3.0
    }
}

// MARK: - 全局设置

struct AppSettings: Codable, Equatable {
    var port: Int = 8741
    var stabilityFrames: Int = 3
    var launchRecognitionOnStart: Bool = true
    var launchAtLogin: Bool = false
    var apiToken: String = ""
    var ownerGateEnabled: Bool = false
    var faceMatchMaxDistance: Double = 12.0

    private enum CodingKeys: String, CodingKey {
        case port
        case stabilityFrames = "stability_frames"
        case launchRecognitionOnStart = "launch_recognition_on_start"
        case launchAtLogin = "launch_at_login"
        case apiToken = "api_token"
        case ownerGateEnabled = "owner_gate_enabled"
        case faceMatchMaxDistance = "face_match_max_distance"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8741
        stabilityFrames = try c.decodeIfPresent(Int.self, forKey: .stabilityFrames) ?? 3
        launchRecognitionOnStart = try c.decodeIfPresent(Bool.self, forKey: .launchRecognitionOnStart) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken) ?? ""
        ownerGateEnabled = try c.decodeIfPresent(Bool.self, forKey: .ownerGateEnabled) ?? false
        faceMatchMaxDistance = try c.decodeIfPresent(Double.self, forKey: .faceMatchMaxDistance) ?? 12.0
    }
}
