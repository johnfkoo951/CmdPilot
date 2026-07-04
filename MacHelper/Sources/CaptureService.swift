import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// 양방향 캡처.
/// ① 맥 화면 → 폰: `screencapture` 로 찍어 JPEG base64 회신 (화면 기록 권한 필요 — 최초 1회 시스템이 요청)
/// ② 폰 카메라 → 맥: 이미지에서 Vision OCR(한/영) → 맥 클립보드에 복사 (클립보드 히스토리 앱에 쌓임)
enum CaptureService {
    private static let queue = DispatchQueue(label: "com.joonlab.macpilot.capture", qos: .userInitiated)

    // MARK: - 맥 화면 → 폰

    /// 화면 기록 권한 상태 (헬퍼 프로세스 기준). 폰 UI 진단용으로도 노출.
    static var screenAccessGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func captureScreen(reply: @escaping (String) -> Void) {
        guard #available(macOS 14.0, *) else {
            reply(#"{"t":"capture","error":"화면 가져오기는 macOS 14 이상에서 지원됩니다"}"#); return
        }
        // ScreenCaptureKit: 권한 없으면 SCShareableContent 가 에러를 던지며,
        // 그 과정에서 시스템이 화면 기록 권한 프롬프트를 띄운다.
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let targetID = currentDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == targetID })
                        ?? content.displays.first else {
                    reply(#"{"t":"capture","error":"디스플레이를 찾지 못했습니다"}"#); return
                }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                // 폰 전송용으로 긴 변 1800px 로 축소 캡처
                let scale = min(1.0, 1800.0 / Double(max(display.width, display.height)))
                config.width = Int(Double(display.width) * scale)
                config.height = Int(Double(display.height) * scale)
                config.showsCursor = true

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let jpeg = jpeg(cgImage) else {
                    reply(#"{"t":"capture","error":"이미지 인코딩 실패"}"#); return
                }
                reply("{\"t\":\"capture\",\"data\":\"\(jpeg.base64EncodedString())\"}")
            } catch {
                reply(#"{"t":"capture","error":"화면 기록 권한이 필요합니다. 맥에 뜬 창에서 허용(Allow) 후, 설정(Settings) → 개인정보 보호 및 보안(Privacy & Security) → 화면 및 시스템 오디오 기록(Screen & System Audio Recording)에서 MacPilot Helper를 켜고 다시 시도하세요."}"#)
            }
        }
    }

    /// 마우스 커서가 위치한 디스플레이 ID (없으면 메인)
    private static func currentDisplayID() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(num.uint32Value)
        }
        return CGMainDisplayID()
    }

    /// CGImage → JPEG(0.72). (크기 축소는 캡처 단계에서 이미 처리)
    private static func jpeg(_ cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
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
