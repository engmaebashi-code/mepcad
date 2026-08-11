import SwiftUI
import AppKit
import MepCore

/// ステータスバー表示用の状態
final class CanvasUIState: ObservableObject {
    @Published var coords = "X: —  Y: —"
    @Published var zoom = "—"
    @Published var snap = "—"
    @Published var info = "⌘O でJWWファイルを開けます(M2)"
}

struct ContentView: View {
    let controller: CanvasController
    @ObservedObject var uiState: CanvasUIState
    @State private var isDark = false

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
                Text("グリッド 250")
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
