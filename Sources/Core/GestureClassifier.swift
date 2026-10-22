import Foundation
import Vision

// MARK: - 手部关键点（归一化坐标，原点在左下，y 轴向上）

/// 21 个手部关节点的平面坐标。与 Vision 解耦，便于纯几何单元测试。
struct HandPoints {
    var wrist: CGPoint

    var thumbCMC: CGPoint
    var thumbMP: CGPoint
    var thumbIP: CGPoint
    var thumbTip: CGPoint

    var indexMCP: CGPoint
    var indexPIP: CGPoint
    var indexTip: CGPoint

    var middleMCP: CGPoint
    var middlePIP: CGPoint
    var middleTip: CGPoint

    var ringMCP: CGPoint
    var ringPIP: CGPoint
    var ringTip: CGPoint

    var littleMCP: CGPoint
    var littlePIP: CGPoint
    var littleTip: CGPoint

    /// 手掌参考尺寸：手腕到中指根的距离
    var handSize: CGFloat { hypot(middleMCP.x - wrist.x, middleMCP.y - wrist.y) }

    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// 手指伸展度：tip/手腕 距离与 mcp/手腕 距离的比值（>1.30 伸直，<1.15 收拢）
    func ratio(tip: CGPoint, mcp: CGPoint) -> CGFloat {
        let mcpDist = dist(mcp, wrist)
        guard mcpDist > 1e-6 else { return 0 }
        return dist(tip, wrist) / mcpDist
    }

    func isExtended(tip: CGPoint, pip: CGPoint, mcp: CGPoint) -> Bool { ratio(tip: tip, mcp: mcp) > 1.30 }
    func isCurled(tip: CGPoint, pip: CGPoint, mcp: CGPoint) -> Bool { ratio(tip: tip, mcp: mcp) < 1.15 }

    var indexExtended: Bool { isExtended(tip: indexTip, pip: indexPIP, mcp: indexMCP) }
    var middleExtended: Bool { isExtended(tip: middleTip, pip: middlePIP, mcp: middleMCP) }
    var ringExtended: Bool { isExtended(tip: ringTip, pip: ringPIP, mcp: ringMCP) }
    var littleExtended: Bool { isExtended(tip: littleTip, pip: littlePIP, mcp: littleMCP) }

    var indexCurled: Bool { isCurled(tip: indexTip, pip: indexPIP, mcp: indexMCP) }
    var middleCurled: Bool { isCurled(tip: middleTip, pip: middlePIP, mcp: middleMCP) }
    var ringCurled: Bool { isCurled(tip: ringTip, pip: ringPIP, mcp: ringMCP) }
    var littleCurled: Bool { isCurled(tip: littleTip, pip: littlePIP, mcp: littleMCP) }

    /// 拇指-食指捏合距离（相对手掌尺寸）
    var pinchDistance: CGFloat { dist(thumbTip, indexTip) / max(handSize, 1e-6) }
    /// 拇指张开程度：拇指尖到小指根的距离（相对手掌尺寸）
    var thumbSpread: CGFloat { dist(thumbTip, littleMCP) / max(handSize, 1e-6) }
}

// MARK: - 几何分类器

