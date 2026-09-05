import Foundation

// MARK: - 可撓管の曲げ M7.9
//
// 架橋ポリエチレン管・ポリブテン管・冷媒管・ケーブルは折れ点に継手を置かず、管を曲げて
// 配管する。平面図では折れ点を「曲げ半径R(管種ごとの最小曲げ半径=外径×倍率)」の
// 円弧で丸める。脚が短くて規定のRが収まらない折れ点は、収まる半径まで小さくする
// (隣り合う折れ点で1つの脚を分け合うときは按分)。
//
// 出力は「直線と円弧の並び(pieces)」。芯線・左右の外形線はそこからオフセット付きの
// 折れ線に落とす(円弧は左折なら内側=R−r・外側=R+r)。

public enum PipeBend {

    public enum Piece: Equatable, Sendable {
        case line(Vec2, Vec2)
        /// 中心・半径・開始角・符号付き回転角(左折=正)
        case arc(center: Vec2, radius: Double, start: Double, sweep: Double)
    }

    /// 円弧を折れ線にするときの1区分の角度(90°を8分割)
    public static let arcStep = Double.pi / 16

    /// 折れ線ptsの折れ点を半径radiusで丸めた直線・円弧の並び。
    /// radius<=0か折れ点が無ければ直線だけ
    public static func pieces(_ pts: [Vec2], radius: Double) -> [Piece] {
        let n = pts.count
        guard n >= 2 else { return [] }
        var dirs: [Vec2] = []
        var lens: [Double] = []
        for i in 0..<(n - 1) {
            let d = pts[i + 1] - pts[i]
            let len = d.length
            dirs.append(len > 1e-9 ? d * (1 / len) : Vec2(1, 0))
            lens.append(len)
        }
        // 折れ点ごとの回転角と希望の接線長 t = R·tan(θ/2)
        var turns = [Double](repeating: 0, count: n)
        var tangents = [Double](repeating: 0, count: n)
        if radius > 0, n >= 3 {
            for i in 1..<(n - 1) {
                guard lens[i - 1] > 1e-9, lens[i] > 1e-9 else { continue }
                var turn = atan2(dirs[i].y, dirs[i].x) - atan2(dirs[i - 1].y, dirs[i - 1].x)
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                let deg = abs(turn) * 180 / .pi
                guard deg > 0.5, deg < 179 else { continue }     // 直進・折り返しは丸めない
                turns[i] = turn
                tangents[i] = radius * tan(abs(turn) / 2)
            }
            // 脚に収まらない接線長は縮める(両端の折れ点で按分)
            for i in 0..<(n - 1) {
                let need = tangents[i] + tangents[i + 1]
                guard need > lens[i], need > 1e-9 else { continue }
                let k = lens[i] / need
                tangents[i] *= k
                tangents[i + 1] *= k
            }
        }
        var out: [Piece] = []
        var cursor = pts[0]
        for i in 1..<n {
            if i < n - 1, turns[i] != 0, tangents[i] > 1e-9 {
                let tIn = pts[i] - dirs[i - 1] * tangents[i]
                let tOut = pts[i] + dirs[i] * tangents[i]
                if tIn.distance(to: cursor) > 1e-9 { out.append(.line(cursor, tIn)) }
                let r = tangents[i] / tan(abs(turns[i]) / 2)
                let n1 = Vec2(-dirs[i - 1].y, dirs[i - 1].x) * (turns[i] > 0 ? 1 : -1)
                let center = tIn + n1 * r
                let start = atan2(tIn.y - center.y, tIn.x - center.x)
                out.append(.arc(center: center, radius: r, start: start, sweep: turns[i]))
                cursor = tOut
            } else {
                if pts[i].distance(to: cursor) > 1e-9 { out.append(.line(cursor, pts[i])) }
                cursor = pts[i]
            }
        }
        return out
    }

    /// 直線・円弧の並びを、進行方向の左へoffsetだけ寄せた折れ線にする(0なら芯線)
    public static func polyline(_ pieces: [Piece], offset: Double) -> [Vec2] {
        var out: [Vec2] = []
        func push(_ p: Vec2) {
            if let last = out.last, last.distance(to: p) <= 1e-9 { return }
            out.append(p)
        }
        for piece in pieces {
            switch piece {
            case .line(let a, let b):
                let d = b - a
                let len = d.length
                let nrm = len > 1e-9 ? Vec2(-d.y, d.x) * (1 / len) : Vec2(0, 1)
                push(a + nrm * offset)
                push(b + nrm * offset)
            case .arc(let c, let radius, let start, let sweep):
                // 左折なら中心は左側: 左の線は内側(R−o)、右の線は外側(R+o)
                let rr = max(radius - offset * (sweep > 0 ? 1 : -1), 0.1)
                let steps = max(2, Int((abs(sweep) / arcStep).rounded(.up)))
                for k in 0...steps {
                    let a = start + sweep * Double(k) / Double(steps)
                    push(Vec2(c.x + cos(a) * rr, c.y + sin(a) * rr))
                }
            }
        }
        return out
    }

    /// 芯線だけを丸めた折れ線(単線表現・ヒット用)
    public static func centerline(_ pts: [Vec2], radius: Double) -> [Vec2] {
        guard pts.count >= 2 else { return pts }
        return polyline(pieces(pts, radius: radius), offset: 0)
    }
}
