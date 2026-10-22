import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 应用模型（设置窗口的数据源）

enum SettingsTab: Hashable {
    case gestures, owner, agent, general
}

final class AppModel: ObservableObject {
    let context: AppContext
    @Published var selectedGesture: GestureKind = .ok
    @Published var selectedTab: SettingsTab = .gestures
    @Published var revision = 0            // 配置变更计数，驱动视图刷新
    @Published var ownerInfo: [String: Any] = [:]
    @Published var recognitionRunning = false

    var onServerRestart: ((UInt16) -> Void)?

    init(context: AppContext) {
        self.context = context
        refreshOwnerInfo()
    }

    func gestureConfig(_ kind: GestureKind) -> GestureConfig {
        context.config.gestureConfig(kind)
    }

    func updateGesture(_ kind: GestureKind, _ mutate: (inout GestureConfig) -> Void) {
        context.config.updateGesture(kind, mutate)
        revision += 1
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        context.config.updateSettings(mutate)
        revision += 1
    }

    var effectivePort: UInt16 { context.effectivePort }
    var baseURL: String { "http://127.0.0.1:\(context.effectivePort)/cli" }

    var configPathLabel: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGestures/config.json").path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func revealConfig() {
        NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGestures", isDirectory: true))
    }

    func refreshOwnerInfo() {
        ownerInfo = MacGesturesAPI.ownerDict(context)
    }

    func startRecognition(_ completion: @escaping (Result<Void, StringError>) -> Void) {
        context.startRecognition { [weak self] result in
            DispatchQueue.main.async {
                self?.recognitionRunning = (try? result.get()) != nil
                completion(result)
            }
        }
    }
}

// MARK: - 根视图（Tab）

struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GestureSettingsView(model: model)
                .tabItem { Label("手势", systemImage: "hand.raised") }
                .tag(SettingsTab.gestures)
            OwnerGateView(model: model)
                .tabItem { Label("属主", systemImage: "faceid") }
                .tag(SettingsTab.owner)
            AgentGuideView(model: model)
                .tabItem { Label("Agent 接口", systemImage: "curlybraces.square") }
                .tag(SettingsTab.agent)
            GeneralSettingsView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(minWidth: 820, minHeight: 560)
        .padding(8)
    }
}

// MARK: - 手势配置页

