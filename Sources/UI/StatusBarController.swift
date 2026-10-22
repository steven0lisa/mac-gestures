import AppKit

/// 托盘（菜单栏）控制器：显示当前识别到的手势 + 主菜单
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var flashWorkItem: DispatchWorkItem?

    private(set) var isRunning = false
    private var lastEventLine: String?
    private var cameraWarning: String?

    var onStartPause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAgentTab: (() -> Void)?
    var onOpenWebDocs: (() -> Void)?

    private let defaultIcon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "MacGestures")

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = defaultIcon
            button.image?.isTemplate = true
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    // MARK: - 状态展示

    func setRecognitionRunning(_ running: Bool) {
        isRunning = running
    }

    func setCameraWarning(_ message: String?) {
        cameraWarning = message
    }

    /// 识别到手势：图标位置闪现对应 emoji 2.5 秒
    func flashGesture(_ kind: GestureKind) {
        guard let button = statusItem.button else { return }
        flashWorkItem?.cancel()
        button.image = nil
        button.title = kind.icon
        let work = DispatchWorkItem { [weak self] in
            guard let button = self?.statusItem.button else { return }
            button.title = ""
            button.image = self?.defaultIcon
            self?.defaultIcon?.isTemplate = true
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - 菜单（每次打开时动态构建）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let stateItem = NSMenuItem(title: isRunning ? "识别中 ✓" : "识别已暂停",
                                   action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        if let warning = cameraWarning {
            let item = NSMenuItem(title: "⚠︎ \(warning)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let line = lastEventLine {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: isRunning ? "暂停识别" : "开启识别",
                                action: #selector(toggleRecognition), keyEquivalent: "r")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let agent = NSMenuItem(title: "Agent 接口说明…", action: #selector(openAgentTab), keyEquivalent: "a")
        agent.target = self
        menu.addItem(agent)
        let docs = NSMenuItem(title: "在浏览器打开接口文档", action: #selector(openWebDocs), keyEquivalent: "")
        docs.target = self
        menu.addItem(docs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MacGestures", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func updateLastEvent(_ line: String?) {
        lastEventLine = line
    }

    @objc private func toggleRecognition() { onStartPause?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openAgentTab() { onOpenAgentTab?() }
    @objc private func openWebDocs() { onOpenWebDocs?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
