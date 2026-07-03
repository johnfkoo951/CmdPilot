import AppKit

/// 발표용 스팟라이트 오버레이 (로지텍 스팟라이트 스타일).
/// 화면 전체를 어둡게 덮고 커서 주변만 원형으로 밝게 뚫는다.
/// 클릭·키 입력은 그대로 아래로 통과(ignoresMouseEvents) — 발표 진행에 방해 없음.
/// 토글: 덱/제스처의 `macpilot://spotlight` (HelperServer 가 가로챔)
final class SpotlightOverlay {
    static let shared = SpotlightOverlay()

    private var window: NSWindow?
    private var timer: Timer?
    var radius: CGFloat = 110

    func toggle() {
        DispatchQueue.main.async { [self] in window == nil ? show() : hide() }
    }

    func off() {
        DispatchQueue.main.async { [self] in hide() }
    }

    private func show() {
        // 커서가 있는 화면(발표 중이면 보통 외부 디스플레이)에 덮는다
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }

        let overlay = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.level = .screenSaver
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SpotlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.radius = radius
        overlay.contentView = view
        overlay.orderFrontRegardless()
        window = overlay

        // 커서 추적 60Hz — 폰 트랙패드로 움직여도 CGEvent 주입이 mouseLocation 에 반영된다
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.window?.contentView as? SpotlightView else { return }
            let loc = NSEvent.mouseLocation
            view.cursor = NSPoint(x: loc.x - screen.frame.minX, y: loc.y - screen.frame.minY)
            view.needsDisplay = true
        }
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

private final class SpotlightView: NSView {
    var cursor = NSPoint.zero
    var radius: CGFloat = 110

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 어두운 덮개
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.fill(bounds)
        // 커서 주변 원형 구멍 (알파를 지워서 아래 화면이 그대로 보이게)
        ctx.setBlendMode(.clear)
        let hole = CGRect(x: cursor.x - radius, y: cursor.y - radius, width: radius * 2, height: radius * 2)
        ctx.fillEllipse(in: hole)
        ctx.setBlendMode(.normal)
        // 가장자리 링 (스팟 위치가 또렷하게 보이도록)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: hole.insetBy(dx: 1, dy: 1))
    }
}
