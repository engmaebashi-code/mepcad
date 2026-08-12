import Foundation

// MARK: - Jw_cad準拠のレイヤ体系(16グループ × 16レイヤ)
//
// JWWとの相互変換で情報の欠落・付け替えを起こさないため、
// 図面のレイヤ構造は常に「16グループ(各グループに縮尺)× 16レイヤ」の固定構造とする。
// 用途別レイヤ(空調配管など)は「レイヤ名の初期割り当て」として表現する。

/// レイヤの住所(グループ0〜15, レイヤ0〜15)。
/// どの経路で作っても0〜15にクランプされる(配列添字の安全性はここで担保)。
public struct LayerAddress: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var group: Int {
        didSet { group = Self.clamp(group) }
    }
    public var layer: Int {
        didSet { layer = Self.clamp(layer) }
    }

    private static func clamp(_ v: Int) -> Int {
        min(max(v, 0), 15)
    }

    public init(_ group: Int, _ layer: Int) {
        self.group = Self.clamp(group)
        self.layer = Self.clamp(layer)
    }

    /// Codable経由(将来の.mepcad読込等)でもクランプを通す
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let g = try container.decode(Int.self, forKey: .group)
        let l = try container.decode(Int.self, forKey: .layer)
        self.init(g, l)
    }

    private enum CodingKeys: String, CodingKey {
        case group, layer
    }

    public static let zero = LayerAddress(0, 0)

    /// Jw_cad流の表記(グループ-レイヤ、16進1桁)
    public var description: String {
        String(format: "%X-%X", group, layer)
    }

    public static func < (a: LayerAddress, b: LayerAddress) -> Bool {
        a.group != b.group ? a.group < b.group : a.layer < b.layer
    }
}

/// 1レイヤの状態(16×16の各スロット)
public struct Layer: Equatable, Codable, Sendable {
    /// レイヤ名(空ならUIは「レイヤ n」等で表示)
    public var name: String
    public var isVisible: Bool
    /// false=ロック(表示のみ。選択・編集の対象外)
    public var isEditable: Bool
    /// byLayerスタイルの既定値(MepCad独自。JWW変換には影響しない)
    public var defaultColorIndex: Int
    public var defaultLineType: Int
    public var defaultLineWeight: Double  // mm

    public init(name: String = "",
                isVisible: Bool = true,
                isEditable: Bool = true,
                defaultColorIndex: Int = 0,
                defaultLineType: Int = 0,
                defaultLineWeight: Double = 0.15) {
        self.name = name
        self.isVisible = isVisible
        self.isEditable = isEditable
        self.defaultColorIndex = defaultColorIndex
        self.defaultLineType = defaultLineType
        self.defaultLineWeight = defaultLineWeight
    }
}

/// 1グループの状態(縮尺を持つ。JWWのレイヤグループに対応)
public struct LayerGroup: Equatable, Codable, Sendable {
    public var name: String
    /// 縮尺の分母(1/50なら50)。実寸mm = JWW図寸座標 × scale
    public var scale: Double
    public var isVisible: Bool
    public var isEditable: Bool
    /// 16レイヤ
    public var layers: [Layer]

    public init(name: String = "",
                scale: Double = 50,
                isVisible: Bool = true,
                isEditable: Bool = true,
                layers: [Layer] = (0..<16).map { _ in Layer() }) {
        self.name = name
        self.scale = scale
        self.isVisible = isVisible
        self.isEditable = isEditable
        self.layers = layers
    }

    /// 「1/50」形式の縮尺表記
    public var scaleLabel: String {
        if abs(scale - scale.rounded()) < 1e-9 {
            return "1/\(Int(scale.rounded()))"
        }
        return String(format: "1/%.1f", scale)
    }
}

public enum DefaultLayers {
    /// 新規図面の既定構成:
    /// グループ0(1/50)に用途別レイヤ名を割り当て、残りは無名の空グループ(1/50)。
    public static func standardGroups() -> [LayerGroup] {
        var groups = (0..<16).map { _ in LayerGroup() }
        var g0 = LayerGroup(name: "作図")
        let names: [(Int, String, Int)] = [  // (レイヤ, 名前, 既定色)
            (0, "下敷き", 8),
            (1, "補助線", 9),
            (2, "基本作図", 0),
            (3, "空調配管", 1),
            (4, "衛生配管", 2),
            (5, "ダクト", 3),
            (6, "傍記", 0),
        ]
        for (idx, name, color) in names {
            g0.layers[idx].name = name
            g0.layers[idx].defaultColorIndex = color
        }
        groups[0] = g0
        return groups
    }

    /// 新規図面のカレント(基本作図)
    public static let standardCurrent = LayerAddress(0, 2)
}
