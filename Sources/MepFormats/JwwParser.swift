import Foundation
import MepCore

// =============================================================================
// JWW(Jw_cad)バイナリパーサ — JWWビューワー v16(JavaScript)からの移植
// 移植元: MFC-aware JWW Binary Parser (v16 - full-file scan, stride-based tag discovery)
// 検証: サンプル4図面のJS版出力との突合テスト(JwwParserFixtureTests)
// =============================================================================

public enum JwwParseError: Error, LocalizedError {
    case notAJwwFile
    public var errorDescription: String? { "JWWファイルではありません" }
}

public final class JwwParser {

    private let d: [UInt8]
    private let len: Int

    // フォーマット依存パラメータ
    private var version: UInt32 = 0
    private var cdSz = 15
    private var lOff = 9
    private var gOff = 11
    private var solidInstPayload = 68

    // 発見したMFCタグ
    private var senTag = -1, enkTag = -1, mojiTag = -1, sunpouTag = -1, tenTag = -1, solidTag = -1
    private var senMapId = -1, enkMapId = -1, mojiMapId = -1, sunpouMapId = -1, tenMapId = -1, solidMapId = -1

    // 出力
    private var lines: [JwwLine] = []
    private var arcs: [JwwArc] = []
    private var solids: [JwwSolid] = []
    private var texts: [JwwText] = []

    public init(data: Data) {
        self.d = [UInt8](data)
        self.len = d.count
    }

    // MARK: - バイト読み取りヘルパ(リトルエンディアン)

    @inline(__always) private func u8(_ i: Int) -> Int {
        (i >= 0 && i < len) ? Int(d[i]) : 0
    }

    @inline(__always) private func u16(_ i: Int) -> Int {
        guard i >= 0, i + 2 <= len else { return 0 }
        return Int(d[i]) | (Int(d[i + 1]) << 8)
    }

    @inline(__always) private func u32(_ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= len else { return 0 }
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }

    @inline(__always) private func f64(_ i: Int) -> Double {
        guard i >= 0, i + 8 <= len else { return .nan }
        var bits: UInt64 = 0
        for k in (0..<8).reversed() {
            bits = (bits << 8) | UInt64(d[i + k])
        }
        return Double(bitPattern: bits)
    }

    // MARK: - 文字列・クラス定義探索

    private func findStr(_ s: [UInt8], from: Int) -> Int {
        let nl = s.count
        guard nl > 0 else { return -1 }
        var i = max(0, from)
        outer: while i <= len - nl {
            for j in 0..<nl where d[i + j] != s[j] {
                i += 1
                continue outer
            }
            return i
        }
        return -1
    }

    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// MFCクラス定義(初出)を探す。戻り値はクラス名の直後の位置
    private func findClassDef(_ className: String) -> Int {
        let name = ascii(className)
        let pos = findStr(name, from: 6)
        if pos < 6 { return -1 }
        if u16(pos - 6) == 0xFFFF && u16(pos - 2) == name.count {
            return pos + name.count
        }
        return -1
    }

    private func findAllClassDefs(_ className: String) -> [Int] {
        let name = ascii(className)
        var result: [Int] = []
        var from = 6
        while from + name.count + 6 < len {
            let p = findStr(name, from: from)
            if p < 6 { break }
            if u16(p - 6) == 0xFFFF && u16(p - 2) == name.count {
                result.append(p + name.count)
            }
            from = p + 1
        }
        return result
    }

    // MARK: - CDataヘッダ

    @inline(__always) private func parseCData(_ off: Int) -> Int {
        if off < 0 || off + cdSz > len { return -1 }
        let layer = u16(off + lOff)
        let glayer = u16(off + gOff)
        if layer > 15 || glayer > 15 { return -1 }
        return off
    }

    @inline(__always) private func cdLayer(_ off: Int) -> UInt8 { UInt8(truncatingIfNeeded: u16(off + lOff)) }
    @inline(__always) private func cdGlayer(_ off: Int) -> UInt8 { UInt8(truncatingIfNeeded: u16(off + gOff)) }

    // MARK: - MFC CString読み取り

    private struct CStr {
        var text: String
        var end: Int
    }

    private func readCStr(_ pos: Int) -> CStr? {
        if pos < 0 || pos + 1 >= len { return nil }
        // Unicode形式: FF FE FF + 文字数
        if pos + 4 <= len && d[pos] == 0xFF && d[pos + 1] == 0xFE && d[pos + 2] == 0xFF {
            var cc: Int
            var hdr: Int
            if d[pos + 3] < 0xFF {
                cc = Int(d[pos + 3]); hdr = pos + 4
            } else {
                if pos + 6 > len { return nil }
                let w = u16(pos + 4)
                if w == 0xFFFF {
                    if pos + 10 > len { return nil }
                    cc = Int(u32(pos + 6)); hdr = pos + 10
                } else {
                    cc = w; hdr = pos + 6
                }
            }
            if cc > 50000 || hdr + cc * 2 > len { return nil }
            let bytes = Data(d[hdr..<(hdr + cc * 2)])
            let text = String(data: bytes, encoding: .utf16LittleEndian)
                ?? String(decoding: bytes, as: UTF8.self)
            return CStr(text: text, end: hdr + cc * 2)
        }
        // ANSI(Shift-JIS)形式
        var bc: Int
        var hdr2: Int
        if d[pos] < 0xFF {
            bc = Int(d[pos]); hdr2 = pos + 1
        } else {
            if pos + 3 > len { return nil }
            let w2 = u16(pos + 1)
            if w2 == 0xFFFF {
                if pos + 7 > len { return nil }
                bc = Int(u32(pos + 3)); hdr2 = pos + 7
            } else {
                bc = w2; hdr2 = pos + 3
            }
        }
        if bc > 50000 || hdr2 + bc > len { return nil }
        if bc == 0 { return CStr(text: "", end: hdr2) }
        let bytes = Data(d[hdr2..<(hdr2 + bc)])
        let text = String(data: bytes, encoding: .shiftJIS)
            ?? String(decoding: bytes, as: UTF8.self)  // TextDecoder同様、失敗時も継続
        return CStr(text: text, end: hdr2 + bc)
    }

    // MARK: - エンティティ追加(JS版のフィルタを忠実に再現)

    private func addLine(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                         _ layer: UInt8, _ glayer: UInt8, _ lntp: UInt8, _ color: UInt8) {
        lines.append(JwwLine(x1: x1, y1: y1, x2: x2, y2: y2,
                             layer: layer, glayer: glayer, lntp: lntp, color: color))
    }

    private func addArc(_ cx: Double, _ cy: Double, _ r: Double, _ sa: Double, _ ea: Double,
                        _ tilt: Double, _ flat: Double, _ layer: UInt8, _ glayer: UInt8,
                        _ isCircle: Bool, _ lntp: UInt8, _ color: UInt8) {
        arcs.append(JwwArc(cx: cx, cy: cy, r: r, startAngle: sa, endAngle: ea,
                           tilt: tilt, flatness: flat, layer: layer, glayer: glayer,
                           isCircle: isCircle, lntp: lntp, color: color))
    }

    private func isCircleSolid(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                               _ x3: Double, _ y3: Double, _ x4: Double, _ y4: Double) -> Bool {
        if x2 <= 0 { return false }
        if y2 < -0.001 || y2 > 1.001 { return false }
        if x3 < -6.3 || x3 > 6.3 { return false }
        if y3 < -6.3 || y3 > 6.3 { return false }
        if abs(x4) < 0.001 || abs(x4) > 6.3 { return false }
        let y4isInt = abs(y4 - y4.rounded()) < 0.01
        if !y4isInt && abs(y4) > 6.3 { return false }
        let centerMag = max(abs(x1), abs(y1))
        if centerMag > 1 && x2 < centerMag * 10 { return true }
        if centerMag <= 1 && x2 > 0 && x2 < 1e5 { return true }
        return false
    }