enum GestureClassifier {
    /// 分类结果：命中手势 + 诊断信息
    static func classify(_ p: HandPoints) -> (kind: GestureKind?, debug: String) {
        let size = p.handSize
        guard size > 0.02 else { return (nil, "hand too small") }

        let pinch = p.pinchDistance
        let fourCurled = p.indexCurled && p.middleCurled && p.ringCurled && p.littleCurled
        let fourExtended = p.indexExtended && p.middleExtended && p.ringExtended && p.littleExtended

        var debug = String(format: "size=%.3f pinch=%.2f spread=%.2f i%.1f m%.1f r%.1f l%.1f",
                           Double(size), Double(pinch), Double(p.thumbSpread),
                           Double(p.ratio(tip: p.indexTip, mcp: p.indexMCP)),
                           Double(p.ratio(tip: p.middleTip, mcp: p.middleMCP)),
                           Double(p.ratio(tip: p.ringTip, mcp: p.ringMCP)),
                           Double(p.ratio(tip: p.littleTip, mcp: p.littleMCP)))

        // 1. OK：拇指食指圈合 + 其余三指张开
        if pinch < 0.30 && p.middleExtended && p.ringExtended && p.littleExtended {
            return (.ok, debug)
        }
        // 2. Victory：食指中指伸出，无名指小指收拢
        if p.indexExtended && p.middleExtended && p.ringCurled && p.littleCurled {
            return (.victory, debug)
        }
        // 3/4. Thumbs up / down：四指握拳 + 拇指方向明显朝上/朝下
        if fourCurled {
            let thumbLen = max(p.dist(p.thumbTip, p.thumbMP), 1e-6)
            let thumbRising = (p.thumbTip.y - p.thumbMP.y) / thumbLen
            let thumbAboveKnuckles = p.thumbTip.y > p.indexMCP.y + 0.3 * size
            let thumbBelowKnuckles = p.thumbTip.y < p.indexMCP.y - 0.3 * size
            if thumbRising > 0.5 && thumbAboveKnuckles {
                return (.thumbsUp, debug)
            }
            if thumbRising < -0.5 && thumbBelowKnuckles {
                return (.thumbsDown, debug)
            }
        }
        // 5. Call me：小指 + 拇指伸出，中指/无名指收拢（食指可半伸，很多真人 shaka 食指松散）
        if p.littleExtended && p.middleCurled && p.ringCurled && pinch > 0.35 {
            return (.callMe, debug)
        }
        // 6. Fist：四指全部收拢
        if fourCurled {
            return (.fist, debug)
        }
        // 7. Point：只伸食指
        if p.indexExtended && p.middleCurled && p.ringCurled && p.littleCurled && pinch > 0.35 {
            return (.indexPoint, debug)
        }
        // 8. Open palm：五指张开（拇指明显离开掌心）
        if fourExtended && pinch > 0.40 && p.thumbSpread > 0.9 {
            return (.openPalm, debug)
        }
        return (nil, "no match: " + debug)
    }
}

// MARK: - Vision 观测结果 → HandPoints

extension HandPoints {
    /// 从 Vision 手部姿态观测构建（同步 VN API）。关节置信度不足时返回 nil（本帧放弃）。
    init?(vnObservation observation: VNHumanHandPoseObservation, minConfidence: Float = 0.3) {
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let joint = try? observation.recognizedPoint(name), joint.confidence >= minConfidence else { return nil }
            return joint.location
        }
        guard let wrist = point(.wrist),
              let thumbCMC = point(.thumbCMC), let thumbMP = point(.thumbMP),
              let thumbIP = point(.thumbIP), let thumbTip = point(.thumbTip),
              let indexMCP = point(.indexMCP), let indexPIP = point(.indexPIP), let indexTip = point(.indexTip),
              let middleMCP = point(.middleMCP), let middlePIP = point(.middlePIP), let middleTip = point(.middleTip),
              let ringMCP = point(.ringMCP), let ringPIP = point(.ringPIP), let ringTip = point(.ringTip),
              let littleMCP = point(.littleMCP), let littlePIP = point(.littlePIP), let littleTip = point(.littleTip)
        else { return nil }
        self.init(wrist: wrist,
                  thumbCMC: thumbCMC, thumbMP: thumbMP, thumbIP: thumbIP, thumbTip: thumbTip,
                  indexMCP: indexMCP, indexPIP: indexPIP, indexTip: indexTip,
                  middleMCP: middleMCP, middlePIP: middlePIP, middleTip: middleTip,
                  ringMCP: ringMCP, ringPIP: ringPIP, ringTip: ringTip,
                  littleMCP: littleMCP, littlePIP: littlePIP, littleTip: littleTip)
    }
}
