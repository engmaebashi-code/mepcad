import Foundation

/// 2Dベクトル/点(内部単位はmm・倍精度)
public struct Vec2: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Vec2) -> Double { (self - other).length }
}

/// 3次元点(配管の芯線用。x,y=平面図、z=高さmm)。M6.2
public struct Vec3: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ xy: Vec2, z: Double) {
        self.x = xy.x
        self.y = xy.y
        self.z = z
    }

    /// 平面図への投影
    public var xy: Vec2 { Vec2(x, y) }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public func distance(to other: Vec3) -> Double { (self - other).length }

    /// 平面上の位置を写像し、高さは維持する(移動・回転・鏡映・倍率用)
    public func mappingXY(_ f: (Vec2) -> Vec2) -> Vec3 { Vec3(f(xy), z: z) }
}

/// 軸平行バウンディングボックス
public struct BBox: Equatable, Codable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// 空(無効)ボックス — union用の単位元
    public static let empty = BBox(minX: .infinity, minY: .infinity,
                                   maxX: -.infinity, maxY: -.infinity)

    public var isEmpty: Bool { minX > maxX || minY > maxY }
    public var width: Double { max(0, maxX - minX) }
    public var height: Double { max(0, maxY - minY) }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }

    public mutating func union(point p: Vec2) {
        minX = Swift.min(minX, p.x)
        minY = Swift.min(minY, p.y)
        maxX = Swift.max(maxX, p.x)
        maxY = Swift.max(maxY, p.y)
    }

    public mutating func union(_ other: BBox) {
        guard !other.isEmpty else { return }
        minX = Swift.min(minX, other.minX)
        minY = Swift.min(minY, other.minY)
        maxX = Swift.max(maxX, other.maxX)
        maxY = Swift.max(maxY, other.maxY)
    }

    public func expanded(by margin: Double) -> BBox {
        BBox(minX: minX - margin, minY: minY - margin,
             maxX: maxX + margin, maxY: maxY + margin)
    }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}
