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

    func paletteColor(_ index: Int) -> Color {
        guard index >= 0, index < paletteColors.count else { return .primary }
        return paletteColors[index]
    }

    func updatePalette(from theme: RenderTheme) {
        paletteColors = theme.palette.map { Color(cgColor: $0) }
    }
}

private func toolIcon(_ kind: ToolKind) -> String {
    switch kind {
    case .select: return "cursorarrow"
    case .line: return "line.diagonal"
    case .circle: return "circle"
    case .text: return "textformat"
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
                // クリックでグリッド表示切替(状態はコントローラから同期)
                Button {
                    controller.toggleGrid()
                } label: {
                    Text(uiState.gridOn ? "グリッド 250" : "グリッド OFF")
                        .foregroundStyle(uiState.gridOn ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .help("クリックでグリッド表示/非表示")
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

            // 角度拘束パレット(常設・マウスだけで切替)
            ToolbarItemGroup {
                Picker("角度拘束", selection: $angle) {
                    ForEach(AngleConstraint.allCases, id: \.self) { constraint in
                        Text(constraint.rawValue).tag(constraint)
                    }
                }
                .pickerStyle(.segmented)
                .help("角度拘束: 作図中の線の角度を丸める(自由/90°/45°/15°)")
                .onChange(of: angle) { _, newValue in
                    controller.tools.angleConstraint = newValue
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

            // スナップ設定(将来は環境設定に移設)
            ToolbarItemGroup {
                Menu {
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
                } label: {
                    Image(systemName: "scope")
                }
                .help("スナップ設定(種別ごとのON/OFF)")
            }

            ToolbarItemGroup {
                Button {
                    controller.openJwwPanel()
                } label: {
                    Image(systemName: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("JWWファイルを開く(⌘O)")

                // パネルのピン留め(自動格納⇔常時表示)
                Button {
                    uiState.panelPinned.toggle()
                    if uiState.panelPinned { panelRevealed = true }
                } label: {
                    Image(systemName: uiState.panelPinned ? "sidebar.trailing" : "sidebar.right")
                }
                .help("レイヤ/プロパティパネル(右端にカーソルを寄せても出ます)")

                Button {
                    controller.toggleTheme()
                    isDark.toggle()
                    uiState.updatePalette(from: controller.theme)
                } label: {
                    Image(systemName: isDark ? "sun.max" : "moon")
                }
                .help("背景色(ライト/ダーク)切替 — 正式版では環境設定に配置")
            }
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
        WindowGroup("MepCad — M4") {
            ContentView(controller: controller, uiState: uiState)
        }
    }
}
