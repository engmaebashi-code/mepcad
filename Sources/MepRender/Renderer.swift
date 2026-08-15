import Foundation
import MepCore
#if canImport(CoreGraphics)
import CoreGraphics
#if canImport(CoreText)
import CoreText
#endif

/// 描画スタイル設定(背景色に応じて自動調整)
public struct RenderTheme {
    public var isDark: Bool
    public var background: CGColor
    public var gridMinor: CGColor
    public var gridMajor: CGColor
    public var defaultStroke: CGColor
    /// 用紙枠の線色
    public var paperFrame: CGColor
    /// 色番号→色(スタイルテーブル。環境設定で編集可能にする予定)
    public var palette: [CGColor]

    public static func light() -> RenderTheme {
        RenderTheme(
            isDark: false,
            background: CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1),
            gridMinor: CGColor(gray: 0, alpha: 0.06),
            gridMajor: CGColor(gray: 0, alpha: 0.12),
            defaultStroke: CGColor(gray: 0.1, alpha: 1),
            paperFrame: CGColor(red: 0.45, green: 0.52, blue: 0.65, alpha: 0.75),
            palette: [
                CGColor(gray: 0.1, alpha: 1),                                  // 0 黒
                CGColor(red: 0.82, green: 0.20, blue: 0.17, alpha: 1),          // 1 赤(冷温水往)
                CGColor(red: 0.00, green: 0.33, blue: 0.75, alpha: 1),          // 2 青(冷温水還/衛生)
                CGColor(red: 0.24, green: 0.55, blue: 0.25, alpha: 1),          // 3 緑(ダクト)
                CGColor(red: 0.91, green: 0.63, blue: 0.00, alpha: 1),          // 4 橙
                CGColor(red: 0.56, green: 0.27, blue: 0.68, alpha: 1),          // 5 紫
                CGColor(red: 0.00, green: 0.60, blue: 0.60, alpha: 1),          // 6 青緑
                CGColor(red: 0.85, green: 0.11, blue: 0.62, alpha: 1),          // 7 マゼンタ
                CGColor(gray: 0.55, alpha: 1),                                  // 8 グレー(下敷き)
                CGColor(red: 0.55, green: 0.58, blue: 0.75, alpha: 1),          // 9 薄紫(補助線)
            ]
        )
    }

    public static func dark() -> RenderTheme {
        var t = RenderTheme.light()
        t.isDark = true
        t.background = CGColor(red: 0.11, green: 0.12, blue: 0.13, alpha: 1)
        t.gridMinor = CGColor(gray: 1, alpha: 0.05)
        t.gridMajor = CGColor(gray: 1, alpha: 0.10)
        t.defaultStroke = CGColor(gray: 0.92, alpha: 1)
        t.paperFrame = CGColor(red: 0.55, green: 0.62, blue: 0.78, alpha: 0.7)
        t.palette[0] = CGColor(gray: 0.92, alpha: 1)
        return t
    }

    public func color(forIndex index: Int) -> CGColor {
        guard index >= 0 && index < palette.count else { return defaultStroke }
        return palette[index]
    }
}

/// ドキュメントをCGContextへ描画する。
/// M1は毎回全描画。レイヤ別CGLayerキャッシュはM2以降(実装構成設計書§3)。
public struct Renderer {
    public var theme: RenderTheme

    public init(theme: RenderTheme = .light()) {
        self.theme = theme
    }

    public func draw(document: Document,
                     transform: ViewTransform,
                     viewSize: CGSize,
                     gridSpacing: Double,   // mm
                     in ctx: CGContext) {
        draw(entities: document.entities, groups: document.groups,
             transform: transform, viewSize: viewSize, gridSpacing: gridSpacing,
             showAuxiliary: document.showAuxiliary,
             blockDefinitions: document.blockDefinitions,
             paperFrame: document.paperFrame, in: ctx)
    }

    /// スナップショット(値コピー)ベースの描画。バックグラウンドスレッドでのキャッシュ生成に使う。
    /// 表示判定はグループ×レイヤの実効状態(両方表示のとき見える)+補助線表示設定。
    public func draw(entities: [Entity], groups: [LayerGroup],
                     transform: ViewTransform,
                     viewSize: CGSize,
                     gridSpacing: Double,
                     showAuxiliary: Bool = true,
                     blockDefinitions: [BlockDefinition] = [],
                     paperFrame: BBox? = nil,
                     in ctx: CGContext) {
        ctx.setFillColor(theme.background)
        ctx.fill(CGRect(origin: .zero, size: viewSize))
        drawGrid(transform: transform, viewSize: viewSize, spacing: gridSpacing, in: ctx)
        drawPaperFrame(paperFrame, transform: transform, in: ctx)

        let defs = Dictionary(uniqueKeysWithValues: blockDefinitions.map { ($0.id, $0) })
        for entity in entities {
            let g = groups[entity.layer.group]
            guard g.isVisible else { continue }
            let layer = g.layers[entity.layer.layer]
            guard layer.isVisible else { continue }
            if !showAuxiliary, entity.isAuxiliary { continue }
            drawEntity(entity, layer: layer, transform: transform, definitions: defs, in: ctx)
        }
    }

