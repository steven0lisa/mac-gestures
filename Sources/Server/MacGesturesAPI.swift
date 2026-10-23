import Foundation

/// mac-gestures 的 HTTP CLI 命令树（http-cli-for-agent v1.0.0 协议）。
/// 挂载在 http://127.0.0.1:<port>/cli ，所有命令都是对既有服务层的薄适配。
enum MacGesturesAPI {
    static func buildRouter(context: AppContext) -> CLIRouter {
        let router = CLIRouter(mountPath: "/cli")
        router.serverVersion = Self.serverVersion
        router.apiToken = context.config.currentSettings.apiToken

        let root = router.root
        root.summary = "MacGestures local control: configure camera hand gestures that run AppleScript/shell scripts"
        root.detailDescription = """
        MacGestures watches the camera for hand gestures (OK, thumbs up, fist, ...) and \
        runs the AppleScript or shell script bound to each gesture. This command tree lets a \
        local agent inspect status and configure gestures. All data stays on this machine. \
        Discovery: start from GET {base}?help=1 and drill down with ?help=1 at each node.
        """
        router.authentication = [
            "scheme": "none",
            "header": "(none)",
            "value_format": "no credential required by default",
            "description": "The server binds to 127.0.0.1 only — reachable by local processes only. "
                + "No credential is checked unless an api_token is set in config.json, "
                + "in which case send Authorization: Bearer <token>. "
                + "Credential carriage: header only, never in URLs; failed attempts return 401 unauthorized.",
            "obtain": "Nothing to obtain by default. To harden: set \"api_token\" in "
                + "~/Library/Application Support/MacGestures/config.json and restart, then pass the same value as a Bearer token.",
        ]

        root.add(statusCommand(context))
        root.add(gesturesGroup(context))
        root.add(recognitionGroup(context))
        root.add(eventsCommand(context))
        root.add(ownerGroup(context))
        root.add(settingsGroup(context))
        root.add(versionGroup())
        return router
    }

    // MARK: - status

    private static func statusCommand(_ context: AppContext) -> CLICommand {
        CLICommand(name: "status", method: "GET",
                   summary: "Show recognition status, camera state and the last detected gesture",
                   description: "Read-only snapshot of the whole app: whether recognition is running, "
                       + "camera permission, frame counters, owner face gate state and the most recent gesture trigger.",
                   examples: ["GET {base}/status?fields=recognition,last_gesture"]) { _ in
            statusDict(context)
        }
    }

    static func statusDict(_ context: AppContext) -> [String: Any] {
        var dict: [String: Any] = [
            "recognition": context.recognitionState,
            "camera_authorized": CameraController.authorizationStatus == .authorized,
            "frames_seen": context.camera.framesSeen,
            "frames_processed": context.camera.framesProcessed,
            "hands_detected_frames": context.camera.handsDetected,
            "approx_fps": (context.camera.approxFPS * 10).rounded() / 10,
            "trigger_count_today": context.engine.triggerCount,
            "power_source": context.powerSource,
            "auto_paused_by_battery": context.autoPausedByBattery,
            "owner_gate": ownerDict(context),
            "port": context.config.currentSettings.port,
            "base_url": "http://127.0.0.1:\(context.config.currentSettings.port)/cli",
            "server_version": Self.serverVersion,
            "protocol_version": "1.0.0",
            "uptime_seconds": Int(Date().timeIntervalSince(context.startedAt)),
        ]
        if let last = context.events.lastGestureEvent() {
            dict["last_gesture"] = [
                "id": last.gestureId,
                "name": last.gestureName,
                "icon": last.icon,
                "detected_at": last.timestamp,
            ]
        } else {
            dict["last_gesture"] = NSNull()
        }
        if let error = context.camera.lastError {
            dict["camera_error"] = error
        }
        return dict
    }

    // MARK: - gestures

