import SwiftUI
import MepCore
import MepData

// MARK: - 継手プレビュー(M6.8)
//
// パラメトリック生成の継手を1個ずつ確認するためのカタログ表示。
// 現在の管種・呼び径(コマンドプロパティの設定)でDL/LL/45L/DT/LT/Y/立てチーズ/
// 立ち上がり/立ち下がり/45°立ち下がり/ひねり/レデューサ/キャップを描く。
// FILDERの部材配置ダイアログのプレビュー相当。継手の作り込み・検証用

struct FittingPreviewView: View {
    @ObservedObject var uiState: CanvasUIState
    private let master = PipeMaster.standard

    /// 表示する部品
    private enum Item: String, CaseIterable, Identifiable {
        case dl = "DL 90°エルボ", ll = "LL 90°大曲エルボ", l45 = "45L 45°エルボ"
        case dt = "DT 90°Y", lt = "LT 90°大曲Y(下流→)", y = "Y 45°Y(枝は上流側から)"
        case vtee = "DT 立て使い(立てチーズ)", riseUp = "立ち上がり", riseDown = "立ち下がり"
        case drop45 = "45°立ち下がり", twist = "ひねり(DL+勾配脚)", reducer = "径違いソケット", cap = "キャップ"
        var id: String { rawValue }
    }

    var body: some View {
        let attrs = currentAttrs()
        VStack(alignment: .leading, spacing: 8) {
            Text("継手プレビュー — \(attrs.materialLabel) \(attrs.sizeLabel)  (継手規格 \(attrs.fittingSeries.isEmpty ? "概算" : attrs.fittingSeries))")
                .font(.system(size: 13, weight: .semibold))
            Text("複線の実形状(左)と単線記号(右)。コマンドプロパティの管種・口径・記号サイズに追従します")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                    ForEach(Item.allCases) { item in
                        VStack(spacing: 4) {
                            FittingCanvas(item: item.rawValue, attrs: attrs, drawer: { attrs, drawFn in
                                self.build(item, attrs: attrs, into: drawFn)
                            })
                            .frame(height: 170)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(item.rawValue).font(.system(size: 11))
                        }
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 560)
    }

    private func currentAttrs() -> PipeAttributes {
        let usage = master.usage(uiState.pipeUsage)
        let material = master.material(uiState.pipeMaterial)
        let size = master.size(material: uiState.pipeMaterial, size: uiState.pipeSize)
            ?? master.sizes(for: uiState.pipeMaterial).first
        let series = FittingMaster.series(material: uiState.pipeMaterial, usage: uiState.pipeUsage)
        let dims = FittingMaster.standard.dims(series: series, size: size?.size ?? "")
        let drain = series == "DV" || ["S", "W", "RW", "VT"].contains(uiState.pipeUsage)
        let scale = 50.0   // プレビューは1/50相当で紙面mm→実寸mm
        return PipeAttributes(usage: uiState.pipeUsage, usageName: usage?.name ?? "",
                              material: uiState.pipeMaterial, materialLabel: material?.shortLabel ?? uiState.pipeMaterial,
                              size: size?.size ?? "", sizeLabel: size?.label ?? "",
                              outerDiameter: size?.outerDiameter ?? 60, annotate: false, textHeight: 2.5 * scale,
                              doubleLine: true, autoFittings: true,
                              fittingSeries: series, fittingDims: dims,
                              symbolSize: (drain ? uiState.pipeSymbolDrain : uiState.pipeSymbolSupply) * scale,
                              longRadius: false, branchKind: "DT")
    }

    /// 部品ごとの配管モデル(実寸mm)。戻り値: (点列, 属性, 追加の接続配管(枝管など))
    private func build(_ item: Item, attrs base: PipeAttributes,
                       into out: (_ pipes: [(points: [Vec3], attrs: PipeAttributes)]) -> Void) {
        var a = base
        let od = a.outerDiameter
        let far = max(od * 4, 400)
        switch item {
        case .dl:
            out([([Vec3(-far, 0, 0), Vec3(0, 0, 0), Vec3(0, far, 0)], a)])
        case .ll:
            a.longRadius = true
            out([([Vec3(-far, 0, 0), Vec3(0, 0, 0), Vec3(0, far, 0)], a)])
        case .l45:
            out([([Vec3(-far, 0, 0), Vec3(0, 0, 0), Vec3(far * 0.7071, far * 0.7071, 0)], a)])
        case .dt, .lt, .y:
            var b = a
            b.branchKind = item == .dt ? "DT" : (item == .lt ? "LT" : "Y")
            let branch: [Vec3] = item == .y
                ? [Vec3(-far * 0.7071, far * 0.7071, 0), Vec3(0, 0, 0)]
                : [Vec3(0, far, 0), Vec3(0, 0, 0)]
            out([([Vec3(-far, 0, 0), Vec3(far, 0, 0)], a), (branch, b)])
        case .vtee:
            // 枝は同径の1つ下のサイズ相当を50%外径で。上から来て立ち下がる
            var b = a
            b.outerDiameter = od * 0.6
            b.fittingDims = PipeFittingDims.estimated(outerDiameter: od * 0.6)
            out([([Vec3(-far, 0, 0), Vec3(far, 0, 0)], a),
                 ([Vec3(0, far, 300), Vec3(0, 0, 300), Vec3(0, 0, 0)], b)])
        case .riseUp:
            out([([Vec3(-far, 0, 0), Vec3(0, 0, 0), Vec3(0, 0, 1000)], a)])
        case .riseDown:
            out([([Vec3(-far, 0, 1000), Vec3(0, 0, 1000), Vec3(0, 0, 0)], a)])
        case .drop45:
            out([([Vec3(-far, 0, 300), Vec3(0, 0, 300), Vec3(300, 0, 0), Vec3(far, 0, 0)], a)])
        case .twist:
            out([([Vec3(-far, 0, 300), Vec3(0, 0, 300), Vec3(0, -300, 0), Vec3(0, -far, 0)], a)])
        case .reducer:
            var b = a
            b.outerDiameter = od * 0.78
            b.fittingDims = PipeFittingDims.estimated(outerDiameter: od * 0.78)
            b.sizeLabel = "小"
            out([([Vec3(-far, 0, 0), Vec3(0, 0, 0)], a), ([Vec3(0, 0, 0), Vec3(far, 0, 0)], b)])
        case .cap:
            a.capEnds = true
            out([([Vec3(-far, 0, 0), Vec3(0, 0, 0)], a)])
        }
    }
}

/// 1部品ぶんのキャンバス(左=複線、右=単線)。Rendererと同じ導出関数を使って描く
private struct FittingCanvas: View {
    let item: String
    let attrs: PipeAttributes
    let drawer: (PipeAttributes, (_ pipes: [(points: [Vec3], attrs: PipeAttributes)]) -> Void) -> Void