    // MARK: - 用紙枠(M4.10)

    /// 作図範囲=用紙の枠(実寸mm。用紙中心=原点)
    private func drawPaperFrame(_ frame: BBox?, transform: ViewTransform, in ctx: CGContext) {
        guard let frame, !frame.isEmpty else { return }
        let p0 = transform.toScreen(Vec2(frame.minX, frame.minY))
        let p1 = transform.toScreen(Vec2(frame.maxX, frame.maxY))
        let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                          width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        ctx.setStrokeColor(theme.paperFrame)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.stroke(rect)
    }

    // MARK: - グリッド

    private func drawGrid(transform: ViewTransform, viewSize: CGSize, spacing: Double, in ctx: CGContext) {
        guard spacing > 0 else { return }  // 0 = グリッド非表示
        let pxPerCell = spacing * transform.scale
        guard pxPerCell >= 4 else { return }  // 細かすぎたら描かない(自動間引き)

        let topLeft = transform.toWorld(Vec2(0, 0))
        let bottomRight = transform.toWorld(Vec2(Double(viewSize.width), Double(viewSize.height)))

        let startX = (topLeft.x / spacing).rounded(.down) * spacing
        let endX = bottomRight.x
        let startY = (bottomRight.y / spacing).rounded(.down) * spacing
        let endY = topLeft.y

        ctx.setLineWidth(1)
        var x = startX
        var index = Int((startX / spacing).rounded())
        while x <= endX {
            let sx = transform.toScreen(Vec2(x, 0)).x
            ctx.setStrokeColor(index % 4 == 0 ? theme.gridMajor : theme.gridMinor)
            ctx.move(to: CGPoint(x: sx, y: 0))
            ctx.addLine(to: CGPoint(x: sx, y: Double(viewSize.height)))
            ctx.strokePath()
            x += spacing
            index += 1
        }
        var y = startY
        index = Int((startY / spacing).rounded())
        while y <= endY {
            let sy = transform.toScreen(Vec2(0, y)).y
            ctx.setStrokeColor(index % 4 == 0 ? theme.gridMajor : theme.gridMinor)
            ctx.move(to: CGPoint(x: 0, y: sy))
            ctx.addLine(to: CGPoint(x: Double(viewSize.width), y: sy))
            ctx.strokePath()
            y += spacing
            index += 1
        }
    }

    // MARK: - エンティティ

    private func drawEntity(_ entity: Entity, layer: Layer, transform: ViewTransform,
                            definitions: [UUID: BlockDefinition] = [:], in ctx: CGContext) {
        let colorIndex = entity.style.colorIndex ?? layer.defaultColorIndex
        let weight = entity.style.lineWeight ?? layer.defaultLineWeight
        let lineType = entity.style.lineType ?? layer.defaultLineType
        ctx.setStrokeColor(theme.color(forIndex: colorIndex))
        // 線幅は紙面mm→pxの簡易換算(最低1px)
        ctx.setLineWidth(max(1, weight * transform.scale * 10))
        // 線種: Jw_cad標準9種(LineTypeTable)。パターン定義はMepCoreと共有
        let dash = LineTypeTable.dashPattern(lineType).map { CGFloat($0) }
        ctx.setLineDash(phase: 0, lengths: dash)
        defer { ctx.setLineDash(phase: 0, lengths: []) }

        switch entity.kind {
        case .line(let a, let b):
            let sa = transform.toScreen(a)
            let sb = transform.toScreen(b)
            ctx.move(to: CGPoint(x: sa.x, y: sa.y))
            ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
            ctx.strokePath()

        case .circle(let center, let radius):
            let sc = transform.toScreen(center)
            let r = radius * transform.scale
            ctx.strokeEllipse(in: CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2))

        case .arc(let center, let radius, let startAngle, let endAngle):
            let sc = transform.toScreen(center)
            let r = radius * transform.scale
            // スクリーンはY反転しているため角度符号を反転
            ctx.addArc(center: CGPoint(x: sc.x, y: sc.y), radius: r,
                       startAngle: -startAngle, endAngle: -endAngle, clockwise: true)
            ctx.strokePath()

        case .text(let position, let content, let height, let angle):
            drawText(content, at: position, height: height, angle: angle,
                     colorIndex: colorIndex, transform: transform, in: ctx)

        case .point(let position):
            // 点は画面上の固定サイズ(小さな塗り丸)で描く
            let sp = transform.toScreen(position)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(theme.color(forIndex: colorIndex))
            let r: CGFloat = 2.5
            ctx.fillEllipse(in: CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2))

