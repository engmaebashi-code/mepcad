import Foundation
import MepCore

// MARK: - JWW(Jw_cad)書き出し M8.1
//
// Jw_cad ver.7/8 が読める JwwData ver.700 のファイルを書く。
// 構造(同梱の実図面4件で全バイトを歩いて検証済み):
//   "JwwData." + DWORD 700 + ヘッダ(メモ・用紙・16グループ×16レイヤの状態と縮尺・各種設定)
//   + 図形リスト(WriteCount + MFC CArchive流のオブジェクト列) + ブロック定義リスト + DWORD 0
// 文字列は Jw_cad 7 と同じ Unicode 形式(FF FE FF + 文字数 + UTF-16LE)。
// クラスタグは MFC の CArchive::WriteObject と同じ: 初出は FFFF+schema(230)+名前、以後は
// (0x8000|クラス番号)。番号はクラスとオブジェクトを合わせて1から数える。
//
// 座標: JWWは図寸(紙面mm)で持つので、要素の所属グループの縮尺で割って書く。
// MepCad独自の要素(寸法・引出線・配管・ハッチング・ブロック)は線・円弧・文字・ソリッドへ
// 分解して書く(Jw_cadで見た目が同じになることを優先。属性の往復は .mepcad で担保する)。

public struct JwwWriter {

    /// ファイルに書くメモ(図面名)
    public var memo: String

    public init(memo: String = "") {
        self.memo = memo
    }

    // MARK: 出力用の図形(実寸mm・所属レイヤ付き)

    fileprivate enum Prim {
        case line(Vec2, Vec2)
        case circle(Vec2, Double, flatness: Double)
        case arc(Vec2, Double, start: Double, sweep: Double)
        case text(Vec2, String, height: Double, angle: Double)
        case solid([Vec2])
        case point(Vec2)
    }

    fileprivate struct Item {
        var layer: LayerAddress
        var color: Int      // JWW線色 1〜9(ソリッドは1〜9)
        var lineType: Int   // JWW線種 1〜9
        var prim: Prim
    }

    // MARK: 変換

    public func data(from document: Document) -> Data {
        let items = collect(document)
        var w = ByteWriter()
        writeHeader(&w, document: document)
        // 図形リスト
        var ar = MfcArchive()
        w.count(items.count)
        for item in items {
            let scale = max(document.groups[item.layer.group].scale, 1e-9)
            write(item, scale: scale, archive: &ar, to: &w)
        }
        // ブロック定義リスト(分解して書くので空)+ 末尾
        w.count(0)
        w.u32(0)
        return Data(w.bytes)
    }

    // MARK: 要素の分解

    fileprivate func collect(_ document: Document) -> [Item] {
        var out: [Item] = []
        let junctions = PipeNetwork.junctions(in: document.entities)
        for e in document.entities {
            append(e, document: document, junctions: junctions[e.id] ?? [], depth: 0, into: &out)
        }
        return out
    }

    fileprivate func styleOf(_ entity: Entity, document: Document) -> (color: Int, lineType: Int) {
        let layer = document.layer(at: entity.layer)
        let c = entity.style.colorIndex ?? layer.defaultColorIndex
        let lt = entity.style.lineType ?? layer.defaultLineType
        return (jwwColor(c), jwwLineType(lt))
    }

    private func jwwColor(_ index: Int) -> Int {
        (1...9).contains(index) ? index : 1
    }

    private func jwwLineType(_ internalType: Int) -> Int {
        (0...8).contains(internalType) ? internalType + 1 : 1
    }

