import AppKit
import Vision

/// 开发自测（CLI）：
///   MacGestures --selftest-classifier          纯几何合成手型断言
///   MacGestures --selftest-image a.png b.jpg   图片走完整 Vision→分类管线
///   MacGestures --selftest-image emoji:👍 ...  渲染 emoji 后走完整管线
enum Selftest {
    static func run() -> Int {
        let args = CommandLine.arguments
        if args.contains("--selftest-classifier") {
            return classifierSuite() ? 0 : 1
        }
        if let index = args.firstIndex(of: "--selftest-image"), index + 1 < args.count {
            return imageSuite(Array(args[(index + 1)...])) ? 0 : 1
        }
        return -1
    }

    // MARK: - 几何断言

    static func classifierSuite() -> Bool {
        let wrist = CGPoint(x: 0.50, y: 0.08)
        let mcps = (
            index: CGPoint(x: 0.40, y: 0.30),
            middle: CGPoint(x: 0.50, y: 0.32),
            ring: CGPoint(x: 0.58, y: 0.30),
            little: CGPoint(x: 0.66, y: 0.27)
        )

        func pose(indexTipY: CGFloat, middleTipY: CGFloat, ringTipY: CGFloat, littleTipY: CGFloat,
                  thumb: (cmc: CGPoint, mp: CGPoint, ip: CGPoint, tip: CGPoint)) -> HandPoints {
            func finger(mcp: CGPoint, tipY: CGFloat) -> (pip: CGPoint, tip: CGPoint) {
                let tip = CGPoint(x: mcp.x, y: tipY)
                let pip = CGPoint(x: mcp.x, y: (mcp.y + tipY) / 2)
                return (pip, tip)
            }
            let i = finger(mcp: mcps.index, tipY: indexTipY)
            let m = finger(mcp: mcps.middle, tipY: middleTipY)
            let r = finger(mcp: mcps.ring, tipY: ringTipY)
            let l = finger(mcp: mcps.little, tipY: littleTipY)
            return HandPoints(
                wrist: wrist,
                thumbCMC: thumb.cmc, thumbMP: thumb.mp, thumbIP: thumb.ip, thumbTip: thumb.tip,
                indexMCP: mcps.index, indexPIP: i.pip, indexTip: i.tip,
                middleMCP: mcps.middle, middlePIP: m.pip, middleTip: m.tip,
                ringMCP: mcps.ring, ringPIP: r.pip, ringTip: r.tip,
                littleMCP: mcps.little, littlePIP: l.pip, littleTip: l.tip)
        }

        // 伸直 ≈ mcp.y + 0.22；收拢 ≈ mcp.y + 0.02；拇指各姿态单独给点
        let thumbUp = (cmc: CGPoint(x: 0.44, y: 0.14), mp: CGPoint(x: 0.46, y: 0.22),
                       ip: CGPoint(x: 0.47, y: 0.34), tip: CGPoint(x: 0.48, y: 0.44))
        let thumbDown = (cmc: CGPoint(x: 0.44, y: 0.20), mp: CGPoint(x: 0.46, y: 0.16),
                         ip: CGPoint(x: 0.47, y: 0.05), tip: CGPoint(x: 0.48, y: 0.00))
        let thumbTucked = (cmc: CGPoint(x: 0.44, y: 0.16), mp: CGPoint(x: 0.42, y: 0.24),
                           ip: CGPoint(x: 0.44, y: 0.28), tip: CGPoint(x: 0.46, y: 0.28))
        let thumbToIndexTip = (cmc: CGPoint(x: 0.44, y: 0.14), mp: CGPoint(x: 0.44, y: 0.28),
                               ip: CGPoint(x: 0.43, y: 0.42), tip: CGPoint(x: 0.405, y: 0.52))
        let thumbRelaxed = (cmc: CGPoint(x: 0.44, y: 0.14), mp: CGPoint(x: 0.42, y: 0.22),
                            ip: CGPoint(x: 0.43, y: 0.25), tip: CGPoint(x: 0.44, y: 0.26))
        let thumbOutSide = (cmc: CGPoint(x: 0.46, y: 0.14), mp: CGPoint(x: 0.38, y: 0.18),
                            ip: CGPoint(x: 0.33, y: 0.21), tip: CGPoint(x: 0.30, y: 0.24))
        let thumbWide = (cmc: CGPoint(x: 0.44, y: 0.14), mp: CGPoint(x: 0.38, y: 0.24),
                         ip: CGPoint(x: 0.32, y: 0.32), tip: CGPoint(x: 0.28, y: 0.40))

        let cases: [(expect: GestureKind?, name: String, pose: HandPoints)] = [
            (.ok, "ok",
             pose(indexTipY: 0.52, middleTipY: 0.54, ringTipY: 0.52, littleTipY: 0.49, thumb: thumbToIndexTip)),
            (.victory, "victory",
             pose(indexTipY: 0.52, middleTipY: 0.56, ringTipY: 0.32, littleTipY: 0.29, thumb: thumbRelaxed)),
            (.thumbsUp, "thumbs_up",
             pose(indexTipY: 0.32, middleTipY: 0.34, ringTipY: 0.32, littleTipY: 0.29, thumb: thumbUp)),
            (.thumbsDown, "thumbs_down",
             pose(indexTipY: 0.32, middleTipY: 0.34, ringTipY: 0.32, littleTipY: 0.29, thumb: thumbDown)),
            (.callMe, "call_me",
             pose(indexTipY: 0.32, middleTipY: 0.34, ringTipY: 0.32, littleTipY: 0.50, thumb: thumbOutSide)),
            (.fist, "fist",
             pose(indexTipY: 0.32, middleTipY: 0.34, ringTipY: 0.32, littleTipY: 0.29, thumb: thumbTucked)),
            (.indexPoint, "index_point",
             pose(indexTipY: 0.52, middleTipY: 0.34, ringTipY: 0.32, littleTipY: 0.29, thumb: thumbRelaxed)),
            (.openPalm, "open_palm",
             pose(indexTipY: 0.52, middleTipY: 0.56, ringTipY: 0.52, littleTipY: 0.50, thumb: thumbWide)),
        ]

        var allPassed = true
        for testCase in cases {
            let (kind, debug) = GestureClassifier.classify(testCase.pose)
            let passed = kind == testCase.expect
            allPassed = allPassed && passed
            print("\(passed ? "PASS" : "FAIL")  expect=\(testCase.expect?.rawValue ?? "none") got=\(kind?.rawValue ?? "none")  [\(testCase.name)] \(debug)")
        }

        // 负例：半握（ratio 落在伸直/收拢阈值之间的模糊区）应无分类
        let half = pose(indexTipY: 0.35, middleTipY: 0.37, ringTipY: 0.35, littleTipY: 0.32, thumb: thumbRelaxed)
        let (negativeKind, negativeDebug) = GestureClassifier.classify(half)
        let negativePassed = negativeKind == nil
        allPassed = allPassed && negativePassed
        print("\(negativePassed ? "PASS" : "FAIL")  expect=none got=\(negativeKind?.rawValue ?? "none")  [half-curled negative] \(negativeDebug)")

        print(allPassed ? "classifier suite: ALL PASS" : "classifier suite: FAILED")
        return allPassed
    }

    // MARK: - 图片管线

    static func imageSuite(_ inputs: [String]) -> Bool {
        var allDetected = true
        for input in inputs {
            let cgImage: CGImage?
            if input.hasPrefix("emoji:") {
                cgImage = renderEmoji(String(input.dropFirst("emoji:".count)))
            } else {
                guard let image = NSImage(contentsOfFile: input) else {
                    print("SKIP   \(input): 无法读取")
                    continue
                }
                cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            guard let image = cgImage else {
                print("SKIP   \(input): 无法获取 CGImage")
                continue
            }
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                guard let observation = (request.results ?? []).first as? VNHumanHandPoseObservation,
                      let points = HandPoints(vnObservation: observation) else {
                    print("RESULT \(input): no hand detected")
                    allDetected = false
                    continue
                }
                let (kind, debug) = GestureClassifier.classify(points)
                print("RESULT \(input): gesture=\(kind?.rawValue ?? "none") [\(debug)]")
            } catch {
                print("ERROR  \(input): \(error)")
                allDetected = false
            }
        }
        return allDetected
    }

    static func renderEmoji(_ emoji: String, size: CGFloat = 512) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.75)]
        let string = NSAttributedString(string: emoji, attributes: attributes)
        let textSize = string.size()
        string.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