    private func addSolid(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                          _ x3: Double, _ y3: Double, _ x4: Double, _ y4: Double,
                          _ layer: UInt8, _ glayer: UInt8) {
        if isCircleSolid(x1, y1, x2, y2, x3, y3, x4, y4) {
            solids.append(JwwSolid(values: [x1, y1, x2, x2, x3, x4, y3, 0],
                                   layer: layer, glayer: glayer, isCircleMode: true))
            return
        }
        let v12max = max(abs(x1), abs(y1), max(abs(x2), abs(y2)))
        let v34max = max(abs(x3), abs(y3), max(abs(x4), abs(y4)))
        if v12max > 1 && v34max < 1 { return }
        if v34max > 1 && v12max < 1 { return }
        if v12max > 1e7 || v34max > 1e7 { return }
        if abs(x1 - x2) < 0.001 && abs(y1 - y2) < 0.001 &&
            abs(x2 - x3) < 0.001 && abs(y2 - y3) < 0.001 { return }
        let e1 = (pow(x2 - x1, 2) + pow(y2 - y1, 2)).squareRoot()
        let e2 = (pow(x3 - x2, 2) + pow(y3 - y2, 2)).squareRoot()
        let e3 = (pow(x4 - x3, 2) + pow(y4 - y3, 2)).squareRoot()
        let e4 = (pow(x1 - x4, 2) + pow(y1 - y4, 2)).squareRoot()
        let emax = max(e1, e2, max(e3, e4))
        let emin = min(e1, e2, min(e3, e4))
        if emin > 0 && emax / emin > 500 { return }
        solids.append(JwwSolid(values: [x1, y1, x2, y2, x3, y3, x4, y4],
                               layer: layer, glayer: glayer, isCircleMode: false))
    }

    // MARK: - 個別エンティティのペイロード読み(共通ヘルパ)

    /// CDataSen: CData(cdSz)+4doubles(32)。成功時true
    @discardableResult
    private func readSenPayload(_ instPos: Int) -> Bool {
        let scd = parseCData(instPos)
        guard scd >= 0 else { return false }
        let so = scd + cdSz
        guard so + 32 <= len else { return false }
        let x1 = f64(so), y1 = f64(so + 8), x2 = f64(so + 16), y2 = f64(so + 24)
        guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite,
              abs(x1) < 1e7, abs(y1) < 1e7, abs(x2) < 1e7, abs(y2) < 1e7 else { return false }
        let ll = (pow(x2 - x1, 2) + pow(y2 - y1, 2)).squareRoot()
        if ll > 0.001 && ll < 1e7 {
            addLine(x1, y1, x2, y2, cdLayer(scd), cdGlayer(scd), d[scd + 4], d[scd + 5])
        }
        return true
    }

    /// CDataEnko: CData(cdSz)+60bytes。成功時true
    @discardableResult
    private func readEnkoPayload(_ instPos: Int) -> Bool {
        let acd = parseCData(instPos)
        guard acd >= 0 else { return false }
        let ao = acd + cdSz
        guard ao + 60 <= len else { return false }
        let cx = f64(ao), cy = f64(ao + 8), r = f64(ao + 16), sa = f64(ao + 24)
        let arcA = f64(ao + 32), tilt = f64(ao + 40), flat = f64(ao + 48)
        let full = u32(ao + 56)
        guard cx.isFinite, cy.isFinite, r.isFinite, r > 0, r <= 1e7,
              abs(cx) <= 1e7, abs(cy) <= 1e7 else { return false }
        let isC = full == 1 || abs(abs(arcA) - Double.pi * 2) < 0.01
        addArc(cx, cy, r, sa, sa + arcA, tilt, flat, cdLayer(acd), cdGlayer(acd), isC, d[acd + 4], d[acd + 5])
        return true
    }

    /// CDataMoji: CData(cdSz)+68bytes+font+text。成功時はtextの終端、失敗時 -1
    private func readMojiPayload(_ instPos: Int) -> Int {
        let mcd = parseCData(instPos)
        guard mcd >= 0 else { return -1 }
        let mo = mcd + cdSz
        guard mo + 68 <= len else { return -1 }
        let mx = f64(mo), my = f64(mo + 8)
        let msx = f64(mo + 36), msy = f64(mo + 44)
        let mk = f64(mo + 60)
        guard mx.isFinite, my.isFinite, abs(mx) <= 1e7, abs(my) <= 1e7,
              msx.isFinite, msx > 0, msx <= 10000, msy.isFinite, msy > 0, msy <= 10000 else { return -1 }
        guard let fr = readCStr(mo + 68), let tr = readCStr(fr.end), !tr.text.isEmpty else { return -1 }
        texts.append(JwwText(x: mx, y: my, size: max(msx, msy), angleDegrees: mk,
                             text: tr.text, layer: cdLayer(mcd), glayer: cdGlayer(mcd)))
        return tr.end
    }

    /// CDataMoji終端位置のみ計算(mfcウォーカー用・追加なし)
    private func mojiEnd(_ instPos: Int) -> Int {
        guard instPos + cdSz + 68 <= len else { return -1 }
        guard let mfr = readCStr(instPos + cdSz + 68), let mtr = readCStr(mfr.end) else { return -1 }
        return mtr.end
    }

    // MARK: - CDataSunpou

    /// インライン寸法(N本の埋込線+パラメータ+フォント+文字)。成功時は終端位置、失敗時 -1
    private func parseSunpouAndAdd(_ instPos: Int) -> Int {
        guard instPos + cdSz <= len else { return -1 }
        let spLyr = cdLayer(instPos)
        let spGly = cdGlayer(instPos)
        if spLyr > 15 || spGly > 15 { return -1 }

        var slp = instPos + cdSz
        struct EmbLine { var x1, y1, x2, y2: Double; var layer, glayer, lntp, color: UInt8 }
        var spLines: [EmbLine] = []
        while slp + cdSz + 32 <= len {
            let sl = u16(slp + lOff)
            let sg = u16(slp + gOff)
            if sl > 15 || sg > 15 { break }
            let sx1 = f64(slp + cdSz), sy1 = f64(slp + cdSz + 8)
            let sx2 = f64(slp + cdSz + 16), sy2 = f64(slp + cdSz + 24)
            if !sx1.isFinite || !sy1.isFinite || !sx2.isFinite || !sy2.isFinite { break }
            if abs(sx1) > 1e8 || abs(sy1) > 1e8 || abs(sx2) > 1e8 || abs(sy2) > 1e8 { break }
            spLines.append(EmbLine(x1: sx1, y1: sy1, x2: sx2, y2: sy2,
                                   layer: UInt8(sl), glayer: UInt8(sg),
                                   lntp: d[slp + 4], color: d[slp + 5]))
            slp += cdSz + 32
        }
        if spLines.isEmpty { return -1 }

        let gapPos = slp + 36
        if gapPos + 3 >= len { return -1 }
        guard let sfr = readCStr(gapPos), sfr.text.count <= 200 else { return -1 }
        guard let str = readCStr(sfr.end) else { return -1 }

        for sle in spLines {
            let sll = (pow(sle.x2 - sle.x1, 2) + pow(sle.y2 - sle.y1, 2)).squareRoot()
            if sll > 0.001 && sll < 1e7 {
                addLine(sle.x1, sle.y1, sle.x2, sle.y2, sle.layer, sle.glayer, sle.lntp, sle.color)
            }
        }

        if !str.text.isEmpty {
            var spSz = 3.0
            if slp + 4 + 8 <= len {
                let v = f64(slp + 4)
                if v.isFinite && v > 0 && v < 1000 { spSz = v }
            }
            let txLine = spLines.count >= 2 ? spLines[1] : spLines[0]
            let tx = (txLine.x1 + txLine.x2) * 0.5
            let ty = (txLine.y1 + txLine.y2) * 0.5
            let rad = atan2(txLine.y2 - txLine.y1, txLine.x2 - txLine.x1)
            let angle: Double = (abs(rad) > .pi / 4 && abs(rad) < 3 * .pi / 4) ? 90 : 0
            texts.append(JwwText(x: tx, y: ty, size: spSz, angleDegrees: angle,
                                 text: str.text, layer: spLyr, glayer: spGly))
        }
        return str.end
    }

