import Foundation

public typealias LayerID = UUID

public struct Layer: Identifiable, Equatable, Codable, Sendable {
    public let id: LayerID
    public var name: String
    public var isVisible: Bool
    public var isEditable: Bool
    public var defaultColorIndex: Int
    public var defaultLineType: Int
    public var defaultLineWeight: Double  // mm
    /// JWW/PDF取込で作られた下敷きレイヤか(ファイルを開き直す時にまとめて入れ替える)
    public var isUnderlay: Bool

    public init(id: LayerID = LayerID(),
                name: String,
                isVisible: Bool = true,
                isEditable: Bool = true,
                defaultColorIndex: Int = 0,
                defaultLineType: Int = 0,
                defaultLineWeight: Double = 0.15,
                isUnderlay: Bool = false) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isEditable = isEditable
        self.defaultColorIndex = defaultColorIndex
        self.defaultLineType = defaultLineType
        self.defaultLineWeight = defaultLineWeight
        self.isUnderlay = isUnderlay
    }
}

public enum DefaultLayers {
    /// 新規図面の既定レイヤセット(機能仕分けの用途別レイヤ運用に対応)
    public static func standardSet() -> [Layer] {
        [
            Layer(name: "下敷き", defaultColorIndex: 8),
            Layer(name: "補助線", defaultColorIndex: 9),
            Layer(name: "基本作図", defaultColorIndex: 0),
            Layer(name: "空調配管", defaultColorIndex: 1),
            Layer(name: "衛生配管", defaultColorIndex: 2),
            Layer(name: "ダクト", defaultColorIndex: 3),
            Layer(name: "傍記", defaultColorIndex: 0),
        ]
    }
}
