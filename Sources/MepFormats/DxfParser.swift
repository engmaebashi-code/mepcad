import Foundation

// MARK: - DXF読込(M5.0)
//
// 対応範囲は「Jw_cadの概念のDXF」= R12〜2007のモデル空間2D図形:
//   LINE / CIRCLE / ARC / TEXT / MTEXT / POINT / POLYLINE(+VERTEX) / LWPOLYLINE /
//   INSERT(→ブロック配置) / DIMENSION(寸法図形ブロックの展開)
// 主な用途:
//   1. メーカー機器CADデータ(R12/R13, Shift-JIS)→ ブロック化してライブラリへ
//   2. JWWから変換されたDXF2007(UTF-8)の施工図 → そのまま編集
// 検証データ: TOTO/ダイキン等の機器DXF 4件+実案件施工図の変換DXF 4件(23〜46MB)
//
// HATCH(塗り)・VIEWPORT・3D系はv1では読み飛ばす(件数を報告)。

public enum DxfParseError: Error, LocalizedError {
    case notADxf
    public var errorDescription: String? { "DXFファイルとして解釈できません(ENTITIESセクションがありません)" }
}

/// 頂点(bulge=膨らみ。0=直線、±で円弧。JWWにはない概念なので円弧に変換する)
public struct DxfVertex: Sendable {
    public var x = 0.0
    public var y = 0.0
    public var bulge = 0.0
}

/// 1エンティティの生データ(型ごとに使うフィールドが異なる)
public struct DxfEntityData: Sendable {
    public var type = ""
    public var layer = "0"
    public var colorACI: Int?          // 62。nil=未指定(ByLayer)。0=ByBlock、256=ByLayer
    public var lineTypeName: String?   // 6。nil=未指定
    public var x1 = 0.0, y1 = 0.0      // 10/20(位置・始点・中心・挿入点)
    public var x2 = 0.0, y2 = 0.0      // 11/21(終点・整列点・方向ベクトル)
    public var has2 = false
    public var value40 = 0.0           // 半径/文字高
    public var angle50 = 0.0           // 開始角/回転角(度)
    public var angle51 = 0.0           // 終了角(度)
    public var text = ""               // 1(+MTEXTは3の連結)
    public var name = ""               // 2(INSERT/DIMENSIONのブロック名)
    public var scaleX = 1.0            // 41
    public var scaleY = 1.0            // 42(LWPOLYLINEではbulgeに使うため専用処理)
    public var alignment72 = 0         // TEXT水平整列
    public var attachment71 = 0        // MTEXT取付点(1-9)
    public var flags70 = 0             // 閉フラグ・HATCHのソリッドフラグ等
    public var vertices: [DxfVertex] = []
    // SOLID(3・4点目)
    public var x3 = 0.0, y3 = 0.0      // 12/22
    public var x4 = 0.0, y4 = 0.0      // 13/23
    public var has4 = false
    // HATCH(境界とパターンの取り込み状態)
    public var hatchLoops = 0              // 92の出現回数(最初のループだけ取り込む)
    public var hatchPolylineLoop = false   // 92のbit1
    public var hatchEdgeType = 1           // 72(1=線 2=円弧)
    public var hatchBoundaryDone = false   // 75以降はシード点等なので座標を拾わない
    public var hatchArcActive = false
    public var hatchArcCx = 0.0, hatchArcCy = 0.0, hatchArcR = 0.0
    public var hatchArcA0 = 0.0, hatchArcA1 = 0.0   // 度
    public var hatchArcCCW = true          // 73
    public var patternAngle53: Double?     // パターン線の角度(度)
    public var pat45: Double?              // パターンのオフセットベクトル(=間隔)。最初の線のみ
    public var pat46: Double?

    public var closed: Bool { flags70 & 1 != 0 }
}

public struct DxfBlockData: Sendable {
    public var name = ""
    public var baseX = 0.0
    public var baseY = 0.0
    public var entities: [DxfEntityData] = []
}

public struct DxfLayerData: Sendable {
    public var name = ""
    public var colorACI = 7
    public var lineTypeName = "CONTINUOUS"
}

