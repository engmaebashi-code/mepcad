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
                              gridSpacing: controller.effectiveGridSpacing,
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
        let gridSpacing = controller.effectiveGridSpacing
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

        // 作図プレビュー(ラバーバンド)
        let accent = CGColor(red: 0.0, green: 0.4, blue: 0.9, alpha: 0.9)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        switch controller.previewShape {
        case .none:
            break
        case .line(let a, let b):
            let sa = controller.transform.toScreen(a)
            let sb = controller.transform.toScreen(b)
            ctx.move(to: CGPoint(x: sa.x, y: sa.y))
            ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
            ctx.strokePath()
            // 長さ表示
            let len = a.distance(to: b)
            drawOverlayLabel(String(format: "%.0f", len),
                             at: CGPoint(x: (sa.x + sb.x) / 2 + 8, y: (sa.y + sb.y) / 2 - 8),
                             in: ctx)
        case .circle(let c, let r):
            let sc = controller.transform.toScreen(c)
            let sr = r * controller.transform.scale
            ctx.strokeEllipse(in: CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2))
            drawOverlayLabel(String(format: "R%.0f", r),
                             at: CGPoint(x: sc.x + 10, y: sc.y - 10), in: ctx)
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 数値入力ポップアップ(カーソルのすぐ近くに表示)
        let buffer = controller.tools.numericBuffer
        if !buffer.isEmpty, let p = controller.cursorScreen {
            drawInputBadge("\(buffer) ⏎", near: CGPoint(x: p.x + 18, y: p.y + 18), in: ctx)
        }
    }

    /// 数値入力バッジ(角丸背景付き)
    private func drawInputBadge(_ text: String, near point: CGPoint, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let rect = CGRect(x: point.x, y: point.y,
                          width: size.width + 16, height: size.height + 8)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.0, green: 0.4, blue: 0.9, alpha: 0.92))
        ctx.fillPath()
        attributed.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4))
    }

    private func drawOverlayLabel(_ text: String, at point: CGPoint, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: controller?.theme.isDark == true ? NSColor.white : NSColor.black,
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: point)
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
        controller.mouseMoved(toScreen: screenPoint(event),
                              shiftDown: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        // ドラッグでパン(M3で選択ドラッグに置き換え、パンはスペース+ドラッグへ)
        controller.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func mouseExited(with event: NSEvent) {
        controller.mouseExited()
    }

    override func scrollWheel(with event: NSEvent) {
        // マウスホイール(粗い離散デルタ)= ズーム(Jw_cad/FILDERの流儀)
        // トラックパッド(精密デルタ)= パン、⌘併用でズーム
        let isTrackpad = event.hasPreciseScrollingDeltas
        if !isTrackpad || event.modifierFlags.contains(.command) {
            let sensitivity = isTrackpad ? 0.01 : 0.1
            let factor = 1 + Double(event.scrollingDeltaY) * sensitivity
            controller.zoom(factor: factor, atScreen: screenPoint(event))
        } else {
            controller.pan(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        controller.zoom(factor: 1 + Double(event.magnification), atScreen: screenPoint(event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if controller.tools.isDrawingToolActive {
            // 作図ツール: クリック=点の指示
            controller.mouseMoved(toScreen: screenPoint(event),
                                  shiftDown: event.modifierFlags.contains(.shift))
            controller.toolClick(shiftDown: event.modifierFlags.contains(.shift))
        } else if event.clickCount == 2 {
            controller.fit(viewSize: bounds.size)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右クリック: 作図の終了/キャンセル(コンテキストメニューはM4)
        controller.toolCancel()
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Z / ⇧⌘Z
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "z" {
                if event.modifierFlags.contains(.shift) {
                    controller.redo()
                } else {
                    controller.undo()
                }
                return
            }
            super.keyDown(with: event)
            return
        }
        // esc
        if event.keyCode == 53 {
            controller.toolCancel()
            return
        }
        // 数値入力等はツールへ
        if let chars = event.characters, let first = chars.first,
           controller.toolKey(first) {
            return
        }
        super.keyDown(with: event)
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