    private static func gesturesGroup(_ context: AppContext) -> CLIGroup {
        let group = CLIGroup(name: "gestures", summary: "List, inspect and configure the 8 built-in gestures",
                             description: "Every gesture has a stable snake_case id. Updating a gesture takes effect "
                                 + "immediately (no restart). Scripts are executed with the user's privileges: "
                                 + "AppleScript via osascript (script on stdin), shell via /bin/zsh -c.")
        group.add(CLICommand(name: "list", method: "GET",
                             summary: "List all built-in gestures with their config",
                             description: "Bounded list: exactly 8 built-in gestures, no pagination.",
                             params: [CLIParam("enabled", "boolean", description: "Only return gestures with this enabled state")],
                             examples: ["GET {base}/gestures/list?enabled=true&fields=id,name,enabled"]) { ctx in
                var configs: [[String: Any]] = []
                for kind in GestureKind.allCases {
                    let config = context.config.gestureConfig(kind)
                    if let enabled = ctx.bool("enabled"), config.enabled != enabled { continue }
                    configs.append(gestureSummary(kind, config))
                }
                return configs
            })
        group.add(CLICommand(name: "get", method: "GET",
                             summary: "Full detail of one gesture (including the script)",
                             params: [CLIParam("id", "enum", required: true,
                                               enum: GestureKind.allCases.map(\.rawValue),
                                               description: "Gesture id")],
                             examples: ["GET {base}/gestures/get?id=ok"]) { ctx in
                guard let id = ctx.string("id"), let kind = GestureKind(rawValue: id) else {
                    throw CLIError(status: 404, code: "not_found",
                                   message: "unknown gesture \"\(ctx.string("id") ?? "")\"",
                                   hint: "GET {base}/gestures/list to see all ids")
                }
                return gestureDetail(kind, context.config.gestureConfig(kind))
            })
        group.add(CLICommand(name: "update", method: "POST",
                             summary: "Update a gesture's script / enabled / cooldown",
                             description: "Partial update: only the parameters you send are changed. "
                                 + "Set enabled=true plus a script to arm a gesture. Takes effect immediately.",
                             params: [
                                 CLIParam("id", "enum", required: true,
                                          enum: GestureKind.allCases.map(\.rawValue), description: "Gesture id"),
                                 CLIParam("enabled", "boolean", description: "Arm/disarm the gesture"),
                                 CLIParam("script_type", "enum", enum: ["applescript", "shell"],
                                          description: "Which interpreter runs the script"),
                                 CLIParam("script", "string",
                                          description: "Script body. AppleScript runs via osascript; shell via /bin/zsh -c. Max 100000 characters"),
                                 CLIParam("cooldown", "number",
                                          description: "Minimum seconds between two triggers of this gesture (1-60)"),
                             ],
                             examples: [
                                 "POST {base}/gestures/update {\"id\":\"ok\",\"enabled\":true,\"script_type\":\"applescript\",\"script\":\"display notification \\\"OK!\\\"\",\"cooldown\":3}",
                                 "POST {base}/gestures/update {\"id\":\"thumbs_up\",\"enabled\":false}",
                             ]) { ctx in
                guard let id = ctx.string("id"), let kind = GestureKind(rawValue: id) else {
                    throw CLIError(status: 404, code: "not_found",
                                   message: "unknown gesture \"\(ctx.string("id") ?? "")\"",
                                   hint: "GET {base}/gestures/list to see all ids")
                }
                if let script = ctx.string("script"), script.count > 100_000 {
                    throw CLIError.invalidParam("script", "(\(script.count) chars)",
                                                hint: "script must be at most 100000 characters")
                }
                if let cooldown = ctx.double("cooldown"), cooldown < 1 || cooldown > 60 {
                    throw CLIError.invalidParam("cooldown", "\(cooldown)", hint: "allowed range: 1 - 60 seconds")
                }
                let updated = context.config.updateGesture(kind) { config in
                    if let enabled = ctx.bool("enabled") { config.enabled = enabled }
                    if let type = ctx.string("script_type"), let t = ScriptType(rawValue: type) { config.scriptType = t }
                    if let script = ctx.string("script") { config.script = script }
                    if let cooldown = ctx.double("cooldown") { config.cooldown = cooldown }
                }
                return gestureDetail(kind, updated)
            })
        return group
    }

    static func gestureSummary(_ kind: GestureKind, _ config: GestureConfig) -> [String: Any] {
        [
            "id": kind.rawValue,
            "name": kind.name,
            "icon": kind.icon,
            "how_to": kind.howTo,
            "enabled": config.enabled,
            "script_type": config.scriptType.rawValue,
            "cooldown_seconds": config.cooldown,
            "has_script": !config.script.isEmpty,
        ]
    }

    static func gestureDetail(_ kind: GestureKind, _ config: GestureConfig) -> [String: Any] {
        var dict = gestureSummary(kind, config)
        dict["script"] = config.script
        return dict
    }

    // MARK: - recognition