    /// mfcウォーカー用: CDataSunpouの終端のみ計算
    private func sunpouEnd(_ instPos: Int) -> Int {
        guard instPos + cdSz <= len else { return -1 }
        var slp = instPos + cdSz
        while slp + cdSz + 32 <= len {
            let sl = u16(slp + lOff)
            let sg = u16(slp + gOff)
            if sl > 15 || sg > 15 { break }
            let sx1 = f64(slp + cdSz)
            if !sx1.isFinite || abs(sx1) > 1e8 { break }
            let sy1 = f64(slp + cdSz + 8)
            if !sy1.isFinite || abs(sy1) > 1e8 { break }
            slp += cdSz + 32
        }
        if slp == instPos + cdSz { return -1 }
        let gapPos = slp + 36
        if gapPos + 3 >= len { return -1 }
        guard let sfr = readCStr(gapPos), sfr.text.count <= 200 else { return -1 }
        guard let str = readCStr(sfr.end) else { return -1 }
        return str.end
    }

    // MARK: - メイン解析

    public func parse() throws -> JwwDrawing {
        // ヘッダ検証
        if len < 12 { throw JwwParseError.notAJwwFile }
        let header = String(bytes: d[0..<7], encoding: .ascii)
        if header != "JwwData" { throw JwwParseError.notAJwwFile }

        version = u32(8)
        cdSz = version >= 351 ? 15 : 13
        lOff = cdSz == 15 ? 9 : 7
        gOff = cdSz == 15 ? 11 : 9

        var drawing = JwwDrawing()
        drawing.version = version

        // ===== グループ別縮尺+レイヤ/グループ状態 =====
        // グループブロック(148バイト×16)の構造 — サンプル4図面の実バイトで検証済み:
        //   +0        double  縮尺の分母(1/50なら50.0)
        //   +12+k*8   DWORD   レイヤk(0〜15)の状態: 0=非表示 1=表示のみ 2=編集可 3=書込
        //   +140      DWORD   グループ状態(同じコード。3=書込グループ)
        // 縮尺がexpected.json(JS版パーサ)と全一致することでブロック先頭位置の正しさを確認、
        // 状態値は4図面×256レイヤすべて0〜3に収まることを確認した。
        // 旧実装(タイトル長からの位置推定)はズレるファイルがあり削除。
        var scales: [Double] = []
        var layerStates = [UInt8](repeating: 2, count: 256)
        var groupStates = [UInt8](repeating: 2, count: 16)
        var statesValid = true
        if let nameR = readCStr(12) {
            // メモ直後のDWORD=用紙コード(0=A0…4=A4)。サンプル4図面(いずれもA1施工図)で検証
            if nameR.end + 4 <= len {
                let code = Int(u32(nameR.end))
                if code >= 0 && code <= 15 {
                    drawing.paperCode = code
                }
            }
            let firstScale = nameR.end + 16
            for gi in 0..<16 {
                let sOff = firstScale + gi * 148
                if sOff + 148 <= len {
                    let sv = f64(sOff)
                    scales.append((sv.isFinite && sv >= 0.1 && sv <= 100000) ? sv : 1)
                    for k in 0..<16 {
                        let v = u32(sOff + 12 + k * 8)
                        // 正規値: 下位3bitが0〜3、上位はプロテクトbit(8)のみ許容(0〜3, 8〜11)
                        if v & ~UInt32(0xF) == 0, v & 0x7 <= 3 {
                            layerStates[gi * 16 + k] = UInt8(v)
                        } else {
                            statesValid = false  // 範囲外=レイアウト不一致(別バージョン等)
                        }
                    }
                    let gv = u32(sOff + 140)
                    if gv & ~UInt32(0xF) == 0, gv & 0x7 <= 3 {
                        groupStates[gi] = UInt8(gv)
                    } else {
                        statesValid = false
                    }
                } else {
                    scales.append(1)
                    statesValid = false
                }
            }
        } else {
            statesValid = false
        }
        while scales.count < 16 { scales.append(100) }
        drawing.scales = scales
        // レイアウトが合わないファイルでは状態を「不明」にする
        // (読込側が全表示・全編集可で開く。誤ったロック/非表示を作らない)
        if statesValid {
            drawing.layerStates = layerStates
            drawing.groupStates = groupStates
        }

        // ===== クラス定義位置 =====
        let senDef = findClassDef("CDataSen")
        let enkDef = findClassDef("CDataEnko")
        let mojiDef = findClassDef("CDataMoji")
        let tenDef = findClassDef("CDataTen")
        let blockDef = findClassDef("CDataBlock")
        let listDef = findClassDef("CDataList")
        let sunpouDef = findClassDef("CDataSunpou")

        // CDataSolid(CDataSolidFigure内の前方一致を除外して探す)
        var solidCDataDef = -1
        do {
            let name = ascii("CDataSolid")
            var from = 6
            while from + 16 < len {
                let p = findStr(name, from: from)
                if p < 6 { break }
                if u16(p - 6) == 0xFFFF && u16(p - 2) == 10 {
                    solidCDataDef = p + 10
                    break
                }
                from = p + 1
            }
        }

        var allBlockDefs = findAllClassDefs("CDataBlock")
        var allListDefs = findAllClassDefs("CDataList")
        allBlockDefs.sort()
        allListDefs.sort()

        // ===== scanEnd(エンティティ領域の終端) =====
        var scanEnd = len
        var hasPackedBlockDefs = false
        if blockDef > 0 {
            let blkInstEnd = blockDef + 15 + 44
            hasPackedBlockDefs = blkInstEnd + 2 <= len && d[blkInstEnd] == 0xFF && d[blkInstEnd + 1] == 0x7F
            if hasPackedBlockDefs {
                let blockFfff = blockDef - 10 - 6
                if blockFfff > 0 && blockFfff < scanEnd { scanEnd = blockFfff }
            }
        }
        if listDef > 0 {
            let listFfff = listDef - 9 - 6
            if listFfff > 0 && listFfff < scanEnd { scanEnd = listFfff }
        }

        // ===== CDataSolidペイロードサイズの推定 =====
        solidInstPayload = version >= 351 ? 68 : 64
        if solidCDataDef > 0 {
            func isValidNextMarker(_ p: Int) -> Bool {
                if p + 2 > len { return false }
                let w = u16(p)
                if w == 0xFFFF { return true }
                if (w & 0x8000) != 0 && w != 0xFFFF { return true }
                if w == 0x7FFF { return true }
                return false
            }
            let ok64 = isValidNextMarker(solidCDataDef + cdSz + 64)
            let ok68 = isValidNextMarker(solidCDataDef + cdSz + 68)
            if ok64 && !ok68 { solidInstPayload = 64 }
            else if ok68 && !ok64 { solidInstPayload = 68 }
        }

        // ===== seqStart / earliestFfff =====
        var seqStart = -1
        for def in [senDef, enkDef, mojiDef, solidCDataDef, tenDef, sunpouDef] where def > 0 {
            if seqStart < 0 || def < seqStart { seqStart = def }
        }

        var earliestFfff = -1
        func considerFfff(_ def: Int, _ nameLen: Int) {
            guard def > 0 else { return }
            let p = def - nameLen - 6
            if p >= 0 && (earliestFfff < 0 || p < earliestFfff) { earliestFfff = p }
        }
        considerFfff(enkDef, 9)
        considerFfff(senDef, 8)
        considerFfff(mojiDef, 9)
        considerFfff(solidCDataDef, 10)
        considerFfff(tenDef, 8)
        considerFfff(sunpouDef, 11)

        // ===== MFC mapIdウォーカーによるタグ発見 =====
        if earliestFfff > 0 {
            var mapIdToClass: [Int: String] = [:]
            var mapId = 0
            var mfcPos = earliestFfff
            let mfcLimit = min(len, mfcPos + 5_000_000)

            func registerClass(_ name: String, _ id: Int) {
                switch name {
                case "CDataSen": senMapId = id; senTag = id < 0x8000 ? (id | 0x8000) : -1
                case "CDataEnko": enkMapId = id; enkTag = id < 0x8000 ? (id | 0x8000) : -1
                case "CDataMoji": mojiMapId = id; mojiTag = id < 0x8000 ? (id | 0x8000) : -1
                case "CDataSunpou": sunpouMapId = id; sunpouTag = id < 0x8000 ? (id | 0x8000) : -1
                case "CDataTen": tenMapId = id; tenTag = id < 0x8000 ? (id | 0x8000) : -1
                case "CDataSolid": solidMapId = id; solidTag = id < 0x8000 ? (id | 0x8000) : -1
                default: break
                }
            }

            /// クラス名に応じてインスタンスをスキップ。進めない場合は -1
            func skipInstance(_ name: String, _ instPos: Int) -> Int {
                switch name {
                case "CDataSen": return instPos + cdSz + 32
                case "CDataEnko": return instPos + cdSz + 60
                case "CDataMoji":
                    let e = mojiEnd(instPos)
                    return e > instPos ? e : -1
                case "CDataSunpou":
                    let e = sunpouEnd(instPos)
                    return e > instPos ? e : -1
                case "CDataTen": return instPos + cdSz + 20
                case "CDataSolid": return instPos + cdSz + solidInstPayload
                default: return -1
                }
            }

            walker: while mfcPos < mfcLimit - 2 {
                let mw = u16(mfcPos)

                if mw == 0xFFFF {
                    if mfcPos + 6 > mfcLimit { break }
                    let nameLen = u16(mfcPos + 4)
                    if nameLen == 0 || nameLen > 64 || mfcPos + 6 + nameLen > mfcLimit { break }
                    let name = String(bytes: d[(mfcPos + 6)..<(mfcPos + 6 + nameLen)], encoding: .ascii) ?? ""
                    mapId += 1
                    mapIdToClass[mapId] = name
                    registerClass(name, mapId)
                    let instPos = mfcPos + 6 + nameLen
                    mapId += 1
                    let next = skipInstance(name, instPos)
                    if next < 0 { break walker }
                    mfcPos = next
                    continue
                }

                if mw == 0x7FFF {
                    if mfcPos + 6 > mfcLimit { break }
                    let extDw = u32(mfcPos + 2)
                    if (extDw & 0x8000_0000) != 0 {
                        let classRef = Int(extDw & 0x7FFF_FFFF)
                        if let refClass = mapIdToClass[classRef] {
                            mapId += 1
                            let instPos = mfcPos + 6
                            let next = skipInstance(refClass, instPos)
                            if next < 0 { mfcPos += 1; continue }
                            mfcPos = next
                            continue
                        }
                    }
                    mfcPos += 1
                    continue
                }

                if (mw & 0x8000) != 0 {
                    let classRef = mw & 0x7FFF
                    guard let refClass = mapIdToClass[classRef] else { mfcPos += 1; continue }
                    mapId += 1
                    let instPos = mfcPos + 2
                    let next = skipInstance(refClass, instPos)
                    if next < 0 { mfcPos += 1; continue }
                    mfcPos = next
                    continue
                }

                // ギャップ: 次のタグ/クラス境界までバイト単位で前進(mapIdは増やさない)
                let gapScanEnd = min(mfcPos + 50000, mfcLimit)
                mfcPos += 1
                while mfcPos < gapScanEnd - 2 {
                    let gw = u16(mfcPos)
                    if gw == 0xFFFF || (gw & 0x8000) != 0 { break }
                    mfcPos += 1
                }
                if mfcPos >= gapScanEnd - 2 { break }
            }
        }

        // ===== solidTagのフォールバック推定 =====
        if solidCDataDef > 0 && solidTag < 0 && solidMapId < 0 {
            let sdnsp = solidCDataDef + cdSz + solidInstPayload
            if sdnsp + 6 <= len {
                let sdcand = u16(sdnsp)
                if sdcand == 0x7FFF {
                    let dw = u32(sdnsp + 2)
                    if (dw & 0x8000_0000) != 0 {
                        solidMapId = Int(dw & 0x7FFF_FFFF)
                        solidTag = -1
                    }
                } else if (sdcand & 0x8000) != 0 && sdcand != 0xFFFF {
                    let chk = parseCData(sdnsp + 2)
                    if chk >= 0 && chk + cdSz + 64 <= len {
                        let x1 = f64(chk + cdSz), y1 = f64(chk + cdSz + 8)
                        let x2 = f64(chk + cdSz + 16), y2 = f64(chk + cdSz + 24)
                        if x1.isFinite && y1.isFinite && abs(x1) < 1e7 && abs(y1) < 1e7 &&
                            x2.isFinite && y2.isFinite && abs(x2) < 1e7 && abs(y2) < 1e7 {
                            solidTag = sdcand
                        }
                    }
                }
            }
        }

        // ===== メインストリームスキャン =====
        let parseStart = earliestFfff > 0 ? earliestFfff : seqStart
        if parseStart > 0 && parseStart < scanEnd {
            mainScan(parseStart: parseStart, scanEnd: scanEnd, seqStart: seqStart,
                     allBlockDefs: allBlockDefs, allListDefs: allListDefs)
        }

        // ===== CDataSunpou プレストリーム領域 =====
        if sunpouDef > 0 {
            parseSunpouSection(sunpouDef: sunpouDef)
        }

        // ===== CDataBlock / CDataList =====
        if !allBlockDefs.isEmpty {
            parseBlocks(allBlockDefs: allBlockDefs, allListDefs: allListDefs,
                        seqStart: seqStart, hasPackedBlockDefs: hasPackedBlockDefs)
        }

        drawing.lines = lines
        drawing.arcs = arcs
        drawing.solids = solids
        drawing.texts = texts
        return drawing
    }

