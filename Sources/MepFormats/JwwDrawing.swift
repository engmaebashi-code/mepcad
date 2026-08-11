import Foundation
import MepCore

/// JWW解析結果(v16パーサ互換の生データ)。
/// 座標系はJWWのワールド座標(mm・Y上向き)そのまま。
public struct JwwLine: Sendable {
    public var x1, y1, x2, y2: Double
    public var layer, glayer, lntp, color: UInt8
}

public struct JwwArc: Sendable {
    public var cx, cy, r, startAngle, endAngle, tilt, flatness: Double
    public var layer, glayer: UInt8
    public var isCircle: Bool
    public var lntp, color: UInt8
}

public struct JwwSolid: Sendable {
    /// polygonモード: x1,y1,x2,y2,x3,y3,x4,y4 / circleモード: cx,cy,rx,ry,sa,sweep,tilt,0
    public var values: [Double]
    public var layer, glayer: UInt8
    public var isCircleMode: Bool
}

public struct JwwText: Sendable {
    public var x, y: Double
    public var size: Double        // 文字高(mm)
    public var angleDegrees: Double
    public var text: String
    public var layer, glayer: UInt8
}

public struct JwwDrawing: Sendable {
    public var version: UInt32 = 0
    public var lines: [JwwLine] = []
    public var arcs: [JwwArc] = []
    public var solids: [JwwSolid] = []
    public var texts: [JwwText] = []
    public var scales: [Double] = []          // グループ別縮尺(16)
    public var layerStates: [UInt8]? = nil    // 256スロット(0=非表示,2=表示,3=カレント,8=プロテクト)
    public var groupStates: [UInt8]? = nil    // 16グループ

    public var bounds: BBox {
        var box = BBox.empty
        for l in lines {
            box.union(point: Vec2(l.x1, l.y1))
            box.union(point: Vec2(l.x2, l.y2))
        }
        for a in arcs {
            box.union(point: Vec2(a.cx - a.r, a.cy - a.r))
            box.union(point: Vec2(a.cx + a.r, a.cy + a.r))
        }
        return box
    }
}