    private static func recognitionGroup(_ context: AppContext) -> CLIGroup {
        let group = CLIGroup(name: "recognition", summary: "Start/stop camera recognition and test-run gesture scripts")
        group.add(CLICommand(name: "start", method: "POST",
                             summary: "Start camera recognition (requests camera permission if needed)",
                             description: "Equivalent to the tray menu 'start'. If camera permission has not been "
                                 + "granted yet, the system prompt is shown; retry after the user approves.",
                             examples: ["POST {base}/recognition/start"]) { _ in
                var startError: String?
                let semaphore = DispatchSemaphore(value: 0)
                context.startRecognition { result in
                    if case .failure(let error) = result { startError = error.message }
                    semaphore.signal()
                }
                semaphore.wait()
                if let message = startError {
                    throw CLIError(status: 409, code: "conflict", message: message,
                                   hint: "approve camera access, then retry: POST {base}/recognition/start")
                }
                return statusDict(context)
            })
        group.add(CLICommand(name: "stop", method: "POST",
                             summary: "Pause camera recognition (camera light turns off)",
                             examples: ["POST {base}/recognition/stop"]) { _ in
                context.stopRecognition()
                return statusDict(context)
            })
        group.add(CLICommand(name: "test", method: "POST",
                             summary: "Run a gesture's script right now (no camera needed)",
                             description: "Executes the configured script immediately and returns its output. "
                                 + "The run is recorded in /events with source \"test\".",
                             params: [CLIParam("id", "enum", required: true,
                                               enum: GestureKind.allCases.map(\.rawValue),
                                               description: "Gesture id whose script should run")],
                             examples: ["POST {base}/recognition/test {\"id\":\"ok\"}"]) { ctx in
                guard let id = ctx.string("id"), let kind = GestureKind(rawValue: id) else {
                    throw CLIError(status: 404, code: "not_found",
                                   message: "unknown gesture \"\(ctx.string("id") ?? "")\"",
                                   hint: "GET {base}/gestures/list to see all ids")
                }
                let config = context.config.gestureConfig(kind)
                guard !config.script.isEmpty else {
                    throw CLIError(status: 409, code: "conflict",
                                   message: "gesture \"\(id)\" has no script configured",
                                   hint: "POST {base}/gestures/update {\"id\":\"\(id)\",\"script\":\"...\"} first")
                }
                let started = Date()
                let result = ScriptRunner.shared.runSync(scriptType: config.scriptType, script: config.script, timeout: 15)
                let event = GestureEngine.makeEvent(kind: kind, source: "test", at: started,
                                                    scriptType: config.scriptType, result: result)
                context.events.append(event)
                return [
                    "gesture_id": kind.rawValue,
                    "source": "test",
                    "script_type": config.scriptType.rawValue,
                    "exit_code": result.exitCode.map { Int($0) } ?? NSNull(),
                    "timed_out": result.timedOut,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "launch_error": result.launchError ?? NSNull(),
                    "duration_ms": (result.durationMs * 100).rounded() / 100,
                ]
            })
        return group
    }

    // MARK: - events

    private static func eventsCommand(_ context: AppContext) -> CLICommand {
        CLICommand(name: "events", method: "GET",
                   summary: "Recent detection/test runs, newest first",
                   description: "In-memory ring buffer (last 200 events, not persisted). Pagination: offset form.",
                   params: [
                       CLIParam("offset", "integer", default: "0", description: "Skip this many newest events (0-based)"),
                       CLIParam("limit", "integer", default: "20", description: "Maximum events returned (1-100)"),
                       CLIParam("gesture", "enum", enum: GestureKind.allCases.map(\.rawValue),
                                description: "Only events of this gesture"),
                   ],
                   examples: ["GET {base}/events?limit=5&fields=timestamp,gesture_id,exit_code"]) { ctx in
            let limit = min(max(ctx.int("limit") ?? 20, 1), 100)
            let offset = max(ctx.int("offset") ?? 0, 0)
            let gestureFilter = ctx.string("gesture").flatMap { GestureKind(rawValue: $0) }
            var all = context.events.all()
            if let gestureFilter = gestureFilter {
                all = all.filter { $0.gestureId == gestureFilter.rawValue }
            }
            let total = all.count
            let start = min(offset, total)
            let end = min(offset + limit, total)
            let page = all[start..<end].map { event -> [String: Any] in
                [
                    "id": event.id,
                    "timestamp": event.timestamp,
                    "source": event.source,
                    "gesture_id": event.gestureId,
                    "gesture_name": event.gestureName,
                    "icon": event.icon,
                    "script_type": event.scriptType,
                    "exit_code": event.exitCode.map { Int($0) } ?? NSNull(),
                    "timed_out": event.timedOut,
                    "stdout": event.stdout,
                    "stderr": event.stderr,
                    "launch_error": event.launchError ?? NSNull(),
                    "duration_ms": event.durationMs,
                ]
            }
            return CLIPage(items: page, meta: [
                "total": total, "offset": start, "limit": limit, "has_more": end < total,
            ])
        }
    }