    // MARK: - メインスキャンループ

    private func mainScan(parseStart: Int, scanEnd: Int, seqStart: Int,
                          allBlockDefs: [Int], allListDefs: [Int]) {
        var pos = parseStart

        // ブロックスキップ領域(パックドブロックのみ)
        var blockSkipRegions: [(Int, Int)] = []
        var li = 0
        for bd in allBlockDefs {
            if bd <= seqStart { continue }
            let firstEnd = bd + cdSz + 44
            let packed = firstEnd + 2 <= len && d[firstEnd] == 0xFF && d[firstEnd + 1] == 0x7F
            if !packed { continue }
            while li < allListDefs.count && allListDefs[li] <= bd { li += 1 }
            let ld = li < allListDefs.count ? allListDefs[li] : len
            blockSkipRegions.append((bd, ld))
        }
        var skipRegionIdx = 0

        while pos < scanEnd - 2 {
            while skipRegionIdx < blockSkipRegions.count && pos >= blockSkipRegions[skipRegionIdx].1 {
                skipRegionIdx += 1
            }
            if skipRegionIdx < blockSkipRegions.count {
                let sr = blockSkipRegions[skipRegionIdx]
                if pos >= sr.0 && pos < sr.1 {
                    pos = sr.1
                    continue
                }
            }

            let lo = Int(d[pos])
            let hi = Int(d[pos + 1])

            // 0xFFFF: 新規クラス定義(最初のインスタンスがタグなしで続く)
            if lo == 0xFF && hi == 0xFF {
                if pos + 6 <= scanEnd {
                    let nameLen = u16(pos + 4)
                    if nameLen > 0 && nameLen <= 64 && pos + 6 + nameLen <= scanEnd {
                        let name = String(bytes: d[(pos + 6)..<(pos + 6 + nameLen)], encoding: .ascii) ?? ""
                        let inst = pos + 6 + nameLen

                        switch name {
                        case "CDataSen":
                            if senTag < 0 && senMapId < 0 {
                                discoverTag(after: inst + cdSz + 32, tag: &senTag, mapId: &senMapId)
                            }
                            readSenPayload(inst)
                            pos = inst + cdSz + 32
                            continue
                        case "CDataEnko":
                            if enkTag < 0 && enkMapId < 0 {
                                discoverTag(after: inst + cdSz + 60, tag: &enkTag, mapId: &enkMapId)
                            }
                            readEnkoPayload(inst)
                            pos = inst + cdSz + 60
                            continue
                        case "CDataMoji":
                            let end = readMojiPayload(inst)
                            if end > 0 {
                                if mojiTag < 0 && mojiMapId < 0 {
                                    discoverTag(after: end, tag: &mojiTag, mapId: &mojiMapId)
                                }
                                pos = end
                            } else {
                                pos = inst
                            }
                            continue
                        case "CDataSunpou":
                            let end = parseSunpouAndAdd(inst)
                            pos = end > inst ? end : inst
                            continue
                        case "CDataTen":
                            pos = inst + cdSz + 20
                            continue
                        case "CDataSolid":
                            if solidTag < 0 && solidMapId < 0 {
                                discoverTag(after: inst + cdSz + solidInstPayload, tag: &solidTag, mapId: &solidMapId)
                            }
                            let sld = parseCData(inst)
                            if sld >= 0 {
                                readSolidPayload(sld)
                            }
                            pos = inst + cdSz + solidInstPayload
                            continue
                        default:
                            pos = inst
                            continue
                        }
                    }
                }
                pos += 1
                continue
            }

            // 拡張タグ 0x7FFF + DWORD
            if lo == 0xFF && hi == 0x7F && pos + 6 <= scanEnd {
                let extDw = u32(pos + 2)
                if (extDw & 0x8000_0000) != 0 {
                    let mid = Int(extDw & 0x7FFF_FFFF)
                    let ip = pos + 6

                    if solidMapId >= 0x8000 && mid == solidMapId {
                        let c = parseCData(ip)
                        if c >= 0 && c + cdSz + 64 <= len {
                            if readSolidPayload(c) {
                                pos = c + cdSz + solidInstPayload
                                continue
                            }
                        }
                    }
                    if senMapId >= 0x8000 && mid == senMapId {
                        let c = parseCData(ip)
                        // JS版同様、座標が有効なときのみ前進(無効時は1バイト送り)
                        if c >= 0 && c + cdSz + 32 <= len && readSenPayload(ip) {
                            pos = c + cdSz + 32
                            continue
                        }
                    }
                    if enkMapId >= 0x8000 && mid == enkMapId {
                        let c = parseCData(ip)
                        if c >= 0 && c + cdSz + 60 <= len && readEnkoPayload(ip) {
                            pos = c + cdSz + 60
                            continue
                        }
                    }
                    if mojiMapId >= 0x8000 && mid == mojiMapId {
                        let end = readMojiPayload(ip)
                        if end > 0 { pos = end; continue }
                    }
                    if sunpouMapId >= 0x8000 && mid == sunpouMapId {
                        if parseCData(ip) >= 0 {
                            let end = parseSunpouAndAdd(ip)
                            if end > ip { pos = end; continue }
                        }
                    }
                    if tenMapId >= 0x8000 && mid == tenMapId {
                        pos = ip + cdSz + 20
                        continue
                    }
                }
                pos += 1
                continue
            }

            if (hi & 0x80) == 0 {
                pos += 1
                continue
            }

            let t = lo | (hi << 8)

            // CDataSolid(senTagと衝突する場合の判別付き)
            if solidTag > 0 && t == solidTag {
                let sldc = parseCData(pos + 2)
                if sldc >= 0 {
                    let sloc = sldc + cdSz
                    var isSolid = false
                    if solidTag != senTag {
                        isSolid = true
                    } else if sloc + solidInstPayload <= len {
                        let afterSolid = sloc + solidInstPayload
                        let afterSen = sloc + 32
                        let solidNext = afterSolid + 1 < len &&
                            ((d[afterSolid + 1] & 0x80) != 0 || (d[afterSolid] == 0xFF && d[afterSolid + 1] == 0xFF))
                        let senNext = afterSen + 1 < len &&
                            ((d[afterSen + 1] & 0x80) != 0 || (d[afterSen] == 0xFF && d[afterSen + 1] == 0xFF))
                        if solidNext && !senNext {
                            isSolid = true
                        } else if solidNext && senNext {
                            var solidChainOk = false
                            var senChainOk = false
                            if afterSolid + 2 + cdSz + 16 <= len {
                                let nsc = parseCData(afterSolid + 2)
                                if nsc >= 0 {
                                    let nsx = f64(nsc + cdSz)
                                    if nsx.isFinite && abs(nsx) < 1e7 { solidChainOk = true }
                                }
                            }
                            if afterSen + 2 + cdSz + 16 <= len {
                                let nnc = parseCData(afterSen + 2)
                                if nnc >= 0 {
                                    let nnx = f64(nnc + cdSz)
                                    if nnx.isFinite && abs(nnx) < 1e7 { senChainOk = true }
                                }
                            }
                            if solidChainOk && !senChainOk { isSolid = true }
                        }
                    }
                    if isSolid && sloc + 64 <= len {
                        readSolidPayload(sldc)
                        pos = sloc + solidInstPayload
                        continue
                    }
                    // solidでない場合はsenTag判定にフォールスルー
                }
            }

            if t == senTag {
                let scd = parseCData(pos + 2)
                if scd >= 0 {
                    let so = scd + cdSz
                    if so + 32 > len { break }
                    readSenPayload(pos + 2)
                    pos = so + 32
                    continue
                }
            }

            if t == enkTag {
                let acd = parseCData(pos + 2)
                if acd >= 0 {
                    let ao = acd + cdSz
                    if ao + 60 > len { break }
                    readEnkoPayload(pos + 2)
                    pos = ao + 60
                    continue
                }
            }

            if t == mojiTag {
                let end = readMojiPayload(pos + 2)
                if end > 0 {
                    pos = end
                    continue
                }
            }

            if sunpouTag > 0 && t == sunpouTag {
                if parseCData(pos + 2) >= 0 {
                    let end = parseSunpouAndAdd(pos + 2)
                    if end > pos + 2 { pos = end; continue }
                }
            }

            if tenTag > 0 && t == tenTag {
                pos = pos + 2 + cdSz + 20
                continue
            }

            pos += 1
        }
    }

