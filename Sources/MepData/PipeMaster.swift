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
    /// 継手の規格シリーズ("DV"等。型番の引き当てに使う)M7
    public var series: String = ""
    /// 呼び径のマスタキー(型番の引き当てに使う)M7
    public var size: String = ""
    public let totalLengthMm: Double
    public let runCount: Int
    /// エルボ90°の個数(折れ点の自動発生分。M6.1)
    public let elbow90Count: Int
    /// エルボ45°の個数
    public let elbow45Count: Int
    /// ティーズ(本管側で数える)・キャップ・レデューサの個数(M6.3)
    public let teeCount: Int
    public let capCount: Int
    public let reducerCount: Int

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
            let series: String
            let sizeKey: String
        }
        var lengths: [Key: (length: Double, count: Int, e90: Int, e45: Int,
                            tee: Int, cap: Int, red: Int)] = [:]
        let junctions = PipeNetwork.junctions(in: entities)
        for e in entities {
            guard case .pipe(let points, let attrs) = e.kind, points.count >= 2 else { continue }
            let len = PipeGeometry.length(of: points)
            var e90 = 0, e45 = 0, tee = 0, cap = 0, red = 0
            if attrs.autoFittings {
                for f in PipeGeometry.fittings(points: points) {
                    switch f.kind {
                    case .elbow90: e90 += 1
                    case .elbow45: e45 += 1
                    default: break
                    }
                }
                for j in junctions[e.id] ?? [] {
                    switch j.kind {
                    case .tee: tee += 1
                    case .cap: cap += 1
                    case .reducer: red += 1
                    case .teeBranch: break
                    }
                }
            }
            let key = Key(usage: attrs.usageName, material: attrs.materialLabel,
                          size: attrs.sizeLabel, series: attrs.fittingSeries, sizeKey: attrs.size)
            let cur = lengths[key] ?? (0, 0, 0, 0, 0, 0, 0)
            lengths[key] = (cur.length + len, cur.count + 1, cur.e90 + e90, cur.e45 + e45,
                            cur.tee + tee, cur.cap + cap, cur.red + red)
        }
        return lengths.map { key, value in
            PipeTotal(usageName: key.usage, materialLabel: key.material,
                      sizeLabel: key.size, series: key.series, size: key.sizeKey,
                      totalLengthMm: value.length,
                      runCount: value.count,
                      elbow90Count: value.e90, elbow45Count: value.e45,
                      teeCount: value.tee, capCount: value.cap, reducerCount: value.red)
        }
        .sorted {
            ($0.usageName, $0.materialLabel, $0.sizeLabel.count, $0.sizeLabel)
                < ($1.usageName, $1.materialLabel, $1.sizeLabel.count, $1.sizeLabel)
        }
    }

    /// 集計結果の表形式テキスト(コピー・保存用。タブ区切り)
    public static func reportText(_ totals: [PipeTotal]) -> String {
        var lines = ["用途\t管種\t呼び径\t延長(m)\t本数\tエルボ90°\tエルボ45°\tティーズ\tキャップ\tレデューサ"]
        for t in totals {
            lines.append("\(t.usageName)\t\(t.materialLabel)\t\(t.sizeLabel)\t"
                         + String(format: "%.1f", t.lengthMeters)
                         + "\t\(t.runCount)\t\(t.elbow90Count)\t\(t.elbow45Count)"
                         + "\t\(t.teeCount)\t\(t.capCount)\t\(t.reducerCount)")
        }
        return lines.joined(separator: "\n")
    }

    /// 型番つきの集計表(M7)。継手マスタに型番があれば継手ごとの列に添える。
    /// 発注・見積の受け渡しでは呼び径だけでなく型番が要るため
    public static func reportText(_ totals: [PipeTotal], master: FittingMaster) -> String {
        var lines = ["用途\t管種\t呼び径\t延長(m)\t本数"
                     + "\tエルボ90°\t型番\tエルボ45°\t型番\tティーズ\t型番\tキャップ\t型番\tレデューサ"]
        for t in totals {
            func part(_ kind: String) -> String {
                guard !t.series.isEmpty, !t.size.isEmpty else { return "" }
                return master.row(series: t.series, kind: kind, size: t.size)?.partNumber ?? ""
            }
            lines.append("\(t.usageName)\t\(t.materialLabel)\t\(t.sizeLabel)\t"
                         + String(format: "%.1f", t.lengthMeters)
                         + "\t\(t.runCount)"
                         + "\t\(t.elbow90Count)\t\(part("elbow90"))"
                         + "\t\(t.elbow45Count)\t\(part("elbow45"))"
                         + "\t\(t.teeCount)\t\(part("tee"))"
                         + "\t\(t.capCount)\t\(part("cap"))"
                         + "\t\(t.reducerCount)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 継手マスタ(M6.3)

/// 継手寸法マスタ(fittings.csv)。規格シリーズ×継手種別×呼び径→A寸法・受口深さ・受口外径。
/// 継手は図面に置かず、配管の折れ点・分岐点・端部から「その都度」この表を引いて導出する
public final class FittingMaster {

    public struct Row: Equatable, Sendable {
        public let series: String   // "DV" "TS" "HI" "HT" "SGP"
        public let kind: String     // "elbow90" "elbow45" "tee" "cap" "socket" "reducer"
        public let size: String
        public let a: Double
        public let socketDepth: Double
        public let socketOD: Double
        /// メーカー型番("2151 DL-100"等。任意)。集計表に出す・採寸元をたどる。M7
        public let partNumber: String
        /// 元CSVの行番号(1始まり。検査結果の表示用)
        public let line: Int

        public var key: String { "\(series)|\(kind)|\(size)" }

        public init(series: String, kind: String, size: String, a: Double,
                    socketDepth: Double, socketOD: Double,
                    partNumber: String = "", line: Int = 0) {
            self.series = series
            self.kind = kind
            self.size = size
            self.a = a
            self.socketDepth = socketDepth
            self.socketOD = socketOD
            self.partNumber = partNumber
            self.line = line
        }
    }

    /// 寸法表の検査結果(M7)。OSE Piping Workbench の Dimensions.isValid() 相当を
    /// ロード時に走らせ、破綻した行を図面に出る前に捕まえる
    public struct Issue: Equatable, Sendable {
        public let line: Int
        public let key: String
        public let message: String

        public var description: String { "\(line)行目 \(key): \(message)" }
    }

    public let rows: [Row]
    /// ロード時に見つかった破綻(寸法の矛盾・キー重複・列不足)
    public let issues: [Issue]
    private let index: [String: Row]   // "series|kind|size"

    public static let standard: FittingMaster = {
        guard let url = Bundle.module.url(forResource: "fittings.csv", withExtension: nil,
                                          subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "fittings.csv", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return FittingMaster(csv: "")
        }
        return FittingMaster(csv: text)
    }()

    public init(csv: String) {
        var parsed: [Row] = []
        var found: [Issue] = []
        var seen: [String: Int] = [:]     // key → 先に出た行番号
        for (i, raw) in csv.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init).enumerated() {
            let lineNo = i + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 6 else {
                found.append(Issue(line: lineNo, key: f.first ?? "",
                                   message: "列が足りません(6列必要・\(f.count)列)"))
                continue
            }
            guard let a = Double(f[3]), let d = Double(f[4]), let od = Double(f[5]) else {
                found.append(Issue(line: lineNo, key: "\(f[0])|\(f[1])|\(f[2])",
                                   message: "寸法が数値として読めません"))
                continue
            }
            let row = Row(series: f[0], kind: f[1], size: f[2], a: a, socketDepth: d,
                          socketOD: od, partNumber: f.count >= 7 ? f[6] : "", line: lineNo)
            found.append(contentsOf: FittingMaster.validate(row))
            if let prev = seen[row.key] {
                found.append(Issue(line: lineNo, key: row.key,
                                   message: "キーが\(prev)行目と重複しています(先の行が使われます)"))
            } else {
                seen[row.key] = lineNo
            }
            parsed.append(row)
        }
        rows = parsed
        issues = found
        index = Dictionary(parsed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 1行ぶんの妥当性検査。OSEの isValid() と同じ考え方で、
    /// 「幾何として成立しない寸法」だけを弾く(値の当否は判定しない)
    static func validate(_ row: Row) -> [Issue] {
        var out: [Issue] = []
        func bad(_ m: String) { out.append(Issue(line: row.line, key: row.key, message: m)) }
        if !(row.a > 0) { bad("A寸法が正の値ではありません(\(row.a))") }
        if !(row.socketDepth > 0) { bad("受口深さが正の値ではありません(\(row.socketDepth))") }
        if !(row.socketOD > 0) { bad("受口外径が正の値ではありません(\(row.socketOD))") }
        if row.a > 0, row.socketDepth > 0, !(row.a >= row.socketDepth) {
            bad("A寸法(\(row.a))が受口深さ(\(row.socketDepth))より小さい — 受口が継手からはみ出します")
        }
        return out
    }

    /// 配管マスタと突き合わせた検査(受口外径 > 管外径 か)。
    /// 管外径は継手マスタ側では分からないので別関数にしてある。
    /// 戻り値にはロード時のissuesも含む
    public func validate(with master: PipeMaster) -> [Issue] {
        // series → その規格が使われる管種のod表(呼び径→外径)
        var odBySeries: [String: [String: Double]] = [:]
        for material in master.materials {
            for usage in master.usages {
                let s = FittingMaster.series(material: material.id, usage: usage.id)
                guard !s.isEmpty else { continue }
                for size in master.sizes(for: material.id) {
                    odBySeries[s, default: [:]][size.size] = size.outerDiameter
                }
            }
        }
        var out = issues
        for row in rows {
            guard let od = odBySeries[row.series]?[row.size] else { continue }
            if !(row.socketOD > od) {
                out.append(Issue(line: row.line, key: row.key,
                                 message: "受口外径(\(row.socketOD))が管外径(\(od))以下です"))
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    public var seriesList: [String] {
        var seen: [String] = []
        for r in rows where !seen.contains(r.series) { seen.append(r.series) }
        return seen
    }

    public func row(series: String, kind: String, size: String) -> Row? {
        index["\(series)|\(kind)|\(size)"]
    }

    /// 管種+用途から継手の規格シリーズを決める(標準ルール。会社ルールで上書き可)
    /// - 排水系(汚水/雑排水/雨水/通気)のVP/VU → DV
    /// - 給水・給湯系のHIVP → HI、VP → TS、HTVP → HT
    /// - 鋼管(SGP-W/SGP-VB) → SGP(ねじ込み)
    /// - 銅管/SUS はマスタ未整備 → ""(外径概算にフォールバック)
    public static func series(material: String, usage: String) -> String {
        let drain: Set<String> = ["S", "W", "RW", "VT"]
        switch material {
        case "VP", "VU":
            return drain.contains(usage) ? "DV" : "TS"
        case "HIVP":
            return "HI"
        case "HTVP":
            return "HT"
        case "SGP-W", "SGP-VB":
            return "SGP"
        default:
            return ""
        }
    }

    /// 規格シリーズ×呼び径の寸法一式(マスタに無い項目は0=呼び出し側で概算にフォールバック)
    public func dims(series: String, size: String) -> PipeFittingDims {
        guard !series.isEmpty else { return PipeFittingDims() }
        let e90 = row(series: series, kind: "elbow90", size: size)
        let e45 = row(series: series, kind: "elbow45", size: size)
        let tee = row(series: series, kind: "tee", size: size)
        let cap = row(series: series, kind: "cap", size: size)
        let ll = row(series: series, kind: "elbow90LL", size: size)
        let y45 = row(series: series, kind: "y45", size: size)
        guard let e90 else { return PipeFittingDims() }
        return PipeFittingDims(elbow90A: e90.a,
                               elbow45A: e45?.a ?? e90.a * 0.6,
                               teeA: tee?.a ?? e90.a,
                               socketDepth: e90.socketDepth,
                               socketOD: e90.socketOD,
                               capLength: cap?.a ?? e90.socketDepth + 8,
                               elbow90LLA: ll?.a ?? 0,
                               y45A: y45?.a ?? 0)
    }
}
