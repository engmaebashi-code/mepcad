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
}

/// M1のエンティティ。設備エンティティ(PipeRun等)はPhase 2で追加する。
/// enumにすることでCodable・網羅的switchが単純になる(種類追加時はコンパイラが漏れを検出)。
public enum EntityKind: Equatable, Codable, Sendable {
    case line(a: Vec2, b: Vec2)
    case circle(center: Vec2, radius: Double)
    case arc(center: Vec2, radius: Double, startAngle: Double, endAngle: Double)  // rad, CCW
    case text(position: Vec2, content: String, height: Double, angle: Double)     // height=紙面mm
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
        case .text(let p, _, _, _):
            box.union(point: p)
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
        }
    }
}
