import Foundation
import MepCore

/// JWW(Jw_cad)読込 — v16パーサ移植版(JwwParser)の結果をMepCadドキュメントに変換する。
///
/// M4.1の方針(Jw_cad完全準拠):
/// JWWのレイヤ構造(16グループ×16レイヤ・グループ別縮尺・表示/編集状態)を
/// そのままドキュメントの16×16構造に展開し、開いた図面を直接編集できるようにする。
/// 色・線種も要素ごとに取り込む。将来のJWW保存で無劣化の往復を可能にするための基盤。
public struct JwwImportResult {
    public let drawing: JwwDrawing
    public let entityCount: Int
    public let parseSeconds: Double
}

public struct JwwReader {

    public init() {}

    /// JWWファイルを解析してdocumentに展開する
    @discardableResult
    public func read(url: URL, into document: Document) throws -> JwwImportResult {
        let start = Date()
        let data = try Data(contentsOf: url)
        let parser = JwwParser(data: data)
        let drawing = try parser.parse()
        let count = Self.importDrawing(drawing, into: document)
        return JwwImportResult(drawing: drawing,
                               entityCount: count,
                               parseSeconds: Date().timeIntervalSince(start))
    }

    // MARK: - 状態コードの解釈

    /// JWWのレイヤ/グループ状態: 下位3bit 0=非表示 1=表示のみ 2=編集可 3=書込(カレント)、
    /// bit3(8)=プロテクト
    static func decodeState(_ s: UInt8) -> (visible: Bool, editable: Bool, isCurrent: Bool) {
        let base = s & 0x7
        let isProtected = (s & 0x8) != 0
        let visible = base != 0
        let editable = visible && !isProtected && base >= 2
        return (visible, editable, base == 3)
    }

    /// JWWの色コード(1〜9)→ パレット番号。範囲外はbyLayer
    static func mapColor(_ c: UInt8) -> Int? {
        (1...9).contains(Int(c)) ? Int(c) : nil
    }

    /// JWWの線種(1=実線 2〜4=点線 5〜8=鎖線 9=補助線)→ 0=実線 1=破線 2=一点鎖線
    static func mapLineType(_ t: UInt8) -> Int? {
        switch Int(t) {
        case 1: return 0
        case 2, 3, 4, 9: return 1
        case 5, 6, 7, 8: return 2
        default: return nil
        }
    }

    // MARK: - レイヤ構造の展開

    /// JwwDrawingから16グループ×16レイヤの構造を作る
    static func buildGroups(from drawing: JwwDrawing) -> (groups: [LayerGroup], current: LayerAddress) {
        var groups: [LayerGroup] = []
        var current: LayerAddress?

        for g in 0..<16 {
            let scale: Double
            if g < drawing.scales.count, drawing.scales[g].isFinite, drawing.scales[g] > 0 {
                scale = drawing.scales[g]
            } else {
                scale = 1
            }

            var groupVisible = true
            var groupEditable = true
            var groupCurrent = false
            if let states = drawing.groupStates, g < states.count {
                (groupVisible, groupEditable, groupCurrent) = decodeState(states[g])
            }

            var layers: [Layer] = []
            for l in 0..<16 {
                var visible = true
                var editable = true
                var isCurrent = false
                if let states = drawing.layerStates, g * 16 + l < states.count {
                    (visible, editable, isCurrent) = decodeState(states[g * 16 + l])
                }
                layers.append(Layer(name: "",
                                    isVisible: visible,
                                    isEditable: editable))
                // 書込グループ内の書込レイヤを優先。無ければ最初に見つかった書込レイヤ
                if isCurrent, groupCurrent || current == nil {
                    current = LayerAddress(g, l)
                }
            }
            groups.append(LayerGroup(name: "",
                                     scale: scale,
                                     isVisible: groupVisible,
                                     isEditable: groupEditable,
                                     layers: layers))
        }

        // カレントが見つからない/書き込めない場合のフォールバック
        var resolved = current ?? LayerAddress(0, 0)
        func selectable(_ a: LayerAddress) -> Bool {
            let g = groups[a.group]
            return g.isVisible && g.isEditable
                && g.layers[a.layer].isVisible && g.layers[a.layer].isEditable
        }
        if !selectable(resolved) {
            outer: for g in 0..<16 where groups[g].isVisible && groups[g].isEditable {
                for l in 0..<16 where groups[g].layers[l].isVisible && groups[g].layers[l].isEditable {
                    resolved = LayerAddress(g, l)
                    break outer
                }
            }
            // それでも無ければ(全ロック図面)0-0を書込可能にする
            if !selectable(resolved) {
                groups[0].isVisible = true
                groups[0].isEditable = true
                groups[0].layers[0].isVisible = true
                groups[0].layers[0].isEditable = true
                resolved = LayerAddress(0, 0)
            }
        }
        return (groups, resolved)
    }