    fileprivate func append(_ entity: Entity, document: Document, junctions: [PipeJunction],
                            depth: Int, into out: inout [Item]) {
        let st = styleOf(entity, document: document)
        func add(_ p: Prim, lineType: Int? = nil) {
            out.append(Item(layer: entity.layer, color: st.color,
                            lineType: lineType ?? st.lineType, prim: p))
        }
        func seg(_ a: Vec2, _ b: Vec2, lineType: Int? = nil) {
            guard a.distance(to: b) > 1e-9 else { return }
            add(.line(a, b), lineType: lineType)
        }
        func poly(_ pts: [Vec2], close: Bool, lineType: Int? = nil) {
            guard pts.count >= 2 else { return }
            for i in 0..<(pts.count - 1) { seg(pts[i], pts[i + 1], lineType: lineType) }
            if close, pts.count >= 3 { seg(pts[pts.count - 1], pts[0], lineType: lineType) }
        }

        switch entity.kind {
        case .line(let a, let b):
            seg(a, b)
        case .circle(let c, let r):
            add(.circle(c, r, flatness: 1))
        case .arc(let c, let r, let sa, let ea):
            var sweep = ea - sa
            while sweep <= 0 { sweep += 2 * .pi }
            while sweep > 2 * .pi { sweep -= 2 * .pi }
            add(.arc(c, r, start: sa, sweep: sweep))
        case .text(let p, let content, let height, let angle):
            add(.text(p, content, height: height, angle: angle))
        case .point(let p):
            add(.point(p))
        case .blockRef(let defID, let insert, let rotation, let scale, let mirrored, _):
            // ブロックは分解して書く(Jw_cadのブロックには変換しない)
            guard depth < 8, let def = document.blockDefinitions.first(where: { $0.id == defID }) else { return }
            let members = def.instantiate(insert: insert, rotation: rotation, scale: scale,
                                          mirrored: mirrored, layer: entity.layer,
                                          overrideStyle: entity.style)
            for m in members {
                append(m, document: document, junctions: [], depth: depth + 1, into: &out)
            }
        case .hatch(let boundary, let pattern):
            if pattern.kind == .solid {
                // 扇形分割でソリッドに(凸多角形で正確。凹は近似)
                guard boundary.count >= 3 else { return }
                for i in 1..<(boundary.count - 1) {
                    add(.solid([boundary[0], boundary[i], boundary[i + 1]]))
                }
            } else {
                for s in HatchGeometry.strokes(boundary: boundary, pattern: pattern) {
                    seg(s.a, s.b)
                }
            }
        case .dimension:
            guard let layout = DimensionGeometry.layout(of: entity) else { return }
            for s in layout.hitSegments + layout.arrowStrokes { seg(s.0, s.1, lineType: 1) }
            for c in layout.dotCenters { add(.circle(c, layout.dotRadius, flatness: 1), lineType: 1) }
            add(.text(layout.textPosition, layout.textContent,
                      height: layout.textHeight, angle: layout.textAngle))
        case .leader:
            guard let layout = LeaderGeometry.layout(of: entity) else { return }
            for s in layout.segments + layout.arrowStrokes + layout.dividers { seg(s.0, s.1, lineType: 1) }
            for el in layout.ellipses where el.rx > 1e-9 {
                add(.circle(el.center, el.rx, flatness: max(el.ry / el.rx, 0.01)), lineType: 1)
            }
            for t in layout.texts {
                add(.text(t.position, t.content, height: layout.textHeight, angle: 0))
            }
        case .pipe(let points, let attrs):
            guard points.count >= 2 else { return }
            appendPipe(points: points, attrs: attrs, junctions: junctions, add: add, seg: seg, poly: poly)
        }
    }