        case .blockRef(let defID, let insert, let rotation, let scale, let mirrored, _):
            // 定義を実体化して描画(中身はblockRefを含まない=再帰しない)。
            // 配置側のスタイル(色・線種・太さ)は上書きとして中身へ伝播する(M4.8.1)
            guard let def = definitions[defID] else { break }
            ctx.setLineDash(phase: 0, lengths: [])
            for sub in def.instantiate(insert: insert, rotation: rotation, scale: scale,
                                       mirrored: mirrored, layer: entity.layer,
                                       overrideStyle: entity.style) {
                drawEntity(sub, layer: layer, transform: transform, in: ctx)
            }

        case .hatch(let boundary, let pattern):
            guard boundary.count >= 3 else { break }
            if pattern.kind == .solid {
                // 塗りつぶし(JWWソリッド・DXF SOLID/HATCH相当)
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setFillColor(theme.color(forIndex: colorIndex))
                let first = transform.toScreen(boundary[0])
                ctx.move(to: CGPoint(x: first.x, y: first.y))
                for p in boundary.dropFirst() {
                    let sp = transform.toScreen(p)
                    ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
                }
                ctx.closePath()
                ctx.fillPath(using: .evenOdd)
            } else {
                // パターン線(境界クリップ済み)。線種・太さは属性に従う
                for stroke in HatchGeometry.strokes(boundary: boundary, pattern: pattern) {
                    let sa = transform.toScreen(stroke.a)
                    let sb = transform.toScreen(stroke.b)
                    ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                    ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
                }
                ctx.strokePath()
            }

        case .dimension:
            guard let layout = DimensionGeometry.layout(of: entity) else { break }
            // 寸法線・補助線・矢印は線種によらず実線で描く(CADの慣例)
            ctx.setLineDash(phase: 0, lengths: [])
            for seg in layout.hitSegments + layout.arrowStrokes {
                let sa = transform.toScreen(seg.0)
                let sb = transform.toScreen(seg.1)
                ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
            }
            ctx.strokePath()
            // 黒丸(実点)は最低でも見えるサイズを確保
            if !layout.dotCenters.isEmpty {
                ctx.setFillColor(theme.color(forIndex: colorIndex))
                let r = max(layout.dotRadius * transform.scale, 1.5)
                for c in layout.dotCenters {
                    let sc = transform.toScreen(c)
                    ctx.fillEllipse(in: CGRect(x: sc.x - r, y: sc.y - r,
                                               width: r * 2, height: r * 2))
                }
            }
            drawText(layout.textContent, at: layout.textPosition,
                     height: layout.textHeight, angle: layout.textAngle,
                     colorIndex: colorIndex, transform: transform, in: ctx)

