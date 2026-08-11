import SwiftUI
import AppKit
import MepCore
import MepTools

/// ステータスバー表示用の状態
final class CanvasUIState: ObservableObject {
    @Published var coords = "X: —  Y: —"
    @Published var zoom = "—"
    @Published var snap = "—"
    @Published var info = "⌘O=JWWを開く / ツールバーで作図ツールを選択(M3)"
    @Published var tool: ToolKind = .select
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
    @State private var gridOn = true

    var body: some View {
        VStack(spacing: 0) {
            CanvasView(controller: controller)
                .frame(minWidth: 800, minHeight: 500)

            // ステータスバー(モックv0.4準拠の最小構成)
            HStack(spacing: 14) {
                // 幅固定: 文字数の変化でレイアウトが揺れないようにする
                Text(uiState.coords)
                    .monospacedDigit()
                    .frame(width: 190, alignment: .leading)
                // クリックでグリッド表示切替
                Button {
                    controller.toggleGrid()
                    gridOn.toggle()
                } label: {
                    Text(gridOn ? "グリッド 250" : "グリッド OFF")
                        .foregroundStyle(gridOn ? .primary : .tertiary)
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
            // 作図ツール(モックの左パレット簡易版。パネルUIはM4)
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

            ToolbarItemGroup {
                Button {
                    controller.openJwwPanel()
                } label: {
                    Image(systemName: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("JWWファイルを開く(⌘O)")

                Button {
                    controller.toggleTheme()
                    isDark.toggle()
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
        }
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
        WindowGroup("MepCad — M1") {
            ContentView(controller: controller, uiState: uiState)
        }
    }
}