    /// 配管: 画面描画(Renderer)と同じ部品構成で線・円弧・文字に分解する
    private func appendPipe(points: [Vec3], attrs: PipeAttributes, junctions: [PipeJunction],
                            add: (Prim, Int?) -> Void,
                            seg: (Vec2, Vec2, Int?) -> Void,
                            poly: ([Vec2], Bool, Int?) -> Void) {
        if attrs.doubleLine, let layout = PipeGeometry.doubleLineLayout(points: points, attrs: attrs) {
            for run in layout.runs {
                poly(run.left, false, 1)
                poly(run.right, false, 1)
                poly(run.center, false, 5)          // 芯線は一点鎖線
            }
            for cap in layout.endCaps { seg(cap.0, cap.1, 1) }
            if attrs.autoFittings {
                var shapes = layout.fittings
                for j in junctions { shapes += PipeNetwork.junctionShapes(j, attrs: attrs) }
                for shape in shapes {
                    for part in shape.parts {
                        switch part {
                        case .polygon(let pts): poly(pts, true, 1)
                        case .polyline(let pts): poly(pts, false, 1)
                        case .circle(let c, let r): add(.circle(c, r, flatness: 1), 1)
                        }
                    }
                }
            }
        } else {
            for run in PipeSymbols.singleLineRuns(points: points, attrs: attrs, junctions: junctions) {
                poly(run, false, nil)
            }
            for el in PipeSymbols.elements(points: points, attrs: attrs, junctions: junctions) {
                switch el {
                case .segment(let a, let b): seg(a, b, 1)
                case .arc(let c, let r, let s, let e):
                    var sweep = e - s
                    while sweep <= 0 { sweep += 2 * .pi }
                    add(.arc(c, r, start: s, sweep: sweep), 1)
                case .circle(let c, let r): add(.circle(c, r, flatness: 1), 1)
                }
            }
        }
        // 立上り/立下り記号(立上り=閉じた円、立下り=管側が開いたC形)
        let risers = PipeGeometry.risers(points: points)
        if !risers.isEmpty {
            let rs = PipeGeometry.riserSymbolRadius(attrs)
            let suppressed: [Vec2] = junctions.compactMap {
                if case .teeBranch(_, _, let v) = $0.kind, v { return $0.position }
                return nil
            }
            for (idx, riser) in risers.enumerated() {
                if suppressed.contains(where: { $0.distance(to: riser.position) <= PipeNetwork.joinTolerance }) {
                    continue
                }
                let innerR = attrs.doubleLine ? attrs.outerDiameter / 2 : 0
                if riser.isUp {
                    add(.circle(riser.position, rs, flatness: 1), 1)
                    if innerR > 0.5 { add(.circle(riser.position, innerR, flatness: 1), 1) }
                } else {
                    let lead = PipeSymbols.riserLead(points: points, riserIndex: idx)
                    let toward = lead?.toward ?? Vec2(-1, 0)
                    let a0 = atan2(toward.y, toward.x)
                    var halfOpen = Double.pi / 6
                    if attrs.doubleLine {
                        halfOpen = asin(min(max(attrs.outerDiameter / 2 / max(rs, 1e-9), 0.3), 0.95))
                    }
                    add(.arc(riser.position, rs, start: a0 + halfOpen, sweep: 2 * .pi - 2 * halfOpen), 1)
                    if innerR > 0.5 {
                        add(.arc(riser.position, innerR, start: a0 + .pi / 2, sweep: .pi), 1)
                    }
                }
            }
        }
        if let note = PipeGeometry.annotation(points: points, attrs: attrs) {
            add(.text(note.position, note.content, height: attrs.textHeight, angle: note.angle), nil)
        }
    }

    // MARK: 図形の書き出し

