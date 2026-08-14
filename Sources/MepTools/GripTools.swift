import Foundation
import MepCore

// MARK: - 伸縮(グリップ編集)M4.9
//
// 選択中の図形に小さな四角(グリップ)を表示し、掴んでドラッグすると
// 端点・半径・位置がカーソルに追随する。UI非依存のロジック部(テスト対象)。
// - 線: 両端点(反対側の端点は固定。数値⏎=固定端からの長さ)
// - 円弧: 両端(半径は維持し角度が変わる)
// - 円: 四半点(半径変更。数値⏎=半径)
// - 文字・点・ブロック配置: 位置(スナップを効かせた微調整移動)

/// グリップ1個(どのエンティティの・どの部位か・現在のワールド座標)
public struct Grip: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case lineStart
        case lineEnd
        case arcStart
        case arcEnd
        case circleRadius(quadrant: Int)   // 0=+X 1=+Y 2=-X 3=-Y の四半点
        case position                      // 文字・点・ブロック配置の位置
        case dimStart                      // 寸法: 測定点a
        case dimEnd                        // 寸法: 測定点b
        case dimLine                       // 寸法: 寸法線の位置(引出し量の調整)
    }

    public let entityID: EntityID
    public let kind: Kind
    public let point: Vec2

    public init(entityID: EntityID, kind: Kind, point: Vec2) {
        self.entityID = entityID
        self.kind = kind
        self.point = point
    }
}

public enum GripEngine {

    /// グリップを表示する選択数の上限(多すぎると四角だらけになるため)
    public static let selectionLimit = 10

    /// エンティティのグリップ一覧
    public static func grips(for entity: Entity) -> [Grip] {
        switch entity.kind {
        case .line(let a, let b):
            return [Grip(entityID: entity.id, kind: .lineStart, point: a),
                    Grip(entityID: entity.id, kind: .lineEnd, point: b)]
        case .circle(let c, let r):
            return (0..<4).map { q in
                let angle = Double(q) * .pi / 2
                return Grip(entityID: entity.id, kind: .circleRadius(quadrant: q),
                            point: Vec2(c.x + r * cos(angle), c.y + r * sin(angle)))
            }
        case .arc(let c, let r, let sa, let ea):
            return [Grip(entityID: entity.id, kind: .arcStart,
                         point: Vec2(c.x + r * cos(sa), c.y + r * sin(sa))),
                    Grip(entityID: entity.id, kind: .arcEnd,
                         point: Vec2(c.x + r * cos(ea), c.y + r * sin(ea)))]
        case .text(let p, _, _, _):
            return [Grip(entityID: entity.id, kind: .position, point: p)]
        case .point(let p):
            return [Grip(entityID: entity.id, kind: .position, point: p)]
        case .blockRef(_, let insert, _, _, _, _):
            return [Grip(entityID: entity.id, kind: .position, point: insert)]
        case .hatch(let boundary, _):
            // v1は位置グリップのみ(先頭頂点を掴んで全体移動。頂点伸縮は次回)
            guard let first = boundary.first else { return [] }
            return [Grip(entityID: entity.id, kind: .position, point: first)]
        case .dimension(let a, let b, _, _, _):
            guard let layout = DimensionGeometry.layout(of: entity) else { return [] }
            let mid = Vec2((layout.dimLine.0.x + layout.dimLine.1.x) / 2,
                           (layout.dimLine.0.y + layout.dimLine.1.y) / 2)
            return [Grip(entityID: entity.id, kind: .dimStart, point: a),
                    Grip(entityID: entity.id, kind: .dimEnd, point: b),
                    Grip(entityID: entity.id, kind: .dimLine, point: mid)]
        }
    }

    /// グリップをワールド点pへ動かした結果のエンティティ(idは維持)。
    /// 組合せが不正・退化する場合は元のまま返す
    public static func apply(_ kind: Grip.Kind, to entity: Entity, at p: Vec2) -> Entity {
        var copy = entity
        switch (kind, entity.kind) {
        case (.lineStart, .line(_, let b)):
            guard p.distance(to: b) > 1e-9 else { return entity }
            copy.kind = .line(a: p, b: b)
        case (.lineEnd, .line(let a, _)):
            guard p.distance(to: a) > 1e-9 else { return entity }
            copy.kind = .line(a: a, b: p)
        case (.circleRadius, .circle(let c, _)):
            let r = c.distance(to: p)
            guard r > 1e-9 else { return entity }
            copy.kind = .circle(center: c, radius: r)
        case (.arcStart, .arc(let c, let r, _, let ea)):
            let d = p - c
            guard d.length > 1e-9 else { return entity }
            copy.kind = .arc(center: c, radius: r, startAngle: atan2(d.y, d.x), endAngle: ea)
        case (.arcEnd, .arc(let c, let r, let sa, _)):
            let d = p - c
            guard d.length > 1e-9 else { return entity }
            copy.kind = .arc(center: c, radius: r, startAngle: sa, endAngle: atan2(d.y, d.x))
        case (.position, _):
            guard let anchor = anchorPoint(of: entity) else { return entity }
            return entity.translated(by: p - anchor)
        case (.dimStart, .dimension(_, let b, let lp, let angle, let attrs)):
            guard p.distance(to: b) > 1e-9 else { return entity }
            copy.kind = .dimension(a: p, b: b, linePoint: lp, angle: angle, attrs: attrs)
        case (.dimEnd, .dimension(let a, _, let lp, let angle, let attrs)):
            guard p.distance(to: a) > 1e-9 else { return entity }
            copy.kind = .dimension(a: a, b: p, linePoint: lp, angle: angle, attrs: attrs)
        case (.dimLine, .dimension(let a, let b, _, let angle, let attrs)):
            // 寸法線がpを通るように動かす(方向・測定点は不変=引出し量の調整)
            copy.kind = .dimension(a: a, b: b, linePoint: p, angle: angle, attrs: attrs)
        default:
            return entity
        }
        return copy
    }

    /// 位置グリップの現在点(文字・点・ブロック配置)
    public static func anchorPoint(of entity: Entity) -> Vec2? {
        switch entity.kind {
        case .text(let p, _, _, _): return p
        case .point(let p): return p
        case .blockRef(_, let insert, _, _, _, _): return insert
        case .hatch(let boundary, _): return boundary.first
        default: return nil
        }
    }

    /// 数値入力の基準になる「固定点」。
    /// 線=反対側の端点(数値⏎=固定端からの長さ)、円=中心(数値⏎=半径)。
    /// それ以外はnil(数値入力なし)
    public static func fixedPoint(for kind: Grip.Kind, of entity: Entity) -> Vec2? {
        switch (kind, entity.kind) {
        case (.lineStart, .line(_, let b)): return b
        case (.lineEnd, .line(let a, _)): return a
        case (.circleRadius, .circle(let c, _)): return c
        default: return nil
        }
    }

    /// 角度拘束を効かせられるグリップか(線の端点のみ。固定端からの方向を丸める)
    public static func supportsAngleConstraint(_ kind: Grip.Kind) -> Bool {
        kind == .lineStart || kind == .lineEnd
    }
}
