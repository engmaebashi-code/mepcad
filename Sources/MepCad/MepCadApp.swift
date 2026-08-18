import SwiftUI
import AppKit
import MepCore
import MepData
import MepRender
import MepTools

/// ステータスバー・パネル表示用の状態
final class CanvasUIState: ObservableObject {
    @Published var coords = "X: —  Y: —"
    @Published var zoom = "—"
    @Published var snap = "—"
    @Published var info = "⌘O=JWWを開く / クリック=選択 / 右クリック=メニュー(M4)"
    @Published var tool: ToolKind = .select
    // M4.1: レイヤ(16グループ×16レイヤ)・選択・パネル
    @Published var groups: [LayerGroup] = []
    @Published var current: LayerAddress = .zero
    /// レイヤパネルで一覧表示しているグループ
    @Published var viewingGroup: Int = 0
    /// レイヤ別の要素数(256スロット。空レイヤの薄表示用)
    @Published var layerCounts: [Int] = Array(repeating: 0, count: 256)

    func count(at address: LayerAddress) -> Int {
        let idx = address.group * 16 + address.layer
        return layerCounts.indices.contains(idx) ? layerCounts[idx] : 0
    }

    func groupCount(_ group: Int) -> Int {
        guard group >= 0, group < 16 else { return 0 }
        return layerCounts[(group * 16)..<(group * 16 + 16)].reduce(0, +)
    }
    @Published var selection: SelectionSummary?
    @Published var panelPinned = false
    @Published var paletteColors: [Color] = []
    @Published var gridOn = true
    @Published var gridSpacing: Double = 250
    @Published var auxOn = true
    /// 用紙サイズと書込グループの縮尺分母(フッター表示)
    @Published var paperSize: PaperSize = .a3
    @Published var scaleDenominator: Double = 50

    /// 「1/50」形式の縮尺表記
    var scaleLabel: String {
        let d = scaleDenominator
        if abs(d - d.rounded()) < 1e-9 {
            return "1/\(Int(d.rounded()))"
        }
        return String(format: "1/%.1f", d)
    }
    /// 実行中の編集操作(コマンドプロパティカードの表示用)
    @Published var activeEditOp: EditOpKind?
    /// 移動・複写の角度プロパティ(度)
    @Published var editRotation: Double = 0
    // 文字設定(文字種チップ: 紙面mm+角度。内部は実寸mm保持)
    @Published var textPaperSize: Double = 3.5
    @Published var textAngle: Double = 0
    // ハッチング設定(FILDER準拠: パターン・A/B間隔・角度・実寸/印刷寸)
    @Published var hatchKind: HatchPattern.Kind = .horizontal
    @Published var hatchA: Double = 2      // A間隔
    @Published var hatchB: Double = 1      // B間隔
    @Published var hatchAngle: Double = 45 // 度
    @Published var hatchPaperUnits = true  // true=印刷寸(紙面mm×縮尺)、false=実寸mm
    // 寸法設定(M5.4: 方向・端部・補助線長さ・文字サイズ・色)
    @Published var dimAxis: DimAxisMode = .horizontal
    @Published var dimTerminator: DimTerminator = .dot
    /// 寸法補助線の長さ(紙面mm)。-1=測定点まで、0=なし、>0=指定長さ
    @Published var dimExtension: Double = -1
    @Published var dimTextSize: Double = 2.5   // 紙面mm
    /// 寸法の色(nil=レイヤ既定)
    @Published var dimColorIndex: Int? = nil
    // 引出線設定(M5.5: タイプ・矢印・二重枠・文字サイズ・縦横比・色)
    @Published var leaderBalloon = false        // false=引出線文字、true=バルーン
    @Published var leaderArrow = true
    @Published var leaderDoubleFrame = false
    @Published var leaderTextSize: Double = 3.5 // 紙面mm
    @Published var leaderAspect: Double = 80    // バルーン縦横比(%)
    /// バルーン横サイズ(紙面mm)。-1=文字に合わせて自動
    @Published var leaderWidth: Double = -1
    @Published var leaderColorIndex: Int? = nil
    // 配管設定(M6.0: 用途・管種・呼び径・傍記)
    @Published var pipeUsage = "CW"
    @Published var pipeMaterial = "HIVP"
    @Published var pipeSize = "20"
    @Published var pipeAnnotate = true
    @Published var pipeTextSize: Double = 2.5   // 紙面mm
    // M6.1/M6.2: 高さ・複線・継手・基準面
    @Published var pipeLevel: Double = 0        // mm(基準面から)
    @Published var pipeShowLevel = false
    @Published var levelDatum = "1FL"           // 図面の高さ基準面(Documentと同期)
    @Published var pipeDoubleLine = false
    @Published var pipeAutoFittings = true
    @Published var pipeCapEnds = false          // 接続されていない端部にキャップ(M6.3)
    @Published var pipeSymbolDrain: Double = 2.5   // 単線記号サイズ 排水(紙面mm)M6.5
    @Published var pipeSymbolSupply: Double = 2.0  // 単線記号サイズ 給水ほか(紙面mm)M6.5
    @Published var pipeLongRadius = false        // 90°曲り部品を大曲(LL)に(排水)M6.6
    @Published var pipeAnnotateMaterial = true   // 傍記に管種略号を含める M6.6
    @Published var pipeBranchKind = "DT"         // 分岐部品 DT/LT/Y(枝管側で指定)M6.8
    @Published var pipeDrop45 = false            // 高さ変更を45°勾配で(立ち下がり45°)M6.8

