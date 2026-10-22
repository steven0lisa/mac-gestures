# MacGestures

macOS 菜单栏应用：**摄像头识别手部手势 → 运行对应的 AppleScript / Shell 脚本**。
纯 Swift 实现（Apple Vision 框架，无 Python、无第三方依赖、无外部模型下载），识别全程在本机神经网络引擎完成，不联网、不上传画面。

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black) [![Release](https://img.shields.io/github/v/release/steven0lisa/mac-gestures)](../../releases)

## 功能

- **8 种内置手势**，每种可单独绑定脚本、启停、设冷却时间
- **菜单栏常驻**：托盘实时闪现当前识别到的手势；菜单提供 开启/暂停识别、设置、退出
- **本地 HTTP 接口**（[http-cli-for-agent](https://github.com/steven0lisa/http-cli-for-agent) v1.0.0 协议）：`?help=1` 渐进式自描述命令树，AI Agent 无需文档即可探索并完成全部配置
- **属主人脸门控**（可选）：录入本人人脸后，只有「你」的手势才触发，其他人的手势被忽略
- 设置窗口：手势列表（带示意图标）+ 脚本编辑器 + 测试运行 + Agent 接口说明页 + 通用设置

| 图标 | 手势 id | 动作要领 |
|---|---|---|
| 👌 | `ok` | 拇指与食指圈成 O，其余三指张开 |
| ✌️ | `victory` | 食指与中指张开伸出，其余收拢 |
| 👍 | `thumbs_up` | 竖大拇指，其余四指握拳，手背朝摄像头 |
| 👎 | `thumbs_down` | 大拇指向下，其余四指握拳 |
| ✊ | `fist` | 四指握拳 |
| 🖐️ | `open_palm` | 五指全部张开，掌心朝摄像头 |
| ☝️ | `index_point` | 只伸出食指 |
| 🤙 | `call_me` | 拇指与小指伸出，其余收拢 |

## 安装

从 [Releases](../../releases) 下载 DMG，拖入 Applications。
ad-hoc 签名，首次打开如果被 Gatekeeper 拦截：**右键 → 打开**。

## 权限说明

| 权限 | 用途 | 授权入口 |
|---|---|---|
| 摄像头 | 手势识别（必需） | 首次开启识别时系统弹窗，或 系统设置 → 隐私与安全性 → 摄像头 |
| 辅助功能 | 仅当脚本使用 `keystroke` 模拟键盘输入时需要 | 系统设置 → 隐私与安全性 → 辅助功能 |

## 给 Agent 的接口（HTTP CLI）

应用启动后监听 `http://127.0.0.1:8741/cli`（仅回环地址，仅本机进程可达；端口可在设置中修改）。
协议遵循 [http-cli-for-agent v1.0.0](https://github.com/steven0lisa/http-cli-for-agent)：统一信封、渐进式 `?help=1`、`fields=` 投影、标准错误码、`version` 版本面。设置窗口的「Agent 接口」标签页内含完整说明与可复制命令。

```bash
BASE=http://127.0.0.1:8741/cli

curl -s "$BASE?help=1"                    # 根帮助：列出全部顶层命令
curl -s "$BASE/gestures?help=1"           # gestures 组下的子命令
curl -s "$BASE/gestures/update?help=1&detail=1"   # update 参数 schema + 示例

# 把 OK 手势绑定为「弹通知」并启用
curl -s -X POST "$BASE/gestures/update" -H 'Content-Type: application/json' \
  -d '{"id":"ok","enabled":true,"script_type":"applescript","script":"display notification \"OK 触发\" with title \"MacGestures\"","cooldown":3}'

curl -s "$BASE/status"                    # 识别状态 / 相机帧计数 / 最近触发
curl -s "$BASE/events?limit=5"            # 最近触发与测试记录（分页 + fields 投影）
curl -s -X POST "$BASE/recognition/start" # 开启识别（未授权摄像头会触发系统弹窗）
curl -s -X POST "$BASE/recognition/stop"  # 暂停识别（摄像头灯熄灭）
curl -s -X POST "$BASE/recognition/test" -H 'Content-Type: application/json' -d '{"id":"ok"}'  # 手动跑一次脚本

# 属主人脸门控
curl -s "$BASE/owner/status"              # 录入/门控/阈值/实时距离
curl -s -X POST "$BASE/owner/enroll" -H 'Content-Type: application/json' -d '{"gate_enabled":true}'  # 需正对摄像头

curl -s "$BASE/version/current"           # 实现版本 + 协议版本
```

命令一览：`status`、`gestures/list|get|update`、`recognition/start|stop|test`、`events`、`owner/status|enroll|update|delete`、`version/current|releases`。

### 安全模型（auth duty of care）

- **传输**：仅绑定 `127.0.0.1`，无 TLS（本地回环豁免）；凭据只经 Header 传递
- **默认无凭据**：本机任意进程可调用；如需加固，在 `config.json` 设 `api_token`，之后所有请求须带 `Authorization: Bearer <token>`（错误时 401）
- 脚本以当前用户权限执行——接口等价于本机 RCE，请不要把他人的 token 泄露给不受信的 Agent

## 从源码构建

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project MacGestures.xcodeproj -scheme MacGestures -configuration Release build
# 产物: build/Build/Products/Release/MacGestures.app
```

开发自测：

```bash
MacGestures --selftest-classifier          # 几何分类器断言（9 例）
MacGestures --selftest-image a.png emoji:👌   # 图片走完整 Vision→分类管线
```

## 发版（GitHub Release 流水线）

```bash
./scripts/bump-version.sh minor            # VERSION / package.json / project.yml 三处同步
# 在 package.json 的 releaseHistory 顶部补一条英文 changes
git add <files> && git commit && git tag vX.Y.Z
git push origin main --tags                # tag 触发 Actions：构建 → ad-hoc 签名 → DMG → Release
```

推送前敏感扫描：`./scripts/check-sensitive.sh`（公司/雇主词走本地清单，不入库）。

## 隐私

- 画面仅在内存中逐帧处理，**不保存、不上传**；唯一落盘的是你主动录入时裁剪的基准人脸小图（`~/Library/Application Support/MacGestures/owner-face.jpg`）
- 手势判定为关键点几何规则（Vision 手部 21 关键点 + 距离/方向比值），人脸比对为 Vision 特征打印距离——全部设备端计算

## License

MIT