    /// 次インスタンスのタグバイトからタグ/mapIdを発見(未発見時のみ呼ぶ)
    private func discoverTag(after p: Int, tag: inout Int, mapId: inout Int) {
        guard p + 2 <= len else { return }
        let w = u16(p)
        if w == 0x7FFF && p + 6 <= len {
            let dw = u32(p + 2)
            if (dw & 0x8000_0000) != 0 { mapId = Int(dw & 0x7FFF_FFFF) }
        } else if (w & 0x8000) != 0 && w != 0xFFFF {
            tag = w
        }
    }

    /// CDataSolidペイロード読み(64bytes = 4頂点)。座標検証込み
    @discardableResult
    private func readSolidPayload(_ cdataPos: Int) -> Bool {
        let o = cdataPos + cdSz
        guard o + 64 <= len else { return false }
        let x1 = f64(o), y1 = f64(o + 8), x2 = f64(o + 16), y2 = f64(o + 24)
        let x3 = f64(o + 32), y3 = f64(o + 40), x4 = f64(o + 48), y4 = f64(o + 56)
        guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite,
              x3.isFinite, y3.isFinite, x4.isFinite, y4.isFinite,
              abs(x1) < 1e7, abs(y1) < 1e7, abs(x2) < 1e7, abs(y2) < 1e7,
              abs(x3) < 1e7, abs(y3) < 1e7, abs(x4) < 1e7, abs(y4) < 1e7 else { return false }
        addSolid(x1, y1, x2, y2, x3, y3, x4, y4, cdLayer(cdataPos), cdGlayer(cdataPos))
        return true
    }

    // MARK: - CDataSunpou プレストリーム領域

