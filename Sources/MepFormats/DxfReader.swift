import Foundation
import MepCore

// MARK: - DXF → Document 展開(M5.0)
//
// 方針は「開く=編集」(JWWと同じ)。
// - レイヤ: DXFの平坦なレイヤをテーブル順に 16グループ×16レイヤ へ順詰め
//   (レイヤk → グループk/16のレイヤk%16。最大256。あふれた分は最後のレイヤへ)
// - 縮尺: $LTSCALE(JWW変換DXFでは縮尺分母が入っている)を全グループへ
// - 用紙: $LIMMIN/$LIMMAX の大きさが「用紙×縮尺」に一致すればその用紙(A0〜A4)
// - 座標: 実寸mmのまま。用紙中心=原点に合わせるため図面全体を平行移動
//   ($LIMMINと$LIMMAXの中心を原点へ。JWW取込と同じ見え方になる)
// - BLOCKS → BlockDefinition(入れ子INSERTは展開して取り込む=定義は1段)
// - INSERT → blockRef(等倍率のみ。負の倍率は反転+回転に合成)
// - DIMENSION → 参照する寸法図形ブロック(_D…)をその場に展開(見た目を維持)
// - HATCH等の非対応型は読み飛ばして件数を報告

public struct DxfImportStats: Sendable {
    public var entityCount = 0
    public var blockDefinitionCount = 0
    public var blockRefCount = 0
    public var dimensionCount = 0
    public var layerCount = 0
    public var skippedTypes: [String: Int] = [:]
    public var scaleDenominator: Double = 1
    public var paperDetected = false
}

public enum DxfReader {

    // MARK: - スタイル対応表

    /// ACI色番号 → MepCadパレット(0黒 1赤 2青 3緑 4橙 5紫 6青緑 7マゼンタ 8グレー 9薄紫)
    public static func mapColor(_ aci: Int) -> Int? {
        switch aci {
        case 0, 256: return nil          // ByBlock / ByLayer
        case 1: return 1                 // 赤
        case 2: return 4                 // 黄 → 橙
        case 3: return 3                 // 緑
        case 4: return 6                 // シアン → 青緑
        case 5: return 2                 // 青
        case 6: return 7                 // マゼンタ
        case 7: return 0                 // 白/黒
        case 8, 9: return 8              // グレー
        case 250...255: return 8         // グレースケール
        case 10...249:
            // 10刻みで色相が赤→黄→緑→シアン→青→マゼンタと回る(近い色相へ丸める)
            let hue = (aci - 10) / 10    // 0〜23
            switch hue {
            case 0..<2: return 1         // 赤系
            case 2..<5: return 4         // 橙・黄系
            case 5..<10: return 3        // 緑系
            case 10..<14: return 6       // 青緑系
            case 14..<18: return 2       // 青系
            case 18..<21: return 5       // 紫系
            default: return 7            // マゼンタ系
            }
        default: return 0
        }
    }

    /// DXF線種名 → MepCad線種(0実線 1-3点線 4-5一点鎖 6-7二点鎖 8補助線種)
    public static func mapLineType(_ name: String) -> Int? {
        let upper = name.uppercased()
        switch true {
        case upper.isEmpty, upper == "CONTINUOUS", upper == "BYLAYER", upper == "BYBLOCK":
            return upper == "CONTINUOUS" ? 0 : nil
        case upper.contains("PHANTOM"), upper.contains("DIVIDE"):
            return 6                     // 二点鎖
        case upper.contains("CENTER"), upper.contains("DASHDOT"):
            return 4                     // 一点鎖
        case upper.contains("HIDDEN"), upper.contains("DASHED"), upper.contains("DOT"):
            return 1                     // 点線・破線
        default:
            return 0
        }
    }

    // MARK: - 取込本体

