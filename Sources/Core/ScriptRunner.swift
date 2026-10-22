import Foundation

struct ScriptResult {
    var exitCode: Int32?
    var timedOut: Bool = false
    var stdout: String = ""
    var stderr: String = ""
    var durationMs: Double = 0
    var launchError: String?
}

/// AppleScript / Shell 脚本执行器。
/// - AppleScript：脚本经 stdin 喂给 osascript，规避引号转义问题
/// - Shell：/bin/zsh -c <script>
final class ScriptRunner {
    static let shared = ScriptRunner()
    private let queue = DispatchQueue(label: "com.macgestures.scripts", attributes: .concurrent)

    static func truncate(_ s: String, to maxChars: Int = 2000) -> String {
        guard s.count > maxChars else { return s }
        return String(s.prefix(maxChars)) + "…(truncated)"
    }

    func run(scriptType: ScriptType, script: String, timeout: TimeInterval = 10,
             completion: @escaping (ScriptResult) -> Void) {
        queue.async {
            completion(self.runSync(scriptType: scriptType, script: script, timeout: timeout))
        }
    }

    func runSync(scriptType: ScriptType, script: String, timeout: TimeInterval = 10) -> ScriptResult {
        let started = Date()
        var result = ScriptResult()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        do {
            switch scriptType {
            case .applescript:
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                try process.run()
                // 脚本较大时管道写满会阻塞，放到后台线程写
                let scriptData = Data(script.utf8)
                DispatchQueue.global().async {
                    stdinPipe.fileHandleForWriting.write(scriptData)
                    try? stdinPipe.fileHandleForWriting.close()
                }
            case .shell:
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", script]
                try process.run()
            }
        } catch {
            result.launchError = "无法启动 \(scriptType.displayName) 进程: \(error.localizedDescription)"
            result.durationMs = Date().timeIntervalSince(started) * 1000
            return result
        }

        // 后台先读管道（避免输出超管道缓冲时子进程写阻塞），再等待退出
        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        // 超时看门狗
        let timedOut = DispatchSemaphore(value: 0)
        let watchdog = DispatchWorkItem {
            _ = timedOut.wait(timeout: .now() + timeout)
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().async(execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        timedOut.signal()
        readGroup.wait()

        result.exitCode = process.terminationStatus
        result.timedOut = process.terminationReason == .uncaughtSignal
        result.stdout = Self.truncate(String(data: stdoutData, encoding: .utf8) ?? "")
        result.stderr = Self.truncate(String(data: stderrData, encoding: .utf8) ?? "")
        result.durationMs = Date().timeIntervalSince(started) * 1000
        return result
    }
}
