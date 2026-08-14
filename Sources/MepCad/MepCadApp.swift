import SwiftUI
import AppKit
import MepCore
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
    @Published var leaderColorIndex: Int? = nil

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
                                            aspectPercent: min(max(uiState.leaderAspect, 30), 150)),
                    colorIndex: uiState.leaderColorIndex)
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
                    Text("縦横比")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    TextField("", value: $uiState.leaderAspect, format: .number)
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
                 ? "枠は文字数に合わせて自動サイズ。既存バルーンはダブルクリックで再編集"
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
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 50)
                    if uiState.hatchKind.usesSpacingB {
                        Text("B間隔")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", value: $uiState.hatchB, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 50)
                    }
                    Text("角度")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    TextField("", value: $uiState.hatchAngle, format: .number)
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