    // MARK: - owner（人脸门控）

    private static func ownerGroup(_ context: AppContext) -> CLIGroup {
        let group = CLIGroup(name: "owner", summary: "Owner face enrollment: only the enrolled face triggers gestures",
                             description: "When a face is enrolled and the gate is enabled, every camera frame is "
                                 + "checked against the enrolled face first; gestures from other people are ignored. "
                                 + "Face features are computed on-device by Vision and never leave this machine.")
        group.add(CLICommand(name: "status", method: "GET",
                             summary: "Face enrollment and gate state",
                             examples: ["GET {base}/owner/status"]) { _ in
                ownerDict(context)
            })
        group.add(CLICommand(name: "enroll", method: "POST",
                             summary: "Enroll the owner's face from the current camera frame",
                             description: "Captures the latest camera frame, detects the face and stores its feature "
                                 + "as the owner baseline. The user must look at the camera. Recognition must be running.",
                             params: [
                                 CLIParam("gate_enabled", "boolean", default: "true",
                                          description: "Enable the gate right after enrolling"),
                                 CLIParam("threshold", "number",
                                          description: "Face match threshold to set (2-40, lower = stricter). "
                                              + "Watch owner/status last_distance while recognizing to tune it"),
                             ],
                             examples: ["POST {base}/owner/enroll {\"gate_enabled\":true}"]) { ctx in
                if let threshold = ctx.double("threshold"), threshold < 2 || threshold > 40 {
                    throw CLIError.invalidParam("threshold", "\(threshold)", hint: "allowed range: 2 - 40")
                }
                guard context.camera.isRunning, let buffer = context.camera.latestPixelBuffer else {
                    throw CLIError(status: 409, code: "conflict",
                                   message: "camera is not running, cannot capture a frame",
                                   hint: "POST {base}/recognition/start first, wait ~2s, then retry")
                }
                do {
                    _ = try context.faceGate.enroll(pixelBuffer: buffer)
                    context.presenceScreen.setEnrolled(true)
                } catch {
                    throw CLIError(status: 409, code: "conflict",
                                   message: error.localizedDescription,
                                   hint: "make sure a face is clearly visible, then retry")
                }
                context.config.updateSettings { settings in
                    if let gate = ctx.bool("gate_enabled") { settings.ownerGateEnabled = gate }
                    if let threshold = ctx.double("threshold") { settings.faceMatchMaxDistance = threshold }
                }
                return ownerDict(context)
            })
        group.add(CLICommand(name: "update", method: "POST",
                             summary: "Enable/disable the gate, presence dimming, or adjust matching",
                             params: [
                                 CLIParam("gate_enabled", "boolean", description: "Enable/disable owner gating"),
                                 CLIParam("threshold", "number", description: "Face match threshold (2-40); "
                                             + "compare with last_distance in owner/status"),
                                 CLIParam("presence_dim_enabled", "boolean",
                                          description: "Turn the display off (screen sleep, not system sleep) after no owner "
                                              + "face for a while; wake instantly when the owner returns. Requires an enrolled face"),
                                 CLIParam("presence_dim_seconds", "number",
                                          description: "Seconds without the owner's face before the screen turns off (3-60)"),
                             ],
                             examples: ["POST {base}/owner/update {\"gate_enabled\":false}",
                                        "POST {base}/owner/update {\"presence_dim_enabled\":true,\"presence_dim_seconds\":5}"]) { ctx in
                guard ctx.bool("gate_enabled") != nil || ctx.double("threshold") != nil
                        || ctx.bool("presence_dim_enabled") != nil || ctx.double("presence_dim_seconds") != nil else {
                    throw CLIError(status: 400, code: "missing_param",
                                   message: "nothing to update: send gate_enabled, threshold, presence_dim_enabled and/or presence_dim_seconds",
                                   hint: "POST {base}/owner/update {\"gate_enabled\":true}")
                }
                if let threshold = ctx.double("threshold"), threshold < 2 || threshold > 40 {
                    throw CLIError.invalidParam("threshold", "\(threshold)", hint: "allowed range: 2 - 40")
                }
                if let seconds = ctx.double("presence_dim_seconds"), seconds < 3 || seconds > 60 {
                    throw CLIError.invalidParam("presence_dim_seconds", "\(seconds)", hint: "allowed range: 3 - 60 seconds")
                }
                context.config.updateSettings { settings in
                    if let gate = ctx.bool("gate_enabled") { settings.ownerGateEnabled = gate }
                    if let threshold = ctx.double("threshold") { settings.faceMatchMaxDistance = threshold }
                    if let presence = ctx.bool("presence_dim_enabled") { settings.presenceDimEnabled = presence }
                    if let seconds = ctx.double("presence_dim_seconds") { settings.presenceDimSeconds = seconds }
                }
                return ownerDict(context)
            })
        group.add(CLICommand(name: "delete", method: "POST",
                             summary: "Remove the enrolled face and disable gating",
                             examples: ["POST {base}/owner/delete"]) { _ in
                guard context.faceGate.isEnrolled else {
                    throw CLIError(status: 404, code: "not_found",
                                   message: "no face enrolled",
                                   hint: "POST {base}/owner/enroll while facing the camera")
                }
                context.faceGate.deleteEnrollment()
                context.presenceScreen.setEnrolled(false)
                context.config.updateSettings {
                    $0.ownerGateEnabled = false
                    $0.presenceDimEnabled = false
                }
                return ownerDict(context)
            })
        return group
    }