/// DXF解析結果(生データ。Documentへの展開はDxfReader)
public struct DxfDrawing: Sendable {
    public var acadVersion: String?
    public var layers: [DxfLayerData] = []          // LAYERテーブル順
    public var blocks: [DxfBlockData] = []
    public var entities: [DxfEntityData] = []       // ENTITIES(モデル空間)
    public var ltScale: Double?                     // $LTSCALE(JWW変換DXFでは縮尺分母)
    public var limMinX: Double?, limMinY: Double?
    public var limMaxX: Double?, limMaxY: Double?
    public var skippedTypes: [String: Int] = [:]    // 読み飛ばした型と件数
}

public struct DxfParser {

    /// 対応するエンティティ型
    static let supportedTypes: Set<String> = [
        "LINE", "CIRCLE", "ARC", "TEXT", "MTEXT", "POINT",
        "POLYLINE", "LWPOLYLINE", "INSERT", "DIMENSION",
        "SOLID", "HATCH",   // 塗り(M5.2)
    ]
    /// エンティティとして数えない制御レコード
    static let controlTypes: Set<String> = ["VERTEX", "SEQEND", "ENDBLK", "ATTDEF", "ATTRIB"]

    private let data: Data

    public init(data: Data) {
        self.data = data
    }

    /// 改行をLFへ正規化する。
    /// SwiftのStringはCRLF(\r\n)を1文字(書記素クラスタ)として扱うため、
    /// split(separator: "\n")ではWindows改行のファイルが1行も分割できない。
    /// バイト段階でCR/CRLF→LFに揃えてから文字列化する
    /// (0x0DはUTF-8のマルチバイト列にもShift-JISの2バイト目にも現れないため安全)。
    static func normalizeNewlines(_ data: Data) -> Data {
        guard data.contains(0x0D) else { return data }
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D {
                out.append(0x0A)
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    i += 2   // CRLF
                } else {
                    i += 1   // 単独CR
                }
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return Data(out)
    }

