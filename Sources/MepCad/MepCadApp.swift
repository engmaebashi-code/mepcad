import SwiftUI
import AppKit
import MepCore

/// SwiftPM実行時にも標準メニューを日本語で表示する。
private enum MenuLocalizer {
    private static var refreshTimer: Timer?
    private static let translations: [String: String] = [
        "File": "ファイル", "Edit": "編集", "View": "表示",
        "Window": "ウインドウ", "Help": "ヘルプ",
        "About MepCad": "MepCadについて", "About mepcad": "MepCadについて",
        "Settings…": "設定…", "Settings...": "設定…",
        "Services": "サービス", "Hide MepCad": "MepCadを隠す",
        "Hide Others": "ほかを隠す", "Show All": "すべてを表示",
        "Quit MepCad": "MepCadを終了", "Quit mepcad": "MepCadを終了",
        "New Window": "新規ウインドウ", "Close": "閉じる",
        "Undo": "取り消す", "Redo": "やり直す",
        "Cut": "カット", "Copy": "コピー", "Paste": "ペースト",
        "Paste and Match Style": "ペーストしてスタイルを合わせる",
        "Delete": "削除", "Select All": "すべてを選択",
        "Substitutions": "自動置換", "Transformations": "変換",
        "Speech": "スピーチ",
        "Show Toolbar": "ツールバーを表示",
        "Hide Toolbar": "ツールバーを隠す",
        "Customize Toolbar…": "ツールバーをカスタマイズ…",
        "Enter Full Screen": "フルスクリーンにする",
        "Exit Full Screen": "フルスクリーンを解除",
        "Minimize": "しまう", "Zoom": "拡大／縮小",
        "Move & Resize": "移動とサイズ変更",
        "Bring All to Front": "すべてを手前に移動",
        "Search": "検索",
    ]

    static func localize() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        localize(items: mainMenu.items)
    }

    /// SwiftUIの標準メニューを残したまま、メニュー検証で英語へ戻された
    /// タイトルだけを日本語へ戻す。
    static func localizeAfterMenuUpdates() {
        localize()
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            localize()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private static func localize(items: [NSMenuItem]) {
        for item in items {
            if let translated = translations[item.title] {
                item.title = translated
            }
            if let submenu = item.submenu {
                localize(items: submenu.items)
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuLocalizer.localizeAfterMenuUpdates()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MenuLocalizer.localizeAfterMenuUpdates()
    }
}

/// ステータスバー表示用の状態
final class CanvasUIState: ObservableObject {
    @Published var coords = "X: —  Y: —"
    @Published var zoom = "—"
    @Published var snap = "—"
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
                    .lineLimit(1)
                    .frame(width: 190, alignment: .leading)
                Text("グリッド 250")
                    .lineLimit(1)
                Text("スナップ: \(uiState.snap)")
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
                Text("ズーム \(uiState.zoom)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)
                Spacer()
                Text("M1 デモ図面 — スクロール=パン / ピンチ・⌘スクロール=ズーム / ダブルクリック=全体表示")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            // スナップ種別や座標文字列が変化してもキャンバス寸法を変えない。
            .frame(height: 26)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
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
            // SwiftUIが標準メニューを構築した後にタイトルを置き換える。
            MenuLocalizer.localizeAfterMenuUpdates()
        }
    }
}

@main
struct MepCadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
