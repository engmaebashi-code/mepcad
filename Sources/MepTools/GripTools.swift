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
        case dimExtension                  // 寸法: 補助線の端(2本同時に伸縮)
        case leaderTip                     // 引出線: 指示点(矢印先端)
        case leaderElbow                   // 引出線: 文字位置/バルーン中心
        case pipeVertex(index: Int)        // 配管: 折れ点(頂点ごと)
        case pipeSegment(index: Int)       // 配管: 区間の中点(区間ごと平行移動=伸縮)M7.5
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
            var grips = [Grip(entityID: entity.id, kind: .dimStart, point: a),
                         Grip(entityID: entity.id, kind: .dimEnd, point: b),
                         Grip(entityID: entity.id, kind: .dimLine, point: mid)]
            // 補助線の端(測定点側)。どちらを掴んでも2本同時に伸縮する
            for ext in layout.extLines {
                grips.append(Grip(entityID: entity.id, kind: .dimExtension, point: ext.0))
            }
            return grips
        case .leader(let tip, let elbow, _, _):
            return [Grip(entityID: entity.id, kind: .leaderTip, point: tip),
                    Grip(entityID: entity.id, kind: .leaderElbow, point: elbow)]
        case .pipe(let points, _):
            // 平面上で同じ位置の頂点(立管の上下端)は1つのグリップにまとめる
            var grips: [Grip] = []
            for (i, p) in points.enumerated() {
                if i > 0, points[i - 1].xy.distance(to: p.xy) <= PipeGeometry.planEpsilon { continue }
                grips.append(Grip(entityID: entity.id, kind: .pipeVertex(index: i), point: p.xy))
            }
            // 区間の中点(掴むとその区間だけ平行に動き、隣の区間が伸縮して吸収する)M7.5
            for i in 0..<(points.count - 1) {
                let a = points[i].xy, b = points[i + 1].xy
                guard a.distance(to: b) > PipeGeometry.planEpsilon else { continue }  // 立管は除く
                grips.append(Grip(entityID: entity.id, kind: .pipeSegment(index: i),
                                  point: Vec2((a.x + b.x) / 2, (a.y + b.y) / 2)))
            }
            return grips
        }
    }

    /// グリップをワールド点pへ動かした結果のエンティティ(idは維持)。
    /// 組合せが不正・退化する場合は元のまま返す。
    /// - preserveAngles: 配管の頂点を動かすとき、継手の角度を保つ「伸縮」にする(M7.1)。
    ///   falseなら頂点だけが自由に動く(従来の挙動)
    public static func apply(_ kind: Grip.Kind, to entity: Entity, at p: Vec2,
                             preserveAngles: Bool = true) -> Entity {
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
        case (.dimExtension, .dimension(let a, let b, let lp, let angle, var attrs)):
            // 補助線の長さ=寸法線からカーソルまでの垂直距離(2本同時に変わる)。
            // 測定点の近くまで引っ張ったら「測定点まで」モードに戻す
            let u = Vec2(cos(angle), sin(angle))
            let n = Vec2(-u.y, u.x)
            let len = abs((p.x - lp.x) * n.x + (p.y - lp.y) * n.y)
            let da = abs((a.x - lp.x) * n.x + (a.y - lp.y) * n.y)
            let db = abs((b.x - lp.x) * n.x + (b.y - lp.y) * n.y)
            // 近い方の測定点距離を閾値にする: どちらのグリップを掴んでいても
            // 測定点まで引っ張れば「測定点まで」に戻せる(各線は自分の測定点で頭打ち)
            if len >= min(da, db) - attrs.extensionGap {
                attrs.extensionLength = nil
            } else {
                // ドラッグでは0(補助線消滅=グリップも消える)にはしない。
                // 「なし」にしたいときはプロパティの選択肢から
                attrs.extensionLength = max(len, attrs.extensionGap * 0.5)
            }
            copy.kind = .dimension(a: a, b: b, linePoint: lp, angle: angle, attrs: attrs)
        case (.leaderTip, .leader(_, let elbow, let content, let attrs)):
            guard p.distance(to: elbow) > 1e-9 else { return entity }
            copy.kind = .leader(tip: p, elbow: elbow, content: content, attrs: attrs)
        case (.leaderElbow, .leader(let tip, _, let content, let attrs)):
            guard p.distance(to: tip) > 1e-9 else { return entity }
            copy.kind = .leader(tip: tip, elbow: p, content: content, attrs: attrs)
        case (.pipeSegment(let index), .pipe(let points, let attrs)):
            // 区間の伸縮: 掴んだ区間を平行に動かし、隣の区間が伸び縮みして吸収する。
            // 掴んだ区間の向こう側は1つも動かない(他の配管の位置に影響しない)M7.5
            guard index >= 0, index + 1 < points.count else { return entity }
            let mid = Vec2((points[index].x + points[index + 1].x) / 2,
                           (points[index].y + points[index + 1].y) / 2)
            copy.kind = .pipe(points: PipeGeometry.stretchSegment(points: points, index: index,
                                                                 by: p - mid),
                              attrs: attrs)
        case (.pipeVertex(let index), .pipe(let points, let attrs)):
            guard points.indices.contains(index) else { return entity }
            if preserveAngles {
                // 伸縮: 継手の角度(90°/45°)を保ったまま脚を伸び縮みさせる(M7.1)
                copy.kind = .pipe(points: PipeGeometry.stretch(points: points, index: index, to: p),
                                  attrs: attrs)
                break
            }
            var moved = points
            // 立管の上下端(平面上同一点の連続頂点)は一緒に動かす。高さは維持
            let anchor = points[index].xy
            var j = index
            while j < points.count, points[j].xy.distance(to: anchor) <= PipeGeometry.planEpsilon {
                moved[j] = Vec3(p, z: points[j].z)
                j += 1
            }
            copy.kind = .pipe(points: moved, attrs: attrs)
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