    public func parse() throws -> DxfDrawing {
        // 文字コード: DXF2007以降(AC1021〜)はUTF-8、R12〜2004はShift-JIS(dos932)が通例。
        // UTF-8として厳密に読めればUTF-8、だめならShift-JIS(ASCIIのみのファイルはどちらでも同じ)
        let normalized = Self.normalizeNewlines(data)
        let text = String(data: normalized, encoding: .utf8)
            ?? String(data: normalized, encoding: .shiftJIS)
            ?? String(decoding: normalized, as: UTF8.self)

        var drawing = DxfDrawing()

        // セクション状態
        var section = ""            // HEADER / TABLES / BLOCKS / ENTITIES
        var pendingSection = false
        var currentTable = ""       // TABLES内のテーブル名
        var headerVar = ""          // 直前の$変数名

        // レイヤテーブルの構築中レコード
        var currentLayer: DxfLayerData?

        // ブロック構築中
        var currentBlock: DxfBlockData?
        var blockAwaitingName = false

        // エンティティ構築中
        var current: DxfEntityData?
        var currentIsSupported = false
        var openPolyline: DxfEntityData?   // POLYLINE(VERTEX待ち)
        var inVertex = false               // VERTEXの10/20/42を集めている

        var sawEntities = false

        /// HATCHの円弧エッジをサンプリングして境界頂点列へ落とす
        func finishHatchArc(_ e: inout DxfEntityData) {
            guard e.hatchArcActive else { return }
            e.hatchArcActive = false
            guard e.hatchArcR > 1e-12 else { return }
            var a0 = e.hatchArcA0 * .pi / 180
            var a1 = e.hatchArcA1 * .pi / 180
            if !e.hatchArcCCW {
                swap(&a0, &a1)   // 時計回りエッジはCCW表現へ
            }
            var span = (a1 - a0).truncatingRemainder(dividingBy: 2 * .pi)
            if span <= 1e-12 { span += 2 * .pi }
            let steps = max(4, Int(span / (.pi / 8)))
            for i in 0...steps {
                let t = a0 + span * Double(i) / Double(steps)
                e.vertices.append(DxfVertex(x: e.hatchArcCx + e.hatchArcR * cos(t),
                                            y: e.hatchArcCy + e.hatchArcR * sin(t),
                                            bulge: 0))
            }
        }

        // 完成したエンティティを格納先へ
        func flushEntity() {
            defer {
                current = nil
                currentIsSupported = false
                inVertex = false
            }
            guard current != nil, currentIsSupported else { return }
            if current!.type == "HATCH" {
                finishHatchArc(&current!)
            }
            let e = current!
            if e.type == "POLYLINE" {
                openPolyline = e   // SEQENDまでVERTEXを集める
                return
            }
            store(e)
        }

        func store(_ e: DxfEntityData) {
            if currentBlock != nil {
                currentBlock!.entities.append(e)
            } else if section == "ENTITIES" {
                drawing.entities.append(e)
            }
        }

        func flushLayer() {
            if let l = currentLayer {
                drawing.layers.append(l)
            }
            currentLayer = nil
        }

        // 行を2行ペア(コード, 値)で歩く
        var iterator = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        func nextLine() -> Substring? { iterator.next() }

        while let codeLine = nextLine() {
            guard let valueLine = nextLine() else { break }
            let code = Int(codeLine.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            var value = String(valueLine)
            if value.hasSuffix("\r") { value.removeLast() }
            if code != 1 && code != 3 {
                value = value.trimmingCharacters(in: .whitespaces)
            }

            // ---- セクション遷移 ----
            if code == 0 {
                if value == "SECTION" { pendingSection = true; continue }
                if value == "ENDSEC" {
                    flushEntity()
                    if section == "TABLES" { flushLayer() }
                    if let pl = openPolyline { store(pl); openPolyline = nil }
                    section = ""
                    currentTable = ""
                    currentBlock = nil
                    continue
                }
                if value == "EOF" { break }
            }
            if pendingSection {
                if code == 2 {
                    section = value
                    pendingSection = false
                    if section == "ENTITIES" { sawEntities = true }
                }
                continue
            }

            switch section {
            case "HEADER":
                if code == 9 {
                    headerVar = value
                } else if code == 1 && headerVar == "$ACADVER" {
                    drawing.acadVersion = value
                } else if code == 40 && headerVar == "$LTSCALE" {
                    drawing.ltScale = Double(value)
                } else if headerVar == "$LIMMIN" {
                    if code == 10 { drawing.limMinX = Double(value) }
                    if code == 20 { drawing.limMinY = Double(value) }
                } else if headerVar == "$LIMMAX" {
                    if code == 10 { drawing.limMaxX = Double(value) }
                    if code == 20 { drawing.limMaxY = Double(value) }
                }

            case "TABLES":
                if code == 0 {
                    flushLayer()
                    if value == "TABLE" { currentTable = "" }
                    else if value == "LAYER" && currentTable == "LAYER" {
                        currentLayer = DxfLayerData()
                    } else if value == "ENDTAB" { currentTable = "" }
                } else if code == 2 {
                    if currentTable.isEmpty { currentTable = value }
                    else if currentLayer != nil { currentLayer!.name = value }
                } else if currentLayer != nil {
                    if code == 62 { currentLayer!.colorACI = abs(Int(value) ?? 7) }  // 負=非表示レイヤ
                    if code == 6 { currentLayer!.lineTypeName = value }
                }

            case "BLOCKS", "ENTITIES":
                if code == 0 {
                    // 前のエンティティを確定
                    if inVertex {
                        inVertex = false
                        current = nil
                        currentIsSupported = false
                    } else {
                        flushEntity()
                    }

                    switch value {
                    case "BLOCK":
                        currentBlock = DxfBlockData()
                        blockAwaitingName = true
                    case "ENDBLK":
                        if let pl = openPolyline { currentBlock?.entities.append(pl); openPolyline = nil }
                        if let b = currentBlock { drawing.blocks.append(b) }
                        currentBlock = nil
                    case "VERTEX":
                        if openPolyline != nil {
                            openPolyline!.vertices.append(DxfVertex())
                            inVertex = true
                        }
                    case "SEQEND":
                        if let pl = openPolyline { store(pl); openPolyline = nil }
                    default:
                        var e = DxfEntityData()
                        e.type = value
                        current = e
                        currentIsSupported = Self.supportedTypes.contains(value)
                        if !currentIsSupported && !Self.controlTypes.contains(value) {
                            drawing.skippedTypes[value, default: 0] += 1
                        }
                    }
                    continue
                }

                // ブロックヘッダ(名前・基準点)
                if blockAwaitingName, currentBlock != nil, current == nil, !inVertex {
                    if code == 2 { currentBlock!.name = value; continue }
                    if code == 10 { currentBlock!.baseX = Double(value) ?? 0; continue }
                    if code == 20 { currentBlock!.baseY = Double(value) ?? 0; blockAwaitingName = false; continue }
                    if code == 3 || code == 1 { continue }   // ブロック名の別名等
                }

                // VERTEXの座標
                if inVertex, openPolyline != nil, !openPolyline!.vertices.isEmpty {
                    let last = openPolyline!.vertices.count - 1
                    if code == 10 { openPolyline!.vertices[last].x = Double(value) ?? 0 }
                    if code == 20 { openPolyline!.vertices[last].y = Double(value) ?? 0 }
                    if code == 42 { openPolyline!.vertices[last].bulge = Double(value) ?? 0 }
                    continue
                }

                // エンティティ本体
                guard current != nil else { continue }
                let type = current!.type

                // HATCHは構造が特殊(ループ・エッジ・パターン定義)なので専用処理。
                // レイヤ・色・線種・パターン名・ソリッドフラグだけ共通処理へ流す
                if type == "HATCH" {
                    switch code {
                    case 8, 62, 6, 2, 70:
                        break   // 下の共通switchで処理
                    case 92:
                        finishHatchArc(&current!)
                        current!.hatchLoops += 1
                        current!.hatchPolylineLoop = ((Int(value) ?? 0) & 2) != 0
                        current!.hatchEdgeType = 1
                        continue
                    case 72:
                        // エッジループのエッジ種(ポリラインループではbulge有無フラグ)
                        if current!.hatchLoops >= 1 && !current!.hatchPolylineLoop {
                            finishHatchArc(&current!)
                            current!.hatchEdgeType = Int(value) ?? 1
                        }
                        continue
                    case 75, 76, 98:
                        current!.hatchBoundaryDone = true   // 以降の10/20はシード点等
                        continue
                    case 10:
                        if current!.hatchLoops == 1 && !current!.hatchBoundaryDone {
                            // 円弧エッジ(72=2)のみ中心+半径+角度で解釈。
                            // 楕円(3)・スプライン(4)は制御点をそのまま頂点として拾う(近似)
                            if current!.hatchEdgeType == 2 && !current!.hatchPolylineLoop {
                                current!.hatchArcActive = true
                                current!.hatchArcCx = Double(value) ?? 0
                            } else {
                                current!.vertices.append(
                                    DxfVertex(x: Double(value) ?? 0, y: 0, bulge: 0))
                            }
                        }
                        continue
                    case 20:
                        if current!.hatchLoops == 1 && !current!.hatchBoundaryDone {
                            if current!.hatchArcActive {
                                current!.hatchArcCy = Double(value) ?? 0
                            } else if !current!.vertices.isEmpty {
                                current!.vertices[current!.vertices.count - 1].y = Double(value) ?? 0
                            }
                        }
                        continue
                    case 42:
                        if current!.hatchLoops == 1 && !current!.hatchBoundaryDone,
                           !current!.vertices.isEmpty {
                            current!.vertices[current!.vertices.count - 1].bulge = Double(value) ?? 0
                        }
                        continue
                    case 40:
                        if current!.hatchArcActive { current!.hatchArcR = Double(value) ?? 0 }
                        continue
                    case 50:
                        if current!.hatchArcActive { current!.hatchArcA0 = Double(value) ?? 0 }
                        continue
                    case 51:
                        if current!.hatchArcActive { current!.hatchArcA1 = Double(value) ?? 0 }
                        continue
                    case 73:
                        if current!.hatchArcActive { current!.hatchArcCCW = (Int(value) ?? 1) != 0 }
                        continue
                    case 53:
                        if current!.patternAngle53 == nil {
                            current!.patternAngle53 = Double(value)   // 最初のパターン線の角度
                        }
                        continue
                    case 45:
                        if current!.pat45 == nil { current!.pat45 = Double(value) }
                        continue
                    case 46:
                        if current!.pat46 == nil { current!.pat46 = Double(value) }
                        continue
                    default:
                        continue
                    }
                }

                switch code {
                case 8: current!.layer = value
                case 62: current!.colorACI = Int(value)
                case 6: current!.lineTypeName = value
                case 10:
                    if type == "LWPOLYLINE" {
                        current!.vertices.append(DxfVertex(x: Double(value) ?? 0, y: 0, bulge: 0))
                    } else {
                        current!.x1 = Double(value) ?? 0
                    }
                case 20:
                    if type == "LWPOLYLINE" {
                        if !current!.vertices.isEmpty {
                            current!.vertices[current!.vertices.count - 1].y = Double(value) ?? 0
                        }
                    } else {
                        current!.y1 = Double(value) ?? 0
                    }
                case 11: current!.x2 = Double(value) ?? 0; current!.has2 = true
                case 21: current!.y2 = Double(value) ?? 0; current!.has2 = true
                case 12: current!.x3 = Double(value) ?? 0
                case 22: current!.y3 = Double(value) ?? 0
                case 13: current!.x4 = Double(value) ?? 0; current!.has4 = true
                case 23: current!.y4 = Double(value) ?? 0
                case 40: current!.value40 = Double(value) ?? 0
                case 50: current!.angle50 = Double(value) ?? 0
                case 51: current!.angle51 = Double(value) ?? 0
                case 41: current!.scaleX = Double(value) ?? 1
                case 42:
                    if type == "LWPOLYLINE" {
                        if !current!.vertices.isEmpty {
                            current!.vertices[current!.vertices.count - 1].bulge = Double(value) ?? 0
                        }
                    } else {
                        current!.scaleY = Double(value) ?? 1
                    }
                case 1: current!.text += value
                case 3:
                    if type == "MTEXT" { current!.text += value }
                case 2: current!.name = value
                case 70: current!.flags70 = Int(value) ?? 0
                case 71: current!.attachment71 = Int(value) ?? 0
                case 72: current!.alignment72 = Int(value) ?? 0
                default: break
                }

            default:
                break
            }
        }
        flushEntity()

        guard sawEntities else { throw DxfParseError.notADxf }
        return drawing
    }
}

// MARK: - MTEXT/TEXTの整形コード除去

public enum DxfTextDecoder {