struct GestureSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // 左：手势列表
            List(GestureKind.allCases, selection: Binding(
                get: { model.selectedGesture },
                set: { model.selectedGesture = $0 ?? .ok })) { kind in
                GestureRow(model: model, kind: kind)
            }
            .listStyle(.sidebar)
            .frame(width: 300)

            Divider()

            // 右：详情编辑
            GestureDetailView(model: model, kind: model.selectedGesture)
                .id(model.selectedGesture)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct GestureRow: View {
    @ObservedObject var model: AppModel
    let kind: GestureKind

    var body: some View {
        HStack(spacing: 10) {
            Text(kind.icon).font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.name).fontWeight(.medium)
                    if model.gestureConfig(kind).enabled {
                        Text("已启用")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(kind.howTo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedGesture = kind }
    }
}

struct GestureDetailView: View {
    @ObservedObject var model: AppModel
    let kind: GestureKind

    @State private var enabled = false
    @State private var scriptType: ScriptType = .applescript
    @State private var script = ""
    @State private var cooldown: Double = 3
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Text(kind.icon).font(.system(size: 44))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(kind.name) (\(kind.rawValue))").font(.title3).fontWeight(.semibold)
                    Text(kind.howTo).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { newValue in
                        model.updateGesture(kind) { $0.enabled = newValue }
                    }
            }

            Divider()

            Picker("脚本类型", selection: $scriptType) {
                ForEach(ScriptType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240, alignment: .leading)
            .onChange(of: scriptType) { newValue in
                model.updateGesture(kind) { $0.scriptType = newValue }
            }

            Text(scriptType == .applescript
                 ? "AppleScript 将通过 osascript 执行（多行脚本直接粘贴）。示例：display notification \"OK 手势触发\""
                 : "Shell 脚本将通过 /bin/zsh -c 执行。示例：open -a 'Music'")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: script) { newValue in
                    model.updateGesture(kind) { $0.script = newValue }
                }

            HStack {
                Stepper(value: $cooldown, in: 1...60, step: 0.5) {
                    Text("冷却时间：\(String(format: "%.1f", cooldown)) 秒（触发后间隔内不重复触发）")
                        .font(.callout)
                }
                .onChange(of: cooldown) { newValue in
                    model.updateGesture(kind) { $0.cooldown = newValue }
                }
                Spacer()
                Button("测试运行") { runTest() }
                    .disabled(script.isEmpty)
            }

            if let testResult = testResult {
                ScrollView {
                    Text(testResult)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let config = model.gestureConfig(kind)
        enabled = config.enabled
        scriptType = config.scriptType
        script = config.script
        cooldown = config.cooldown
        testResult = nil
    }

    private func runTest() {
        let started = Date()
        ScriptRunner.shared.run(scriptType: scriptType, script: script) { result in
            let event = GestureEngine.makeEvent(kind: kind, source: "test", at: started,
                                                scriptType: scriptType, result: result)
            model.context.events.append(event)
            DispatchQueue.main.async {
                var lines: [String] = []
                if let error = result.launchError { lines.append("启动失败: \(error)") }
                lines.append("exit=\(result.exitCode.map(String.init) ?? "?") \(result.timedOut ? "(超时)" : "") 耗时 \(String(format: "%.0f", result.durationMs))ms")
                if !result.stdout.isEmpty { lines.append("stdout: \(result.stdout)") }
                if !result.stderr.isEmpty { lines.append("stderr: \(result.stderr)") }
                testResult = lines.joined(separator: "\n")
            }
        }
    }
}

// MARK: - 属主人脸页

struct OwnerGateView: View {
    @ObservedObject var model: AppModel
    @State private var message: String?
    @State private var enrolling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("属主人脸门控").font(.title2).fontWeight(.semibold)
            Text("录入本人人脸后，只有画面中识别到「你」的手势才会触发脚本；其他人的手势会被忽略。"
                 + "人脸特征由系统 Vision 框架在本机计算，基准照片只保存在本机，不会上传。")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    let enrolled = model.ownerInfo["enrolled"] as? Bool ?? false
                    Toggle("仅本人的手势生效（未录入人脸时此开关不可用）", isOn: Binding(
                        get: { model.ownerInfo["gate_enabled"] as? Bool ?? false },
                        set: { newValue in
                            model.updateSettings { $0.ownerGateEnabled = newValue }
                            model.refreshOwnerInfo()
                        }))
                        .toggleStyle(.switch)
                        .disabled(!enrolled)

                    HStack {
                        Button(enrolled ? "重新录入人脸" : "录入人脸") { enroll() }
                            .disabled(enrolling)
                        if enrolled {
                            Button("删除录入", role: .destructive) {
                                model.context.faceGate.deleteEnrollment()
                                model.updateSettings { $0.ownerGateEnabled = false }
                                model.refreshOwnerInfo()
                                message = "已删除人脸录入"
                            }
                        }
                        if enrolling { ProgressView().controlSize(.small) }
                    }

                    if enrolled {
                        if let enrolledAt = model.ownerInfo["enrolled_at"] as? String {
                            Text("录入时间：\(enrolledAt)").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            let threshold = model.ownerInfo["threshold"] as? Double ?? 12
                            Text("匹配阈值 \(String(format: "%.0f", threshold))")
                                .font(.callout)
                                .frame(width: 130, alignment: .leading)
                            Slider(value: Binding(
                                get: { threshold },
                                set: { newValue in
                                    model.updateSettings { $0.faceMatchMaxDistance = newValue }
                                    model.refreshOwnerInfo()
                                }), in: 2...40, step: 1)
                            Text(model.ownerInfo["last_distance"].map { "实时距离 \(String(format: "%.1f", $0 as? Double ?? 0))" } ?? "实时距离 —")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .trailing)
                        }
                        Text("阈值越低越严格。对着摄像头比手势时观察「实时距离」，取正常值上限再留少量余量即可。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            if let message = message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(24)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.refreshOwnerInfo()
        }
    }

    private func enroll() {
        enrolling = true
        message = nil
        let finish: (Result<Void, StringError>) -> Void = { result in
            DispatchQueue.main.async {
                enrolling = false
                switch result {
                case .success: message = "人脸录入成功，门控已开启"
                case .failure(let error): message = "录入失败：\(error.message)"
                }
                model.refreshOwnerInfo()
            }
        }
        let capture: () -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let buffer = model.context.camera.latestPixelBuffer else {
                    finish(.failure(StringError(message: "取不到摄像头画面")))
                    return
                }
                do {
                    _ = try model.context.faceGate.enroll(pixelBuffer: buffer)
                    model.updateSettings { $0.ownerGateEnabled = true }
                    finish(.success(()))
                } catch {
                    finish(.failure(StringError(message: error.localizedDescription)))
                }
            }
        }
        if model.context.camera.isRunning {
            capture()
        } else {
            model.startRecognition { result in
                switch result {
                case .success: capture()
                case .failure(let error): finish(.failure(error))
                }
            }
        }
    }
}

