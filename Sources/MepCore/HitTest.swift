import Foundation

/// 選択用のヒットテスト幾何(M4)。
/// カーソル点や選択矩形とエンティティの当たり判定を行う。UI非依存・ユニットテスト対象。
public enum HitGeometry {

    /// 点から線分への最近点(垂線の足。線分外なら近い方の端点)
    public static func closestPointOnSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Vec2 {
        let ab = b - a
        let lenSq = ab.x * ab.x + ab.y * ab.y
        guard lenSq > 1e-12 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lenSq))
        return Vec2(a.x + ab.x * t, a.y + ab.y * t)
    }

    /// 線分と軸平行矩形が交差するか(端点が中に入っている場合も交差扱い)
    public static func segmentIntersectsRect(_ a: Vec2, _ b: Vec2, _ rect: BBox) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        // 4辺との交差判定
        let corners = [Vec2(rect.minX, rect.minY), Vec2(rect.maxX, rect.minY),
                       Vec2(rect.maxX, rect.maxY), Vec2(rect.minX, rect.maxY)]
        for i in 0..<4 {
            if segmentsIntersect(a, b, corners[i], corners[(i + 1) % 4]) { return true }
        }
        return false
    }

    /// 線分同士が交差するか(接触含む)
    public static func segmentsIntersect(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ p4: Vec2) -> Bool {
        let d1 = p2 - p1
        let d2 = p4 - p3
        let denom = d1.x * d2.y - d1.y * d2.x
        guard abs(denom) > 1e-12 else { return false }
        let dp = p3 - p1
        let t = (dp.x * d2.y - dp.y * d2.x) / denom
        let u = (dp.x * d1.y - dp.y * d1.x) / denom
        let eps = 1e-9
        return t >= -eps && t <= 1 + eps && u >= -eps && u <= 1 + eps
    }

    /// 円弧上の角度を start→end(CCW)の範囲内か判定
    public static func angleInArc(_ angle: Double, start: Double, end: Double) -> Bool {
        func norm(_ a: Double) -> Double {
            var v = a.truncatingRemainder(dividingBy: 2 * .pi)
            if v < 0 { v += 2 * .pi }
            return v
        }
        let a = norm(angle - start)
        let span = norm(end - start)
        // span==0 は全周扱い
        return span < 1e-12 ? true : a <= span + 1e-9
    }

    /// 円弧を折れ線近似した点列(交差・内包判定用)
    public static func arcSamplePoints(center: Vec2, radius: Double,
                                       startAngle: Double, endAngle: Double,
                                       count: Int = 17) -> [Vec2] {
        func norm(_ a: Double) -> Double {
            var v = a.truncatingRemainder(dividingBy: 2 * .pi)
            if v < 0 { v += 2 * .pi }
            return v
        }
        var span = norm(endAngle - startAngle)
        if span < 1e-12 { span = 2 * .pi }
        return (0..<count).map { i in
            let t = startAngle + span * Double(i) / Double(count - 1)
            return Vec2(center.x + radius * cos(t), center.y + radius * sin(t))
        }
    }
}

extension Entity {

    /// 文字の概算バウンディングボックス(baseline左端基準・角度は無視した概算)
    public var approximateTextBounds: BBox? {
        guard case .text(let p, let content, let height, _) = kind else { return nil }
        let width = max(height * 0.6, Double(content.count) * height * 0.9)
        return BBox(minX: p.x, minY: p.y, maxX: p.x + width, maxY: p.y + height)
    }

    /// 点からエンティティ(の輪郭)への距離。選択のヒットテストに使う
    public func hitDistance(to p: Vec2) -> Double {
        switch kind {
        case .line(let a, let b):
            return HitGeometry.closestPointOnSegment(p, a, b).distance(to: p)

        case .circle(let c, let r):
            return abs(c.distance(to: p) - r)

        case .arc(let c, let r, let sa, let ea):
            let angle = atan2(p.y - c.y, p.x - c.x)
            if HitGeometry.angleInArc(angle, start: sa, end: ea) {
                return abs(c.distance(to: p) - r)
            }
            // 範囲外は両端点への距離
            let pa = Vec2(c.x + r * cos(sa), c.y + r * sin(sa))
            let pb = Vec2(c.x + r * cos(ea), c.y + r * sin(ea))
            return min(pa.distance(to: p), pb.distance(to: p))

        case .text:
            guard let box = approximateTextBounds else { return .infinity }
            if box.contains(p) { return 0 }
            let dx = max(box.minX - p.x, 0, p.x - box.maxX)
            let dy = max(box.minY - p.y, 0, p.y - box.maxY)
            return (dx * dx + dy * dy).squareRoot()

        case .point(let pos):
            return pos.distance(to: p)
        }
    }

    /// 矩形に完全内包されるか(窓選択=内包モード)
    public func isContained(in rect: BBox) -> Bool {
        switch kind {
        case .line(let a, let b):
            return rect.contains(a) && rect.contains(b)
        case .circle(let c, let r):
            return rect.contains(Vec2(c.x - r, c.y - r)) && rect.contains(Vec2(c.x + r, c.y + r))
        case .arc(let c, let r, let sa, let ea):
            return HitGeometry.arcSamplePoints(center: c, radius: r, startAngle: sa, endAngle: ea)
                .allSatisfy { rect.contains($0) }
        case .text:
            guard let box = approximateTextBounds else { return false }
            return rect.contains(Vec2(box.minX, box.minY)) && rect.contains(Vec2(box.maxX, box.maxY))
        case .point(let pos):
            return rect.contains(pos)
        }
    }