    private func parseSunpouSection(sunpouDef: Int) {
        func parseSunpouPayload(_ payloadPos: Int) -> Int {
            var scan = payloadPos
            // SenBase[0]: 引出線
            if scan + cdSz + 32 > len { return -1 }
            let sb0cd = parseCData(scan)
            if sb0cd < 0 { return -1 }
            let sb0 = scan + cdSz
            let lx1 = f64(sb0), ly1 = f64(sb0 + 8), lx2 = f64(sb0 + 16), ly2 = f64(sb0 + 24)
            scan = sb0 + 32

            // SenBase[1]: 寸法線
            if scan + cdSz + 32 > len { return -1 }
            let sb1cd = parseCData(scan)
            if sb1cd < 0 { return -1 }
            let sb1 = scan + cdSz
            let dx1 = f64(sb1), dy1 = f64(sb1 + 8), dx2 = f64(sb1 + 16), dy2 = f64(sb1 + 24)
            scan = sb1 + 32

            // パラメータ36bytes
            if scan + 36 > len { return -1 }
            var msx = Double(f32(scan + 8))
            var msy = Double(f32(scan + 16))
            if msx <= 0 || msx > 10000 {
                msx = f64(scan + 8)
                msy = f64(scan + 16)
            }
            scan += 36

            guard let fr = readCStr(scan) else { return -1 }
            guard let tr = readCStr(fr.end), !tr.text.isEmpty else { return -1 }

            if lx1.isFinite && ly1.isFinite && lx2.isFinite && ly2.isFinite {
                let ll = (pow(lx2 - lx1, 2) + pow(ly2 - ly1, 2)).squareRoot()
                if ll > 0.001 && ll < 1e7 {
                    addLine(lx1, ly1, lx2, ly2, cdLayer(sb0cd), cdGlayer(sb0cd), 0, 0)
                }
            }
            if dx1.isFinite && dy1.isFinite && dx2.isFinite && dy2.isFinite {
                let dl = (pow(dx2 - dx1, 2) + pow(dy2 - dy1, 2)).squareRoot()
                if dl > 0.001 && dl < 1e7 {
                    addLine(dx1, dy1, dx2, dy2, cdLayer(sb1cd), cdGlayer(sb1cd), 0, 0)
                }
            }

            let tx = (dx1 + dx2) / 2, ty = (dy1 + dy2) / 2
            let rad = atan2(dy2 - dy1, dx2 - dx1)
            let dimAngle: Double = (abs(rad) > .pi / 4 && abs(rad) < 3 * .pi / 4) ? 90 : 0
            if tx.isFinite && ty.isFinite && msx.isFinite && msx > 0 && msx <= 10000 {
                let size = max(msx, (msy.isFinite && msy > 0) ? msy : msx)
                texts.append(JwwText(x: tx, y: ty, size: size, angleDegrees: dimAngle,
                                     text: tr.text, layer: cdLayer(sb1cd), glayer: cdGlayer(sb1cd)))
            }

            var skipPos = tr.end
            while skipPos < len - 2 {
                if (d[skipPos + 1] & 0x80) != 0 { break }
                if d[skipPos] == 0xFF && d[skipPos + 1] == 0xFF { break }
                skipPos += 1
            }
            return skipPos
        }

        var spPos = sunpouDef
        var spCount = 0
        while spPos < len - cdSz - 10 && spCount < 100000 {
            if spPos + 2 <= len && d[spPos] == 0xFF && d[spPos + 1] == 0x7F && spPos + 6 <= len {
                if sunpouMapId >= 0x8000 {
                    let dw = u32(spPos + 2)
                    if (dw & 0x8000_0000) != 0 && Int(dw & 0x7FFF_FFFF) == sunpouMapId {
                        spPos += 6
                        continue
                    }
                }
                break
            }
            if spPos + 2 <= len && (d[spPos + 1] & 0x80) != 0 {
                if sunpouTag > 0 {
                    let tag = u16(spPos)
                    if tag == sunpouTag { spPos += 2; continue }
                    break
                } else {
                    spPos += 2
                    continue
                }
            }
            if parseCData(spPos) < 0 { break }
            let end = parseSunpouPayload(spPos + cdSz)
            if end <= spPos { break }
            spCount += 1
            spPos = end
        }
    }

    @inline(__always) private func f32(_ i: Int) -> Float {
        guard i >= 0, i + 4 <= len else { return .nan }
        let bits = u32(i)
        return Float(bitPattern: bits)
    }

    // MARK: - CDataBlock / CDataList

    private struct BlockTransform {
        var ox, oy, sx, sy, ang: Double
        var lyr, gly: Int
    }