    /// MTEXTの書式コード({}, \P, \f...; 等)を落として素の文字にする。%%記号も展開
    public static func plainText(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "}" {
                i += 1
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let cmd = chars[i + 1]
                switch cmd {
                case "\\", "{", "}":
                    out.append(cmd); i += 2
                case "P", "X":                       // 改行・分数区切り → 空白1つ
                    out.append(" "); i += 2
                case "~":
                    out.append(" "); i += 2
                case "L", "l", "O", "o", "K", "k":   // 下線等のトグル(引数なし)
                    i += 2
                case "U":                            // \U+XXXX
                    if i + 6 < chars.count, chars[i + 2] == "+",
                       let scalar = UInt32(String(chars[(i + 3)...(i + 6)]), radix: 16),
                       let u = Unicode.Scalar(scalar) {
                        out.append(Character(u))
                        i += 7
                    } else {
                        i += 2
                    }
                case "S":                            // 分数 \S上^下; → 上/下
                    var j = i + 2
                    var frag = ""
                    while j < chars.count, chars[j] != ";" {
                        frag.append(chars[j] == "^" ? "/" : chars[j])
                        j += 1
                    }
                    out += frag
                    i = min(j + 1, chars.count)
                default:                             // \f...; \H...; \W...; \A...; \C...; \T...; \Q...;
                    var j = i + 2
                    while j < chars.count, chars[j] != ";" { j += 1 }
                    i = (j < chars.count) ? j + 1 : chars.count
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return decodePercent(out)
    }

    /// %%c(φ)・%%d(°)・%%p(±)・%%u/%%o(下線トグル=除去)
    public static func decodePercent(_ s: String) -> String {
        guard s.contains("%%") else { return s }
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 2 < chars.count, chars[i + 1] == "%" {
                switch String(chars[i + 2]).lowercased() {
                case "c": out.append("φ")
                case "d": out.append("°")
                case "p": out.append("±")
                case "u", "o": break
                default: out.append(chars[i + 2])
                }
                i += 3
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