    public static func importDrawing(_ drawing: DxfDrawing, into document: Document) -> DxfImportStats {
        var stats = DxfImportStats()
        stats.skippedTypes = drawing.skippedTypes

        // ---- レイヤ対応表(テーブル順 → 16×16へ順詰め) ----
        var layerOrder: [String] = drawing.layers.map(\.name)
        var known = Set(layerOrder)
        func noteLayer(_ name: String) {
            if !known.contains(name) {
                known.insert(name)
                layerOrder.append(name)
            }
        }
        for e in drawing.entities { noteLayer(e.layer) }
        for b in drawing.blocks {
            for e in b.entities { noteLayer(e.layer) }
        }

        var layerAddress: [String: LayerAddress] = [:]
        for (k, name) in layerOrder.enumerated() {
            let idx = min(k, 255)
            layerAddress[name] = LayerAddress(idx / 16, idx % 16)
        }
        stats.layerCount = layerOrder.count

        // ---- 縮尺・用紙 ----
        var scale = drawing.ltScale ?? 1
        if !(scale >= 1 && scale <= 1000) { scale = 1 }
        stats.scaleDenominator = scale

        var paper: PaperSize?
        var shift = Vec2(0, 0)
        if let x0 = drawing.limMinX, let y0 = drawing.limMinY,
           let x1 = drawing.limMaxX, let y1 = drawing.limMaxY,
           x1 - x0 > 1, y1 - y0 > 1 {
            let w = x1 - x0
            let h = y1 - y0
            for candidate in PaperSize.allCases {
                let pw = candidate.widthMm * scale
                let ph = candidate.heightMm * scale
                if abs(w - pw) / pw < 0.02 && abs(h - ph) / ph < 0.02 {
                    paper = candidate
                    break
                }
            }
            // 用紙中心=原点へ(JWW取込と同じ座標系にそろえる)。
            // LIMITSが用紙×縮尺と一致した(=信頼できる)場合のみ。
            // 機器CADデータ等でLIMITSが当てにならない場合は座標をそのまま使う
            if paper != nil {
                shift = Vec2(-(x0 + x1) / 2, -(y0 + y1) / 2)
            }
        }
        stats.paperDetected = paper != nil

        // ---- レイヤ構造の構築 ----
        var groups = (0..<16).map { _ in LayerGroup() }
        for i in groups.indices { groups[i].scale = scale }
        // 同名レイヤの重複はあり得る(結合・手編集されたファイル)ため先勝ちで許容
        let layerTable = Dictionary(drawing.layers.map { ($0.name, $0) },
                                    uniquingKeysWith: { first, _ in first })
        for (name, address) in layerAddress {
            groups[address.group].layers[address.layer].name = name == "0" ? "0(既定)" : name
            if let l = layerTable[name] {
                groups[address.group].layers[address.layer].defaultColorIndex = mapColor(l.colorACI) ?? 0
                groups[address.group].layers[address.layer].defaultLineType = mapLineType(l.lineTypeName) ?? 0
            }
        }

        // ---- ブロック定義(入れ子は展開して1段に) ----
        let rawBlocks = Dictionary(drawing.blocks.map { ($0.name, $0) },
                                   uniquingKeysWith: { first, _ in first })

        var builtDefinitions: [String: BlockDefinition] = [:]

        /// ブロックのローカル図形(基準点原点)を構築。入れ子INSERTは変換して展開
        func localEntities(of name: String, depth: Int, visited: Set<String>) -> [Entity] {
            guard depth < 8, let raw = rawBlocks[name], !visited.contains(name) else { return [] }
            var visited = visited
            visited.insert(name)
            var members: [Entity] = []
            for e in raw.entities {
                if e.type == "INSERT" {
                    let sub = localEntities(of: e.name, depth: depth + 1, visited: visited)
                    members.append(contentsOf: applyInsertTransform(sub, insert: e))
                } else if e.type == "DIMENSION" {
                    members.append(contentsOf: localEntities(of: e.name, depth: depth + 1, visited: visited))
                } else {
                    members.append(contentsOf: convert(e, layer: .zero))
                }
            }
            // 基準点を原点へ
            let base = Vec2(-raw.baseX, -raw.baseY)
            if abs(base.x) > 1e-12 || abs(base.y) > 1e-12 {
                members = members.map { $0.translated(by: base) }
            }
            return members
        }

        func definition(named name: String) -> BlockDefinition? {
            if let d = builtDefinitions[name] { return d }
            guard rawBlocks[name] != nil else { return nil }
            let members = localEntities(of: name, depth: 0, visited: [])
            guard !members.isEmpty else { return nil }
            let def = BlockDefinition(name: name, entities: members.map {
                Entity(layer: $0.layer, style: $0.style, kind: $0.kind)
            })
            builtDefinitions[name] = def
            return def
        }

        // ---- モデル空間エンティティ ----
        var entities: [Entity] = []
        entities.reserveCapacity(drawing.entities.count)

        for e in drawing.entities {
            let address = layerAddress[e.layer] ?? .zero
            switch e.type {
            case "INSERT":
                guard let def = definition(named: e.name) else { break }
                let placement = insertPlacement(e)
                let insertPoint = Vec2(e.x1 + shift.x, e.y1 + shift.y)
                let bounds = def.bounds(insert: insertPoint, rotation: placement.rotation,
                                        scale: placement.scale, mirrored: placement.mirrored)
                entities.append(Entity(layer: address,
                                       kind: .blockRef(definitionID: def.id,
                                                       insert: insertPoint,
                                                       rotation: placement.rotation,
                                                       scale: placement.scale,
                                                       mirrored: placement.mirrored,
                                                       cachedBounds: bounds)))
                stats.blockRefCount += 1
            case "DIMENSION":
                // 寸法は図形ブロック(_D…)をその場に展開(見た目を維持・編集可能)
                let expanded = localEntities(of: e.name, depth: 0, visited: [])
                for var sub in expanded {
                    sub = sub.translated(by: shift)
                    sub.layer = address
                    entities.append(Entity(layer: sub.layer, style: sub.style, kind: sub.kind))
                }
                if !expanded.isEmpty { stats.dimensionCount += 1 }
            default:
                for var sub in convert(e, layer: address) {
                    sub = sub.translated(by: shift)
                    entities.append(sub)
                }
            }
        }

        // ---- Documentへ反映 ----
        document.removeAllEntities()
        let current = LayerAddress(0, 0)
        document.replaceGroups(groups, current: current)
        if let paper {
            document.setPaperSize(paper)
        }
        for def in builtDefinitions.values.sorted(by: { $0.name < $1.name }) {
            // 配置から参照されている定義だけ登録(寸法用の匿名ブロックは除く)
            document.addBlockDefinition(def)
        }
        document.appendBulk(entities)

        stats.entityCount = entities.count
        stats.blockDefinitionCount = builtDefinitions.count
        return stats
    }

