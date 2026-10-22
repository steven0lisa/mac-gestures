import Foundation

/// 一次识别触发 / 手动测试的执行记录
struct GestureEvent: Codable {
    var id: String
    var timestamp: String        // RFC 3339 UTC
    var source: String           // "recognition" | "test"
    var gestureId: String        // snake_case id，"none" 表示未命中手势
    var gestureName: String
    var icon: String
    var scriptType: String
    var exitCode: Int32?
    var timedOut: Bool
    var stdout: String
    var stderr: String
    var launchError: String?
    var durationMs: Double

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, source
        case gestureId = "gesture_id"
        case gestureName = "gesture_name"
        case icon
        case scriptType = "script_type"
        case exitCode = "exit_code"
        case timedOut
        case stdout, stderr
        case launchError = "launch_error"
        case durationMs = "duration_ms"
    }
}

/// 内存环形事件日志（最近 200 条，不落盘）
final class EventLog {
    static let capacity = 200
    private let queue = DispatchQueue(label: "com.macgestures.events")
    private var events: [GestureEvent] = []

    var count: Int { queue.sync { events.count } }

    func append(_ event: GestureEvent) {
        queue.sync {
            events.append(event)
            if events.count > Self.capacity {
                events.removeFirst(events.count - Self.capacity)
            }
        }
    }

    /// newest first 分页
    func slice(offset: Int, limit: Int) -> (items: [GestureEvent], total: Int) {
        queue.sync {
            let total = events.count
            let start = max(total - offset - limit, 0)
            let end = total - offset
            guard start < end else { return ([], total) }
            return (Array(events[start..<end]).reversed(), total)
        }
    }

    /// 全部事件，newest first
    func all() -> [GestureEvent] {
        queue.sync { events.reversed() }
    }

    func lastGestureEvent() -> GestureEvent? {
        queue.sync { events.reversed().first { $0.source == "recognition" } }
    }
}