    /// 矩形と交差するか(交差選択モード。内包も交差に含む)
    public func intersects(rect: BBox) -> Bool {
        switch kind {
        case .line(let a, let b):
            return HitGeometry.segmentIntersectsRect(a, b, rect)

        case .circle(let c, let r):
            // 矩形の最近点が半径以内 かつ 矩形が円の内側に完全に入っていない
            let nx = min(max(c.x, rect.minX), rect.maxX)
            let ny = min(max(c.y, rect.minY), rect.maxY)
            guard Vec2(nx, ny).distance(to: c) <= r else { return false }
            let fx = max(abs(rect.minX - c.x), abs(rect.maxX - c.x))
            let fy = max(abs(rect.minY - c.y), abs(rect.maxY - c.y))
            let farthest = (fx * fx + fy * fy).squareRoot()
            return farthest >= r

        case .arc(let c, let r, let sa, let ea):
            let pts = HitGeometry.arcSamplePoints(center: c, radius: r, startAngle: sa, endAngle: ea)
            if pts.contains(where: { rect.contains($0) }) { return true }
            for i in 0..<(pts.count - 1) {
                if HitGeometry.segmentIntersectsRect(pts[i], pts[i + 1], rect) { return true }
            }
            return false

        case .text:
            guard let box = approximateTextBounds else { return false }
            return !(box.maxX < rect.minX || box.minX > rect.maxX ||
                     box.maxY < rect.minY || box.minY > rect.maxY)
        case .point(let pos):
            return rect.contains(pos)
        }
    }

    /// 平行移動したコピーを返す(idは維持=移動用)
    public func translated(by delta: Vec2) -> Entity {
        var copy = self
        switch kind {
        case .line(let a, let b):
            copy.kind = .line(a: a + delta, b: b + delta)
        case .circle(let c, let r):
            copy.kind = .circle(center: c + delta, radius: r)
        case .arc(let c, let r, let sa, let ea):
            copy.kind = .arc(center: c + delta, radius: r, startAngle: sa, endAngle: ea)
        case .text(let p, let content, let h, let angle):
            copy.kind = .text(position: p + delta, content: content, height: h, angle: angle)
        case .point(let p):
            copy.kind = .point(position: p + delta)
        }
        return copy
    }

    /// 基準点まわりに回転したコピーを返す(idは維持=回転用。angleはラジアン・反時計回り正)
    public func rotated(around center: Vec2, byRadians angle: Double) -> Entity {
        func rot(_ p: Vec2) -> Vec2 {
            let dx = p.x - center.x
            let dy = p.y - center.y
            let c = cos(angle)
            let s = sin(angle)
            return Vec2(center.x + dx * c - dy * s, center.y + dx * s + dy * c)
        }
        var copy = self
        switch kind {
        case .line(let a, let b):
            copy.kind = .line(a: rot(a), b: rot(b))
        case .circle(let c, let r):
            copy.kind = .circle(center: rot(c), radius: r)
        case .arc(let c, let r, let sa, let ea):
            copy.kind = .arc(center: rot(c), radius: r, startAngle: sa + angle, endAngle: ea + angle)
        case .text(let p, let content, let h, let textAngle):
            copy.kind = .text(position: rot(p), content: content, height: h, angle: textAngle + angle)
        case .point(let p):
            copy.kind = .point(position: rot(p))
        }
        return copy
    }

    /// 基準線(a-b)に対して鏡映したコピーを返す(idは維持)。
    /// 円弧は向き(CCW)を保つよう開始/終了角を入れ替える。文字は位置と角度のみ鏡映
    /// (文字自体は裏返さない — CADの慣例)。
    public func mirrored(acrossLineFrom a: Vec2, to b: Vec2) -> Entity {
        let d = b - a
        let len = d.length
        guard len > 1e-9 else { return self }
        let axisAngle = atan2(d.y, d.x)
        let c = cos(axisAngle)
        let s = sin(axisAngle)

        func reflect(_ p: Vec2) -> Vec2 {
            // 軸をx軸に合わせて y→-y、戻す
            let px = p.x - a.x
            let py = p.y - a.y
            let lx = px * c + py * s
            let ly = -px * s + py * c
            let ry = -ly
            return Vec2(a.x + lx * c - ry * s, a.y + lx * s + ry * c)
        }

        func reflectAngle(_ angle: Double) -> Double {
            2 * axisAngle - angle
        }

        var copy = self
        switch kind {
        case .line(let p1, let p2):
            copy.kind = .line(a: reflect(p1), b: reflect(p2))
        case .circle(let center, let r):
            copy.kind = .circle(center: reflect(center), radius: r)
        case .arc(let center, let r, let sa, let ea):
            // 鏡映は向きを反転させるので、CCWを保つため開始/終了を入れ替える
            copy.kind = .arc(center: reflect(center), radius: r,
                             startAngle: reflectAngle(ea), endAngle: reflectAngle(sa))
        case .text(let p, let content, let h, let angle):
            copy.kind = .text(position: reflect(p), content: content,
                              height: h, angle: reflectAngle(angle))
        case .point(let p):
            copy.kind = .point(position: reflect(p))
        }
        return copy
    }

    /// 平行移動した複製を返す(新しいid=複写用)
    public func duplicated(by delta: Vec2) -> Entity {
        var copy = translated(by: delta)
        copy = Entity(id: EntityID(), layer: copy.layer, style: copy.style, kind: copy.kind)
        return copy
    }
}