    var body: some View {
        Canvas { ctx, size in
            for (half, doubleLine) in [(0, true), (1, false)] {
                var pipes: [(points: [Vec3], attrs: PipeAttributes)] = []
                var base = attrs
                base.doubleLine = doubleLine
                drawer(base) { pipes = $0 }
                pipes = pipes.map { p in
                    var at = p.attrs
                    at.doubleLine = doubleLine
                    return (points: p.points, attrs: at)
                }
                let entities = pipes.map { Entity(layer: LayerAddress(0, 0), kind: .pipe(points: $0.points, attrs: $0.attrs)) }
                let junctions = PipeNetwork.junctions(in: entities)
                // 表示範囲: 全点のbbox
                var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
                for p in pipes { for v in p.points { minX = min(minX, v.x); maxX = max(maxX, v.x); minY = min(minY, v.y); maxY = max(maxY, v.y) } }
                let od = attrs.outerDiameter
                minX -= od * 1.5; maxX += od * 1.5; minY -= od * 1.5; maxY += od * 1.5
                let w = Double(size.width) / 2 - 8, h = Double(size.height) - 8
                let scale = min(w / max(maxX - minX, 1), h / max(maxY - minY, 1))
                let ox = Double(half) * Double(size.width) / 2 + 4 + (w - (maxX - minX) * scale) / 2
                let oy = 4 + (h - (maxY - minY) * scale) / 2
                func S(_ v: Vec2) -> CGPoint {
                    CGPoint(x: ox + (v.x - minX) * scale, y: oy + (maxY - v.y) * scale)
                }
                let stroke = GraphicsContext.Shading.color(.primary)
                let fill = GraphicsContext.Shading.color(Color(nsColor: .textBackgroundColor))
                for (e, p) in zip(entities, pipes) {
                    let js = junctions[e.id] ?? []
                    if doubleLine, let layout = PipeGeometry.doubleLineLayout(points: p.points, attrs: p.attrs) {
                        var path = Path()
                        for run in layout.runs {
                            for line in [run.left, run.right] where line.count >= 2 {
                                path.move(to: S(line[0])); for q in line.dropFirst() { path.addLine(to: S(q)) }
                            }
                        }
                        for cap in layout.endCaps { path.move(to: S(cap.0)); path.addLine(to: S(cap.1)) }
                        ctx.stroke(path, with: stroke, lineWidth: 1)
                        var shapes = layout.fittings
                        for j in js { shapes += PipeNetwork.junctionShapes(j, attrs: p.attrs) }
                        for shape in shapes {
                            for part in shape.parts {
                                switch part {
                                case .polygon(let pts):
                                    var pp = Path(); pp.move(to: S(pts[0])); for q in pts.dropFirst() { pp.addLine(to: S(q)) }; pp.closeSubpath()
                                    ctx.fill(pp, with: fill); ctx.stroke(pp, with: stroke, lineWidth: 1.4)
                                case .polyline(let pts):
                                    var pp = Path(); pp.move(to: S(pts[0])); for q in pts.dropFirst() { pp.addLine(to: S(q)) }
                                    ctx.stroke(pp, with: stroke, lineWidth: 1.4)
                                case .circle(let c, let r):
                                    let sc = S(c); let sr = r * scale
                                    let rect = CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2)
                                    ctx.fill(Path(ellipseIn: rect), with: fill); ctx.stroke(Path(ellipseIn: rect), with: stroke, lineWidth: 1.4)
                                }
                            }
                        }
                    } else {
                        var path = Path()
                        for run in PipeSymbols.singleLineRuns(points: p.points, attrs: p.attrs, junctions: js) where run.count >= 2 {
                            path.move(to: S(run[0])); for q in run.dropFirst() { path.addLine(to: S(q)) }
                        }
                        ctx.stroke(path, with: stroke, lineWidth: 1)
                        var sp = Path()
                        for el in PipeSymbols.elements(points: p.points, attrs: p.attrs, junctions: js) {
                            switch el {
                            case .segment(let a, let b): sp.move(to: S(a)); sp.addLine(to: S(b))
                            case .arc(let c, let r, let s0, let e0):
                                let sc = S(c)
                                sp.move(to: CGPoint(x: sc.x + r * scale * cos(s0), y: sc.y - r * scale * sin(s0)))
                                sp.addArc(center: sc, radius: r * scale, startAngle: .radians(-s0), endAngle: .radians(-e0), clockwise: true)
                            case .circle(let c, let r):
                                let sc = S(c); let sr = r * scale
                                sp.addEllipse(in: CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2))
                            }
                        }
                        ctx.stroke(sp, with: stroke, lineWidth: 1.2)
                    }
                    // 立管記号(単線: 上り=閉円 / 下り=C形、複線: 受口外径)
                    let rs = PipeGeometry.riserSymbolRadius(p.attrs)
                    let suppressed: [Vec2] = js.compactMap { if case .teeBranch(_, _, let v) = $0.kind, v { return $0.position }; return nil }
                    for (idx, riser) in PipeGeometry.risers(points: p.points).enumerated() {
                        if suppressed.contains(where: { $0.distance(to: riser.position) <= 1 }) { continue }
                        let sc = S(riser.position); let sr = rs * scale
                        let rect = CGRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2)
                        ctx.fill(Path(ellipseIn: rect), with: fill)
                        if riser.isUp {
                            ctx.stroke(Path(ellipseIn: rect), with: stroke, lineWidth: 1.4)
                        } else {
                            let toward = PipeSymbols.riserLead(points: p.points, riserIndex: idx)?.toward ?? Vec2(-1, 0)
                            let a0 = atan2(toward.y, toward.x)
                            var half = Double.pi / 6
                            if doubleLine { half = asin(min(max(p.attrs.outerDiameter / 2 / max(rs, 1e-9), 0.3), 0.95)) }
                            var arc = Path()
                            arc.addArc(center: sc, radius: sr, startAngle: .radians(-(a0 + half)), endAngle: .radians(-(a0 - half)), clockwise: true)
                            ctx.stroke(arc, with: stroke, lineWidth: 1.4)
                        }
                    }
                }
            }
        }
    }
}