    static func ownerDict(_ context: AppContext) -> [String: Any] {
        let gate = context.faceGate
        var dict: [String: Any] = [
            "enrolled": gate.isEnrolled,
            "gate_enabled": gate.gateEnabled,
            "threshold": gate.threshold,
        ]
        if let enrolledAt = gate.enrolledAt {
            dict["enrolled_at"] = GestureEngine.rfc3339(enrolledAt)
        }
        if let distance = gate.lastDistance {
            dict["last_distance"] = (distance * 100).rounded() / 100
        }
        if let verifiedAt = gate.lastVerifyAt {
            dict["last_verify_at"] = GestureEngine.rfc3339(verifiedAt)
        }
        let screen = context.presenceScreen
        var presence: [String: Any] = [
            "supported": screen.supported,
            "enabled": gate.presenceEnabled,
            "seconds": screen.thresholdSeconds,
            "screen_off": screen.isScreenOff,
        ]
        if let offAt = screen.screenOffAt {
            presence["screen_off_at"] = GestureEngine.rfc3339(offAt)
        }
        dict["presence_dim"] = presence
        return dict
    }

    // MARK: - settings（全局设置）

    private static func settingsGroup(_ context: AppContext) -> CLIGroup {
        let group = CLIGroup(name: "settings", summary: "App-wide settings: port, stability, battery pause, autostart",
                             description: "Changes take effect immediately. Changing the port restarts the HTTP "
                                 + "listener, so the response comes from the NEW port.")
        group.add(CLICommand(name: "get", method: "GET",
                             summary: "Read app-wide settings",
                             examples: ["GET {base}/settings/get"]) { _ in
                settingsDict(context)
            })
        group.add(CLICommand(name: "update", method: "POST",
                             summary: "Update app-wide settings (partial)",
                             description: "Only the parameters you send are changed and persisted to config.json. "
                                 + "pause_on_battery pauses recognition while on battery power and resumes on AC. "
                                 + "Changing the port restarts the HTTP listener immediately.",
                             params: [
                                 CLIParam("port", "integer", description: "HTTP CLI port (1024-65535); restarts the listener"),
                                 CLIParam("stability_frames", "integer",
                                          description: "Consecutive frames of the same gesture required before triggering (1-10)"),
                                 CLIParam("launch_recognition_on_start", "boolean",
                                          description: "Resume recognition automatically on app launch (camera already authorized)"),
                                 CLIParam("pause_on_battery", "boolean",
                                          description: "Pause all recognition when on battery power, resume on AC (default true)"),
                             ],
                             examples: ["POST {base}/settings/update {\"pause_on_battery\":false}",
                                        "POST {base}/settings/update {\"stability_frames\":4}"]) { ctx in
                if let port = ctx.int("port") {
                    guard (1024...65535).contains(port) else {
                        throw CLIError.invalidParam("port", "\(port)", hint: "allowed range: 1024 - 65535")
                    }
                }
                if let frames = ctx.int("stability_frames"), frames < 1 || frames > 10 {
                    throw CLIError.invalidParam("stability_frames", "\(frames)", hint: "allowed range: 1 - 10")
                }
                context.config.updateSettings { settings in
                    if let port = ctx.int("port") { settings.port = port }
                    if let frames = ctx.int("stability_frames") { settings.stabilityFrames = frames }
                    if let launch = ctx.bool("launch_recognition_on_start") { settings.launchRecognitionOnStart = launch }
                    if let battery = ctx.bool("pause_on_battery") { settings.pauseOnBattery = battery }
                }
                if ctx.bool("pause_on_battery") != nil {
                    context.applyPauseOnBatterySetting()
                }
                if let port = ctx.int("port") {
                    context.onServerRestart?(UInt16(port))
                }
                return settingsDict(context)
            })
        return group
    }