    fileprivate func write(_ item: Item, scale: Double, archive ar: inout MfcArchive, to w: inout ByteWriter) {
        let k = 1 / scale
        func cdata(_ w: inout ByteWriter, color: Int, lineType: Int) {
            w.u32(0)                          // 曲線属性番号
            w.u8(UInt8(lineType))             // 線種
            w.u16(UInt16(color))              // 線色
            w.u16(0)                          // 線幅
            w.u16(UInt16(item.layer.layer))
            w.u16(UInt16(item.layer.group))
            w.u16(0)                          // 属性フラグ
        }
        switch item.prim {
        case .line(let a, let b):
            ar.object("CDataSen", to: &w)
            cdata(&w, color: item.color, lineType: item.lineType)
            w.f64(a.x * k); w.f64(a.y * k); w.f64(b.x * k); w.f64(b.y * k)
        case .circle(let c, let r, let flatness):
            ar.object("CDataEnko", to: &w)
            cdata(&w, color: item.color, lineType: item.lineType)
            w.f64(c.x * k); w.f64(c.y * k); w.f64(r * k)
            w.f64(0); w.f64(2 * .pi); w.f64(0); w.f64(flatness)
            w.u32(1)
        case .arc(let c, let r, let start, let sweep):
            ar.object("CDataEnko", to: &w)
            cdata(&w, color: item.color, lineType: item.lineType)
            w.f64(c.x * k); w.f64(c.y * k); w.f64(r * k)
            w.f64(start); w.f64(sweep); w.f64(0); w.f64(1)
            w.u32(0)
        case .text(let p, let content, let height, let angle):
            ar.object("CDataMoji", to: &w)
            cdata(&w, color: item.color, lineType: 1)
            let h = height * k
            let width = LeaderGeometry.textWidth(content, height: height) * k
            let end = Vec2(p.x * k + cos(angle) * width, p.y * k + sin(angle) * width)
            w.f64(p.x * k); w.f64(p.y * k); w.f64(end.x); w.f64(end.y)
            w.u32(0)                          // 文字種: 任意サイズ
            w.f64(h); w.f64(h); w.f64(0)      // 幅・高さ・間隔(紙面mm)
            w.f64(angle * 180 / .pi)
            w.str("ＭＳ ゴシック")
            w.str(content)
        case .solid(let pts):
            ar.object("CDataSolid", to: &w)
            cdata(&w, color: item.color, lineType: 1)
            let p1 = pts[0], p2 = pts[1], p3 = pts[2], p4 = pts.count >= 4 ? pts[3] : pts[2]
            w.f64(p1.x * k); w.f64(p1.y * k)
            w.f64(p4.x * k); w.f64(p4.y * k)
            w.f64(p2.x * k); w.f64(p2.y * k)
            w.f64(p3.x * k); w.f64(p3.y * k)
        case .point(let p):
            ar.object("CDataTen", to: &w)
            cdata(&w, color: item.color, lineType: 1)
            w.f64(p.x * k); w.f64(p.y * k)
            w.u32(0)                          // 実点
        }
    }

    // MARK: ヘッダ