    /// メニュー項目用の色スウォッチ(テーマ切替時に作り直す)
    @Published var colorSwatches: [NSImage] = []
    /// メニュー項目用の線種パターン(テンプレート画像なのでテーマ非依存)
    let lineTypeSwatches: [NSImage] = (0..<LineTypeTable.count).map { SwatchFactory.lineTypeSwatch($0) }

    func paletteColor(_ index: Int) -> Color {
        guard index >= 0, index < paletteColors.count else { return .primary }
        return paletteColors[index]
    }

    func colorSwatch(_ index: Int) -> NSImage {
        guard index >= 0, index < colorSwatches.count else { return NSImage() }
        return colorSwatches[index]
    }

    func lineTypeSwatch(_ index: Int) -> NSImage {
        guard index >= 0, index < lineTypeSwatches.count else { return NSImage() }
        return lineTypeSwatches[index]
    }

    func updatePalette(from theme: RenderTheme) {
        paletteColors = theme.palette.map { Color(cgColor: $0) }
        colorSwatches = theme.palette.map { SwatchFactory.colorSwatch($0) }
    }
}

/// メニュー項目に出す小さな画像(色丸・線種パターン)の生成
enum SwatchFactory {

    /// 色見本の丸(実際のパレット色)
    static func colorSwatch(_ color: CGColor, diameter: CGFloat = 13) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.insetBy(dx: 0.75, dy: 0.75)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: inset)
            // 背景色と同化しないよう薄い縁取り
            ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.45))
            ctx.setLineWidth(0.75)
            ctx.strokeEllipse(in: inset)
            return true
        }
    }

    /// 線種パターンの横線(テンプレート画像: メニューの文字色で自動着色される)
    static func lineTypeSwatch(_ index: Int, width: CGFloat = 58, height: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1.6)
            let dash = LineTypeTable.dashPattern(index).map { CGFloat($0) }
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.move(to: CGPoint(x: 1.5, y: rect.midY))
            ctx.addLine(to: CGPoint(x: rect.maxX - 1.5, y: rect.midY))
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private func toolIcon(_ kind: ToolKind) -> String {
    switch kind {
    case .select: return "cursorarrow"
    case .line: return "line.diagonal"
    case .rect: return "rectangle"
    case .circle: return "circle"
    case .arc: return "point.topleft.down.curvedto.point.bottomright.up"
    case .doubleLine: return "equal"
    case .centerline: return "align.horizontal.center"
    case .point: return "smallcircle.filled.circle"
    case .text: return "textformat"
    case .hatch: return "line.3.horizontal"
    case .dimension: return "ruler"
    case .leader: return "text.bubble"
    case .pipe: return "point.3.connected.trianglepath.dotted"
    }
}

