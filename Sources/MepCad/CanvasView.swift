import SwiftUI
import AppKit
import MepCore
import MepRender
import MepTools

// MARK: - 図面本体を描くビュー

final class CanvasContentView: NSView {
    weak var controller: CanvasController?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let renderer = Renderer(theme: controller.theme)
        renderer.draw(document: controller.document,
                      transform: controller.transform,
                      viewSize: bounds.size,
                      gridSpacing: controller.gridSpacing,
                      in: ctx)
    }
}

// MARK: - 十字カーソル・ピックボックス・スナップマークのオーバーレイ

final class CrosshairOverlayView: NSView {
    weak var controller: CanvasController?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // イベントは下へ通す

    override func draw(_ dirtyRect: NSRect) {
        guard let controller,
              let p = controller.cursorScreen,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let lineColor: CGColor = controller.theme.isDark
            ? CGColor(gray: 1, alpha: 0.85)
            : CGColor(gray: 0.1, alpha: 0.75)

        // 十字(全画面)
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: p.y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: 0))
        ctx.addLine(to: CGPoint(x: p.x, y: bounds.height))
        ctx.strokePath()

        // ピックボックス
        let half = controller.pickBoxPx / 2
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: p.x - half, y: p.y - half,
                          width: controller.pickBoxPx, height: controller.pickBoxPx))

        // スナップマーク(オレンジ菱形)
        if let s = controller.snappedScreen {
            ctx.setStrokeColor(CGColor(red: 0.91, green: 0.63, blue: 0, alpha: 1))
            ctx.setLineWidth(2)
            let r: CGFloat = 7
            ctx.move(to: CGPoint(x: s.x, y: s.y - r))
            ctx.addLine(to: CGPoint(x: s.x + r, y: s.y))
            ctx.addLine(to: CGPoint(x: s.x, y: s.y + r))
            ctx.addLine(to: CGPoint(x: s.x - r, y: s.y))
            ctx.closePath()
            ctx.strokePath()
        }
    }
}

// MARK: - イベントを受けるコンテナ

final class CanvasContainerView: NSView {
    let controller: CanvasController
    private let content = CanvasContentView()
    private let overlay = CrosshairOverlayView()
    private var invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        // レイヤーバッキング必須: これがないとオーバーレイの再描画が
        // 下の図面ビューまで巻き込み、スナップ表示のたびに画面全体が揺れる
        wantsLayer = true
        content.wantsLayer = true
        overlay.wantsLayer = true
        content.layer?.isOpaque = true
        overlay.layer?.isOpaque = false
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        content.layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlay.layerContentsRedrawPolicy = .onSetNeedsDisplay
        content.controller = controller
        overlay.controller = controller
        for view in [content, overlay] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        controller.needsContentRedraw = { [weak self] in self?.content.needsDisplay = true }
        controller.needsOverlayRedraw = { [weak self] in self?.overlay.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: カーソル(標準矢印を消して十字に)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: invisibleCursor)
    }

    // MARK: トラッキング

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    private func screenPoint(_ event: NSEvent) -> Vec2 {
        let p = convert(event.locationInWindow, from: nil)
        return Vec2(Double(p.x), Double(p.y))
    }

    override func mouseMoved(with event: NSEvent) {
        controller.mouseMoved(toScreen: screenPoint(event))
    }

    override func mouseDragged(with event: NSEvent) {
        // ドラッグでパン(M3で選択ドラッグに置き換え、パンはスペース+ドラッグへ)
        controller.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func mouseExited(with event: NSEvent) {
        controller.mouseExited()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘+スクロールでズーム
            let factor = 1 + Double(event.scrollingDeltaY) * 0.01
            controller.zoom(factor: factor, atScreen: screenPoint(event))
        } else {
            controller.pan(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        controller.zoom(factor: 1 + Double(event.magnification), atScreen: screenPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller.fit(viewSize: bounds.size)
        }
        window?.makeFirstResponder(self)
    }
}

// MARK: - SwiftUIラッパー

struct CanvasView: NSViewRepresentable {
    let controller: CanvasController

    func makeNSView(context: Context) -> CanvasContainerView {
        CanvasContainerView(controller: controller)
    }

    func updateNSView(_ nsView: CanvasContainerView, context: Context) {}
}