    fileprivate func writeHeader(_ w: inout ByteWriter, document: Document) {
        let D = JwwHeaderDefaults.self
        w.ascii("JwwData.")
        w.u32(700)
        w.str(memo)
        w.u32(UInt32(document.paperSize.rawValue))          // 用紙(JWWコードと同じ)
        let cur = document.current
        w.u32(UInt32(cur.group))                             // 書込グループ
        for g in 0..<16 {
            let group = document.groups[g]
            // JWWの書込レイヤは表示・編集可能である必要がある。現在レイヤが
            // ロック／非表示になっている場合は、そのグループ内の有効なレイヤへ退避する。
            let currentLayerIsWritable = g == cur.group
                && group.layers[cur.layer].isVisible
                && group.layers[cur.layer].isEditable
            let writeLayer = currentLayerIsWritable ? cur.layer
                : (group.layers.firstIndex(where: { $0.isVisible && $0.isEditable }) ?? 0)
            w.u32(state(visible: group.isVisible, editable: group.isEditable, current: g == cur.group))
            w.u32(UInt32(writeLayer))
            w.f64(group.scale)
            w.u32(0)                                         // グループのプロテクト
            for l in 0..<16 {
                let layer = group.layers[l]
                w.u32(state(visible: layer.isVisible, editable: layer.isEditable, current: l == writeLayer))
                w.u32(0)
            }
        }
        for _ in 0..<14 { w.u32(0) }                         // Dummy
        for v in D.sunpou { w.u32(v) }
        w.u32(0)                                             // Dummy1
        w.i32(-100)                                          // 線幅: 1/100mm単位モード
        w.f64(0); w.f64(0); w.f64(1); w.u32(0)               // 印刷原点・倍率・90°回転
        w.u32(0); w.f64(15); w.f64(5); w.f64(5); w.f64(0); w.f64(0)   // 目盛
        for g in 0..<16 {
            for l in 0..<16 { w.str(document.groups[g].layers[l].name) }
        }
        for g in 0..<16 { w.str(document.groups[g].name) }
        w.f64(1.5); w.f64(36); w.u32(0); w.f64(0)            // 日影
        w.f64(0); w.f64(50)                                  // 天空図
        w.u32(0)                                             // 2.5D単位
        w.f64(1); w.f64(0); w.f64(0)                         // 画面倍率・原点
        w.f64(1); w.f64(0); w.f64(0)                         // 範囲記憶
        for _ in 0..<8 { w.f64(1); w.f64(0); w.f64(0); w.u32(0xFFFF_FFFF) }   // ズーム記憶
        w.f64(1); w.f64(0); w.f64(0); w.u32(0xFFFF_FFFF); w.f64(1); w.f64(0)   // Dummy
        w.f64(0); w.u32(0xFFFF_FFFF)                         // 文字背景
        for v in D.fukusen { w.f64(v) }
        w.f64(0)
        for (c, wd) in D.pen { w.u32(c); w.u32(wd) }
        for (c, wd, r) in D.prtPen { w.u32(c); w.u32(wd); w.f64(r) }
        for row in D.lineType2to9 { for v in row { w.u32(v) } }
        for row in D.lineType11to15 { for v in row { w.u32(v) } }
        for row in D.lineType16to19 { for v in row { w.u32(v) } }
        for _ in 0..<5 { w.u32(0) }                          // 描画フラグ
        for v in D.printFlags { w.u32(v) }
        w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)     // 作図時間・2.5D視点
        for _ in 0..<5 { w.f64(0) }
        w.f64(0); w.f64(0); w.f64(0); w.f64(0)               // 寸法の既定値
        w.u32(0); w.u32(8421504)                             // ソリッド色
        // SXF拡張色(257)・拡張線種(33)
        for n in 0...256 {
            let c = n < D.sxfColors.count ? D.sxfColors[n].rgb : 0
            w.u32(c); w.u32(18)
        }
        for n in 0...256 {
            let name = n < D.sxfColors.count ? D.sxfColors[n].name : ""
            let c = n < D.sxfColors.count ? D.sxfColors[n].rgb : 0
            w.str(name); w.u32(c); w.u32(18); w.f64(0.18)
        }
        for n in 0...32 {
            let row = n < D.sxfLineTypes.count ? D.sxfLineTypes[n].pattern : (0, 32, 1, 10)
            w.u32(row.0); w.u32(row.1); w.u32(row.2); w.u32(row.3)
        }
        for n in 0...32 {
            let lt = n < D.sxfLineTypes.count ? D.sxfLineTypes[n] : D.emptySxfLineType
            w.str(lt.name); w.u32(lt.segments)
            for j in 0..<10 { w.f64(j < lt.pitch.count ? lt.pitch[j] : 0) }
        }
        for (x, y, d, c) in D.textKinds { w.f64(x); w.f64(y); w.f64(d); w.u32(c) }
        w.f64(2); w.f64(2); w.f64(0); w.u32(1); w.u32(1)     // 現在の文字設定
        w.f64(5); w.f64(0); w.u32(0)                         // 文字整理
        for v in [-1.0, 0, 1, -1, 0, 1] { w.f64(v) }         // 文字基準点ずれ
    }

    private func state(visible: Bool, editable: Bool, current: Bool) -> UInt32 {
        if !visible { return 0 }
        if !editable { return 1 }
        return current ? 3 : 2
    }
}

// MARK: - バイト列・MFCアーカイブ