    private func parseBlocks(allBlockDefs: [Int], allListDefs: [Int],
                             seqStart: Int, hasPackedBlockDefs: Bool) {
        // エンティティ領域のBBox(ブロックフィルタの基準)
        var eaMinX = Double.infinity, eaMaxX = -Double.infinity
        var eaMinY = Double.infinity, eaMaxY = -Double.infinity
        for l in lines {
            eaMinX = min(eaMinX, min(l.x1, l.x2))
            eaMaxX = max(eaMaxX, max(l.x1, l.x2))
            eaMinY = min(eaMinY, min(l.y1, l.y2))
            eaMaxY = max(eaMaxY, max(l.y1, l.y2))
        }
        var blkFilterMinX = -1e8, blkFilterMaxX = 1e8
        var blkFilterMinY = -1e8, blkFilterMaxY = 1e8
        var maxLocalOffset = 1e8

        var blockTransforms: [BlockTransform] = []
        var blockDataPositions: [Int] = []

        for (gi, gBd) in allBlockDefs.enumerated() {
            // 拡張タグDWORDの検出
            var blkTagDw: UInt32 = 0
            let firstBlkEnd = gBd + cdSz + 44
            if firstBlkEnd + 6 <= len && d[firstBlkEnd] == 0xFF && d[firstBlkEnd + 1] == 0x7F {
                blkTagDw = u32(firstBlkEnd + 2)
            }

            if gBd + cdSz + 44 <= len {
                blockTransforms.append(BlockTransform(
                    ox: f64(gBd + cdSz), oy: f64(gBd + cdSz + 8),
                    sx: f64(gBd + cdSz + 16), sy: f64(gBd + cdSz + 24),
                    ang: f64(gBd + cdSz + 32),
                    lyr: u16(gBd + lOff), gly: u16(gBd + gOff)))
                blockDataPositions.append(gBd)
            }

            var ali = 0
            while ali < allListDefs.count && allListDefs[ali] <= gBd { ali += 1 }
            let gLd = ali < allListDefs.count ? allListDefs[ali] : -1
            let gBlkAreaEnd = gLd > gBd ? (gLd - 9 - 6) : len

            // 残りのCDataBlockインスタンスを拡張タグで走査
            if blkTagDw != 0 {
                var bp = firstBlkEnd
                while bp < gBlkAreaEnd - 6 && blockTransforms.count < 100000 {
                    if d[bp] == 0xFF && d[bp + 1] == 0x7F && u32(bp + 2) == blkTagDw {
                        let bip = bp + 6
                        if bip + cdSz + 44 <= len {
                            blockTransforms.append(BlockTransform(
                                ox: f64(bip + cdSz), oy: f64(bip + cdSz + 8),
                                sx: f64(bip + cdSz + 16), sy: f64(bip + cdSz + 24),
                                ang: f64(bip + cdSz + 32),
                                lyr: u16(bip + lOff), gly: u16(bip + gOff)))
                            blockDataPositions.append(bip)
                        }
                        bp = bip + cdSz + 44
                    } else {
                        bp += 1
                    }
                }
            }

            // フィルタ範囲の計算
            var refMinX = eaMinX, refMaxX = eaMaxX, refMinY = eaMinY, refMaxY = eaMaxY
            for bt in blockTransforms {
                if bt.ox.isFinite && abs(bt.ox) < 1e6 {
                    refMinX = min(refMinX, bt.ox)
                    refMaxX = max(refMaxX, bt.ox)
                }
                if bt.oy.isFinite && abs(bt.oy) < 1e6 {
                    refMinY = min(refMinY, bt.oy)
                    refMaxY = max(refMaxY, bt.oy)
                }
            }
            let lineCount = lines.count
            var filterMargin = 0.0
            var spanCheckMult = 0.0
            var useBlkFilter = false
            if lineCount >= 500 {
                filterMargin = 0.3; spanCheckMult = 1.5; useBlkFilter = true
            } else if lineCount >= 100 {
                filterMargin = 1.0; spanCheckMult = 3.0; useBlkFilter = true
            }
            var refSpanX = 1000.0, refSpanY = 1000.0
            if useBlkFilter && refMinX.isFinite && (lineCount > 0 || !blockTransforms.isEmpty) {
                refSpanX = refMaxX - refMinX
                refSpanY = refMaxY - refMinY
                if refSpanX < 1 { refSpanX = 1000 }
                if refSpanY < 1 { refSpanY = 1000 }
                blkFilterMinX = refMinX - filterMargin * refSpanX
                blkFilterMaxX = refMaxX + filterMargin * refSpanX
                blkFilterMinY = refMinY - filterMargin * refSpanY
                blkFilterMaxY = refMaxY + filterMargin * refSpanY
                maxLocalOffset = max(refSpanX, refSpanY)
            }
            let minWorldFeature = 0.01
            var blkEntitiesParsed = 0

            // ===== パックドブロック内エンティティ(ワールド座標・重複除去付き) =====
            if hasPackedBlockDefs && blockDataPositions.count > 1 {
                var seenLines = Set<String>()
                var seenArcs = Set<String>()
                for bci in 0..<blockDataPositions.count {
                    let bcStart = blockDataPositions[bci] + cdSz + 44
                    let bcEnd = bci + 1 < blockDataPositions.count
                        ? blockDataPositions[bci + 1] - 6
                        : gBlkAreaEnd
                    if bcEnd - bcStart <= 10 { continue }

                    var bep = bcStart
                    while bep < bcEnd - 2 {
                        let bew = u16(bep)

                        if senTag > 0 && bew == senTag {
                            let bsip = bep + 2
                            if bsip + cdSz + 32 > len { break }
                            let bsl = u16(bsip + lOff), bsg = u16(bsip + gOff)
                            if bsl > 15 || bsg > 15 { bep += 1; continue }
                            let x1 = f64(bsip + cdSz), y1 = f64(bsip + cdSz + 8)
                            let x2 = f64(bsip + cdSz + 16), y2 = f64(bsip + cdSz + 24)
                            if x1.isFinite && y1.isFinite && x2.isFinite && y2.isFinite &&
                                abs(x1) < 1e7 && abs(y1) < 1e7 && abs(x2) < 1e7 && abs(y2) < 1e7 {
                                let hash = "\(Int((x1 * 1000).rounded())),\(Int((y1 * 1000).rounded())),\(Int((x2 * 1000).rounded())),\(Int((y2 * 1000).rounded()))"
                                if seenLines.insert(hash).inserted {
                                    addLine(x1, y1, x2, y2, UInt8(bsl), UInt8(bsg), d[bsip + 4], d[bsip + 5])
                                }
                                blkEntitiesParsed += 1
                            }
                            bep = bsip + cdSz + 32
                            continue
                        }

                        if enkTag > 0 && bew == enkTag {
                            let baip = bep + 2
                            if baip + cdSz + 60 > len { break }
                            let bal = u16(baip + lOff), bag = u16(baip + gOff)
                            if bal > 15 || bag > 15 { bep += 1; continue }
                            let cx = f64(baip + cdSz), cy = f64(baip + cdSz + 8)
                            let r = f64(baip + cdSz + 16), sa = f64(baip + cdSz + 24)
                            let aa = f64(baip + cdSz + 32), tilt = f64(baip + cdSz + 40)
                            let flat = f64(baip + cdSz + 48)
                            let full = u32(baip + cdSz + 56)
                            if cx.isFinite && cy.isFinite && r.isFinite && r > 0 && r <= 1e7 &&
                                abs(cx) <= 1e7 && abs(cy) <= 1e7 {
                                let hash = "\(Int((cx * 1000).rounded())),\(Int((cy * 1000).rounded())),\(Int((r * 1000).rounded()))"
                                if seenArcs.insert(hash).inserted {
                                    let isC = full == 1 || abs(abs(aa) - Double.pi * 2) < 0.01
                                    addArc(cx, cy, r, sa, sa + aa, tilt, flat,
                                           UInt8(bal), UInt8(bag), isC, d[baip + 4], d[baip + 5])
                                }
                                blkEntitiesParsed += 1
                            }
                            bep = baip + cdSz + 60
                            continue
                        }

                        if mojiTag > 0 && bew == mojiTag {
                            let bmip = bep + 2
                            if bmip + cdSz + 68 > len { break }
                            let bml = u16(bmip + lOff), bmg = u16(bmip + gOff)
                            if bml > 15 || bmg > 15 { bep += 1; continue }
                            let mx = f64(bmip + cdSz), my = f64(bmip + cdSz + 8)
                            let msx = f64(bmip + cdSz + 36), msy = f64(bmip + cdSz + 44)
                            let mk = f64(bmip + cdSz + 60)
                            if mx.isFinite && my.isFinite && abs(mx) <= 1e7 && abs(my) <= 1e7 &&
                                msx.isFinite && msx > 0 && msx <= 10000 {
                                if let fr = readCStr(bmip + cdSz + 68),
                                   let tr = readCStr(fr.end), !tr.text.isEmpty {
                                    texts.append(JwwText(x: mx, y: my, size: max(msx, msy),
                                                         angleDegrees: mk, text: tr.text,
                                                         layer: UInt8(bml), glayer: UInt8(bmg)))
                                    blkEntitiesParsed += 1
                                    bep = tr.end
                                    continue
                                }
                            }
                            bep += 1
                            continue
                        }

                        bep += 1
                    }
                }
            }

            // ===== CDataList(ローカル座標×ブロック変換) =====
            let skipCDataList = hasPackedBlockDefs && blkEntitiesParsed > 100
            if gLd > 0 && !skipCDataList {
                var listTagDw: UInt32 = 0
                let listAreaEnd = gi + 1 < allBlockDefs.count ? allBlockDefs[gi + 1] : len
                var listPositions: [Int] = [gLd]

                var lscan = gLd + cdSz
                let lscanLimit = min(gLd + 500_000, listAreaEnd) - 6
                while lscan < lscanLimit {
                    if d[lscan] == 0xFF && d[lscan + 1] == 0x7F {
                        let ldw = u32(lscan + 2)
                        if (ldw & 0x8000_0000) != 0 && ldw != blkTagDw {
                            let lcand = lscan + 6
                            if lcand + cdSz + 4 <= len {
                                let ll = u16(lcand + lOff)
                                let lg = u16(lcand + gOff)
                                if ll <= 15 && lg <= 15 {
                                    listTagDw = ldw
                                    listPositions.append(lcand)
                                    break
                                }
                            }
                        }
                    }
                    lscan += 1
                }

                if listTagDw != 0 {
                    var lsp = listPositions[listPositions.count - 1] + cdSz
                    while lsp < listAreaEnd - 6 && listPositions.count < 200000 {
                        if d[lsp] == 0xFF && d[lsp + 1] == 0x7F && u32(lsp + 2) == listTagDw {
                            listPositions.append(lsp + 6)
                            lsp += 6 + cdSz
                        } else {
                            lsp += 1
                        }
                    }
                }

                for (li2, lp) in listPositions.enumerated() {
                    let lNext = li2 + 1 < listPositions.count ? listPositions[li2 + 1] - 6 : listAreaEnd
                    if lp + cdSz + 4 > len { continue }
                    let llyr = u16(lp + lOff)
                    let lgly = u16(lp + gOff)
                    let blkIdx = Int(u32(lp + cdSz))
                    if blkIdx >= blockTransforms.count { continue }
                    let bt = blockTransforms[blkIdx]
                    if !bt.ox.isFinite || !bt.oy.isFinite || !bt.sx.isFinite || !bt.sy.isFinite ||
                        !bt.ang.isFinite || abs(bt.ox) > 1e8 || abs(bt.oy) > 1e8 ||
                        abs(bt.sx) < 1e-10 || abs(bt.sy) < 1e-10 ||
                        abs(bt.sx) > 1e6 || abs(bt.sy) > 1e6 { continue }
                    let bCos = cos(bt.ang), bSin = sin(bt.ang)

                    // ヘッダのCStringをスキップ
                    var ep = lp + cdSz + 8
                    let csb = u8(ep)
                    if csb == 0xFF {
                        let csw = u16(ep + 1)
                        ep = csw == 0xFFFF ? ep + 7 + Int(u32(ep + 3)) : ep + 3 + csw
                    } else if csb == 0xFE {
                        ep = ep + 3 + u16(ep + 1) * 2
                    } else {
                        ep = ep + 1 + csb
                    }

                    // プリチェック: サンプル座標から異常スケールのインスタンスを除外
                    if useBlkFilter && spanCheckMult > 0 && refMinX.isFinite {
                        var preCount = 0
                        var preEp = ep
                        var preWMinX = Double.infinity, preWMaxX = -Double.infinity
                        var preWMinY = Double.infinity, preWMaxY = -Double.infinity
                        while preEp < lNext - 2 && preCount < 30 {
                            let pew = u16(preEp)
                            if senTag > 0 && pew == senTag {
                                let psip = preEp + 2
                                if psip + cdSz + 32 > len { break }
                                let psl = u16(psip + lOff)
                                if psl <= 15 {
                                    let psx = f64(psip + cdSz)
                                    let psy = f64(psip + cdSz + 8)
                                    if psx.isFinite && psy.isFinite && abs(psx) < 1e4 && abs(psy) < 1e4 {
                                        let pwx = bt.ox + (psx * bt.sx * bCos - psy * bt.sy * bSin)
                                        let pwy = bt.oy + (psx * bt.sx * bSin + psy * bt.sy * bCos)
                                        preWMinX = min(preWMinX, pwx)
                                        preWMaxX = max(preWMaxX, pwx)
                                        preWMinY = min(preWMinY, pwy)
                                        preWMaxY = max(preWMaxY, pwy)
                                        preCount += 1
                                    }
                                }
                                preEp = psip + cdSz + 32
                                continue
                            }
                            preEp += 1
                        }
                        if preCount >= 3 {
                            let preSpanX = preWMaxX - preWMinX
                            let preSpanY = preWMaxY - preWMinY
                            let refMax = max(refSpanX, refSpanY)
                            if preSpanX > spanCheckMult * refMax || preSpanY > spanCheckMult * refMax { continue }
                            let preCx = (preWMinX + preWMaxX) * 0.5
                            let preCy = (preWMinY + preWMaxY) * 0.5
                            let refCx = (refMinX + refMaxX) * 0.5
                            let refCy = (refMinY + refMaxY) * 0.5
                            if abs(preCx - refCx) > spanCheckMult * refMax ||
                                abs(preCy - refCy) > spanCheckMult * refMax { continue }
                        }
                    }

                    // 本パース(ローカル→ワールド変換)
                    while ep < lNext - 2 {
                        let ew = u16(ep)

                        if senTag > 0 && ew == senTag {
                            let sip = ep + 2
                            if sip + cdSz + 32 > len { break }
                            let sl = u16(sip + lOff), sg = u16(sip + gOff)
                            if sl > 15 || sg > 15 { ep += 1; continue }
                            let sx1 = f64(sip + cdSz), sy1 = f64(sip + cdSz + 8)
                            let sx2 = f64(sip + cdSz + 16), sy2 = f64(sip + cdSz + 24)
                            if sx1.isFinite && sy1.isFinite && sx2.isFinite && sy2.isFinite &&
                                abs(sx1) < 1e4 && abs(sy1) < 1e4 && abs(sx2) < 1e4 && abs(sy2) < 1e4 &&
                                abs(sx1 * bt.sx) < maxLocalOffset && abs(sy1 * bt.sy) < maxLocalOffset &&
                                abs(sx2 * bt.sx) < maxLocalOffset && abs(sy2 * bt.sy) < maxLocalOffset {
                                let wx1 = bt.ox + (sx1 * bt.sx * bCos - sy1 * bt.sy * bSin)
                                let wy1 = bt.oy + (sx1 * bt.sx * bSin + sy1 * bt.sy * bCos)
                                let wx2 = bt.ox + (sx2 * bt.sx * bCos - sy2 * bt.sy * bSin)
                                let wy2 = bt.oy + (sx2 * bt.sx * bSin + sy2 * bt.sy * bCos)
                                let wll = (pow(wx2 - wx1, 2) + pow(wy2 - wy1, 2)).squareRoot()
                                if wll > minWorldFeature && wll < 1e7 &&
                                    wx1 > blkFilterMinX && wx1 < blkFilterMaxX &&
                                    wy1 > blkFilterMinY && wy1 < blkFilterMaxY &&
                                    wx2 > blkFilterMinX && wx2 < blkFilterMaxX &&
                                    wy2 > blkFilterMinY && wy2 < blkFilterMaxY {
                                    addLine(wx1, wy1, wx2, wy2,
                                            UInt8(sl <= 15 ? sl : min(llyr, 255)),
                                            UInt8(sg <= 15 ? sg : min(lgly, 255)),
                                            d[sip + 4], d[sip + 5])
                                }
                            }
                            ep = sip + cdSz + 32
                            continue
                        }

                        if enkTag > 0 && ew == enkTag {
                            let aip = ep + 2
                            if aip + cdSz + 60 > len { break }
                            let al = u16(aip + lOff), ag = u16(aip + gOff)
                            if al > 15 || ag > 15 { ep += 1; continue }
                            let acx = f64(aip + cdSz), acy = f64(aip + cdSz + 8)
                            let ar = f64(aip + cdSz + 16), asa = f64(aip + cdSz + 24)
                            let aaa = f64(aip + cdSz + 32), atilt = f64(aip + cdSz + 40)
                            let aflat = f64(aip + cdSz + 48)
                            let afull = u32(aip + cdSz + 56)
                            if acx.isFinite && acy.isFinite && ar.isFinite && ar > 0 && ar < 1e4 &&
                                abs(acx) < 1e4 && abs(acy) < 1e4 &&
                                abs(acx * bt.sx) < maxLocalOffset && abs(acy * bt.sy) < maxLocalOffset {
                                let wcx = bt.ox + (acx * bt.sx * bCos - acy * bt.sy * bSin)
                                let wcy = bt.oy + (acx * bt.sx * bSin + acy * bt.sy * bCos)
                                let wr = ar * abs(bt.sx)
                                let isC = afull == 1 || abs(abs(aaa) - Double.pi * 2) < 0.01
                                if wr > minWorldFeature && wr < 1e5 &&
                                    wcx > blkFilterMinX && wcx < blkFilterMaxX &&
                                    wcy > blkFilterMinY && wcy < blkFilterMaxY {
                                    addArc(wcx, wcy, wr, asa + bt.ang, asa + aaa + bt.ang,
                                           atilt + bt.ang, aflat,
                                           UInt8(al <= 15 ? al : min(llyr, 255)),
                                           UInt8(ag <= 15 ? ag : min(lgly, 255)),
                                           isC, d[aip + 4], d[aip + 5])
                                }
                            }
                            ep = aip + cdSz + 60
                            continue
                        }

                        if mojiTag > 0 && ew == mojiTag {
                            let mip = ep + 2
                            if mip + cdSz + 68 > len { break }
                            let ml = u16(mip + lOff), mg = u16(mip + gOff)
                            if ml > 15 || mg > 15 { ep += 1; continue }
                            let mx = f64(mip + cdSz), my = f64(mip + cdSz + 8)
                            let msx = f64(mip + cdSz + 36), msy = f64(mip + cdSz + 44)
                            let mk = f64(mip + cdSz + 60)
                            if mx.isFinite && my.isFinite && abs(mx) <= 1e4 && abs(my) <= 1e4 &&
                                abs(mx * bt.sx) < maxLocalOffset && abs(my * bt.sy) < maxLocalOffset &&
                                msx.isFinite && msx > 0 && msx <= 1000 {
                                if let fr = readCStr(mip + cdSz + 68),
                                   let tr = readCStr(fr.end), !tr.text.isEmpty {
                                    let wtx = bt.ox + (mx * bt.sx * bCos - my * bt.sy * bSin)
                                    let wty = bt.oy + (mx * bt.sx * bSin + my * bt.sy * bCos)
                                    if wtx > blkFilterMinX && wtx < blkFilterMaxX &&
                                        wty > blkFilterMinY && wty < blkFilterMaxY {
                                        let wsz = max(msx, msy) * max(abs(bt.sx), abs(bt.sy))
                                        if wsz > minWorldFeature {
                                            texts.append(JwwText(
                                                x: wtx, y: wty, size: wsz,
                                                angleDegrees: mk + bt.ang, text: tr.text,
                                                layer: UInt8(ml <= 15 ? ml : min(llyr, 255)),
                                                glayer: UInt8(mg <= 15 ? mg : min(lgly, 255))))
                                        }
                                    }
                                    ep = tr.end
                                    continue
                                }
                            }
                            ep += 1
                            continue
                        }

                        ep += 1
                    }
                }
            }
        }
    }
}
