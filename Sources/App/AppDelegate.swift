import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigStore!
    private var events: EventLog!
    private var engine: GestureEngine!
    private var camera: CameraController!
    private var faceGate: FaceGate!
    private var presenceDimmer: PresenceDimmer?
    private var context: AppContext!
    private var server: HTTPServer!
    private var statusBar: StatusBarController!
    private var settingsController: SettingsWindowController?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigStore.shared
        events = EventLog()
        camera = CameraController()
        engine = GestureEngine(config: config, events: events)
        faceGate = FaceGate(config: config)
        let dimmer = PresenceDimmer(config: config)
        presenceDimmer = dimmer
        context = AppContext(config: config, events: events, engine: engine,
                             camera: camera, faceGate: faceGate, presenceDimmer: dimmer)
        AppContext.shared = context

        // 引擎回调 → 托盘
        engine.onGestureFired = { [weak self] kind in
            self?.statusBar.flashGesture(kind)
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            self?.statusBar.updateLastEvent("最近识别：\(kind.icon) \(kind.name) · \(time)")
        }

        // HTTP CLI
        let router = MacGesturesAPI.buildRouter(context: context)
        context.router = router
        startServer(preferredPort: UInt16(config.currentSettings.port))
        context.onServerRestart = { [weak self] port in
            self?.restartServer(port: port)
        }

        // 托盘
        statusBar = StatusBarController()
        statusBar.onStartPause = { [weak self] in self?.toggleRecognitionFromMenu() }
        statusBar.onOpenSettings = { [weak self] in self?.openSettings(tab: nil) }
        statusBar.onOpenAgentTab = { [weak self] in self?.openSettings(tab: .agent) }
        statusBar.onOpenWebDocs = { [weak self] in self?.openWebDocs() }
        statusBar.setRecognitionRunning(false)
        refreshCameraWarning()
        context.onAutoPauseChange = { [weak self] message in
            self?.statusBar.setCameraWarning(message)
        }

        // 电源监控（电池自动暂停 / 插电恢复）
        context.startPowerMonitor()

        // 启动即恢复识别（仅在摄像头已授权、且没有因电池保持暂停时；首次授权交给用户主动开启）
        if config.currentSettings.launchRecognitionOnStart,
           CameraController.authorizationStatus == .authorized,
           !(context.powerSource == "battery" && config.currentSettings.pauseOnBattery) {
            startRecognition()
        }

        NSLog("MacGestures 启动完成：HTTP CLI http://127.0.0.1:\(context.effectivePort)/cli")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前务必把屏幕亮度恢复回去
        presenceDimmer?.ensureRestored()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - HTTP 服务

    private func startServer(preferredPort: UInt16) {
        let handler: HTTPServer.Handler = { [weak self] request in
            self?.route(request) ?? HTTPResponse.json(500, ["error": ["code": "internal_error", "message": "not ready"]])
        }
        // 配置端口被占用则顺延尝试 10 个
        for offset in 0...10 {
            let port = UInt16(Int(preferredPort) + offset)
            let candidate = HTTPServer(port: port, handler: handler)
            do {
                try candidate.start()
                server = candidate
                context.effectivePort = port
                context.router?.port = port
                return
            } catch {
                continue
            }
        }
        NSLog("MacGestures: HTTP 服务启动失败（端口 \(preferredPort)+10 均不可用）")
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        if request.path == "/" {
            return LandingPage.html(context: context)
        }
        if request.path == "/.well-known/http-cli" {
            return .json(200, [
                "base_url": "http://127.0.0.1:\(context.effectivePort)/cli",
                "protocol_version": "1.0.0",
            ])
        }
        if request.path == "/cli" || request.path.hasPrefix("/cli/") {
            return context.router.handle(request: request)
        }
        return .json(404, ["error": [
            "code": "unknown_command",
            "message": "unknown path \"\(request.path)\"",
            "hint": "GET http://127.0.0.1:\(context.effectivePort)/cli?help=1",
        ]])
    }

    // MARK: - 动作

    private func toggleRecognitionFromMenu() {
        if camera.isRunning {
            context.stopRecognition()
            statusBar.setRecognitionRunning(false)
        } else {
            startRecognition()
        }
    }

    private func startRecognition() {
        context.startRecognition { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    let message = error.message
                    self?.statusBar.setCameraWarning(message)
                    return
                }
                self?.statusBar.setRecognitionRunning(true)
                self?.statusBar.setCameraWarning(nil)
            }
        }
    }

    private func refreshCameraWarning() {
        switch CameraController.authorizationStatus {
        case .denied, .restricted:
            statusBar.setCameraWarning("摄像头未授权")
        default:
            statusBar.setCameraWarning(nil)
        }
    }

    private func restartServer(port: UInt16) {
        server.stop()
        startServer(preferredPort: port)
    }

    private func openSettings(tab: SettingsTab?) {
        if settingsController == nil {
            let model = AppModel(context: context)
            model.onServerRestart = { [weak self] port in
                self?.restartServer(port: port)
            }
            self.model = model
            settingsController = SettingsWindowController(model: model)
        }
        if let tab = tab {
            model?.selectedTab = tab
        }
        settingsController?.showAndActivate()
    }

    private func openWebDocs() {
        if let url = URL(string: "http://127.0.0.1:\(context.effectivePort)/cli?help=1") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 落地页（浏览器可读的状态页 + Agent 快速开始）

enum LandingPage {
    static func html(context: AppContext) -> HTTPResponse {
        let baseURL = "http://127.0.0.1:\(context.effectivePort)/cli"
        let state = context.recognitionState
        let stateText: String
        switch state {
        case "running": stateText = "识别中 ✓"
        case "unauthorized": stateText = "摄像头未授权"
        default: stateText = "已暂停"
        }

        var gestureRows = ""
        for kind in GestureKind.allCases {
            let config = context.config.gestureConfig(kind)
            let stateBadge = config.enabled ? "✅ 已启用" : "未启用"
            gestureRows += "<tr><td>\(kind.icon)</td><td><code>\(kind.rawValue)</code> \(kind.name)</td><td>\(stateBadge)</td><td>\(config.scriptType.displayName)</td></tr>\n"
        }

        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <title>MacGestures</title>
        <style>
          body { font-family: -apple-system, "PingFang SC", sans-serif; max-width: 780px; margin: 40px auto; padding: 0 20px; color: #1d1d1f; }
          h1 { font-size: 28px; } code, pre { font-family: "SF Mono", Menlo, monospace; background: #f5f5f7; border-radius: 6px; }
          pre { padding: 12px; overflow-x: auto; font-size: 13px; }
          table { border-collapse: collapse; } td, th { border-bottom: 1px solid #e5e5ea; padding: 6px 14px; text-align: left; font-size: 14px; }
          .badge { display: inline-block; background: #e8f5e9; color: #1b5e20; border-radius: 10px; padding: 2px 10px; font-size: 13px; }
          a { color: #0066cc; }
        </style></head><body>
        <h1>🖐️ MacGestures</h1>
        <p>摄像头手势 → AppleScript/Shell 脚本。识别状态：<span class="badge">\(stateText)</span>　接口：<code>\(baseURL)</code></p>
        <h2>手势配置</h2>
        <table><tr><th>图标</th><th>手势</th><th>状态</th><th>脚本类型</th></tr>
        \(gestureRows)</table>
        <h2>Agent 快速开始（http-cli-for-agent 协议）</h2>
        <pre>BASE=\(baseURL)
        curl -s "$BASE?help=1"                    # 根帮助，逐级 ?help=1 探索
        curl -s "$BASE/gestures/update?help=1"    # 查看 update 参数
        curl -s -X POST "$BASE/recognition/start" # 开启识别
        curl -s "$BASE/status"                    # 状态
        curl -s "$BASE/events?limit=5"            # 最近触发</pre>
        <p>更多：<a href="\(baseURL)?help=1">打开命令树帮助</a> ·
        <a href="\(baseURL)/version/current">版本信息</a> ·
        全程本机运行，不联网、不上传画面。</p>
        </body></html>
        """
        return .html(200, html)
    }
}