    // MARK: - エンティティ変換

    /// INSERTの倍率・回転をMepCadのブロック配置パラメータへ合成する。
    /// 負の倍率は反転フラグ+180°回転に正規化(sx<0,sy>0=反転 / sy<0=反転+180° / 両負=180°)
    static func insertPlacement(_ e: DxfEntityData) -> (scale: Double, rotation: Double, mirrored: Bool) {
        let sx = e.scaleX
        let sy = e.scaleY
        var scale = max(abs(sx), 1e-9)
        // 非等倍は平均で近似(機器CADではほぼ等倍)
        if abs(abs(sx) - abs(sy)) > 1e-9 {
            scale = (abs(sx) + abs(sy)) / 2
        }
        var rotation = e.angle50 * .pi / 180
        var mirrored = false
        if sx < 0 && sy < 0 {
            rotation += .pi
        } else if sx < 0 {
            mirrored = true
        } else if sy < 0 {
            mirrored = true
            rotation += .pi
        }
        return (scale, rotation, mirrored)
    }

    /// 頂点列(bulge付き)→ 線分と円弧
    static func polylineSegments(_ vertices: [DxfVertex], closed: Bool,
                                 layer: LayerAddress, style: Style) -> [Entity] {
        guard vertices.count >= 2 else { return [] }
        var out: [Entity] = []
        let count = closed ? vertices.count : vertices.count - 1
        for i in 0..<count {
            let a = vertices[i]
            let b = vertices[(i + 1) % vertices.count]
            let p1 = Vec2(a.x, a.y)
            let p2 = Vec2(b.x, b.y)
            if abs(a.bulge) < 1e-12 {
                if p1.distance(to: p2) > 1e-12 {
                    out.append(Entity(layer: layer, style: style, kind: .line(a: p1, b: p2)))
                }
                continue
            }
            // bulge = tan(挟角/4)。正=反時計回り
            let theta = 4 * atan(a.bulge)
            let chord = p1.distance(to: p2)
            guard chord > 1e-12 else { continue }
            let radius = abs(chord / (2 * sin(theta / 2)))
            // 中心は弦の中点から左法線方向へ r·cos(θ/2)(CCW弧は進行方向の左に中心)。
            // 劣弧/優弧の別はcosの符号が、時計回りはsign(θ)が自動的に処理する
            let mid = Vec2((p1.x + p2.x) / 2, (p1.y + p2.y) / 2)
            let dir = Vec2((p2.x - p1.x) / chord, (p2.y - p1.y) / chord)
            let normal = Vec2(-dir.y, dir.x)   // 進行方向の左
            let offset = radius * cos(theta / 2) * (theta > 0 ? 1 : -1)
            let center = Vec2(mid.x + normal.x * offset, mid.y + normal.y * offset)
            var start = atan2(p1.y - center.y, p1.x - center.x)
            var end = atan2(p2.y - center.y, p2.x - center.x)
            if theta < 0 {
                // 時計回りの弧はCCW表現に反転(start/endを入れ替え)
                swap(&start, &end)
            }
            out.append(Entity(layer: layer, style: style,
                              kind: .arc(center: center, radius: radius,
                                         startAngle: start, endAngle: end)))
        }
        return out
    }