        case .leader:
            guard let layout = LeaderGeometry.layout(of: entity) else { break }
            // 引出線・矢印・バルーン枠・行区切り線は実線で描く
            ctx.setLineDash(phase: 0, lengths: [])
            for seg in layout.segments + layout.arrowStrokes + layout.dividers {
                let sa = transform.toScreen(seg.0)
                let sb = transform.toScreen(seg.1)
                ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
            }
            ctx.strokePath()
            for e in layout.ellipses {
                let sc = transform.toScreen(e.center)
                let rx = e.rx * transform.scale
                let ry = e.ry * transform.scale
                ctx.strokeEllipse(in: CGRect(x: sc.x - rx, y: sc.y - ry,
                                             width: rx * 2, height: ry * 2))
            }
            for t in layout.texts {
                drawText(t.content, at: t.position,
                         height: layout.textHeight, angle: 0,
                         colorIndex: colorIndex, transform: transform, in: ctx)
            }
        }
    }

    // MARK: - 輪郭のみの描画(選択ハイライト・移動/複写ゴースト用。M4)

    /// エンティティ群を指定色・指定線幅の輪郭だけで描く(背景は塗らない)。
    /// オーバーレイでの選択ハイライトとゴーストプレビューに使う。
    public func drawOutlines(_ entities: [Entity],
                             transform: ViewTransform,
                             color: CGColor,
                             lineWidth: CGFloat,
                             blockDefinitions: [BlockDefinition] = [],
                             in ctx: CGContext) {
        let defs = Dictionary(uniqueKeysWithValues: blockDefinitions.map { ($0.id, $0) })
        // blockRefは中身に展開してから輪郭描画(1段のみ・再帰なし)
        var flat: [Entity] = []
        flat.reserveCapacity(entities.count)
        for e in entities {
            if case .blockRef(let defID, let insert, let rotation, let scale, let mirrored, _) = e.kind,
               let def = defs[defID] {
                flat.append(contentsOf: def.instantiate(insert: insert, rotation: rotation,
                                                        scale: scale, mirrored: mirrored,
                                                        layer: e.layer))
            } else {
                flat.append(e)
            }
        }
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        for entity in flat {
            switch entity.kind {
            case .line(let a, let b):
                let sa = transform.toScreen(a)
                let sb = transform.toScreen(b)
                ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
                ctx.strokePath()
            case .circle(let center, let radius):
                let sc = transform.toScreen(center)
                let r = radius * transform.scale
                ctx.strokeEllipse(in: CGRect(x: sc.x - r, y: sc.y - r, width: r * 2, height: r * 2))
            case .arc(let center, let radius, let startAngle, let endAngle):
                let sc = transform.toScreen(center)
                let r = radius * transform.scale
                ctx.addArc(center: CGPoint(x: sc.x, y: sc.y), radius: r,
                           startAngle: -startAngle, endAngle: -endAngle, clockwise: true)
                ctx.strokePath()
            case .text:
                // 文字は回転を考慮した概算グリフボックスで示す(縦文字も正しい向きの枠)
                guard let corners = entity.textGlyphCorners else { break }
                let first = transform.toScreen(corners[0])
                ctx.move(to: CGPoint(x: first.x, y: first.y))
                for corner in corners.dropFirst() {
                    let sp = transform.toScreen(corner)
                    ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
                }
                ctx.closePath()
                ctx.strokePath()
            case .point(let position):
                let sp = transform.toScreen(position)
                let r: CGFloat = 4
                ctx.strokeEllipse(in: CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2))
            case .blockRef(_, _, _, _, _, let cached):
                // 定義が引けない場合のフォールバック(通常はflat展開済みでここへ来ない)
                if !cached.isEmpty {
                    let p0 = transform.toScreen(Vec2(cached.minX, cached.minY))
                    let p1 = transform.toScreen(Vec2(cached.maxX, cached.maxY))
                    ctx.stroke(CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                      width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)))
                }
            case .hatch(let boundary, _):
                // 輪郭=境界ポリゴン
                guard boundary.count >= 2 else { break }
                let first = transform.toScreen(boundary[0])
                ctx.move(to: CGPoint(x: first.x, y: first.y))
                for p in boundary.dropFirst() {
                    let sp = transform.toScreen(p)
                    ctx.addLine(to: CGPoint(x: sp.x, y: sp.y))
                }
                ctx.closePath()
                ctx.strokePath()
            case .dimension:
                // 輪郭=寸法線+補助線(ゴースト・選択ハイライト用)
                guard let layout = DimensionGeometry.layout(of: entity) else { break }
                for seg in layout.hitSegments + layout.arrowStrokes {
                    let sa = transform.toScreen(seg.0)
                    let sb = transform.toScreen(seg.1)
                    ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                    ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
                }
                ctx.strokePath()
            case .leader:
                // 輪郭=引出線+バルーン枠
                guard let layout = LeaderGeometry.layout(of: entity) else { break }
                for seg in layout.segments + layout.arrowStrokes {
                    let sa = transform.toScreen(seg.0)
                    let sb = transform.toScreen(seg.1)
                    ctx.move(to: CGPoint(x: sa.x, y: sa.y))
                    ctx.addLine(to: CGPoint(x: sb.x, y: sb.y))
                }
                ctx.strokePath()
                for e in layout.ellipses {
                    let sc = transform.toScreen(e.center)
                    let rx = e.rx * transform.scale
                    let ry = e.ry * transform.scale
                    ctx.strokeEllipse(in: CGRect(x: sc.x - rx, y: sc.y - ry,
                                                 width: rx * 2, height: ry * 2))
                }
            }
        }
        ctx.restoreGState()
    }

    private func drawText(_ string: String, at position: Vec2, height: Double, angle: Double,
                          colorIndex: Int, transform: ViewTransform, in ctx: CGContext) {
        #if canImport(CoreText)
        let sp = transform.toScreen(position)
        // 文字高さは実寸mm(JWW取込時に紙面mm×グループ縮尺で変換済み)
        let fontSize = height * transform.scale
        guard fontSize >= 3 else { return }  // 読めないサイズは描かない(ズームアウト時の性能確保)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: theme.color(forIndex: colorIndex),
        ]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.translateBy(x: sp.x, y: sp.y)
        ctx.scaleBy(x: 1, y: -1)  // CoreTextはY上向きなので反転を戻す
        if angle != 0 { ctx.rotate(by: angle) }
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
        #endif
    }
}
#endif