fileprivate struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func ascii(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }

    /// MFC CObList::Serialize と同じ個数表記(0xFFFF未満はWORD、以上は0xFFFF+DWORD)
    mutating func count(_ n: Int) {
        if n < 0xFFFF { u16(UInt16(n)) } else { u16(0xFFFF); u32(UInt32(n)) }
    }

    /// Jw_cad 7 の CString(Unicode): FF FE FF + 文字数 + UTF-16LE
    mutating func str(_ s: String) {
        let units = Array(s.utf16)
        u8(0xFF); u8(0xFE); u8(0xFF)
        let n = units.count
        if n < 0xFF {
            u8(UInt8(n))
        } else if n < 0xFFFE {
            u8(0xFF); u16(UInt16(n))
        } else {
            u8(0xFF); u16(0xFFFF); u32(UInt32(n))
        }
        for u in units { u16(u) }
    }
}

/// MFC CArchive::WriteObject 互換のクラスタグ管理
fileprivate struct MfcArchive {
    private var classIndex: [String: Int] = [:]
    private var mapCount = 1

    /// オブジェクト1個の前置き(クラスタグ)。この後に本体を書く
    mutating func object(_ className: String, to w: inout ByteWriter) {
        if let idx = classIndex[className] {
            if idx < 0x7FFF {
                w.u16(UInt16(0x8000 | idx))
            } else {
                w.u16(0x7FFF)
                w.u32(UInt32(0x8000_0000 | idx))
            }
        } else {
            w.u16(0xFFFF)
            w.u16(230)                                  // schema(Jw_cadの全クラス共通)
            let name = Array(className.utf8)
            w.u16(UInt16(name.count))
            w.bytes.append(contentsOf: name)
            classIndex[className] = mapCount
            mapCount += 1
        }
        mapCount += 1                                   // オブジェクト自身も番号を消費する
    }
}

// MARK: - ヘッダの既定値(Jw_cad 7 の新規図面から採取)

