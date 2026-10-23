# MacGestures — 项目说明（Agent 协作约定）

macOS 菜单栏应用：摄像头手部手势 → AppleScript/Shell 脚本；本地 HTTP CLI（http-cli-for-agent v1.0.0）供 Agent 配置。纯 Swift（Vision + AVFoundation + Network/POSIX），无第三方 Swift 依赖。

## 结构

```
Sources/
├── App/       main.swift（含 --selftest-* 入口）、AppDelegate（装配/HTTP 路由/落地页）、Selftest.swift
├── Core/      Gesture.swift(模型/配置) GestureClassifier.swift(几何分类) CameraController.swift
│              GestureEngine.swift(稳定帧/冷却/触发) ScriptRunner.swift ConfigStore.swift EventLog.swift
│              FaceGate.swift(属主人脸) PresenceDimmer.swift(离开变暗) PowerMonitor.swift(电源监控)
├── Server/    HTTPServer.swift(POSIX 回环 HTTP/1.1) CLIRouter.swift(协议引擎) MacGesturesAPI.swift(命令树) AppContext.swift
└── UI/        StatusBarController.swift SettingsWindowController.swift SettingsViews.swift(四个 Tab)
Resources/     Assets.xcassets（图标由 scripts/generate-icon.swift 生成）
scripts/       bump-version.sh / create-dmg.sh / check-sensitive.sh（来自 general-staff GS-SOL-004 模板）
```

## 构建

```bash
xcodegen generate     # 源码文件增删后必须重新生成（*.xcodeproj 不入库）
xcodebuild -project MacGestures.xcodeproj -scheme MacGestures -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/MacGestures.app
```

- 部署目标 macOS 15.0（新版 Vision Swift API 需要）；SWIFT_VERSION 5.0 语言模式
- 自测：`MacGestures --selftest-classifier`（几何断言 9 例，须全 PASS）、`--selftest-image <path|emoji:👌>`
- 协议一致性：`python3 ~/work/personal/http-cli-for-agent/conformance/run.py --base http://127.0.0.1:8741/cli` 须 0 failed

## 已知坑（实测踩过）

- **NWListener 的 `requiredLocalEndpoint` 对 listener 不生效**（state ready 但实际不绑定端口）——HTTP 服务必须用 POSIX socket bind 127.0.0.1（现实现）
- `CLICommand` 的 `method` 是继承自 CLINode 的存储属性（在 super.init 后赋值）；别改成子类重新声明（计算属性不能被存储属性覆盖，会编译错）
- 老版 VN API：`handler.perform([request])` 返回 Void，结果在 `request.results`；特征距离用 `computeDistance(&out, to:)`（Float）。**全项目统一用 VN-前缀同步 API**——新版 Swift Vision API（`DetectHumanHandPoseRequest` 等）的 `joint(for:)` 在 Xcode 16 的 macOS 15.5 SDK 里不存在，CI（macos-15 runner）会编译失败（本机 Xcode 26 能过，别被本地构建骗了）
- **macOS 26 (Tahoe) 移除了 CoreDisplay 私有框架**（文件系统与 dyld cache 都没有），`CoreDisplay_Display_SetUserBrightness` 亮度控制不可用、合成 NX 亮度键也失效（BetterDisplay 同样受影响）——PresenceDimmer 在 Tahoe 上 supported=false 如实上报；屏幕调暗功能只在 macOS 15 及以下可用
- IOKit IOPS（`IOKit.ps`）读电源状态正常可用（PowerMonitor 用它做电池暂停）
- `[GestureKind: GestureConfig]`（enum key）Codable 会编成数组，持久化结构体里要转 `[String: GestureConfig]`
- 从终端直接跑 bundle 内二进制，Bash 工具会话结束会连带杀进程；用 `open xxx.app` 交给 launchd 托管

## HTTP CLI maintenance

- Protocol: HTTP CLI Protocol v1.0.0 — spec at
  `~/work/personal/http-cli-for-agent/docs/specification/v1.0.0/http-cli.md` (source of truth).
- Command tree registry: `Sources/Server/MacGesturesAPI.swift`（`buildRouter`，全部节点在此注册）
- Help is generated from the dispatch registry — never hand-edit help text.
- **When adding or changing an API endpoint or service method, register the corresponding command node in the same change.** A PR that adds an endpoint without its command node (or an explicit exclusion note) is incomplete.
- CLI commands are thin adapters: registration + parameter mapping only, delegating to the existing service layer (`AppContext` 的 config/engine/camera/faceGate/events). New business logic inside a CLI handler is a review flag.
- Auth model: 默认无凭据 + 仅绑定 127.0.0.1；可选 `config.json` 的 `api_token`（Bearer，永久有效，改文件即换发/吊销）。八项 duty-of-care 的公开说明在根帮助 `authentication` 对象与 README「安全模型」一节。
- Conformance gate: `python3 ~/work/personal/http-cli-for-agent/conformance/run.py --base http://127.0.0.1:8741/cli` must pass (0 failed) before release.
- Version surface: `version/current` + `version/releases` are fed from the bundled `package.json` `releaseHistory`（project.yml 把根目录 package.json 拷进 Resources）；keep them in sync with root help.

## 版本管理

- 三处版本号（VERSION / package.json / project.yml）用 `./scripts/bump-version.sh [major|minor|patch]` 同步，别手改
- Release Notes = package.json `releaseHistory` 顶部条目（英文，version 必须与 VERSION 一致）
- 发版 = push + tag（`.github/workflows/release.yml`：敏感扫描 → xcodegen → xcodebuild Release → ad-hoc 签名 → create-dmg.sh → gh-release）