    // MARK: - 取り込み

    /// 解析済みJwwDrawingをdocumentへ展開する(戻り値は追加エンティティ数)。
    /// レイヤ構造・エンティティとも全置換(「開く」の意味論)。
    ///
    /// 座標系について(サンプル4図面で実測検証済み):
    /// JWWの座標は紙面mm(図寸)で格納されている。実寸mm = 座標 × 所属グループの縮尺。
    /// MepCadは実寸主義なので、要素ごとにグループ縮尺を掛けて取り込む。
    @discardableResult
    public static func importDrawing(_ drawing: JwwDrawing, into document: Document) -> Int {
        let (groups, current) = buildGroups(from: drawing)
        document.removeAllEntities()
        document.replaceGroups(groups, current: current)

        func scale(forGroup g: UInt8) -> Double {
            groups[min(Int(g), 15)].scale
        }

        func address(_ g: UInt8, _ l: UInt8) -> LayerAddress {
            LayerAddress(Int(g), Int(l))
        }

        var entities: [Entity] = []
        entities.reserveCapacity(drawing.lines.count + drawing.arcs.count
                                 + drawing.solids.count + drawing.texts.count)

        for l in drawing.lines {
            let s = scale(forGroup: l.glayer)
            entities.append(Entity(layer: address(l.glayer, l.layer),
                                   style: Style(colorIndex: mapColor(l.color),
                                                lineType: mapLineType(l.lntp)),
                                   kind: .line(a: Vec2(l.x1 * s, l.y1 * s),
                                               b: Vec2(l.x2 * s, l.y2 * s))))
        }
        for a in drawing.arcs {
            let s = scale(forGroup: a.glayer)
            let style = Style(colorIndex: mapColor(a.color), lineType: mapLineType(a.lntp))
            if a.isCircle {
                entities.append(Entity(layer: address(a.glayer, a.layer),
                                       style: style,
                                       kind: .circle(center: Vec2(a.cx * s, a.cy * s), radius: a.r * s)))
            } else {
                entities.append(Entity(layer: address(a.glayer, a.layer),
                                       style: style,
                                       kind: .arc(center: Vec2(a.cx * s, a.cy * s), radius: a.r * s,
                                                  startAngle: a.startAngle, endAngle: a.endAngle)))
            }
        }
        // ソリッドは輪郭線で表現(塗りは将来対応)
        for sd in drawing.solids {
            let s = scale(forGroup: sd.glayer)
            let addr = address(sd.glayer, sd.layer)
            if sd.isCircleMode {
                let cx = sd.values[0] * s, cy = sd.values[1] * s, r = sd.values[2] * s
                entities.append(Entity(layer: addr,
                                       kind: .circle(center: Vec2(cx, cy), radius: r)))
            } else {
                let v = sd.values
                let pts = [Vec2(v[0] * s, v[1] * s), Vec2(v[2] * s, v[3] * s),
                           Vec2(v[4] * s, v[5] * s), Vec2(v[6] * s, v[7] * s)]
                for i in 0..<4 {
                    let a = pts[i], b = pts[(i + 1) % 4]
                    if a.distance(to: b) > 0.001 {
                        entities.append(Entity(layer: addr, kind: .line(a: a, b: b)))
                    }
                }
            }
        }
        for t in drawing.texts {
            let s = scale(forGroup: t.glayer)
            entities.append(Entity(layer: address(t.glayer, t.layer),
                                   kind: .text(position: Vec2(t.x * s, t.y * s), content: t.text,
                                               height: t.size * s,
                                               angle: t.angleDegrees * .pi / 180)))
        }

        document.appendBulk(entities)
        return entities.count
    }
}
