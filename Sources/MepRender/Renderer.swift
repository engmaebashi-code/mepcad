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
    /// 色番号→色(スタイルテーブル。環境設定で編集可能にする予定)
    public var palette: [CGColor]

    public static func light() -> RenderTheme {
        RenderTheme(
            isDark: false,
            background: CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1),
            gridMinor: CGColor(gray: 0, alpha: 0.06),
            gridMajor: CGColor(gray: 0, alpha: 0.12),
            defaultStroke: CGColor(gray: 0.1, alpha: 1),
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
        // 背景
        ctx.setFillColor(theme.background)
        ctx.fill(CGRect(origin: .zero, size: viewSize))

        drawGrid(transform: transform, viewSize: viewSize, spacing: gridSpacing, in: ctx)
        drawEntities(document: document, transform: transform, in: ctx)
    }

    // MARK: - グリッド

    private func drawGrid(transform: ViewTransform, viewSize: CGSize, spacing: Double, in ctx: CGContext) {
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

    private func drawEntities(document: Document, transform: ViewTransform, in ctx: CGContext) {
        for entity in document.entities {
            guard let layer = document.layer(id: entity.layerID), layer.isVisible else { continue }

            let colorIndex = entity.style.colorIndex ?? layer.defaultColorIndex
            let weight = entity.style.lineWeight ?? layer.defaultLineWeight
            ctx.setStrokeColor(theme.color(forIndex: colorIndex))
            // 線幅は紙面mm→pxの簡易換算(最低1px)
            ctx.setLineWidth(max(1, weight * transform.scale * 10))

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
            }
        }
    }

    private func drawText(_ string: String, at position: Vec2, height: Double, angle: Double,
                          colorIndex: Int, transform: ViewTransform, in ctx: CGContext) {
        #if canImport(CoreText)
        let sp = transform.toScreen(position)
        // 紙面mm×縮尺→ワールドmm換算はM2で。M1は高さmm×スケール×10で近似表示
        let fontSize = max(6, height * transform.scale * 10)
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
