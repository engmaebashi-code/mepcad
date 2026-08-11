import Foundation
import MepCore

/// JWW(Jw_cad)読込 — v16パーサ移植版(JwwParser)の結果をMepCadエンティティに変換する。
/// M2の方針: 全要素を「下敷き」レイヤに取り込む(レイヤ展開はM4のレイヤUIと同時に対応)。
public struct JwwImportResult {
    public let drawing: JwwDrawing
    public let entityCount: Int
    public let parseSeconds: Double
}

public struct JwwReader {

    public init() {}

    /// JWWファイルを解析してdocumentに下敷きとして取り込む
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

    /// 解析済みJwwDrawingをdocumentに取り込む(戻り値は追加エンティティ数)。
    /// 解析(重い)をバックグラウンド、取り込み(軽い)をメインで分けられるよう分離している。
    ///
    /// 座標系について(サンプル4図面で実測検証済み):
    /// JWWの座標は紙面mm(図寸)で格納されている。実寸mm = 座標 × 所属グループの縮尺。
    /// MepCadは実寸主義なので、要素ごとにグループ縮尺を掛けて取り込む。
    /// 縮尺1のグループ(図枠・凡例等)は実寸空間では紙サイズのまま小さく残る点に注意
    /// (グループ別の取込選択はレイヤUI実装時(M4)に対応予定)。
    @discardableResult
    public static func importDrawing(_ drawing: JwwDrawing, into document: Document) -> Int {
        // 取り込み先レイヤ(下敷き)
        let underlayLayerID = document.layers.first(where: { $0.name == "下敷き" })?.id
            ?? document.layers[0].id

        // グループ縮尺(不正値は1として扱う)
        func scale(forGroup g: UInt8) -> Double {
            let idx = Int(g)
            guard idx >= 0, idx < drawing.scales.count else { return 1 }
            let s = drawing.scales[idx]
            return (s.isFinite && s > 0) ? s : 1
        }

        var entities: [Entity] = []
        entities.reserveCapacity(drawing.lines.count + drawing.arcs.count
                                 + drawing.solids.count + drawing.texts.count)

        for l in drawing.lines {
            let s = scale(forGroup: l.glayer)
            entities.append(Entity(layerID: underlayLayerID,
                                   kind: .line(a: Vec2(l.x1 * s, l.y1 * s),
                                               b: Vec2(l.x2 * s, l.y2 * s))))
        }
        for a in drawing.arcs {
            let s = scale(forGroup: a.glayer)
            if a.isCircle {
                entities.append(Entity(layerID: underlayLayerID,
                                       kind: .circle(center: Vec2(a.cx * s, a.cy * s), radius: a.r * s)))
            } else {
                entities.append(Entity(layerID: underlayLayerID,
                                       kind: .arc(center: Vec2(a.cx * s, a.cy * s), radius: a.r * s,
                                                  startAngle: a.startAngle, endAngle: a.endAngle)))
            }
        }
        // ソリッドはM2では輪郭線で表現(塗りはM3以降)
        for sd in drawing.solids {
            let s = scale(forGroup: sd.glayer)
            if sd.isCircleMode {
                let cx = sd.values[0] * s, cy = sd.values[1] * s, r = sd.values[2] * s
                entities.append(Entity(layerID: underlayLayerID,
                                       kind: .circle(center: Vec2(cx, cy), radius: r)))
            } else {
                let v = sd.values
                let pts = [Vec2(v[0] * s, v[1] * s), Vec2(v[2] * s, v[3] * s),
                           Vec2(v[4] * s, v[5] * s), Vec2(v[6] * s, v[7] * s)]
                for i in 0..<4 {
                    let a = pts[i], b = pts[(i + 1) % 4]
                    if a.distance(to: b) > 0.001 {
                        entities.append(Entity(layerID: underlayLayerID, kind: .line(a: a, b: b)))
                    }
                }
            }
        }
        for t in drawing.texts {
            let s = scale(forGroup: t.glayer)
            entities.append(Entity(layerID: underlayLayerID,
                                   kind: .text(position: Vec2(t.x * s, t.y * s), content: t.text,
                                               height: t.size * s,
                                               angle: t.angleDegrees * .pi / 180)))
        }

        document.appendBulk(entities)
        return entities.count
    }
}