// MARK: - Agent 接口说明页

struct AgentGuideView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("给 Agent 的接口说明").font(.title2).fontWeight(.semibold)

                Text("本应用只暴露**一个** HTTP CLI 入口，遵循 **http-cli-for-agent v1.0.0** 协议。"
                     + "接口是自描述的：把下面的 Base URL 交给 Agent，它从根帮助开始逐级探索，就能发现全部命令、参数和示例，无需任何额外文档。"
                     + "接口只监听 127.0.0.1，仅本机进程可达。")
                    .font(.callout)

                codeBlock(title: "接口地址（唯一的入口，把这个交给 Agent 即可）", code: model.baseURL, copyLabel: "复制 Base URL")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent 的使用方法（从接口自身逐步获取）").font(.headline)
                    bullet("第 1 步：GET {base}?help=1 — 根帮助列出全部顶层命令（subcommands）。")
                    bullet("第 2 步：对感兴趣的命令逐级请求 ?help=1，得到该命令的方法、参数 schema；加 &detail=1 展开长描述与示例。")
                    bullet("第 3 步：按帮助声明的方法与参数执行；出错时 error.hint 会指出下一步该怎么发。")
                    bullet("可选：?fields=id,name 只取需要的字段省 token；config.json 设置了 api_token 时，请求需带 Header：Authorization: Bearer <token>。")
                }

                codeBlock(title: "起点：读取根帮助（之后的一切都从它的返回里发现）", code: """
                curl -s "\(model.baseURL)?help=1"
                """, copyLabel: "复制起点命令")

                Text("触发打字类 AppleScript（keystroke）需在 系统设置 → 隐私与安全性 → 辅助功能 中允许 MacGestures。")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("在浏览器打开接口") {
                        if let url = URL(string: model.baseURL + "?help=1") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("打开落地页") {
                        if let url = URL(string: "http://127.0.0.1:\(model.effectivePort)/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(title: String, code: String, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copyLabel) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .controlSize(.small)
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).font(.callout)
        }
    }
}

// MARK: - 通用设置页

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var portText: String = ""
    @State private var portMessage: String?
    @State private var loginEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("通用设置").font(.title2).fontWeight(.semibold)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("HTTP 接口端口").frame(width: 150, alignment: .leading)
                        TextField("8741", text: $portText)
                            .frame(width: 90)
                            .onSubmit(applyPort)
                        Button("应用") { applyPort() }
                        if let portMessage = portMessage {
                            Text(portMessage).font(.caption).foregroundStyle(portMessage.contains("✓") ? .green : .red)
                        }
                    }
                    Text("当前生效：\(model.baseURL)（仅监听 127.0.0.1）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录时自动启动", isOn: $loginEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: loginEnabled) { newValue in
                            setLoginItem(newValue)
                        }
                    Toggle("启动时自动开启识别（摄像头未授权时保持暂停）", isOn: Binding(
                        get: { model.context.config.currentSettings.launchRecognitionOnStart },
                        set: { newValue in model.updateSettings { $0.launchRecognitionOnStart = newValue } }))
                        .toggleStyle(.switch)

                    Stepper(value: Binding(
                        get: { model.context.config.currentSettings.stabilityFrames },
                        set: { newValue in model.updateSettings { $0.stabilityFrames = newValue } }), in: 1...10) {
                        Text("手势确认帧数：\(model.context.config.currentSettings.stabilityFrames)（连续 N 帧同一手势才触发，越大越稳）")
                            .font(.callout)
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("API Token（可选）").frame(width: 150, alignment: .leading)
                        SecureField("留空 = 不校验", text: Binding(
                            get: { model.context.config.currentSettings.apiToken },
                            set: { newValue in
                                model.updateSettings { $0.apiToken = newValue }
                                model.context.router?.apiToken = newValue
                            }))
                            .frame(width: 260)
                    }
                    Text("设置后，HTTP 接口要求所有请求携带 Authorization: Bearer <token>")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            HStack {
                Text("版本 \(MacGesturesAPI.serverVersion)　配置文件：")
                Button(model.configPathLabel) { model.revealConfig() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .onAppear {
            portText = String(model.context.config.currentSettings.port)
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func applyPort() {
        guard let port = Int(portText), (1024...65535).contains(port) else {
            portMessage = "端口需在 1024-65535 之间"
            return
        }
        model.updateSettings { $0.port = port }
        model.onServerRestart?(UInt16(port))
        portMessage = "✓ 已应用，当前端口 \(model.effectivePort)"
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            portMessage = "登录项设置失败：\(error.localizedDescription)"
        }
    }
}