    /// 単一エンティティの変換(INSERT/DIMENSIONは呼び出し側で処理)
    static func convert(_ e: DxfEntityData, layer: LayerAddress) -> [Entity] {
        let style = Style(colorIndex: mapColor(e.colorACI ?? 256),
                          lineType: e.lineTypeName.flatMap { mapLineType($0) })
        switch e.type {
        case "LINE":
            let a = Vec2(e.x1, e.y1)
            let b = Vec2(e.x2, e.y2)
            guard a.distance(to: b) > 1e-12 else { return [] }
            return [Entity(layer: layer, style: style, kind: .line(a: a, b: b))]

        case "CIRCLE":
            guard e.value40 > 1e-12 else { return [] }
            return [Entity(layer: layer, style: style,
                           kind: .circle(center: Vec2(e.x1, e.y1), radius: e.value40))]

        case "ARC":
            guard e.value40 > 1e-12 else { return [] }
            return [Entity(layer: layer, style: style,
                           kind: .arc(center: Vec2(e.x1, e.y1), radius: e.value40,
                                      startAngle: e.angle50 * .pi / 180,
                                      endAngle: e.angle51 * .pi / 180))]

        case "POINT":
            return [Entity(layer: layer, style: style, kind: .point(position: Vec2(e.x1, e.y1)))]

        case "TEXT":
            let content = DxfTextDecoder.decodePercent(e.text)
            guard !content.isEmpty, e.value40 > 1e-12 else { return [] }
            // 整列指定(72≠0)があれば整列点(11,21)を使う
            let pos = (e.alignment72 != 0 && e.has2) ? Vec2(e.x2, e.y2) : Vec2(e.x1, e.y1)
            return [Entity(layer: layer, style: style,
                           kind: .text(position: pos, content: content, height: e.value40,
                                       angle: e.angle50 * .pi / 180))]

        case "MTEXT":
            let content = DxfTextDecoder.plainText(e.text)
            guard !content.isEmpty, e.value40 > 1e-12 else { return [] }
            var pos = Vec2(e.x1, e.y1)
            // 取付点(1-3=上段, 4-6=中段)を下端基準へ寄せる
            switch e.attachment71 {
            case 1, 2, 3: pos = Vec2(pos.x, pos.y - e.value40)
            case 4, 5, 6: pos = Vec2(pos.x, pos.y - e.value40 / 2)
            default: break
            }
            // 回転: 方向ベクトル(11,21)優先、なければ50(度)
            var angle = e.angle50 * .pi / 180
            if e.has2, abs(e.x2) + abs(e.y2) > 1e-12 {
                angle = atan2(e.y2, e.x2)
            }
            return [Entity(layer: layer, style: style,
                           kind: .text(position: pos, content: content, height: e.value40,
                                       angle: angle))]

        case "POLYLINE", "LWPOLYLINE":
            return polylineSegments(e.vertices, closed: e.closed, layer: layer, style: style)

        default:
            return []
        }
    }

    /// 入れ子INSERT展開用: ローカル図形へ倍率→回転→挿入点の変換を適用
    static func applyInsertTransform(_ members: [Entity], insert e: DxfEntityData) -> [Entity] {
        let placement = insertPlacement(e)
        return members.map { member in
            var out = member
            if placement.mirrored {
                out = out.mirrored(acrossLineFrom: .zero, to: Vec2(0, 1))
            }
            if abs(placement.scale - 1) > 1e-12 {
                out = out.scaled(by: placement.scale, around: .zero)
            }
            if abs(placement.rotation) > 1e-12 {
                out = out.rotated(around: .zero, byRadians: placement.rotation)
            }
            return out.translated(by: Vec2(e.x1, e.y1))
        }
    }
}
