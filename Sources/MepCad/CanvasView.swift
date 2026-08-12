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
        let groups = controller.document.groups
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
            renderer.draw(entities: entities, groups: groups,
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

// MARK: - 十字カーソル・ピックボックス・スナップマーク・選択表示のオーバーレイ

final class CrosshairOverlayView: NSView {
    weak var controller: CanvasController?

    /// 選択ハイライト/ゴーストを個別に描く上限(超えたらバウンディングボックス表示)
    private let outlineDrawLimit = 2000

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // イベントは下へ通す

    override func draw(_ dirtyRect: NSRect) {
        guard let controller,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let accent = CGColor(red: 0.0, green: 0.4, blue: 0.9, alpha: 0.9)

        // 選択ハイライト(カーソルが無くても描く)
        if !controller.selectedEntities.isEmpty {
            drawSelectionHighlight(controller: controller, in: ctx)
        }

        // 移動・複写のゴースト
        if let delta = controller.ghostDelta, !controller.selectedEntities.isEmpty {
            drawGhost(controller: controller, delta: delta, in: ctx)
        }

        // 矩形選択(マーキー)
        if let s = controller.marqueeStartScreen, let c = controller.marqueeCurrentScreen {
            drawMarquee(from: s, to: c, mode: controller.marqueeMode, in: ctx)
        }

        guard let p = controller.cursorScreen else { return }

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

        // スナップマーク(オレンジ菱形)+ 種別ラベル(カーソル中心付近に文字表示)
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

            if let kind = controller.snappedKind {
                drawSnapLabel(kind.label, near: CGPoint(x: s.x + 12, y: s.y - 26), in: ctx)
            }
        }

        // 作図プレビュー(ラバーバンド)
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
        let buffer = controller.editOp.isActive ? controller.editOp.numericBuffer
                                                : controller.tools.numericBuffer
        if !buffer.isEmpty {
            drawInputBadge("\(buffer) ⏎", near: CGPoint(x: p.x + 18, y: p.y + 18), in: ctx)
        }
    }

    // MARK: 選択ハイライト・ゴースト・マーキー

    private func drawSelectionHighlight(controller: CanvasController, in ctx: CGContext) {
        let renderer = Renderer(theme: controller.theme)
        let highlight = CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.9)
        let entities = controller.selectedEntities
        if entities.count <= outlineDrawLimit {
            renderer.drawOutlines(entities, transform: controller.transform,
                                  color: highlight, lineWidth: 2.5, in: ctx)
        } else {
            // 大量選択はバウンディングボックスで示す
            var box = BBox.empty
            for e in entities { box.union(e.bounds) }
            guard !box.isEmpty else { return }
            let p0 = controller.transform.toScreen(Vec2(box.minX, box.minY))
            let p1 = controller.transform.toScreen(Vec2(box.maxX, box.maxY))
            ctx.setStrokeColor(highlight)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [8, 4])
            ctx.stroke(CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                              width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)))
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    private func drawGhost(controller: CanvasController, delta: Vec2, in ctx: CGContext) {
        let renderer = Renderer(theme: controller.theme)
        let ghostColor = CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.45)
        let entities = controller.selectedEntities
        if entities.count <= outlineDrawLimit {
            let moved = entities.map { $0.translated(by: delta) }
            renderer.drawOutlines(moved, transform: controller.transform,
                                  color: ghostColor, lineWidth: 1.5, in: ctx)
        } else {
            var box = BBox.empty
            for e in entities { box.union(e.bounds) }
            guard !box.isEmpty else { return }
            let p0 = controller.transform.toScreen(Vec2(box.minX + delta.x, box.minY + delta.y))
            let p1 = controller.transform.toScreen(Vec2(box.maxX + delta.x, box.maxY + delta.y))
            ctx.setStrokeColor(ghostColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [8, 4])
            ctx.stroke(CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                              width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // 基準点→カーソルのガイド線と移動量表示
        if let base = controller.editOp.basePoint {
            let sb = controller.transform.toScreen(base)
            let st = controller.transform.toScreen(base + delta)
            ctx.setStrokeColor(ghostColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: CGPoint(x: sb.x, y: sb.y))
            ctx.addLine(to: CGPoint(x: st.x, y: st.y))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drawOverlayLabel(String(format: "dx %.0f  dy %.0f", delta.x, delta.y),
                             at: CGPoint(x: (sb.x + st.x) / 2 + 8, y: (sb.y + st.y) / 2 - 8),
                             in: ctx)
        }
    }

    private func drawMarquee(from s: Vec2, to c: Vec2, mode: RectSelectionMode, in ctx: CGContext) {
        let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                          width: abs(c.x - s.x), height: abs(c.y - s.y))
        switch mode {
        case .window:
            // 窓選択(内包): 青の実線
            ctx.setFillColor(CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.08))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.8))
            ctx.setLineWidth(1)
            ctx.stroke(rect)
        case .crossing:
            // 交差選択: 緑の破線
            ctx.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 0.3, alpha: 0.08))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.65, blue: 0.3, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(rect)
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    /// スナップ種別ラベル(オレンジの小バッジ)
    private func drawSnapLabel(_ text: String, near point: CGPoint, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let rect = CGRect(x: point.x, y: point.y,
                          width: size.width + 12, height: size.height + 5)
        let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.91, green: 0.63, blue: 0, alpha: 0.92))
        ctx.fillPath()
        attributed.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 2.5))
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

    /// 選択ツールでのクリック/ドラッグ判定用
    private var mouseDownScreen: Vec2?
    private var isMarqueeDragging = false

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
        controller.onUIHoverChanged = { [weak self] in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: カーソル(標準矢印を消して十字に。パネル上では矢印に戻す)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: controller.uiHovering ? .arrow : invisibleCursor)
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
        let p = screenPoint(event)
        if let start = mouseDownScreen, controller.tools.kind == .select, !controller.editOp.isActive {
            // 選択ツール: ドラッグ=矩形選択(3px以上動いたらマーキー開始)
            if !isMarqueeDragging, p.distance(to: start) > 3 {
                isMarqueeDragging = true
                controller.marqueeStartScreen = start
            }
            if isMarqueeDragging {
                controller.marqueeCurrentScreen = p
                controller.needsOverlayRedraw?()
            }
            return
        }
        // 作図ツール中・編集操作中はドラッグ=パン(M3の操作感)
        controller.pan(dx: Double(event.deltaX), dy: Double(event.deltaY))
    }

    override func otherMouseDragged(with event: NSEvent) {
        // 中ボタンドラッグ=パン(選択ツールでも常に使える)
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
        let p = screenPoint(event)
        controller.mouseMoved(toScreen: p, shiftDown: event.modifierFlags.contains(.shift))

        if controller.editOp.isActive {
            // 移動・複写: クリック=基準点/目標点の指示
            controller.editClick()
            return
        }
        if controller.tools.isDrawingToolActive {
            // 作図ツール: クリック=点の指示
            controller.toolClick(shiftDown: event.modifierFlags.contains(.shift))
            return
        }
        // 選択ツール
        if event.clickCount == 2 {
            controller.fit(viewSize: bounds.size)
            return
        }
        mouseDownScreen = p
        isMarqueeDragging = false
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreen = nil
            isMarqueeDragging = false
        }
        guard controller.tools.kind == .select, !controller.editOp.isActive else { return }
        let shift = event.modifierFlags.contains(.shift)
        if isMarqueeDragging {
            controller.marqueeCurrentScreen = screenPoint(event)
            controller.commitMarquee(shiftDown: shift)
        } else if let start = mouseDownScreen, event.clickCount == 1 {
            controller.clickSelect(atScreen: start, shiftDown: shift)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 選択ツール: コンテキストメニュー / 作図・編集中: キャンセル(M3の操作感)
        if let menu = controller.contextMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            controller.toolCancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘系ショートカット
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
            if key == "a" {
                controller.selectAll()
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
        // delete / forward delete: 選択削除
        if event.keyCode == 51 || event.keyCode == 117 {
            if controller.tools.kind == .select, !controller.editOp.isActive {
                controller.deleteSelection()
                return
            }
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
