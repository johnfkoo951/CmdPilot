import AppKit
import CoreGraphics
import Foundation
import Vision

/// 양방향 캡처.
/// ① 맥 화면 → 폰: `screencapture` 로 찍어 JPEG base64 회신 (화면 기록 권한 필요 — 최초 1회 시스템이 요청)
/// ② 폰 카메라 → 맥: 이미지에서 Vision OCR(한/영) → 맥 클립보드에 복사 (클립보드 히스토리 앱에 쌓임)
enum CaptureService {
    private static let queue = DispatchQueue(label: "com.joonlab.macpilot.capture", qos: .userInitiated)

    // MARK: - 맥 화면 → 폰

    static func captureScreen(reply: @escaping (String) -> Void) {
        queue.async {
            // 화면 기록 권한이 없으면 시스템 프롬프트 유도 (1회)
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
            let tmp = NSTemporaryDirectory() + "macpilot-capture-\(UUID().uuidString).jpg"
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "jpg", tmp]   // -x: 무음
            do { try process.run() } catch {
                reply(#"{"t":"capture","error":"screencapture 실행 실패"}"#); return
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)) else {
                reply(#"{"t":"capture","error":"권한 없음 또는 캡처 실패"}"#); return
            }
            // 레티나 원본은 수 MB → 폰 전송용으로 긴 변 1800px, JPEG 0.7 다운스케일
            let jpeg = downscaleJPEG(data, maxDim: 1800) ?? data
            reply("{\"t\":\"capture\",\"data\":\"\(jpeg.base64EncodedString())\"}")
        }
    }

    private static func downscaleJPEG(_ data: Data, maxDim: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxDim / max(size.width, size.height))
        let target = NSSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    // MARK: - 폰 카메라 → OCR → 맥 클립보드

    static func ocrToClipboard(base64: String, reply: @escaping (String) -> Void) {
        queue.async {
            guard let data = Data(base64Encoded: base64),
                  let cgImage = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                reply(#"{"t":"ocr","error":"이미지 해석 실패"}"#); return
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try? handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            if !text.isEmpty {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            let payload: [String: Any] = ["t": "ocr", "text": text]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"t":"ocr","text":""}"#
            reply(json)
        }
    }
}
