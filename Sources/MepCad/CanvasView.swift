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
        let showAuxiliary = controller.document.showAuxiliary
        let blockDefinitions = controller.document.blockDefinitions
        let paperFrame = controller.document.paperFrame
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
                          gridSpacing: gridSpacing, showAuxiliary: showAuxiliary,
                          blockDefinitions: blockDefinitions,
                          paperFrame: paperFrame, in: bctx)
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

        // 伸縮グリップ(選択図形の端点等の□ハンドル)と編集中プレビュー
        drawGrips(controller: controller, in: ctx)

        // 移動・複写・回転のゴースト
        if let transform = controller.ghostTransform, !controller.selectedEntities.isEmpty {
            drawGhost(controller: controller, ghost: transform, in: ctx)
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

        case .rect(let p1, let p2):
            let s1 = controller.transform.toScreen(p1)
            let s2 = controller.transform.toScreen(p2)
            ctx.stroke(CGRect(x: min(s1.x, s2.x), y: min(s1.y, s2.y),
                              width: abs(s2.x - s1.x), height: abs(s2.y - s1.y)))
            drawOverlayLabel(String(format: "%.0f × %.0f", abs(p2.x - p1.x), abs(p2.y - p1.y)),
                             at: CGPoint(x: (s1.x + s2.x) / 2 + 8, y: (s1.y + s2.y) / 2 - 8), in: ctx)

        case .arc(let c, let r, let a1, let a2):
            let sc = controller.transform.toScreen(c)
            let sr = r * controller.transform.scale
            // スクリーンはY反転しているため角度符号を反転(RendererのCCW描画と同じ流儀)
            ctx.addArc(center: CGPoint(x: sc.x, y: sc.y), radius: sr,
                       startAngle: -a1, endAngle: -a2, clockwise: true)
            ctx.strokePath()
            drawOverlayLabel(String(format: "R%.0f", r),
                             at: CGPoint(x: sc.x + 10, y: sc.y - 10), in: ctx)

        case .doubleLine(let a, let b, let offsetA, let offsetB):
            let d = Vec2(b.x - a.x, b.y - a.y)
            let len = d.length
            if len > 1e-9 {
                let n = Vec2(-d.y / len, d.x / len)
                for offset in [n * offsetA, n * (-offsetB)] {
                    let sa = controller.transform.toScreen(a + offset)
                    let sb = controller.transform.toScreen(b + offset)
                    ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                    ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
                }
                ctx.strokePath()
                let sm = controller.transform.toScreen(Vec2((a.x + b.x) / 2, (a.y + b.y) / 2))
                drawOverlayLabel(String(format: "L%.0f  A%.0f/B%.0f", len, offsetA, offsetB),
                                 at: CGPoint(x: sm.x + 8, y: sm.y - 8), in: ctx)
            }

        case .polygon(let points, let cursor):
            // ハッチング境界: 確定辺は実線相当、カーソルへのラバー+閉じる辺は破線のまま
            guard let firstPoint = points.first else { break }
            let first = controller.transform.toScreen(firstPoint)
            ctx.move(to: CGPoint(x: first.x, y: first.y))
            for p in points.dropFirst() {
                let sp = controller.transform.toScreen(p)
                ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
            }
            let sc = controller.transform.toScreen(cursor)
            ctx.addLine(to: CGPoint(x: sc.x, y: sc.y))
            if points.count >= 2 {
                ctx.addLine(to: CGPoint(x: first.x, y: first.y))
            }
            ctx.strokePath()
            // 頂点マーク
            ctx.setLineDash(phase: 0, lengths: [])
            for p in points {
                let sp = controller.transform.toScreen(p)
                ctx.stroke(CGRect(x: sp.x - 2.5, y: sp.y - 2.5, width: 5, height: 5))
            }

        case .dimension(let a, let b, let linePoint, let angle, let attrs):
            // 寸法ゴースト: 寸法線・補助線・端部を実際の見た目で、寸法値はラベルで表示
            let layout = DimensionGeometry.layout(a: a, b: b, linePoint: linePoint,
                                                  angle: angle, attrs: attrs)
            ctx.setLineDash(phase: 0, lengths: [])
            for seg in layout.hitSegments + layout.arrowStrokes {
                let sa = controller.transform.toScreen(seg.0)
                let sb = controller.transform.toScreen(seg.1)
                ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
            }
            ctx.strokePath()
            ctx.setFillColor(accent)
            let dr = max(layout.dotRadius * controller.transform.scale, 1.5)
            for c in layout.dotCenters {
                let sc = controller.transform.toScreen(c)
                ctx.fillEllipse(in: CGRect(x: sc.x - dr, y: sc.y - dr,
                                           width: dr * 2, height: dr * 2))
            }
            let st = controller.transform.toScreen(layout.textPosition)
            drawOverlayLabel(layout.textContent,
                             at: CGPoint(x: st.x, y: st.y - 4), in: ctx)

        case .leader(let tip, let elbow, let attrs):
            // 引出線ゴースト: 線+矢印+(バルーンなら2文字ぶんの枠)。文字はクリック後に入力
            let layout = LeaderGeometry.layout(tip: tip, elbow: elbow,
                                               content: "00", attrs: attrs)
            ctx.setLineDash(phase: 0, lengths: [])
            for seg in layout.segments + layout.arrowStrokes {
                let sa = controller.transform.toScreen(seg.0)
                let sb = controller.transform.toScreen(seg.1)
                ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
            }
            ctx.strokePath()
            for e in layout.ellipses {
                let sc = controller.transform.toScreen(e.center)
                let rx = e.rx * controller.transform.scale
                let ry = e.ry * controller.transform.scale
                ctx.strokeEllipse(in: CGRect(x: sc.x - rx, y: sc.y - ry,
                                             width: rx * 2, height: ry * 2))
            }

        case .polyline(let points, let cursor):
            // 配管ルート: 確定済み折れ線+カーソルへのラバーバンド(閉じない)
            guard let firstPoint = points.first else { break }
            let first = controller.transform.toScreen(firstPoint)
            ctx.move(to: CGPoint(x: first.x, y: first.y))
            for p in points.dropFirst() {
                let sp = controller.transform.toScreen(p)
                ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
            }
            let sc = controller.transform.toScreen(cursor)
            ctx.addLine(to: CGPoint(x: sc.x, y: sc.y))
            ctx.strokePath()
            // 複線設定なら外形線もゴースト表示(太さの感覚が掴めるように)
            let style = controller.toolPipeStyle()
            if style.attrs.doubleLine {
                let pts3 = (points + [cursor]).map { Vec3($0, z: style.z) }
                if let layout = PipeGeometry.doubleLineLayout(points: pts3, attrs: style.attrs) {
                    ctx.setLineDash(phase: 0, lengths: [3, 3])
                    for run in layout.runs {
                        for pts in [run.left, run.right] where pts.count >= 2 {
                            let f = controller.transform.toScreen(pts[0])
                            ctx.move(to: CGPoint(x: f.x, y: f.y))
                            for p in pts.dropFirst() {
                                let sp = controller.transform.toScreen(p)
                                ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
                            }
                        }
                    }
                    // 継手(エルボ)の実形状もゴースト
                    for shape in layout.fittings {
                        for part in shape.parts {
                            if case .polygon(let pts) = part, let f0 = pts.first {
                                let f = controller.transform.toScreen(f0)
                                ctx.move(to: CGPoint(x: f.x, y: f.y))
                                for p in pts.dropFirst() {
                                    let sp = controller.transform.toScreen(p)
                                    ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
                                }
                                ctx.closePath()
                            }
                        }
                    }
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [6, 4])
                }
            }
            // 現区間の長さ表示
            if let last = points.last {
                let len = last.distance(to: cursor)
                drawOverlayLabel(String(format: "%.0f", len),
                                 at: CGPoint(x: sc.x + 8, y: sc.y - 8), in: ctx)
            }
            // 頂点マーク
            ctx.setLineDash(phase: 0, lengths: [])
            for p in points {
                let sp = controller.transform.toScreen(p)
                ctx.stroke(CGRect(x: sp.x - 2.5, y: sp.y - 2.5, width: 5, height: 5))
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 数値入力ポップアップ(カーソルのすぐ近くに表示)
        let buffer = controller.gripDrag != nil ? controller.gripNumericBuffer
                   : controller.editOp.isActive ? controller.editOp.numericBuffer
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
                                  color: highlight, lineWidth: 2.5,
                                  blockDefinitions: controller.document.blockDefinitions, in: ctx)
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

    private func drawGhost(controller: CanvasController, ghost: EditTransform, in ctx: CGContext) {
        let renderer = Renderer(theme: controller.theme)
        let ghostColor = CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.45)
        let entities = controller.selectedEntities

        // 接続を保つために伸縮する配管(M7.3)。移動側と同じ色で先に描く
        if !controller.ghostFollowers.isEmpty {
            renderer.drawOutlines(controller.ghostFollowers, transform: controller.transform,
                                  color: ghostColor, lineWidth: 1.5,
                                  blockDefinitions: controller.document.blockDefinitions, in: ctx)
        }

        // 変換後のゴースト本体(applyingが全変換対応)
        if entities.count <= outlineDrawLimit {
            let moved = entities.map { $0.applying(ghost) }
            renderer.drawOutlines(moved, transform: controller.transform,
                                  color: ghostColor, lineWidth: 1.5,
                                  blockDefinitions: controller.document.blockDefinitions, in: ctx)
        } else if case .translate(let delta) = ghost {
            // 大量選択の移動はバウンディングボックスで示す(回転は省略)
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

        // ガイド線とラベル
        ctx.setStrokeColor(ghostColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        switch ghost {
        case .translate(let delta):
            guard let base = controller.editOp.basePoint else { break }
            let sb = controller.transform.toScreen(base)
            let st = controller.transform.toScreen(base + delta)
            ctx.move(to: CGPoint(x: sb.x, y: sb.y))
            ctx.addLine(to: CGPoint(x: st.x, y: st.y))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drawOverlayLabel(String(format: "dx %.0f  dy %.0f", delta.x, delta.y),
                             at: CGPoint(x: (sb.x + st.x) / 2 + 8, y: (sb.y + st.y) / 2 - 8),
                             in: ctx)
        case .moveRotated(let base, let delta, let angle):
            let sb = controller.transform.toScreen(base)
            let st = controller.transform.toScreen(base + delta)
            ctx.move(to: CGPoint(x: sb.x, y: sb.y))
            ctx.addLine(to: CGPoint(x: st.x, y: st.y))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drawOverlayLabel(String(format: "dx %.0f  dy %.0f  ∠%.0f°", delta.x, delta.y, angle * 180 / .pi),
                             at: CGPoint(x: (sb.x + st.x) / 2 + 8, y: (sb.y + st.y) / 2 - 8),
                             in: ctx)
        case .rotate(_, let angle):
            guard let base = controller.editOp.basePoint else { break }
            let sb = controller.transform.toScreen(base)
            // 回転中心の十字と角度表示
            let r: CGFloat = 6
            ctx.move(to: CGPoint(x: sb.x - r, y: sb.y))
            ctx.addLine(to: CGPoint(x: sb.x + r, y: sb.y))
            ctx.move(to: CGPoint(x: sb.x, y: sb.y - r))
            ctx.addLine(to: CGPoint(x: sb.x, y: sb.y + r))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drawOverlayLabel(String(format: "∠ %.1f°", angle * 180 / .pi),
                             at: CGPoint(x: sb.x + 10, y: sb.y - 22), in: ctx)
        case .mirror(let a, let b):
            // 反転の基準線(画面端まで延長した一点鎖線)
            let sa = controller.transform.toScreen(a)
            let sbp = controller.transform.toScreen(b)
            let dx = sbp.x - sa.x
            let dy = sbp.y - sa.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 1e-9 {
                let ext = 4000.0
                ctx.setLineDash(phase: 0, lengths: [10, 4, 2, 4])
                ctx.move(to: CGPoint(x: sa.x - dx / len * ext, y: sa.y - dy / len * ext))
                ctx.addLine(to: CGPoint(x: sa.x + dx / len * ext, y: sa.y + dy / len * ext))
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
            drawOverlayLabel("基準線(反転)",
                             at: CGPoint(x: (sa.x + sbp.x) / 2 + 8, y: (sa.y + sbp.y) / 2 - 8),
                             in: ctx)
        case .scale(let center, let factor):
            // 拡大縮小: 中心の十字+基準点→カーソルのガイド線+倍率ラベル
            let sc = controller.transform.toScreen(center)
            let r: CGFloat = 6
            ctx.move(to: CGPoint(x: sc.x - r, y: sc.y))
            ctx.addLine(to: CGPoint(x: sc.x + r, y: sc.y))
            ctx.move(to: CGPoint(x: sc.x, y: sc.y - r))
            ctx.addLine(to: CGPoint(x: sc.x, y: sc.y + r))
            if let cursor = controller.cursorScreen {
                ctx.move(to: CGPoint(x: sc.x, y: sc.y))
                ctx.addLine(to: CGPoint(x: cursor.x, y: cursor.y))
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drawOverlayLabel(String(format: "× %.3f", factor),
                             at: CGPoint(x: sc.x + 10, y: sc.y - 22), in: ctx)
        }
    }

    /// 伸縮グリップの□ハンドルと、ドラッグ中のプレビュー(M4.9)
    private func drawGrips(controller: CanvasController, in ctx: CGContext) {
        let accent = CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.95)
        let half: CGFloat = 3.5

        // 待機中のグリップ(青の塗り□。編集中はcurrentGripsが空を返す)
        let grips = controller.currentGrips()
        if !grips.isEmpty {
            ctx.setFillColor(accent)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            for g in grips {
                let s = controller.transform.toScreen(g.point)
                let rect = CGRect(x: s.x - half, y: s.y - half, width: half * 2, height: half * 2)
                ctx.fill(rect)
                ctx.stroke(rect)
            }
        }

        // ドラッグ中: 変形後のプレビュー(破線)+ホットグリップ(オレンジ)+寸法ラベル
        if let state = controller.gripDrag {
            let renderer = Renderer(theme: controller.theme)
            let ghostColor = CGColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 0.55)
            renderer.drawOutlines([state.preview], transform: controller.transform,
                                  color: ghostColor, lineWidth: 1.5,
                                  blockDefinitions: controller.document.blockDefinitions, in: ctx)
            let s = controller.transform.toScreen(state.current)
            let hot = CGRect(x: s.x - half - 1, y: s.y - half - 1,
                             width: (half + 1) * 2, height: (half + 1) * 2)
            ctx.setFillColor(CGColor(red: 0.91, green: 0.63, blue: 0, alpha: 0.95))
            ctx.fill(hot)
            // 線=固定端からの長さ / 円=半径 を表示
            if let fixed = GripEngine.fixedPoint(for: state.grip.kind, of: state.original) {
                let len = state.current.distance(to: fixed)
                let prefix: String
                if case .circleRadius = state.grip.kind { prefix = "R" } else { prefix = "L" }
                drawOverlayLabel(String(format: "%@%.0f", prefix, len),
                                 at: CGPoint(x: s.x + 10, y: s.y - 22), in: ctx)
            }
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

final class CanvasContainerView: NSView, NSTextFieldDelegate {
    let controller: CanvasController
    private let content = CanvasContentView()
    private let overlay = CrosshairOverlayView()

    /// 選択ツールでのクリック/ドラッグ判定用
    private var mouseDownScreen: Vec2?
    private var isMarqueeDragging = false

    /// インライン文字入力(M5.3: クリック位置で直接入力)
    private var inlineField: NSTextField?
    private var inlineCompletion: ((String?) -> Void)?

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
        controller.onTextInputRequested = { [weak self] screen, initial, fontPx, completion in
            self?.beginInlineTextInput(at: screen, initial: initial,
                                       fontPx: fontPx, completion: completion)
        }
    }

    // MARK: - インライン文字入力(M5.3)

    private func beginInlineTextInput(at screen: Vec2, initial: String, fontPx: Double,
                                      completion: @escaping (String?) -> Void) {
        finishInlineInput(commit: false)   // 進行中のものがあれば破棄
        let fontSize = min(max(fontPx, 11), 48)
        let height = fontSize + 12
        let field = NSTextField(frame: NSRect(x: screen.x - 3,
                                              y: screen.y - height + 4,
                                              width: 280, height: height))
        field.stringValue = initial
        field.font = .systemFont(ofSize: fontSize)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = .textBackgroundColor
        field.drawsBackground = true
        field.placeholderString = "文字を入力(⏎確定 / esc中止)"
        field.target = self
        field.action = #selector(inlineFieldCommitted)
        field.delegate = self
        addSubview(field)
        inlineField = field
        inlineCompletion = completion
        window?.makeFirstResponder(field)
    }

    @objc private func inlineFieldCommitted() {
        finishInlineInput(commit: true)
    }

    private func finishInlineInput(commit: Bool) {
        guard let field = inlineField else { return }
        let text = field.stringValue
        let completion = inlineCompletion
        // フォーカスがまだこの欄にある時だけキャンバスへ戻す
        // (他のコントロールへのクリックで確定した場合は、そちらのフォーカスを奪わない)
        let hadFocus = (window?.firstResponder as? NSText)?.delegate === field
            || window?.firstResponder === field
        inlineField = nil
        inlineCompletion = nil
        field.removeFromSuperview()
        if hadFocus {
            window?.makeFirstResponder(self)
        }
        completion?(commit && !text.isEmpty ? text : nil)
    }

    /// escで中止、クリックアウェイ(編集終了)で確定
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineInput(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Enter確定はaction経由で処理済み。フォーカスが外れた場合はここで確定
        finishInlineInput(commit: true)
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
        // 伸縮(グリップ)ドラッグ中
        if controller.gripDrag != nil {
            controller.gripDragMoved(toScreen: p)
            return
        }
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

        // 伸縮のクリック確定モード: クリック=確定
        if controller.gripDrag != nil {
            controller.gripStickyClick()
            return
        }
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
        // ブロック化の基準点指示中(スナップ有効)
        if controller.pendingBlockifyName != nil {
            controller.blockifyBasePointClick()
            return
        }
        // 選択ツール: グリップ(伸縮ハンドル)を掴んだらドラッグ開始
        if event.clickCount == 1, let grip = controller.gripHit(atScreen: p) {
            controller.beginGripDrag(grip, atScreen: p)
            return
        }
        if event.clickCount == 2 {
            // 文字の上ならインライン再編集、それ以外は全体表示
            if !controller.beginTextEditAtCursor() {
                controller.fit(viewSize: bounds.size)
            }
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
        // 伸縮(グリップ)ドラッグの解放: 動いていれば確定、その場ならクリック確定モードへ
        if controller.gripDrag != nil {
            controller.gripDragReleased()
            return
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
        // delete / forward delete: 選択削除(グリップ編集中はバックスペース=数値訂正)
        if event.keyCode == 51 || event.keyCode == 117 {
            if controller.tools.kind == .select, !controller.editOp.isActive,
               controller.gripDrag == nil {
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