enum JwwHeaderDefaults {
    static let sunpou: [UInt32] = [3001111, 0, 50150030, 12000000, 4100]
    static let fukusen: [Double] = [100, 200, 300, 400, 500, 1000, 2000, 3000, 4000, 5000]
    /// 画面の線色(BGR)と線幅 1〜9(先頭は0番)
    static let pen: [(UInt32, UInt32)] = [
        (2105376, 1), (16776960, 1), (16777215, 1), (65280, 1), (65535, 1),
        (12583104, 1), (16719904, 1), (8421376, 1), (160, 1), (8421504, 1)]
    /// 印刷の線色・線幅(1/100mm)・実点半径
    static let prtPen: [(UInt32, UInt32, Double)] = [
        (16777215, 1, 0.1), (0, 15, 0.2), (0, 15, 0.3), (65280, 20, 0.4), (65535, 30, 0.5),
        (16711935, 35, 0.5), (16711680, 40, 0.5), (8421376, 50, 0.5), (255, 60, 0.5), (32768, 70, 0.1)]
    static let lineType2to9: [[UInt32]] = [
        [2576980377, 4, 1, 12], [3284386755, 8, 1, 12], [3890735079, 8, 1, 12], [4188010911, 16, 1, 12],
        [4294549503, 32, 1, 12], [4065325647, 16, 1, 12], [4294070271, 32, 1, 12], [572662306, 4, 1, 10]]
    static let lineType11to15: [[UInt32]] = [
        [3434263338, 1, 3, 1, 5], [3434263338, 1, 4, 1, 10], [3434263338, 2, 5, 2, 15],
        [3434263338, 2, 6, 2, 20], [3434263338, 2, 7, 2, 25]]
    static let lineType16to19: [[UInt32]] = [
        [4294549503, 32, 2, 20], [4294070271, 32, 2, 20], [4294868991, 32, 2, 20], [4294868991, 32, 4, 40]]
    static let printFlags: [UInt32] = [0, 1, 1, 0, 0, 10]
    static let sxfColors: [(name: String, rgb: UInt32)] = [
        ("", 0), ("black", 0), ("red", 255), ("green", 65280), ("blue", 16711680), ("yellow", 65535),
        ("magenta", 16711935), ("cyan", 16776960), ("white", 16777215), ("deeppink", 8388800),
        ("brown", 4227264), ("orange", 33023), ("lightgreen", 8437888), ("lightblue", 16744448),
        ("lavender", 16728192), ("lightgray", 12632256), ("darkgray", 8421504)]
    struct SxfLineType {
        let name: String
        let segments: UInt32
        let pitch: [Double]
        let pattern: (UInt32, UInt32, UInt32, UInt32)
    }
    static let emptySxfLineType = SxfLineType(name: "", segments: 0, pitch: [], pattern: (0, 32, 1, 10))
    static let sxfLineTypes: [SxfLineType] = [
        emptySxfLineType,
        SxfLineType(name: "continuous", segments: 0, pitch: [], pattern: (4294967295, 32, 32, 10)),
        SxfLineType(name: "dashed", segments: 2, pitch: [6, 1.5], pattern: (4265606719, 32, 16, 15)),
        SxfLineType(name: "dashed spaced", segments: 2, pitch: [6, 6], pattern: (4027576335, 32, 16, 24)),
        SxfLineType(name: "long dashed dotted", segments: 4, pitch: [12, 1.5, 0.25, 1.5], pattern: (4294688767, 32, 32, 15)),
        SxfLineType(name: "long dashed double-dotted", segments: 6, pitch: [12, 1.5, 0.25, 1.5, 0.25, 1.5], pattern: (4293849087, 32, 32, 17)),
        SxfLineType(name: "long dashed triplicate-dotted", segments: 8, pitch: [12, 1.5, 0.25, 1.5, 0.25, 1.5, 0.25, 1.5], pattern: (4290493439, 32, 32, 19)),
        SxfLineType(name: "dotted", segments: 2, pitch: [0.25, 1.5], pattern: (269488144, 32, 8, 7)),
        SxfLineType(name: "chain", segments: 4, pitch: [12, 1.5, 3.5, 1.5], pattern: (4294819839, 32, 32, 19)),
        SxfLineType(name: "chain double dash", segments: 6, pitch: [12, 1.5, 3.5, 1.5, 3.5, 1.5], pattern: (4294369279, 32, 32, 24)),
        SxfLineType(name: "dashed dotted", segments: 4, pitch: [6, 1.5, 0.25, 1.5], pattern: (4292903935, 32, 32, 9)),
        SxfLineType(name: "double-dashed dotted", segments: 6, pitch: [6, 1.5, 6, 1.5, 0.25, 1.5], pattern: (4236243231, 32, 32, 17)),
        SxfLineType(name: "dashed double-dotted", segments: 6, pitch: [6, 1.5, 0.25, 1.5, 0.25, 1.5], pattern: (4286849535, 32, 32, 11)),
        SxfLineType(name: "double-dashed double-dotted", segments: 8, pitch: [6, 1.5, 6, 1.5, 0.25, 1.5, 0.25, 1.5], pattern: (4177496207, 32, 32, 19)),
        SxfLineType(name: "dashed triplicate-dotted", segments: 8, pitch: [6, 1.5, 0.25, 1.5, 0.25, 1.5, 0.25, 1.5], pattern: (4262495295, 32, 32, 13)),
        SxfLineType(name: "double-dashed triplicate-dotted", segments: 10, pitch: [6, 1.5, 6, 1.5, 0.25, 1.5, 0.25, 1.5, 0.25, 1.5], pattern: (4194247839, 32, 32, 20)),
        SxfLineType(name: "", segments: 0, pitch: [], pattern: (4294967295, 32, 32, 10))]
    /// 文字種1〜10(幅・高さ・間隔・色)
    static let textKinds: [(Double, Double, Double, UInt32)] = [
        (2, 2, 0, 1), (2.5, 2.5, 0, 1), (3, 3, 0.5, 2), (4, 4, 0.5, 2), (5, 5, 0.5, 3),
        (6, 6, 0.5, 3), (7, 7, 1, 4), (8, 8, 1, 4), (9, 9, 1, 5), (10, 10, 1, 5)]
}
