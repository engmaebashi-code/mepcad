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

    /// 回転を考慮した文字グリフボックスの四隅(基準点→幅方向→対角→高さ方向の順)。
    /// 90°/270°の縦文字も本体クリックで選択できるようにする(M5.4)
    public var textGlyphCorners: [Vec2]? {
        guard case .text(let p, let content, let height, let angle) = kind else { return nil }
        let width = max(height * 0.6, Double(content.count) * height * 0.9)
        let c = cos(angle)
        let s = sin(angle)
        return [Vec2(0, 0), Vec2(width, 0), Vec2(width, height), Vec2(0, height)].map {
            Vec2(p.x + $0.x * c - $0.y * s, p.y + $0.x * s + $0.y * c)
        }
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

        case .text(let pos, let content, let height, let angle):
            // 回転を戻したローカル座標で判定(回転は距離を保つのでそのまま距離になる)。
            // 90°/270°の縦文字も本体クリックで選択できる
            let width = max(height * 0.6, Double(content.count) * height * 0.9)
            let c = cos(angle)
            let s = sin(angle)
            let dxp = p.x - pos.x
            let dyp = p.y - pos.y
            let lx = dxp * c + dyp * s
            let ly = -dxp * s + dyp * c
            let dx = max(-lx, 0, lx - width)
            let dy = max(-ly, 0, ly - height)
            return (dx * dx + dy * dy).squareRoot()

        case .point(let pos):
            return pos.distance(to: p)

        case .blockRef(_, let insert, _, _, _, let cached):
            // 粗い判定: バウンディングボックス内=ヒット(シンボルは塊で掴めれば良い)
            if cached.isEmpty { return insert.distance(to: p) }
            if cached.contains(p) { return 0 }
            let dx = max(cached.minX - p.x, 0, p.x - cached.maxX)
            let dy = max(cached.minY - p.y, 0, p.y - cached.maxY)
            return (dx * dx + dy * dy).squareRoot()

        case .hatch(let boundary, _):
            // ポリゴン内=ヒット(塊で掴む)。外なら境界辺への距離
            guard boundary.count >= 3 else { return .infinity }
            if HatchGeometry.polygonContains(p, boundary) { return 0 }
            var best = Double.infinity
            for i in 0..<boundary.count {
                let a = boundary[i]
                let b = boundary[(i + 1) % boundary.count]
                best = min(best, HitGeometry.closestPointOnSegment(p, a, b).distance(to: p))
            }
            return best

        case .dimension:
            guard let layout = DimensionGeometry.layout(of: self) else { return .infinity }
            var best = Double.infinity
            for seg in layout.hitSegments {
                best = min(best, HitGeometry.closestPointOnSegment(p, seg.0, seg.1).distance(to: p))
            }
            // 寸法値文字はベースライン線分で近似(高さ分は下の許容距離が拾う)
            let w = DimensionGeometry.textWidth(layout.textContent, height: layout.textHeight)
            let ut = Vec2(cos(layout.textAngle), sin(layout.textAngle))
            let textEnd = layout.textPosition + ut * w
            best = min(best, HitGeometry.closestPointOnSegment(p, layout.textPosition, textEnd)
                                .distance(to: p))
            return best

        case .leader(_, _, _, let attrs):
            guard let layout = LeaderGeometry.layout(of: self) else { return .infinity }
            // バルーンの中=ヒット(塊で掴む)
            if let e = layout.ellipses.first {
                let nx = (p.x - e.center.x) / e.rx
                let ny = (p.y - e.center.y) / e.ry
                if nx * nx + ny * ny <= 1 { return 0 }
            }
            var best = Double.infinity
            for seg in layout.segments {
                best = min(best, HitGeometry.closestPointOnSegment(p, seg.0, seg.1).distance(to: p))
            }
            // 楕円は折れ線近似で距離を取る
            for e in layout.ellipses {
                let pts = LeaderGeometry.ellipsePoints(center: e.center, rx: e.rx, ry: e.ry)
                for i in 0..<pts.count {
                    best = min(best, HitGeometry.closestPointOnSegment(
                        p, pts[i], pts[(i + 1) % pts.count]).distance(to: p))
                }
            }
            // 文字ボックス(水平・行ごと)
            for t in layout.texts {
                let w = LeaderGeometry.textWidth(t.content, height: attrs.textHeight)
                let dx = max(t.position.x - p.x, 0, p.x - (t.position.x + w))
                let dy = max(t.position.y - p.y, 0,
                             p.y - (t.position.y + attrs.textHeight))
                best = min(best, (dx * dx + dy * dy).squareRoot())
            }
            return best
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
            guard let corners = textGlyphCorners else { return false }
            return corners.allSatisfy { rect.contains($0) }
        case .point(let pos):
            return rect.contains(pos)
        case .blockRef(_, let insert, _, _, _, let cached):
            if cached.isEmpty { return rect.contains(insert) }
            return rect.contains(Vec2(cached.minX, cached.minY))
                && rect.contains(Vec2(cached.maxX, cached.maxY))
        case .hatch(let boundary, _):
            return !boundary.isEmpty && boundary.allSatisfy { rect.contains($0) }
        case .dimension, .leader:
            // 導出ジオメトリ全体(bounds)が入っていれば内包
            let box = bounds
            return !box.isEmpty && rect.contains(Vec2(box.minX, box.minY))
                && rect.contains(Vec2(box.maxX, box.maxY))
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
            // 回転したグリフボックス(凸四角形)と矩形の交差判定
            guard let corners = textGlyphCorners else { return false }
            if corners.contains(where: { rect.contains($0) }) { return true }
            for i in 0..<4 {
                if HitGeometry.segmentIntersectsRect(corners[i], corners[(i + 1) % 4], rect) {
                    return true
                }
            }
            // 矩形がグリフボックスに完全に入っているケース
            return HatchGeometry.polygonContains(Vec2(rect.minX, rect.minY), corners)
        case .point(let pos):
            return rect.contains(pos)
        case .blockRef(_, let insert, _, _, _, let cached):
            if cached.isEmpty { return rect.contains(insert) }
            return !(cached.maxX < rect.minX || cached.minX > rect.maxX ||
                     cached.maxY < rect.minY || cached.minY > rect.maxY)

        case .hatch(let boundary, _):
            guard boundary.count >= 3 else { return false }
            if boundary.contains(where: { rect.contains($0) }) { return true }
            for i in 0..<boundary.count {
                if HitGeometry.segmentIntersectsRect(boundary[i], boundary[(i + 1) % boundary.count], rect) {
                    return true
                }
            }
            // 矩形がポリゴンに完全に入っているケース
            return HatchGeometry.polygonContains(Vec2(rect.minX, rect.minY), boundary)

        case .dimension:
            guard let layout = DimensionGeometry.layout(of: self) else { return false }
            for seg in layout.hitSegments {
                if HitGeometry.segmentIntersectsRect(seg.0, seg.1, rect) { return true }
            }
            let w = DimensionGeometry.textWidth(layout.textContent, height: layout.textHeight)
            let ut = Vec2(cos(layout.textAngle), sin(layout.textAngle))
            return HitGeometry.segmentIntersectsRect(layout.textPosition,
                                                     layout.textPosition + ut * w, rect)

        case .leader(_, _, _, let attrs):
            guard let layout = LeaderGeometry.layout(of: self) else { return false }
            for seg in layout.segments {
                if HitGeometry.segmentIntersectsRect(seg.0, seg.1, rect) { return true }
            }
            for e in layout.ellipses {
                let pts = LeaderGeometry.ellipsePoints(center: e.center, rx: e.rx, ry: e.ry)
                if pts.contains(where: { rect.contains($0) }) { return true }
                for i in 0..<pts.count {
                    if HitGeometry.segmentIntersectsRect(pts[i], pts[(i + 1) % pts.count], rect) {
                        return true
                    }
                }
            }
            // 文字ボックス(水平・行ごと)との重なり
            for t in layout.texts {
                let w = LeaderGeometry.textWidth(t.content, height: attrs.textHeight)
                if !(t.position.x + w < rect.minX || t.position.x > rect.maxX ||
                     t.position.y + attrs.textHeight < rect.minY || t.position.y > rect.maxY) {
                    return true
                }
            }
            // 矩形がバルーンの中に完全に入っているケース
            if let e = layout.ellipses.first {
                let nx = (rect.minX - e.center.x) / e.rx
                let ny = (rect.minY - e.center.y) / e.ry
                if nx * nx + ny * ny <= 1 { return true }
            }
            return false
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
        case .blockRef(let defID, let insert, let rot, let scale, let mir, let cached):
            var box = cached
            if !box.isEmpty {
                box = BBox(minX: box.minX + delta.x, minY: box.minY + delta.y,
                           maxX: box.maxX + delta.x, maxY: box.maxY + delta.y)
            }
            copy.kind = .blockRef(definitionID: defID, insert: insert + delta,
                                  rotation: rot, scale: scale, mirrored: mir, cachedBounds: box)
        case .hatch(let boundary, let pattern):
            copy.kind = .hatch(boundary: boundary.map { $0 + delta }, pattern: pattern)
        case .dimension(let a, let b, let lp, let angle, let attrs):
            copy.kind = .dimension(a: a + delta, b: b + delta, linePoint: lp + delta,
                                   angle: angle, attrs: attrs)
        case .leader(let tip, let elbow, let content, let attrs):
            copy.kind = .leader(tip: tip + delta, elbow: elbow + delta,
                                content: content, attrs: attrs)
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
        case .blockRef(let defID, let insert, let refRot, let scale, let mir, let cached):
            copy.kind = .blockRef(definitionID: defID, insert: rot(insert),
                                  rotation: refRot + angle, scale: scale, mirrored: mir,
                                  cachedBounds: Self.transformedBounds(cached, rot))
        case .hatch(let boundary, var pattern):
            pattern.angle += angle
            copy.kind = .hatch(boundary: boundary.map(rot), pattern: pattern)
        case .dimension(let a, let b, let lp, let dimAngle, let attrs):
            copy.kind = .dimension(a: rot(a), b: rot(b), linePoint: rot(lp),
                                   angle: dimAngle + angle, attrs: attrs)
        case .leader(let tip, let elbow, let content, let attrs):
            // 位置だけ回す(文字・バルーンは常に水平=CADの慣例)
            copy.kind = .leader(tip: rot(tip), elbow: rot(elbow),
                                content: content, attrs: attrs)
        }
        return copy
    }

    /// バウンディングボックスの4隅を写像してAABBを取り直す(blockRefの境界キャッシュ更新用)
    static func transformedBounds(_ box: BBox, _ map: (Vec2) -> Vec2) -> BBox {
        guard !box.isEmpty else { return box }
        var out = BBox.empty
        out.union(point: map(Vec2(box.minX, box.minY)))
        out.union(point: map(Vec2(box.maxX, box.minY)))
        out.union(point: map(Vec2(box.maxX, box.maxY)))
        out.union(point: map(Vec2(box.minX, box.maxY)))
        return out
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
        case .blockRef(let defID, let insert, let rot, let scale, let mir, let cached):
            // 合成則(検証済): 反転後は 回転' = 2φ - 回転 - π、ローカル反転フラグはトグル
            // (ローカル反転=縦軸鏡映 Refl(π/2) を基準にした場合の閉形式)
            copy.kind = .blockRef(definitionID: defID, insert: reflect(insert),
                                  rotation: 2 * axisAngle - rot - .pi,
                                  scale: scale, mirrored: !mir,
                                  cachedBounds: Self.transformedBounds(cached, reflect))
        case .hatch(let boundary, var pattern):
            // パターン方向も鏡映(文字角度と同じ合成則)
            pattern.angle = 2 * axisAngle - pattern.angle
            copy.kind = .hatch(boundary: boundary.map(reflect), pattern: pattern)
        case .dimension(let p1, let p2, let lp, let dimAngle, let attrs):
            copy.kind = .dimension(a: reflect(p1), b: reflect(p2), linePoint: reflect(lp),
                                   angle: reflectAngle(dimAngle), attrs: attrs)
        case .leader(let tip, let elbow, let content, let attrs):
            // 位置だけ鏡映(文字・バルーンは裏返さない)
            copy.kind = .leader(tip: reflect(tip), elbow: reflect(elbow),
                                content: content, attrs: attrs)
        }
        return copy
    }

    /// 等倍率で拡大縮小したコピーを返す(idは維持。ブロック実体化・将来の倍率複写用)
    public func scaled(by factor: Double, around center: Vec2) -> Entity {
        let f = abs(factor) < 1e-12 ? 1 : factor
        func sc(_ p: Vec2) -> Vec2 {
            Vec2(center.x + (p.x - center.x) * f, center.y + (p.y - center.y) * f)
        }
        var copy = self
        switch kind {
        case .line(let a, let b):
            copy.kind = .line(a: sc(a), b: sc(b))
        case .circle(let c, let r):
            copy.kind = .circle(center: sc(c), radius: r * abs(f))
        case .arc(let c, let r, let sa, let ea):
            copy.kind = .arc(center: sc(c), radius: r * abs(f), startAngle: sa, endAngle: ea)
        case .text(let p, let content, let h, let angle):
            copy.kind = .text(position: sc(p), content: content, height: h * abs(f), angle: angle)
        case .point(let p):
            copy.kind = .point(position: sc(p))
        case .blockRef(let defID, let insert, let rot, let scale, let mir, let cached):
            copy.kind = .blockRef(definitionID: defID, insert: sc(insert),
                                  rotation: rot, scale: scale * abs(f), mirrored: mir,
                                  cachedBounds: Self.transformedBounds(cached, sc))
        case .hatch(let boundary, var pattern):
            pattern.spacingA *= abs(f)
            pattern.spacingB *= abs(f)
            copy.kind = .hatch(boundary: boundary.map(sc), pattern: pattern)
        case .dimension(let a, let b, let lp, let angle, var attrs):
            // 見た目属性も倍率に追随(寸法値は幾何からの実測なので自動で変わる)
            attrs.textHeight *= abs(f)
            if let len = attrs.extensionLength { attrs.extensionLength = len * abs(f) }
            copy.kind = .dimension(a: sc(a), b: sc(b), linePoint: sc(lp),
                                   angle: angle, attrs: attrs)
        case .leader(let tip, let elbow, let content, var attrs):
            attrs.textHeight *= abs(f)
            if let bw = attrs.balloonWidth { attrs.balloonWidth = bw * abs(f) }
            copy.kind = .leader(tip: sc(tip), elbow: sc(elbow),
                                content: content, attrs: attrs)
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
