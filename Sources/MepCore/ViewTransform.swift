import Foundation

/// ワールド座標(mm・Y上向き) ↔ スクリーン座標(px・Y下向き)の変換。
/// スクリーン座標はビュー左上原点・Y下向き(NSView isFlipped=true前提)。
public struct ViewTransform: Equatable, Sendable {
    /// 1mmあたりのピクセル数
    public var scale: Double
    /// ワールド原点(0,0)のスクリーン位置
    public var origin: Vec2

    public init(scale: Double = 0.1, origin: Vec2 = .zero) {
        self.scale = scale
        self.origin = origin
    }

    public func toScreen(_ w: Vec2) -> Vec2 {
        Vec2(origin.x + w.x * scale, origin.y - w.y * scale)
    }

    public func toWorld(_ s: Vec2) -> Vec2 {
        Vec2((s.x - origin.x) / scale, (origin.y - s.y) / scale)
    }

    /// スクリーン上の点を固定してズーム(カーソル中心ズーム)
    public mutating func zoom(by factor: Double, at screenPoint: Vec2) {
        let clamped = min(max(scale * factor, 0.0005), 1000)  // 1px=2m 〜 1mm=1000px
        let worldAnchor = toWorld(screenPoint)
        scale = clamped
        origin.x = screenPoint.x - worldAnchor.x * scale
        origin.y = screenPoint.y + worldAnchor.y * scale
    }

    /// スクリーンピクセル単位のパン
    public mutating func pan(by delta: Vec2) {
        origin = origin + delta
    }

    /// 指定範囲が収まるようにフィット
    public mutating func fit(_ box: BBox, in viewSize: Vec2, marginRatio: Double = 0.05) {
        guard !box.isEmpty, box.width > 0 || box.height > 0,
              viewSize.x > 0, viewSize.y > 0 else { return }
        let w = max(box.width, 1)
        let h = max(box.height, 1)
        let sx = viewSize.x * (1 - marginRatio * 2) / w
        let sy = viewSize.y * (1 - marginRatio * 2) / h
        scale = min(sx, sy)
        let c = box.center
        origin.x = viewSize.x / 2 - c.x * scale
        origin.y = viewSize.y / 2 + c.y * scale
    }
}
