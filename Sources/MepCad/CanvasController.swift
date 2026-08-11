import Foundation
import AppKit
import UniformTypeIdentifiers
import MepCore
import MepFormats
import MepRender
import MepTools

/// キャンバスの状態と操作を束ねるコントローラ(メインスレッド専用)。
/// NSView(イベント)とSwiftUI(ステータスバー)の橋渡しをする。
final class CanvasController {
    let document = Document()
    let commandStack: CommandStack
    let snapEngine = SnapEngine()

    var transform = ViewTransform(scale: 0.08, origin: Vec2(60, 540))
    var theme = RenderTheme.light()
    var gridSpacing: Double = 250  // mm
    var pickBoxPx: Double = 10     // 環境設定と連動予定

    /// 最後に計算したカーソル状態(オーバーレイ描画用)
    var cursorScreen: Vec2?
    var snappedScreen: Vec2?
    var snappedKind: SnapKind?

    /// UI更新通知
    var onStatusUpdate: ((_ coords: String, _ zoom: String, _ snap: String) -> Void)?
    var onInfo: ((String) -> Void)?
    var needsContentRedraw: (() -> Void)?
    var needsOverlayRedraw: (() -> Void)?
    /// ドキュメント内容の変更(描画キャッシュ破棄が必要)
    var onDocumentChanged: (() -> Void)?
    /// キャンバスの現在サイズ(コンテナビューが提供)
    var viewSizeProvider: (() -> CGSize)?

    init() {
        commandStack = CommandStack(document: document)
        document.loadDemoContent()
        snapEngine.rebuild(from: document)
        document.onChange = { [weak self] in
            guard let self else { return }
            self.snapEngine.rebuild(from: self.document)
            self.onDocumentChanged?()
            self.needsContentRedraw?()
        }
    }

    // MARK: - JWW読込(M2)

    func openJwwPanel() {
        let panel = NSOpenPanel()
        panel.title = "JWWファイルを開く"
        if let jwwType = UTType(filenameExtension: "jww") {
            panel.allowedContentTypes = [jwwType]
        }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadJww(url: url)
    }

    func loadJww(url: URL) {
        onInfo?("JWW読込中… \(url.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // 解析はバックグラウンド、ドキュメント反映はメインで行う
                let data = try Data(contentsOf: url)
                let parser = JwwParser(data: data)
                let start = Date()
                let drawing = try parser.parse()
                let parseMs = Int(Date().timeIntervalSince(start) * 1000)

                DispatchQueue.main.async {
                    // 「開く」= 図面全体の置き換え(デモ図面・前回の下敷きも含めて全消去)
                    self.document.removeAllEntities()
                    let count = JwwReader.importDrawing(drawing, into: self.document)
                    if let size = self.viewSizeProvider?() {
                        self.fit(viewSize: size)
                    }
                    self.onInfo?("\(url.lastPathComponent) — 線\(drawing.lines.count) 弧\(drawing.arcs.count) 字\(drawing.texts.count) / 解析\(parseMs)ms / 計\(count)要素")
                }
            } catch {
                DispatchQueue.main.async {
                    self.onInfo?("読込エラー: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 操作

    func pan(dx: Double, dy: Double) {
        transform.pan(by: Vec2(dx, dy))
        needsContentRedraw?()
        needsOverlayRedraw?()
    }

    func zoom(factor: Double, atScreen p: Vec2) {
        transform.zoom(by: factor, at: p)
        needsContentRedraw?()
        needsOverlayRedraw?()
        publishStatus()
    }

    func fit(viewSize: CGSize) {
        var box = document.bounds
        if box.isEmpty { box = BBox(minX: 0, minY: 0, maxX: 10000, maxY: 8000) }
        transform.fit(box.expanded(by: 500), in: Vec2(Double(viewSize.width), Double(viewSize.height)))
        needsContentRedraw?()
        needsOverlayRedraw?()
        publishStatus()
    }

    func mouseMoved(toScreen p: Vec2) {
        cursorScreen = p
        let world = transform.toWorld(p)
        let radiusMm = pickBoxPx / max(transform.scale, 1e-9)
        snapEngine.gridSpacing = gridSpacing
        if let result = snapEngine.snap(world, radius: radiusMm) {
            snappedScreen = transform.toScreen(result.point)
            snappedKind = result.kind
        } else {
            snappedScreen = nil
            snappedKind = nil
        }
        needsOverlayRedraw?()
        publishStatus()
    }

    func mouseExited() {
        cursorScreen = nil
        snappedScreen = nil
        snappedKind = nil
        needsOverlayRedraw?()
    }

    func toggleTheme() {
        theme = theme.isDark ? .light() : .dark()
        needsContentRedraw?()
        needsOverlayRedraw?()
    }

    // MARK: - ステータス

    private func publishStatus() {
        guard let p = cursorScreen else { return }
        let effective = snappedScreen ?? p
        let w = transform.toWorld(effective)
        let coords = String(format: "X: %.0f  Y: %.0f", w.x, w.y)
        let zoom = String(format: "%.0f%%", transform.scale * 1000)  // 1/50図面での見かけ倍率目安
        let snapText: String
        switch snappedKind {
        case .endpoint: snapText = "端点"
        case .midpoint: snapText = "中点"
        case .center: snapText = "中心"
        case .grid: snapText = "グリッド"
        case nil: snapText = "—"
        }
        onStatusUpdate?(coords, zoom, snapText)
    }
}