struct ContentView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState
    @State private var isDark = false
    @State private var angle: AngleConstraint = .free
    // スナップ種別のON/OFF(将来は環境設定ウィンドウに移設)
    @State private var snapEndpoint = true
    @State private var snapIntersection = true
    @State private var snapMidpoint = true
    @State private var snapCenter = true
    @State private var snapOnLine = true
    // パネル自動格納(Dock風: 右端に近づくと出る)
    @State private var panelRevealed = false
    @State private var panelHideWork: DispatchWorkItem?

    private var panelShown: Bool { panelRevealed || uiState.panelPinned }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                CanvasView(controller: controller)
                    .frame(minWidth: 800, minHeight: 500)

                // コマンドプロパティカード(移動・複写中の角度指定 — FILDERのコマンドプロパティ相当)
                if let op = uiState.activeEditOp, op.supportsRotationProperty {
                    VStack {
                        HStack {
                            EditPropertyCard(controller: controller, uiState: uiState)
                                .onHover { controller.uiHovering = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 文字パレット(文字種チップ: 紙面mmサイズ+角度)
                if uiState.tool == .text {
                    VStack {
                        HStack {
                            TextPropertyCard(controller: controller, uiState: uiState)
                                .onHover { controller.uiHovering = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 配管プロパティカード(用途・管種・口径・傍記)
                if uiState.tool == .pipe {
                    VStack {
                        HStack {
                            PipePropertyCard(controller: controller, uiState: uiState)
                                .onHover { controller.uiHovering = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 引出線プロパティカード(タイプ・矢印・二重枠・文字サイズ・色)
                if uiState.tool == .leader {
                    VStack {
                        HStack {
                            LeaderPropertyCard(uiState: uiState)
                                .onHover { controller.uiHovering = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 寸法プロパティカード(方向・端部・補助線・文字サイズ・色)
                if uiState.tool == .dimension {
                    VStack {
                        HStack {
                            DimensionPropertyCard(uiState: uiState)
                                .onHover { controller.uiHovering = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // ハッチングプロパティカード(パターン・間隔・角度 — FILDERのハッチングダイアログ相当)
                if uiState.tool == .hatch {
                    VStack {
                        HStack {
                            HatchPropertyCard(uiState: uiState)
                                .onHover { controller.uiHovering = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // ガラス調自動格納パネル(出現トリガはキャンバス側の右端接近検知)
                if panelShown {
                    SidePanelView(controller: controller, uiState: uiState)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .onHover { hovering in
                            controller.uiHovering = hovering
                            if hovering {
                                revealPanel()
                            } else {
                                scheduleHide()
                            }
                        }
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: panelShown)

            // ステータスバー(モックv0.4準拠の最小構成)
            HStack(spacing: 14) {
                // 幅固定: 文字数の変化でレイアウトが揺れないようにする
                Text(uiState.coords)
                    .monospacedDigit()
                    .frame(width: 190, alignment: .leading)
                // 用紙サイズ(クリックで変更。枠=作図範囲)
                Menu {
                    ForEach(PaperSize.allCases, id: \.self) { size in
                        Button((uiState.paperSize == size ? "✓ " : "   ") + "\(size.label)(横)  \(Int(size.widthMm))×\(Int(size.heightMm))") {
                            controller.setPaperSize(size)
                        }
                    }
                } label: {
                    Text("用紙 \(uiState.paperSize.label)")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("用紙サイズ(横置き)。キャンバスの枠が用紙の作図範囲です")
                // 縮尺(書込グループ。クリックで変更・実寸固定)
                Menu {
                    ForEach([1, 2, 5, 10, 20, 30, 50, 100, 200, 500], id: \.self) { d in
                        Button((Int(uiState.scaleDenominator) == d ? "✓ " : "   ") + "1/\(d)") {
                            controller.setScaleDenominator(Double(d))
                        }
                    }
                    Divider()
                    Button("カスタム…") {
                        controller.promptCustomScale()
                    }
                } label: {
                    Text("縮尺 \(uiState.scaleLabel)")
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("書込グループの縮尺。変更は実寸固定(図形の実寸は変わらず用紙枠の範囲が変わります)")
                // グリッド: 表示切替+間隔選択(50刻みプリセット/自由入力)
                Menu {
                    Button(uiState.gridOn ? "グリッドを隠す" : "グリッドを表示") {
                        controller.toggleGrid()
                    }
                    Divider()
                    ForEach(Array(stride(from: 50, through: 500, by: 50)), id: \.self) { v in
                        Button((Int(uiState.gridSpacing) == v ? "✓ " : "   ") + "\(v) mm") {
                            controller.setGridSpacing(Double(v))
                        }
                    }
                    Divider()
                    Button("カスタム…(910など)") {
                        controller.promptGridSpacing()
                    }
                } label: {
                    Text(uiState.gridOn ? "グリッド \(Int(uiState.gridSpacing))" : "グリッド OFF")
                        .foregroundStyle(uiState.gridOn ? .primary : .tertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("グリッドの表示/非表示と間隔(スナップも連動)")
                // 補助線(補助線種・補助線色)の表示切替 — JWWビューワーと同じ考え方
                Button {
                    controller.toggleAuxiliary()
                } label: {
                    Text(uiState.auxOn ? "補助線" : "補助線 OFF")
                        .foregroundStyle(uiState.auxOn ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .help("補助線(補助線種・補助線色)の表示/非表示。非表示中はスナップ・選択からも外れます")
                Text("スナップ: \(uiState.snap)")
                    .frame(width: 110, alignment: .leading)
                Text("ズーム \(uiState.zoom)")
                    .monospacedDigit()
                    .frame(width: 90, alignment: .leading)
                Spacer()
                Text(uiState.info)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
        }
        .toolbar {
            // 作図ツール(モックの左パレット簡易版)
            ToolbarItemGroup {
                Picker("ツール", selection: Binding(
                    get: { uiState.tool },
                    set: { newTool in
                        uiState.tool = newTool
                        controller.selectTool(newTool)
                    }
                )) {
                    ForEach(ToolKind.allCases, id: \.self) { kind in
                        Image(systemName: toolIcon(kind))
                            .help(kind.rawValue)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 角度拘束パレット(常設・マウスだけで切替。表記を短くして幅を節約)
            ToolbarItemGroup {
                Picker("角度拘束", selection: $angle) {
                    ForEach(AngleConstraint.allCases, id: \.self) { constraint in
                        Text(constraint == .free ? "自由"
                             : constraint.rawValue.replacingOccurrences(of: "°", with: ""))
                            .tag(constraint)
                    }
                }
                .pickerStyle(.segmented)
                .help("角度拘束: 作図・移動・複写の方向を丸める(自由/90°/45°/15°)")
                .onChange(of: angle) { _, newValue in
                    // 作図と移動・複写の両方に効かせる
                    controller.setAngleConstraint(newValue)
                }
            }

            ToolbarItemGroup {
                Button {
                    controller.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("取り消し(⌘Z)")

                Button {
                    controller.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .help("やり直し(⇧⌘Z)")
            }

            // ファイル(新規・開く)— ⌘N/⌘Oはメニューバー側(commands)にも登録
            ToolbarItemGroup {
                Menu {
                    Button("新規図面…(用紙・縮尺を指定)") {
                        controller.newDrawingPanel()
                    }
                    Button("開く…(JWW / DXF)") {
                        controller.openJwwPanel()
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .help("ファイル: 新規図面(⌘N)/ 開く(⌘O)")

                // 設定(パネル固定・背景色・スナップ種別)
                Menu {
                    Button("材料集計…(配管の延長拾い)") {
                        controller.showMaterialReport()
                    }
                    Button("継手プレビュー…(パラメトリック部品の確認)") {
                        openFittingPreviewWindow(uiState: uiState)
                    }
                    Divider()
                    Toggle("パネルを固定表示", isOn: $uiState.panelPinned)
                    Button(isDark ? "背景をライトに" : "背景をダークに") {
                        controller.toggleTheme()
                        isDark.toggle()
                        uiState.updatePalette(from: controller.theme)
                    }
                    Divider()
                    Section("スナップ") {
                        Toggle("端点", isOn: $snapEndpoint)
                            .onChange(of: snapEndpoint) { _, v in controller.snapEngine.settings.endpoint = v }
                        Toggle("交点", isOn: $snapIntersection)
                            .onChange(of: snapIntersection) { _, v in controller.snapEngine.settings.intersection = v }
                        Toggle("中点", isOn: $snapMidpoint)
                            .onChange(of: snapMidpoint) { _, v in controller.snapEngine.settings.midpoint = v }
                        Toggle("円の中心", isOn: $snapCenter)
                            .onChange(of: snapCenter) { _, v in controller.snapEngine.settings.center = v }
                        Toggle("線上", isOn: $snapOnLine)
                            .onChange(of: snapOnLine) { _, v in controller.snapEngine.settings.onLine = v }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定: パネル固定 / 背景色 / スナップ種別")
            }
        }
        .onChange(of: uiState.panelPinned) { _, pinned in
            // メニューから固定をONにしたら即表示する
            if pinned { revealPanel() }
        }
        .onAppear {
            controller.onStatusUpdate = { coords, zoom, snap in
                uiState.coords = coords
                uiState.zoom = zoom
                uiState.snap = snap
            }
            controller.onInfo = { info in
                uiState.info = info
            }
            controller.onToolChanged = { kind in
                uiState.tool = kind
            }
            controller.onLayersChanged = { groups, current, counts in
                uiState.groups = groups
                // 書込レイヤのグループが変わったらレイヤ一覧も追従
                if uiState.current != current {
                    uiState.viewingGroup = current.group
                }
                uiState.current = current
                uiState.layerCounts = counts
            }
            controller.onSelectionChanged = { summary in
                uiState.selection = summary
            }
            controller.onEdgeProximity = { near in
                if near {
                    revealPanel()
                } else if !controller.uiHovering {
                    // パネル上にカーソルがある間は格納しない
                    scheduleHide()
                }
            }
            controller.onGridChanged = { visible in
                uiState.gridOn = visible
            }
            controller.onGridSpacingChanged = { spacing in
                uiState.gridSpacing = spacing
            }
            controller.onAuxiliaryChanged = { visible in
                uiState.auxOn = visible
            }
            controller.onDrawingSetupChanged = { paper, scale in
                uiState.paperSize = paper
                uiState.scaleDenominator = scale
            }
            controller.hatchPatternProvider = { [weak controller, weak uiState] in
                guard let controller, let uiState else {
                    return HatchPattern(kind: .horizontal, spacingA: 100, spacingB: 50, angle: .pi / 4)
                }
                // 印刷寸=紙面mm×書込グループの縮尺(確定時点の縮尺で換算)
                let factor = uiState.hatchPaperUnits ? controller.document.currentScale : 1
                return HatchPattern(kind: uiState.hatchKind,
                                    spacingA: max(uiState.hatchA, 0.1) * factor,
                                    spacingB: max(uiState.hatchB, 0.1) * factor,
                                    angle: uiState.hatchAngle * .pi / 180)
            }
            controller.dimensionStyleProvider = { [weak controller, weak uiState] in
                guard let controller, let uiState else { return DimensionToolStyle() }
                // 紙面mm→実寸mm(書込グループの縮尺で換算。文字パレットと同じ流儀)
                let scale = controller.document.currentScale
                let ext: Double? = uiState.dimExtension < 0 ? nil : uiState.dimExtension * scale
                return DimensionToolStyle(
                    axis: uiState.dimAxis,
                    attrs: DimAttributes(terminator: uiState.dimTerminator,
                                         textHeight: max(uiState.dimTextSize, 0.5) * scale,
                                         extensionLength: ext),
                    colorIndex: uiState.dimColorIndex)
            }
            controller.leaderStyleProvider = { [weak controller, weak uiState] in
                guard let controller, let uiState else { return LeaderToolStyle() }
                let scale = controller.document.currentScale
                return LeaderToolStyle(
                    attrs: LeaderAttributes(balloon: uiState.leaderBalloon,
                                            doubleFrame: uiState.leaderDoubleFrame,
                                            arrow: uiState.leaderArrow,
                                            textHeight: max(uiState.leaderTextSize, 0.5) * scale,
                                            aspectPercent: min(max(uiState.leaderAspect, 30), 150),
                                            balloonWidth: uiState.leaderWidth > 0
                                                ? uiState.leaderWidth * scale : nil),
                    colorIndex: uiState.leaderColorIndex)
            }
            controller.pipeStyleProvider = { [weak controller, weak uiState] in
                guard let controller, let uiState else { return PipeToolStyle() }
                let master = PipeMaster.standard
                let scale = controller.document.currentScale
                let usage = master.usage(uiState.pipeUsage)
                    ?? PipeUsage(id: "CW", name: "給水", colorIndex: 2, lineType: 0,
                                 defaultMaterial: "HIVP")
                let material = master.material(uiState.pipeMaterial)
                    ?? PipeMaterial(id: uiState.pipeMaterial, name: uiState.pipeMaterial,
                                    shortLabel: uiState.pipeMaterial)
                let size = master.size(material: material.id, size: uiState.pipeSize)
                    ?? master.sizes(for: material.id).first
                    ?? PipeSize(material: material.id, size: "20", label: "20", outerDiameter: 26)
                // 継手の規格シリーズと寸法(fittings.csv)。無ければ外径概算にフォールバック
                let series = FittingMaster.series(material: material.id, usage: usage.id)
                let dims = FittingMaster.standard.dims(series: series, size: size.size)
                // 単線記号の基準寸法(紙面mm→実寸)。排水系は大きめ・給水系は一回り小さく(FILDER準拠)
                let drainStyle = series == "DV" || ["S", "W", "RW", "VT"].contains(usage.id)
                let symbol = max(drainStyle ? uiState.pipeSymbolDrain : uiState.pipeSymbolSupply, 0.5) * scale
                return PipeToolStyle(
                    attrs: PipeAttributes(usage: usage.id, usageName: usage.name,
                                          material: material.id,
                                          materialLabel: material.shortLabel,
                                          size: size.size, sizeLabel: size.label,
                                          outerDiameter: size.outerDiameter,
                                          annotate: uiState.pipeAnnotate,
                                          textHeight: max(uiState.pipeTextSize, 0.5) * scale,
                                          datum: controller.document.levelDatum,
                                          showLevel: uiState.pipeShowLevel,
                                          doubleLine: uiState.pipeDoubleLine,
                                          autoFittings: uiState.pipeAutoFittings,
                                          fittingSeries: series, fittingDims: dims,
                                          capEnds: uiState.pipeCapEnds, symbolSize: symbol,
                                          longRadius: drainStyle && uiState.pipeLongRadius,
                                          annotateMaterial: uiState.pipeAnnotateMaterial,
                                          branchKind: drainStyle ? uiState.pipeBranchKind : "DT"),
                    style: Style(colorIndex: usage.colorIndex, lineType: usage.lineType),
                    z: uiState.pipeLevel, drop45: uiState.pipeDrop45)
            }
            controller.onEditOpChanged = { kind in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    uiState.activeEditOp = kind
                }
                uiState.editRotation = 0
            }
            uiState.updatePalette(from: controller.theme)
            controller.publishInitialState()
        }
    }

    // MARK: - パネル自動格納

    private func revealPanel() {
        panelHideWork?.cancel()
        panelHideWork = nil
        if !panelRevealed { panelRevealed = true }
    }

    private func scheduleHide() {
        guard !uiState.panelPinned else { return }
        panelHideWork?.cancel()
        let work = DispatchWorkItem {
            // 発火時点でパネル上にカーソルがあれば格納しない
            if !controller.uiHovering {
                panelRevealed = false
            }
        }
        panelHideWork = work
        // 少し待ってから格納(右端→パネルへ移動する間に消えないよう猶予を持たせる)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

/// 文字ツール中に出る文字パレット(文字種チップ: 紙面mm 2.5/3.5/5/7+自由、角度)
struct TextPropertyCard: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    private let presets: [Double] = [2.5, 3.5, 5, 7]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("文字 — クリック位置でそのまま入力")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                Text("文字種")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ForEach(presets, id: \.self) { mm in
                    Button {
                        uiState.textPaperSize = mm
                        push()
                    } label: {
                        Text(mm == mm.rounded() ? "\(Int(mm))" : String(format: "%.1f", mm))
                            .font(.system(size: 11, weight: uiState.textPaperSize == mm ? .bold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(uiState.textPaperSize == mm ? Color.blue : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(uiState.textPaperSize == mm ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("自由", value: $uiState.textPaperSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 46)
                    .onSubmit { push() }
                Text("mm(紙面)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("角度")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("", value: $uiState.textAngle, format: .number)
                    .selectAllOnFocus()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 42)
                    .onSubmit { push() }
                Text("°")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Text(String(format: "実寸 %.0fmm(縮尺1/%.0f換算)。既存の文字はダブルクリックで再編集",
                        uiState.textPaperSize * uiState.scaleDenominator, uiState.scaleDenominator))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
        .onAppear { push() }
        .onChange(of: uiState.scaleDenominator) { _, _ in
            push()   // 縮尺変更に追従(紙面mm→実寸mm換算をやり直す)
        }
    }

    private func push() {
        controller.setTextStyle(paperMm: uiState.textPaperSize,
                                angleDegrees: uiState.textAngle)
    }
}

/// 配管ツール中に出るプロパティカード(用途→管種→口径。色・線種は用途に連動)
/// 継手プレビューを別ウィンドウで開く(M6.8)
@MainActor private var fittingPreviewWindow: NSWindow?
@MainActor func openFittingPreviewWindow(uiState: CanvasUIState) {
    if let w = fittingPreviewWindow, w.isVisible {
        w.makeKeyAndOrderFront(nil)
        return
    }
    let host = NSHostingController(rootView: FittingPreviewView(uiState: uiState))
    let w = NSWindow(contentViewController: host)
    w.title = "継手プレビュー"
    w.isReleasedWhenClosed = false
    w.styleMask = [.titled, .closable, .resizable]
    w.setContentSize(NSSize(width: 860, height: 600))
    w.center()
    w.makeKeyAndOrderFront(nil)
    fittingPreviewWindow = w
}

struct PipePropertyCard: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState

    private let master = PipeMaster.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("配管 — ルートを連続クリック、⏎か右クリックで確定")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("用途")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(master.usages) { usage in
                        Button {
                            uiState.pipeUsage = usage.id
                            uiState.pipeMaterial = usage.defaultMaterial
                            ensureSizeValid()
                        } label: {
                            Label {
                                Text(usage.name)
                            } icon: {
                                Image(nsImage: uiState.colorSwatch(usage.colorIndex))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let usage = master.usage(uiState.pipeUsage) {
                            Circle().fill(uiState.paletteColor(usage.colorIndex))
                                .frame(width: 9, height: 9)
                            Text(usage.name)
                        } else {
                            Text(uiState.pipeUsage)
                        }
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("系統。色・線種はマスタの既定が自動で付きます")

                Text("管種")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(master.materials) { material in
                        Button("\(material.shortLabel)  \(material.name)") {
                            uiState.pipeMaterial = material.id
                            ensureSizeValid()
                        }
                    }
                } label: {
                    Text(master.material(uiState.pipeMaterial)?.shortLabel ?? uiState.pipeMaterial)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("口径")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(master.sizes(for: uiState.pipeMaterial)) { size in
                        Button((uiState.pipeSize == size.size ? "✓ " : "   ") + size.label) {
                            uiState.pipeSize = size.size
                        }
                    }
                } label: {
                    Text(master.size(material: uiState.pipeMaterial, size: uiState.pipeSize)?.label
                         ?? uiState.pipeSize)
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

            }

            HStack(spacing: 6) {
                Text("高さ")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(["GL", "B1FL", "1FL", "2FL", "3FL", "4FL", "5FL", "RFL"], id: \.self) { d in
                        Button((uiState.levelDatum == d ? "✓ " : "   ") + d) {
                            uiState.levelDatum = d
                            controller.setLevelDatum(d)
                        }
                    }
                } label: {
                    Text(uiState.levelDatum)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("高さの基準面(図面設定)。屋内は各階FL、外構はGL")
                TextField("", value: $uiState.pipeLevel, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 58)
                    .selectAllOnFocus()
                    .help("芯の高さ(mm)。作図中に変えると次の頂点で立管(立上り/立下り記号)が発生します")
                Text("mm")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Toggle("傍記に併記", isOn: $uiState.pipeShowLevel)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))

                Picker("", selection: $uiState.pipeDoubleLine) {
                    Text("単線").tag(false)
                    Text("複線").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("複線=外径2本+芯線(一点鎖線)。折れ点にエルボを自動発生")

                Toggle("継手", isOn: $uiState.pipeAutoFittings)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("折れ点にエルボ、分岐にティーズ、口径違いにレデューサを自動発生(規格: \(seriesLabel))。複線は実形状、単線は記号。集計にも個数が出ます")
                if isDrainStyleNow {
                    Picker("", selection: $uiState.pipeLongRadius) {
                        Text("DL").tag(false)
                        Text("LL").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                    .help("90°曲り部品: DL=90°エルボ / LL=90°大曲エルボ。単線の丸みも変わります")
                    Picker("", selection: $uiState.pipeBranchKind) {
                        Text("DT").tag("DT")
                        Text("LT").tag("LT")
                        Text("Y").tag("Y")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                    .help("分岐部品(この配管を枝管として本管に突き当てたときに本管側へ発生): DT=90°Y / LT=90°大曲Y(枝は本管の作図方向へ抜ける) / Y=45°Y(枝を45°で突き当てる)")
                }
                Picker("", selection: $uiState.pipeDrop45) {
                    Text("90°").tag(false)
                    Text("45°").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
                .help("高さを変えたときの立ち下がり/立ち上がり: 90°=垂直の立管(DL) / 45°=高低差ぶんの勾配区間(45L)")
                if !uiState.pipeDoubleLine {
                    Text("記号")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("", value: symbolSizeBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 44)
                        .selectAllOnFocus()
                        .help("単線記号の基準寸法(紙面mm)。管サイズに依らず一定。排水\(isDrainStyleNow ? "(この配管)" : "")2.5 / 給水2.0が既定。縮尺で詰まるときは小さく")
                    Text("mm")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Toggle("端部キャップ", isOn: $uiState.pipeCapEnds)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("接続されていない端部にキャップを付ける(FILDERの端部品)")

                Toggle("口径傍記", isOn: $uiState.pipeAnnotate)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("最長区間の中央に口径を自動記入します")
                Toggle("管種も", isOn: $uiState.pipeAnnotateMaterial)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(!uiState.pipeAnnotate)
                    .help("傍記に管種略号を付ける(例: HI 20 / VP 75)")
            }

            Text("継手規格: \(seriesLabel)(管種と用途から自動)。高さを変えて次点を打つと立管が入ります")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
    }

    /// 現在の用途・管種が排水系(単線記号は排水サイズを使う)か
    private var isDrainStyleNow: Bool {
        let s = FittingMaster.series(material: uiState.pipeMaterial, usage: uiState.pipeUsage)
        return s == "DV" || ["S", "W", "RW", "VT"].contains(uiState.pipeUsage)
    }

    /// 単線記号サイズ(紙面mm)。排水系/給水系のどちらの設定値かは現在の用途で切替。
    /// 変更は選択中の配管にも反映
    private var symbolSizeBinding: Binding<Double> {
        Binding(
            get: { isDrainStyleNow ? uiState.pipeSymbolDrain : uiState.pipeSymbolSupply },
            set: { v in
                let mm = max(min(v, 20), 0.5)
                if isDrainStyleNow { uiState.pipeSymbolDrain = mm } else { uiState.pipeSymbolSupply = mm }
                controller.applyPipeSymbolSize(mm)
            })
    }

    /// 継手の規格シリーズ表示("DV" / "HI" / …。マスタ未整備なら"概算")
    private var seriesLabel: String {
        let s = FittingMaster.series(material: uiState.pipeMaterial, usage: uiState.pipeUsage)
        return s.isEmpty ? "概算" : s
    }

    /// 管種を変えたとき、同じ呼び径が無ければ近いもの(無ければ先頭)へ寄せる
    private func ensureSizeValid() {
        let sizes = master.sizes(for: uiState.pipeMaterial)
        guard !sizes.isEmpty else { return }
        if sizes.contains(where: { $0.size == uiState.pipeSize }) { return }
        let current = Double(uiState.pipeSize) ?? 0
        let nearest = sizes.min {
            abs((Double($0.size) ?? 0) - current) < abs((Double($1.size) ?? 0) - current)
        }
        uiState.pipeSize = (nearest ?? sizes[0]).size
    }
}

/// 引出線ツール中に出るプロパティカード(タイプ・矢印・二重枠・文字サイズ・縦横比・色)
struct LeaderPropertyCard: View {
    @ObservedObject var uiState: CanvasUIState

    private let textPresets: [Double] = [2.5, 3.5, 5, 7]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("引出線 — 指示点→文字位置→その場で入力")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Picker("", selection: $uiState.leaderBalloon) {
                    Text("引出線文字").tag(false)
                    Text("バルーン").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("引出線文字=傍記 / バルーン=円形枠に文字(機器番号など)")

                Toggle("矢印", isOn: $uiState.leaderArrow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("指示点に矢印を付ける")

                if uiState.leaderBalloon {
                    Toggle("二重枠", isOn: $uiState.leaderDoubleFrame)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("バルーンの枠を二重にする")
                    Text("横サイズ")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Menu {
                        Button((uiState.leaderWidth < 0 ? "✓ " : "   ") + "自動(文字に合わせる)") {
                            uiState.leaderWidth = -1
                        }
                        Divider()
                        ForEach([6.0, 8.0, 10.0, 12.0, 15.0, 20.0], id: \.self) { mm in
                            Button((uiState.leaderWidth == mm ? "✓ " : "   ") + "\(Int(mm)) mm(紙面)") {
                                uiState.leaderWidth = mm
                            }
                        }
                    } label: {
                        Text(uiState.leaderWidth < 0 ? "自動"
                             : String(format: "%.0fmm", uiState.leaderWidth))
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("バルーンの横サイズ(直径・紙面mm)。自動=文字数に合わせる")
                    Text("縦横比")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    TextField("", value: $uiState.leaderAspect, format: .number)
                        .selectAllOnFocus()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 42)
                    Text("%")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 5) {
                Text("文字")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ForEach(textPresets, id: \.self) { mm in
                    Button {
                        uiState.leaderTextSize = mm
                    } label: {
                        Text(mm == mm.rounded() ? "\(Int(mm))" : String(format: "%.1f", mm))
                            .font(.system(size: 11, weight: uiState.leaderTextSize == mm ? .bold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(uiState.leaderTextSize == mm ? Color.blue : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(uiState.leaderTextSize == mm ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("mm(紙面)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Text("色")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("レイヤ既定") { uiState.leaderColorIndex = nil }
                    Divider()
                    ForEach(0..<uiState.paletteColors.count, id: \.self) { i in
                        Button {
                            uiState.leaderColorIndex = i
                        } label: {
                            Label {
                                Text("色 \(i)")
                            } icon: {
                                Image(nsImage: uiState.colorSwatch(i))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let idx = uiState.leaderColorIndex {
                            Circle().fill(uiState.paletteColor(idx)).frame(width: 9, height: 9)
                            Text("色 \(idx)")
                        } else {
                            Text("レイヤ既定")
                        }
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(uiState.leaderBalloon
                 ? "「,」区切りで二段・三段に分かれます(例: 排水管,125φ,GL-250)。ダブルクリックで再編集"
                 : "文字は指示点と反対側へ水平に書きます。既存の傍記はダブルクリックで再編集")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
    }
}

/// 寸法ツール中に出るプロパティカード(方向・端部・補助線長さ・文字サイズ・色)
struct DimensionPropertyCard: View {
    @ObservedObject var uiState: CanvasUIState

    private let textPresets: [Double] = [2.5, 3.5, 5, 7]
    /// (表示名, dimExtension値): -1=測定点まで 0=なし >0=紙面mm
    private let extPresets: [(String, Double)] = [("測定点まで", -1), ("5mm", 5), ("3mm", 3), ("なし", 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("寸法 — 測定点1→測定点2→寸法線の位置")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Picker("", selection: $uiState.dimAxis) {
                    ForEach(DimAxisMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("寸法線の方向: 水平/垂直/平行(測定点2点の方向)")

                Picker("", selection: $uiState.dimTerminator) {
                    ForEach(DimTerminator.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("端部記号: 黒丸(実点)/ 矢印")

                Text("補助線")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(extPresets, id: \.1) { preset in
                        Button((uiState.dimExtension == preset.1 ? "✓ " : "   ") + preset.0) {
                            uiState.dimExtension = preset.1
                        }
                    }
                } label: {
                    Text(extLabel)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("寸法補助線の長さ(紙面mm)。測定点まで/指定長さ/なし")
            }

            HStack(spacing: 5) {
                Text("文字")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ForEach(textPresets, id: \.self) { mm in
                    Button {
                        uiState.dimTextSize = mm
                    } label: {
                        Text(mm == mm.rounded() ? "\(Int(mm))" : String(format: "%.1f", mm))
                            .font(.system(size: 11, weight: uiState.dimTextSize == mm ? .bold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(uiState.dimTextSize == mm ? Color.blue : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(uiState.dimTextSize == mm ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("mm(紙面)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Text("色")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("レイヤ既定") { uiState.dimColorIndex = nil }
                    Divider()
                    ForEach(0..<uiState.paletteColors.count, id: \.self) { i in
                        Button {
                            uiState.dimColorIndex = i
                        } label: {
                            Label {
                                Text("色 \(i)")
                            } icon: {
                                Image(nsImage: uiState.colorSwatch(i))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let idx = uiState.dimColorIndex {
                            Circle().fill(uiState.paletteColor(idx)).frame(width: 9, height: 9)
                            Text("色 \(idx)")
                        } else {
                            Text("レイヤ既定")
                        }
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("寸法の色(線・端部・寸法値とも)。レイヤ既定か色番号を指定")
            }

            Text("寸法値は実測値を自動記入(実寸mm)。既存寸法の変更はプロパティパネルから")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
    }

    private var extLabel: String {
        if uiState.dimExtension < 0 { return "測定点まで" }
        if uiState.dimExtension == 0 { return "なし" }
        return String(format: "%.0fmm", uiState.dimExtension)
    }
}

/// ハッチングツール中に出るプロパティカード(FILDERのハッチングダイアログの常駐版)
struct HatchPropertyCard: View {
    @ObservedObject var uiState: CanvasUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ハッチング — 頂点をクリックして領域を指定")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            // パターン選択(塗り+6種)
            HStack(spacing: 4) {
                ForEach(HatchPattern.Kind.allCases, id: \.self) { kind in
                    Button {
                        uiState.hatchKind = kind
                    } label: {
                        Text(kind.label)
                            .font(.system(size: 11, weight: uiState.hatchKind == kind ? .bold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(uiState.hatchKind == kind ? Color.blue : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(uiState.hatchKind == kind ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if uiState.hatchKind != .solid {
                HStack(spacing: 6) {
                    Text("A間隔")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    TextField("", value: $uiState.hatchA, format: .number)
                        .selectAllOnFocus()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 50)
                    if uiState.hatchKind.usesSpacingB {
                        Text("B間隔")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", value: $uiState.hatchB, format: .number)
                            .selectAllOnFocus()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 50)
                    }
                    Text("角度")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    TextField("", value: $uiState.hatchAngle, format: .number)
                        .selectAllOnFocus()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 46)
                    Text("°")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $uiState.hatchPaperUnits) {
                        Text("印刷寸").tag(true)
                        Text("実寸").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .help("印刷寸=紙に刷ったときのmm(縮尺を掛けて実寸に換算)/ 実寸=そのままmm")
                }
            }

            Text(uiState.hatchKind == .solid
                 ? "領域を塗りつぶします(色はプロパティで変更可)"
                 : "2線/3線: A=組ピッチ・B=組内 / クロス: A=横・B=縦 / レンガ: A=段高・B=幅")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
    }
}

/// 移動・複写中に出るコマンドプロパティカード(角度=回転しながら配置)
struct EditPropertyCard: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState
    @State private var customAngle = ""

    private let presets: [Double] = [0, 90, 180, 270]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("コマンドプロパティ — \(uiState.activeEditOp?.label ?? "")")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                Text("角度")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ForEach(presets, id: \.self) { deg in
                    Button {
                        apply(deg)
                    } label: {
                        Text("\(Int(deg))°")
                            .font(.system(size: 11, weight: uiState.editRotation == deg ? .bold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(uiState.editRotation == deg ? Color.blue : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(uiState.editRotation == deg ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("自由", text: $customAngle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 52)
                    .onSubmit {
                        if let deg = Double(customAngle.trimmingCharacters(in: .whitespaces)) {
                            apply(deg)
                        }
                    }
                Text("°")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Text("回転しながら配置(反時計回り正)。反転は右クリック→反転/反転複写")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
    }

    private func apply(_ degrees: Double) {
        uiState.editRotation = degrees
        controller.setEditRotation(degrees)
    }
}

@main
struct MepCadApp: App {
    private let controller = CanvasController()
    @StateObject private var uiState = CanvasUIState()

    init() {
        // SPM実行(swift run)でもウィンドウが前面に来るようにする
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MepCad — M5") {
            ContentView(controller: controller, uiState: uiState)
        }
        .commands {
            // ファイルメニュー(⌘N/⌘Oのショートカットはここで一元管理)
            CommandGroup(replacing: .newItem) {
                Button("新規図面…") {
                    controller.newDrawingPanel()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("開く…(JWW / DXF)") {
                    controller.openJwwPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}


// MARK: - 数値欄はクリックで全選択(M6.6)

/// フォーカスが入ったら内容を全選択する(数値欄で「0の後ろにカーソル」にならないように)
private struct SelectAllOnFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                guard isFocused else { return }
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                }
            }
    }
}

extension View {
    /// 数値入力欄: フォーカス時に全選択
    func selectAllOnFocus() -> some View { modifier(SelectAllOnFocus()) }
}
