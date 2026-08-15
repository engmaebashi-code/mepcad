import Foundation
import MepCore

// MARK: - 配管マスタ M6.0
//
// 用途(給水・給湯・排水…)×管種(VP・HIVP・SGP…)×呼び径のマスタ。
// 源泉はResources/のCSV(会社標準に合わせて差し替え・追記できるようにする)。
// 現在の規模(数百行)はメモリ索引で瞬時に引ける。機器ライブラリ(数千点規模)を
// 載せる段階でSQLite化する予定 — 参照APIはそのまま維持する。

/// 用途(系統)。色・線種の既定と既定管種を持つ
public struct PipeUsage: Identifiable, Equatable, Sendable {
    public let id: String          // "CW"
    public let name: String        // "給水"
    public let colorIndex: Int
    public let lineType: Int
    public let defaultMaterial: String

    public init(id: String, name: String, colorIndex: Int, lineType: Int, defaultMaterial: String) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.lineType = lineType
        self.defaultMaterial = defaultMaterial
    }
}

/// 管種
public struct PipeMaterial: Identifiable, Equatable, Sendable {
    public let id: String          // "VP"
    public let name: String        // "硬質ポリ塩化ビニル管"
    public let shortLabel: String  // "VP"(傍記・集計表示用)

    public init(id: String, name: String, shortLabel: String) {
        self.id = id
        self.name = name
        self.shortLabel = shortLabel
    }
}

/// 呼び径(管種ごと)
public struct PipeSize: Identifiable, Equatable, Sendable {
    public let material: String    // 管種id
    public let size: String        // "50"
    public let label: String       // 傍記表示("50" / "50A" / "50Su")
    public let outerDiameter: Double  // 外径mm

    public var id: String { "\(material)-\(size)" }

    public init(material: String, size: String, label: String, outerDiameter: Double) {
        self.material = material
        self.size = size
        self.label = label
        self.outerDiameter = outerDiameter
    }
}

/// 配管マスタ(CSV読込・参照API)
public final class PipeMaster {

    public let usages: [PipeUsage]
    public let materials: [PipeMaterial]
    public let sizes: [PipeSize]

    private let sizesByMaterial: [String: [PipeSize]]
    private let materialByID: [String: PipeMaterial]
    private let usageByID: [String: PipeUsage]

    /// アプリ同梱の標準マスタ
    public static let standard: PipeMaster = {
        func load(_ name: String) -> String {
            // .copy("Resources")なのでバンドル内は Resources/ サブディレクトリ
            guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                              subdirectory: "Resources")
                    ?? Bundle.module.url(forResource: name, withExtension: nil),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return ""
            }
            return text
        }
        return PipeMaster(usagesCSV: load("pipe_usages.csv"),
                          materialsCSV: load("pipe_materials.csv"),
                          sizesCSV: load("pipe_sizes.csv"))
    }()

    /// CSV文字列から構築(テスト・将来のユーザーマスタ差し替え用)。
    /// 行形式は各CSVのヘッダコメント参照。#始まりと空行は無視
    public init(usagesCSV: String, materialsCSV: String, sizesCSV: String) {
        func rows(_ text: String) -> [[String]] {
            text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
                .map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { $0.split(separator: ",", omittingEmptySubsequences: false)
                          .map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        usages = rows(usagesCSV).compactMap { f in
            guard f.count >= 5, let color = Int(f[2]), let lt = Int(f[3]) else { return nil }
            return PipeUsage(id: f[0], name: f[1], colorIndex: color,
                             lineType: lt, defaultMaterial: f[4])
        }
        materials = rows(materialsCSV).compactMap { f in
            guard f.count >= 3 else { return nil }
            return PipeMaterial(id: f[0], name: f[1], shortLabel: f[2])
        }
        sizes = rows(sizesCSV).compactMap { f in
            guard f.count >= 4, let od = Double(f[3]) else { return nil }
            return PipeSize(material: f[0], size: f[1], label: f[2], outerDiameter: od)
        }
        sizesByMaterial = Dictionary(grouping: sizes, by: \.material)
        materialByID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        usageByID = Dictionary(uniqueKeysWithValues: usages.map { ($0.id, $0) })
    }

    // MARK: - 参照

    public func usage(_ id: String) -> PipeUsage? { usageByID[id] }
    public func material(_ id: String) -> PipeMaterial? { materialByID[id] }

    /// 管種の呼び径一覧(マスタ記載順=細→太)
    public func sizes(for material: String) -> [PipeSize] {
        sizesByMaterial[material] ?? []
    }

    public func size(material: String, size: String) -> PipeSize? {
        sizesByMaterial[material]?.first { $0.size == size }
    }
}

// MARK: - 材料集計

/// 集計行: 用途×管種×呼び径ごとの延長+継手個数
public struct PipeTotal: Equatable, Sendable {
    public let usageName: String
    public let materialLabel: String
    public let sizeLabel: String
    public let totalLengthMm: Double
    public let runCount: Int
    /// エルボ90°の個数(折れ点の自動発生分。M6.1)
    public let elbow90Count: Int
    /// エルボ45°の個数
    public let elbow45Count: Int

    /// 表示用: mに換算し0.1m単位へ切り上げ(拾いの慣例)
    public var lengthMeters: Double {
        (totalLengthMm / 100).rounded(.up) / 10
    }
}

public enum PipeAggregator {

    /// 図面内の配管を(用途, 管種, 呼び径)で集計する。表示中レイヤのみ等の
    /// 絞り込みは呼び出し側でentitiesを間引いて渡す
    public static func aggregate(_ entities: [Entity]) -> [PipeTotal] {
        struct Key: Hashable {
            let usage: String
            let material: String
            let size: String
        }
        var lengths: [Key: (length: Double, count: Int, e90: Int, e45: Int)] = [:]
        for e in entities {
            guard case .pipe(let points, let attrs) = e.kind, points.count >= 2 else { continue }
            let len = PipeGeometry.length(of: points)
            var e90 = 0, e45 = 0
            if attrs.autoFittings {
                for f in PipeGeometry.fittings(points: points) {
                    switch f.kind {
                    case .elbow90: e90 += 1
                    case .elbow45: e45 += 1
                    case .elbowOther: break
                    }
                }
            }
            let key = Key(usage: attrs.usageName, material: attrs.materialLabel,
                          size: attrs.sizeLabel)
            let cur = lengths[key] ?? (0, 0, 0, 0)
            lengths[key] = (cur.length + len, cur.count + 1, cur.e90 + e90, cur.e45 + e45)
        }
        return lengths.map { key, value in
            PipeTotal(usageName: key.usage, materialLabel: key.material,
                      sizeLabel: key.size, totalLengthMm: value.length,
                      runCount: value.count,
                      elbow90Count: value.e90, elbow45Count: value.e45)
        }
        .sorted {
            ($0.usageName, $0.materialLabel, $0.sizeLabel.count, $0.sizeLabel)
                < ($1.usageName, $1.materialLabel, $1.sizeLabel.count, $1.sizeLabel)
        }
    }

    /// 集計結果の表形式テキスト(コピー・保存用。タブ区切り)
    public static func reportText(_ totals: [PipeTotal]) -> String {
        var lines = ["用途\t管種\t呼び径\t延長(m)\t本数\tエルボ90°\tエルボ45°"]
        for t in totals {
            lines.append("\(t.usageName)\t\(t.materialLabel)\t\(t.sizeLabel)\t"
                         + String(format: "%.1f", t.lengthMeters)
                         + "\t\(t.runCount)\t\(t.elbow90Count)\t\(t.elbow45Count)")
        }
        return lines.joined(separator: "\n")
    }
}