    static func settingsDict(_ context: AppContext) -> [String: Any] {
        let settings = context.config.currentSettings
        return [
            "port": context.effectivePort,
            "configured_port": settings.port,
            "stability_frames": settings.stabilityFrames,
            "launch_recognition_on_start": settings.launchRecognitionOnStart,
            "pause_on_battery": settings.pauseOnBattery,
            "power_source": context.powerSource,
            "auto_paused_by_battery": context.autoPausedByBattery,
        ]
    }

    // MARK: - version surface

    private static func versionGroup() -> CLIGroup {
        let group = CLIGroup(name: "version", summary: "Implementation and protocol version info")
        group.add(CLICommand(name: "current", method: "GET",
                             summary: "Current version metadata",
                             examples: ["GET {base}/version/current"]) { _ in
                currentVersionDict()
            })
        group.add(CLICommand(name: "releases", method: "GET",
                             summary: "Release notes, newest first",
                             description: "Bounded history: the embedded package.json releaseHistory. "
                                 + "When \"since\" is not a valid semver the full list is returned.",
                             params: [
                                 CLIParam("since", "string", description: "Return only releases newer than this semver"),
                                 CLIParam("limit", "integer", default: "10", description: "Maximum releases (1-50)"),
                             ],
                             examples: ["GET {base}/version/releases?since=0.1.0"]) { ctx in
                let limit = min(max(ctx.int("limit") ?? 10, 1), 50)
                var releases = Self.releaseHistory()
                if let since = ctx.string("since"), let sinceVersion = Self.parseSemver(since) {
                    releases = releases.filter { release in
                        guard let v = Self.parseSemver(release["version"] as? String ?? "") else { return true }
                        return Self.semverCompare(v, sinceVersion) > 0
                    }
                }
                return Array(releases.prefix(limit))
            })
        return group
    }

    static func currentVersionDict() -> [String: Any] {
        var dict: [String: Any] = [
            "protocol_version": "1.0.0",
            "server_version": serverVersion,
            "released_at": releaseHistory().first?["released_at"] as? String ?? "1970-01-01T00:00:00Z",
            "channel": "stable",
        ]
        if let commit = Bundle.main.infoDictionary?["GitCommit"] as? String, !commit.isEmpty {
            dict["commit"] = commit
        }
        return dict
    }

    static var serverVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 从打包进 bundle 的 package.json releaseHistory 生成版本列表（单一事实源）
    static func releaseHistory() -> [[String: Any]] {
        guard let url = Bundle.main.url(forResource: "package", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let history = object["releaseHistory"] as? [[String: Any]] else { return [] }
        return history.compactMap { entry in
            guard let version = entry["version"] as? String else { return nil }
            let changes = (entry["changes"] as? [String]) ?? []
            let date = (entry["date"] as? String) ?? "1970-01-01"
            return [
                "version": version,
                "released_at": "\(date)T00:00:00Z",
                "summary": changes.first ?? "Release \(version)",
                "notes": changes.joined(separator: "\n"),
            ]
        }
    }

    // MARK: - semver helpers

    static func parseSemver(_ string: String) -> [Int]? {
        let parts = string.split(separator: ".")
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }

    static func semverCompare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<3 where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return 0
    }
}
