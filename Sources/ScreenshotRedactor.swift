import AppKit
import CoreGraphics
import Foundation
import Vision

enum ScreenshotRedactionError: LocalizedError {
    case recognitionFailed
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .recognitionFailed: return "敏感信息检查失败，已禁止保存本页原图"
        case .renderingFailed: return "敏感信息遮挡失败，已禁止保存本页原图"
        }
    }
}

enum ScreenshotRedactor {
    struct Result {
        let image: CGImage
        let transformCount: Int
    }

    static func redact(_ image: CGImage) throws -> CGImage {
        try redactWithReceipt(image).image
    }

    static func redactWithReceipt(_ image: CGImage) throws -> Result {
        let boxes = try recognitionBoxes(in: image)
        guard !boxes.isEmpty else {
            return Result(image: image, transformCount: 0)
        }
        return Result(
            image: try render(image, covering: boxes),
            transformCount: boxes.count
        )
    }

    private static func recognitionBoxes(in image: CGImage) throws -> [CGRect] {
        // Vision can miss small text when an extra-tall stitched page is downscaled.
        // Inspect overlapping vertical tiles, then map every box back to the full image.
        let tileHeight = min(3_000, image.height)
        let step = max(1, tileHeight - 160)
        var originY = 0
        var boxes: [CGRect] = []
        while originY < image.height {
            let height = min(tileHeight, image.height - originY)
            guard let tile = image.cropping(to: CGRect(x: 0, y: originY, width: image.width, height: height)) else {
                throw ScreenshotRedactionError.recognitionFailed
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            do {
                try VNImageRequestHandler(cgImage: tile, orientation: .up).perform([request])
            } catch {
                throw ScreenshotRedactionError.recognitionFailed
            }
            guard let observations = request.results else {
                throw ScreenshotRedactionError.recognitionFailed
            }
            for observation in observations {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let localBox: CGRect?
                if containsSensitiveToken(text) {
                    localBox = expandedTokenBox(observation.boundingBox)
                } else if containsSensitiveLabel(text) {
                    localBox = labelAndValueBox(observation.boundingBox)
                } else {
                    localBox = nil
                }
                guard let localBox else { continue }
                boxes.append(CGRect(
                    x: localBox.minX,
                    y: (CGFloat(originY) + localBox.minY * CGFloat(height)) / CGFloat(image.height),
                    width: localBox.width,
                    height: localBox.height * CGFloat(height) / CGFloat(image.height)
                ))
            }
            if originY + height >= image.height { break }
            originY += step
        }
        return boxes
    }

    static func containsSensitiveToken(_ text: String) -> Bool {
        matches(#"(?i)(?:\b(?:sk[-_]|nb_|rk[-_]|pk[-_])[A-Za-z0-9_-]{6,}|bearer\s+[A-Za-z0-9._~+/-]{6,})"#, text)
    }

    static func containsSensitiveLabel(_ text: String) -> Bool {
        matches(
            #"(?i)^\s*(?:api[ _-]?key|authorization|access[ _-]?token|secret(?:[ _-]?key)?|(?:中转|访问|api[ _-]?)?密钥|(?:访问|身份)?令牌)\s*[:：]?\s*$"#,
            text
        )
    }

    static func labelAndValueBox(_ normalizedBox: CGRect) -> CGRect {
        CGRect(
            x: max(0, normalizedBox.minX - 0.006),
            y: max(0, normalizedBox.minY - 0.008),
            width: min(1, 0.992 - normalizedBox.minX),
            height: min(1, normalizedBox.height + 0.016)
        )
    }

    static func expandedTokenBox(_ normalizedBox: CGRect) -> CGRect {
        CGRect(
            x: max(0, normalizedBox.minX - 0.008),
            y: max(0, normalizedBox.minY - 0.008),
            width: min(1, normalizedBox.width + 0.016),
            height: min(1, normalizedBox.height + 0.016)
        )
    }

    private static func render(_ image: CGImage, covering normalizedBoxes: [CGRect]) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ScreenshotRedactionError.renderingFailed }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for box in normalizedBoxes {
            let pixelBox = CGRect(
                x: box.minX * CGFloat(width),
                y: box.minY * CGFloat(height),
                width: box.width * CGFloat(width),
                height: box.height * CGFloat(height)
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let radius = min(8, pixelBox.height * 0.22)
            let path = CGPath(
                roundedRect: pixelBox,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.88, alpha: 1).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(NSColor(calibratedRed: 0.42, green: 0.48, blue: 0.58, alpha: 1).cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        guard let output = context.makeImage() else {
            throw ScreenshotRedactionError.renderingFailed
        }
        return output
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }
}
