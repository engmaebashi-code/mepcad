import Foundation

public typealias EntityID = UUID

/// 図形スタイル(色・線種・太さ)。値がnilなら「レイヤ既定に従う」
public struct Style: Equatable, Codable, Sendable {
    public var colorIndex: Int?   // 色番号(スタイルテーブル参照)。nil=byLayer
    public var lineType: Int?     // 0=実線 1=破線 2=一点鎖線 …。nil=byLayer
    public var lineWeight: Double?  // mm。nil=byLayer

    public init(colorIndex: Int? = nil, lineType: Int? = nil, lineWeight: Double? = nil) {
        self.colorIndex = colorIndex
        self.lineType = lineType
        self.lineWeight = lineWeight
    }

    public static let byLayer = Style()

    /// selfの非nil項目でbaseを上書きした結果を返す。
    /// ブロック配置(blockRef)のスタイル上書きに使う: 配置側で色や線種を
    /// 指定していればそれが優先され、nilの項目は中身(定義メンバー)の値が残る。
    public func overriding(_ base: Style) -> Style {
        Style(colorIndex: colorIndex ?? base.colorIndex,
              lineType: lineType ?? base.lineType,
              lineWeight: lineWeight ?? base.lineWeight)
    }
}

/// M1のエンティティ。設備エンティティ(PipeRun等)はPhase 2で追加する。
/// enumにすることでCodable・網羅的switchが単純になる(種類追加時はコンパイラが漏れを検出)。
public enum EntityKind: Equatable, Codable, Sendable {
    case line(a: Vec2, b: Vec2)
    case circle(center: Vec2, radius: Double)
    case arc(center: Vec2, radius: Double, startAngle: Double, endAngle: Double)  // rad, CCW
    case text(position: Vec2, content: String, height: Double, angle: Double)     // height=紙面mm
    case point(position: Vec2)                                                    // 点(画面上は固定サイズで描画)
    /// ブロック配置(定義への参照)。cachedBoundsは配置時に計算し変換のたびに更新する
    /// (定義を引かずにbounds/ヒットテストできるようにするため)
    case blockRef(definitionID: UUID, insert: Vec2, rotation: Double, scale: Double,
                  mirrored: Bool, cachedBounds: BBox)
    /// 塗り・ハッチング(境界ポリゴン+パターン。M5.2)
    case hatch(boundary: [Vec2], pattern: HatchPattern)
}

public struct Entity: Identifiable, Equatable, Codable, Sendable {
    public let id: EntityID
    /// 所属レイヤ(グループ0-15 × レイヤ0-15。Jw_cad準拠)
    public var layer: LayerAddress
    public var style: Style
    public var kind: EntityKind

    public init(id: EntityID = EntityID(), layer: LayerAddress, style: Style = .byLayer, kind: EntityKind) {
        self.id = id
        self.layer = layer
        self.style = style
        self.kind = kind
    }

    public var bounds: BBox {
        var box = BBox.empty
        switch kind {
        case .line(let a, let b):
            box.union(point: a)
            box.union(point: b)
        case .circle(let c, let r), .arc(let c, let r, _, _):
            // 円弧は簡易的に全周のボックス(M1では十分)
            box.union(point: Vec2(c.x - r, c.y - r))
            box.union(point: Vec2(c.x + r, c.y + r))
        case .text(let p, let content, let height, let angle):
            // 文字の概算グリフボックス(M5.3.1)。
            // 以前は基準点1点だけだったため、選択エンジンの前段フィルタ
            // (bounds±許容距離)が文字本体のクリックを弾いてしまい、
            // 「文字が選択できない→プロパティの文字セクションが出ない」実害があった。
            let width = max(height * 0.6, Double(content.count) * height * 0.9)
            if abs(angle) < 1e-12 {
                box.union(point: p)
                box.union(point: Vec2(p.x + width, p.y + height))
            } else {
                let c = cos(angle)
                let s = sin(angle)
                for corner in [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)] {
                    box.union(point: Vec2(p.x + corner.x * c - corner.y * s,
                                          p.y + corner.x * s + corner.y * c))
                }
            }
        case .point(let p):
            box.union(point: p)
        case .blockRef(_, let insert, _, _, _, let cached):
            if cached.isEmpty {
                box.union(point: insert)
            } else {
                box.union(cached)
            }
        case .hatch(let boundary, _):
            for p in boundary { box.union(point: p) }
        }
        return box
    }

    /// スナップ候補点(端点・中心)
    public var snapPoints: [Vec2] {
        switch kind {
        case .line(let a, let b):
            return [a, b, Vec2((a.x + b.x) / 2, (a.y + b.y) / 2)]
        case .circle(let c, _):
            return [c]
        case .arc(let c, let r, let sa, let ea):
            return [c,
                    Vec2(c.x + r * cos(sa), c.y + r * sin(sa)),
                    Vec2(c.x + r * cos(ea), c.y + r * sin(ea))]
        case .text(let p, _, _, _):
            return [p]
        case .point(let p):
            return [p]
        case .blockRef(_, let insert, _, _, _, _):
            // 挿入点のみ(中身の端点等はSnapEngineが定義を実体化して索引する)
            return [insert]
        case .hatch(let boundary, _):
            return boundary
        }
    }
}
