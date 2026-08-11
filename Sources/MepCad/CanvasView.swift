import SwiftUI
import AppKit
import MepCore
import MepRender
import MepTools

// MARK: - 図面本体を描くビュー(静的キャッシュ付き)
//
// 実装構成設計書§3の「静的層」: 図面全体をビットマップにキャッシュし、
// パン/ズーム中はキャッシュを平行移動・拡縮して即時表示、
// 操作が落ち着いたらバックグラウンドで再レンダリングして差し替える。
// 数万要素のJWW下敷きでも60fpsの操作感を保つための仕組み。

final class CanvasContentView: NSView {
    weak var controller: CanvasController?

    private var cachedImage: CGImage?
    private var cachedTransform = ViewTransform()
    private var cachedSize = CGSize.zero
    private var renderGeneration = 0
    private var renderInFlight = false

    override var isFlipped: Bool { true }

    /// ドキュメント変更時に呼ぶ(キャッシュ破棄)
    func invalidateCache() {
        cachedImage = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let transform = controller.transform

        if let image = cachedImage, cachedSize == bounds.size {
            // キャッシュを現在のトランスフォームに合わせて表示
            ctx.setFillColor(controller.theme.background)
            ctx.fill(bounds)
            let s = transform.scale / cachedTransform.scale
            let w0 = cachedTransform.toWorld(Vec2(0, 0))
            let p0 = transform.toScreen(w0)
            let rect = CGRect(x: p0.x, y: p0.y,
                              width: Double(cachedSize.width) * s,
                              height: Double(cachedSize.height) * s)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none  // 線画はニアレストの方がにじまない
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()

            if transform != cachedTransform {
                scheduleRegenerate()
            }
        } else {
            // キャッシュなし: 少量なら同期描画、大量なら背景色のみ出して非同期生成
            if controller.document.entities.count < 3000 {
                let renderer = Renderer(theme: controller.theme)
                renderer.draw(document: controller.document,
                              transform: transform,
                              viewSize: bounds.size,
                              gridSpacing: controller.gridSpacing,
                              in: ctx)
                // 同期描画結果をそのままキャッシュ化するため非同期生成も走らせる
                scheduleRegenerate()
            } else {
                ctx.setFillColor(controller.theme.background)
                ctx.fill(bounds)
                scheduleRegenerate()
            }
        }
    }

    private func scheduleRegenerate() {
        guard let controller, !renderInFlight, bounds.width > 1, bounds.height > 1 else { return }
        renderInFlight = true
        renderGeneration += 1
        let generation = renderGeneration

        // スナップショット(配列は値型なのでコピーが安全に取れる)
        let entities = controller.document.entities
        let layers = controller.document.layers
        let transform = controller.transform
        let theme = controller.theme
        let gridSpacing = controller.gridSpacing
        let size = bounds.size
        let scaleFactor = window?.backingScaleFactor ?? 2

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pixelW = Int(size.width * scaleFactor)
            let pixelH = Int(size.height * scaleFactor)
            guard pixelW > 0, pixelH > 0,
                  let bctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                DispatchQueue.main.async { self?.renderInFlight = false }
                return
            }
            // CGBitmapContextはY上向きなので、flippedビュー座標系に合わせて反転
            bctx.translateBy(x: 0, y: CGFloat(pixelH))
            bctx.scaleBy(x: scaleFactor, y: -scaleFactor)

            let renderer = Renderer(theme: theme)
            renderer.draw(entities: entities, layers: layers,
                          transform: transform, viewSize: size,
                          gridSpacing: gridSpacing, in: bctx)
            let image = bctx.makeImage()

            DispatchQueue.main.async {
                guard let self else { return }
                self.renderInFlight = false
                if let image {
                    self.cachedImage = image
                    self.cachedTransform = transform
                    self.cachedSize = size
                    self.needsDisplay = true
                }
                // 生成中にさらに動いていたら追いかけて再生成
                if generation != self.renderGeneration || transform != self.controller?.transform {
                    self.scheduleRegenerate()
                }
            }
        }
    }

    override func layout() {
        super.layout()
        if cachedSize != bounds.size {
            cachedImage = nil
            needsDisplay = true
        }
    }
}

// MARK: - 十字カーソル・ピックボックス・スナップマークのオーバーレイ

final class CrosshairOverlayView: NSView {
    weak var controller: CanvasController?

    override var isFlipped: Bool { true }
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
        controller.onDocumentChanged = { [weak self] in self?.content.invalidateCache() }
        controller.viewSizeProvider = { [weak self] in self?.bounds.size ?? .zero }
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
