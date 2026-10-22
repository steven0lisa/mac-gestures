import Foundation

/// 配置持久化：~/Library/Application Support/MacGestures/config.json
/// UI 与 HTTP CLI 都通过本类读写，串行队列保证线程安全。
final class ConfigStore {
    static let shared = ConfigStore()

    private let queue = DispatchQueue(label: "com.macgestures.config")
    private let fileURL: URL

    private(set) var settings: AppSettings
    private(set) var gestures: [GestureKind: GestureConfig]

    var changeCount = 0  // 调试用：配置被修改的次数

    init(defaults: (settings: AppSettings, gestures: [GestureKind: GestureConfig])? = nil,
         directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGestures", isDirectory: true)
        fileURL = dir.appendingPathComponent("config.json")
        settings = defaults?.settings ?? AppSettings()
        gestures = defaults?.gestures ?? {
            var g: [GestureKind: GestureConfig] = [:]
            for kind in GestureKind.allCases { g[kind] = GestureConfig() }
            return g
        }()
        load()
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONDecoder().decode(PersistedConfig.self, from: data)
        else { return }
        settings = obj.settings
        for (id, config) in obj.gestures {
            if let kind = GestureKind(rawValue: id) {
                gestures[kind] = config
            }
        }
    }

    func save() {
        queue.sync { persistLocked() }
    }

    private struct PersistedConfig: Codable {
        var schemaVersion: Int = 1
        var settings: AppSettings
        // enum-key 字典会被 Codable 编成数组，转 String key 保证配置文件可读
        var gestures: [String: GestureConfig]

        init(settings: AppSettings, gestures: [GestureKind: GestureConfig]) {
            self.schemaVersion = 1
            self.settings = settings
            self.gestures = Dictionary(uniqueKeysWithValues: gestures.map { ($0.key.rawValue, $0.value) })
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
            let raw = try c.decodeIfPresent([String: GestureConfig].self, forKey: .gestures) ?? [:]
            gestures = raw
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case settings
            case gestures
        }
    }

    // MARK: - 修改接口（内部已串行化，调用后无需再 save）

    @discardableResult
    func updateGesture(_ kind: GestureKind, _ mutate: (inout GestureConfig) -> Void) -> GestureConfig {
        queue.sync {
            var config = gestures[kind] ?? GestureConfig()
            mutate(&config)
            gestures[kind] = config
            persistLocked()
            return config
        }
    }

    @discardableResult
    func updateSettings(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        queue.sync {
            mutate(&settings)
            persistLocked()
            return settings
        }
    }

    func gestureConfig(_ kind: GestureKind) -> GestureConfig {
        queue.sync { gestures[kind] ?? GestureConfig() }
    }

    var currentSettings: AppSettings {
        queue.sync { settings }
    }

    /// 私有：在 queue.sync 内部调用（queue 非 recursive，避免死锁）
    private func persistLocked() {
        let persisted = PersistedConfig(settings: settings, gestures: gestures)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            changeCount += 1
        } catch {
            NSLog("MacGestures: 保存配置失败 \(error)")
        }
    }
}
