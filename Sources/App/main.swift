import AppKit

// 自测模式：运行后直接退出（开发/CI 用）
let selftestExit = Selftest.run()
if selftestExit >= 0 {
    exit(Int32(selftestExit))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
