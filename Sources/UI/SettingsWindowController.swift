import AppKit
import SwiftUI

/// 设置窗口控制器（SwiftUI 内容托管）
final class SettingsWindowController: NSWindowController {
    convenience init(model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "MacGestures 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        self.init(window: window)
    }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
