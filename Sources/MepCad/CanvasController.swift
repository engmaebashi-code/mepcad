import Foundation
import AppKit
import UniformTypeIdentifiers
import MepCore
import MepData
import MepFormats
import MepRender
import MepTools

/// 選択中オブジェクトの属性サマリ(プロパティパネル表示用)
struct SelectionSummary: Equatable {
    var count: Int
    var lineCount: Int
    var circleCount: Int
    var arcCount: Int
    var textCount: Int
    var pointCount: Int
    var blockCount: Int
    var hatchCount: Int
    var dimCount: Int
    var leaderCount: Int
    var pipeCount: Int
    /// 選択中のブロックが全て同じ定義ならその名前
    var commonBlockName: String?
    /// 全選択で共通ならその値(内側nil=byLayer)、混在なら外側nil
    var commonColorIndex: Int??
    var commonLineType: Int??
    var commonLineWeight: Double??
    var commonLayer: LayerAddress?
}

/// キャンバスの状態と操作を束ねるコントローラ(メインスレッド専用)。
/// NSView(イベント)とSwiftUI(ステータスバー・パネル)の橋渡しをする。
final class CanvasController: NSObject {
    let document: Document
    let commandStack: CommandStack
    let snapEngine = SnapEngine()
    let tools: DrawingToolController
    let editOp = EditOperation()

    var transform = ViewTransform(scale: 0.08, origin: Vec2(60, 540))
    var theme = RenderTheme.light()
    var gridSpacing: Double = 250  // mm
    var gridVisible = true
    var pickBoxPx: Double = 10     // 環境設定と連動予定

    /// 描画に渡すグリッド間隔(非表示時は0=描かない)
    var effectiveGridSpacing: Double { gridVisible ? gridSpacing : 0 }

    func toggleGrid() {
        gridVisible.toggle()
        // グリッド非表示のときはグリッドスナップも無効にする(端点スナップは維持)
        snapEngine.gridEnabled = gridVisible
        // グリッドはキャッシュに焼き込まれているため破棄が必要
        onDocumentChanged?()
        needsContentRedraw?()
        onGridChanged?(gridVisible)  // 状態はコントローラが唯一の情報源(UI側はこれに追従)
    }

    /// 最後に計算したカーソル状態(オーバーレイ描画用)
    var cursorScreen: Vec2?
    var snappedScreen: Vec2?
    var snappedKind: SnapKind?
    /// 作図プレビュー(ワールド座標。オーバーレイが描画)
    var previewShape: PreviewShape = .none

    // MARK: - 選択状態(M4)

    /// 現在の選択(idの集合)
    private(set) var selection: Set<EntityID> = []
    /// オーバーレイ描画用の選択エンティティ実体キャッシュ
    private(set) var selectedEntities: [Entity] = []
    /// 矩形選択(マーキー)中のスクリーン座標
    var marqueeStartScreen: Vec2?
    var marqueeCurrentScreen: Vec2?
    /// マーキーのモード(ドラッグ方向で決まる: 左→右=窓、右→左=交差)
    var marqueeMode: RectSelectionMode {
        guard let s = marqueeStartScreen, let c = marqueeCurrentScreen else { return .window }
        return c.x >= s.x ? .window : .crossing
    }
    /// 移動/複写/回転ゴーストの変換(ワールド)。nilなら非表示
    var ghostTransform: EditTransform?
    /// SwiftUIパネル上にカーソルがある間true(十字カーソルを消して矢印に戻す)
    var uiHovering = false {
        didSet {
            guard uiHovering != oldValue else { return }
            if uiHovering {
                cursorScreen = nil
                snappedScreen = nil
                snappedKind = nil
            }
            needsOverlayRedraw?()
            onUIHoverChanged?()
        }
    }

    /// UI更新通知
    var onStatusUpdate: ((_ coords: String, _ zoom: String, _ snap: String) -> Void)?
    var onInfo: ((String) -> Void)?
    var onToolChanged: ((ToolKind) -> Void)?
    var needsContentRedraw: (() -> Void)?
    var needsOverlayRedraw: (() -> Void)?
    /// ドキュメント内容の変更(描画キャッシュ破棄が必要)
    var onDocumentChanged: (() -> Void)?
    /// キャンバスの現在サイズ(コンテナビューが提供)
    var viewSizeProvider: (() -> CGSize)?
    /// レイヤ構造の変化(レイヤパネル用: 16グループ+カレント+レイヤ別要素数[256])
    var onLayersChanged: (([LayerGroup], LayerAddress, [Int]) -> Void)?
    /// 選択の変化(プロパティパネル用)
    var onSelectionChanged: ((SelectionSummary?) -> Void)?
    /// パネルホバー状態の変化(カーソル矩形の更新用)
    var onUIHoverChanged: (() -> Void)?
    /// 右端接近の変化(Dock風パネルの出し入れ用。trueで接近)
    var onEdgeProximity: ((Bool) -> Void)?
    private var lastEdgeProximity = false
    /// グリッド表示状態の変化(ステータスバー表示の同期用)
    var onGridChanged: ((Bool) -> Void)?
    /// グリッド間隔の変化(ステータスバー表示の同期用)
    var onGridSpacingChanged: ((Double) -> Void)?
    /// 補助線表示状態の変化(ステータスバー表示の同期用)
    var onAuxiliaryChanged: ((Bool) -> Void)?
    /// 編集操作の開始/終了(コマンドプロパティカードの表示用。nil=非アクティブ)
    var onEditOpChanged: ((EditOpKind?) -> Void)?
    /// 用紙・縮尺の変化(フッター表示の同期用: 用紙サイズ+書込グループの縮尺分母)
    var onDrawingSetupChanged: ((PaperSize, Double) -> Void)?
    /// ハッチング設定の提供(プロパティカードの値。印刷寸→実寸換算込み)
    var hatchPatternProvider: (() -> HatchPattern)?
    /// 寸法設定の提供(プロパティカードの値。紙面mm→実寸mm換算込み)
    var dimensionStyleProvider: (() -> DimensionToolStyle)?
    /// 引出線設定の提供(プロパティカードの値。紙面mm→実寸mm換算込み)
    var leaderStyleProvider: (() -> LeaderToolStyle)?
    /// 配管設定の提供(プロパティカードの値。用途の色・線種込み)
    var pipeStyleProvider: (() -> PipeToolStyle)?
    /// 配管を既存の接続口から描き始めたときの通知(M7)。
    /// 受け側(UI)が口径・管種・用途・高さをコマンドプロパティへ反映する
    var onPipePortPicked: ((PipePort) -> Void)?
    /// インライン文字入力の依頼(スクリーン座標・初期文字列・画面上のフォントpx。
    /// CanvasViewがクリック位置にテキスト欄を出し、確定文字列(キャンセルはnil)を返す)
    var onTextInputRequested: ((_ screen: Vec2, _ initial: String, _ fontPx: Double,
                                _ completion: @escaping (String?) -> Void) -> Void)?

    override init() {
        let doc = Document()
        document = doc
        commandStack = CommandStack(document: doc)
        tools = DrawingToolController(currentLayer: doc.current)
        super.init()
        document.loadDemoContent()
        snapEngine.rebuild(from: document)
        document.onChange = { [weak self] in
            guard let self else { return }
            // グリップ編集中に外部要因(⌘Z等)で図面が変わったら編集を中止
            // (確定時は先にgripDrag=nilになっているためここには来ない)
            if self.gripDrag != nil {
                self.cancelGripDrag()
            }
            self.snapEngine.rebuild(from: self.document)
            // 書込レイヤの変更をツールに同期
            self.tools.currentLayer = self.document.current
            // 選択中エンティティが消えた/変わった場合に追従
            self.pruneSelection()
            self.onDocumentChanged?()
            self.needsContentRedraw?()
            self.publishLayers()
        }
        tools.delegate = self
    }

    // MARK: - 選択(M4)

    /// ワールド座標でのヒット許容距離(画面上のピックボックス半幅+1px)
    private var hitToleranceMm: Double {
        (pickBoxPx / 2 + 1) / max(transform.scale, 1e-9)
    }

    /// クリック選択。shift=追加/除外トグル
    func clickSelect(atScreen p: Vec2, shiftDown: Bool) {
        let world = transform.toWorld(p)
        let hit = SelectionEngine.topmostHit(at: world, tolerance: hitToleranceMm,
                                             entities: document.entities,
                                             groups: document.groups,
                                             includeAuxiliary: document.showAuxiliary)
        if let hit {
            if shiftDown {
                if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) }
            } else {
                selection = [hit]
            }
        } else if !shiftDown {
            selection = []
        }
        selectionDidChange()

        // 空振り時の診断: ロック/表示のみレイヤの要素だったら理由を知らせる
        // (「クリックしても選べない」を無言にしない)
        if hit == nil {
            let visibleOnly = SelectionEngine.topmostHit(at: world, tolerance: hitToleranceMm,
                                                         entities: document.entities,
                                                         groups: document.groups,
                                                         among: SelectionEngine.visibleAddresses(document.groups),
                                                         includeAuxiliary: document.showAuxiliary)
            if let visibleOnly, let entity = document.entity(id: visibleOnly) {
                onInfo?("その要素は \(layerDisplayName(entity.layer)) がロック中のため選択できません(レイヤパネルで解除)")
            }
        }
    }

    /// 矩形選択の確定
    func commitMarquee(shiftDown: Bool) {
        defer {
            marqueeStartScreen = nil
            marqueeCurrentScreen = nil
            needsOverlayRedraw?()
        }
        guard let s = marqueeStartScreen, let c = marqueeCurrentScreen else { return }
        let mode = marqueeMode
        let w1 = transform.toWorld(s)
        let w2 = transform.toWorld(c)
        let rect = BBox(minX: min(w1.x, w2.x), minY: min(w1.y, w2.y),
                        maxX: max(w1.x, w2.x), maxY: max(w1.y, w2.y))
        let ids = SelectionEngine.ids(in: rect, mode: mode,
                                      entities: document.entities,
                                      groups: document.groups,
                                      includeAuxiliary: document.showAuxiliary)
        if shiftDown {
            selection.formUnion(ids)
        } else {
            selection = Set(ids)
        }
        selectionDidChange()
    }

    func selectAll() {
        let selectable = SelectionEngine.selectableAddresses(document.groups)
        selection = Set(document.entities.filter {
            selectable.contains($0.layer) && (document.showAuxiliary || !$0.isAuxiliary)
        }.map(\.id))
        selectionDidChange()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        selectionDidChange()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let snapshot = document.entities(ids: selection)
        selection = []
        commandStack.run(RemoveEntitiesCommand(entities: snapshot))
        selectionDidChange()
        onInfo?("\(snapshot.count)個の要素を削除しました(⌘Zで取り消し)")
    }

    /// ドキュメント変更後、存在しないid・選択不能になったidを選択から取り除く
    private func pruneSelection() {
        guard !selection.isEmpty else {
            selectedEntities = []
            return
        }
        let selectable = SelectionEngine.selectableAddresses(document.groups)
        var pruned = Set<EntityID>()
        for e in document.entities where selection.contains(e.id) && selectable.contains(e.layer) {
            // 補助線が非表示なら補助線も選択から外す
            if !document.showAuxiliary, e.isAuxiliary { continue }
            pruned.insert(e.id)
        }
        selection = pruned
        selectedEntities = document.entities(ids: selection)
        // 移動・複写の途中で選択が消えたら(レイヤロック等)操作も終了する
        if selection.isEmpty, editOp.isActive {
            cancelEditOperation()
        }
        // グリップ編集中の要素が選択から消えたら中止
        if let state = gripDrag, !selection.contains(state.grip.entityID) {
            cancelGripDrag()
        }
        onSelectionChanged?(selectionSummary())
        needsOverlayRedraw?()
    }

    private func selectionDidChange() {
        selectedEntities = document.entities(ids: selection)
        needsOverlayRedraw?()
        onSelectionChanged?(selectionSummary())
        publishSelectionHint()
    }

    private func publishSelectionHint() {
        if editOp.isActive { return }
        if selection.isEmpty {
            if tools.kind == .select {
                onInfo?("クリック=選択 / 左→右ドラッグ=窓選択 / 右→左=交差選択 / 右クリック=メニュー")
            }
        } else if currentGrips().isEmpty {
            onInfo?("\(selection.count)個選択中 — 右クリック=複写・移動 / delete=削除 / esc=解除")
        } else {
            onInfo?("\(selection.count)個選択中 — □グリップをドラッグ=伸縮 / 右クリック=メニュー / delete=削除 / esc=解除")
        }
    }

    private func selectionSummary() -> SelectionSummary? {
        guard !selectedEntities.isEmpty else { return nil }
        var lines = 0, circles = 0, arcs = 0, texts = 0, points = 0, blocks = 0, hatches = 0
        var dims = 0, leaders = 0, pipes = 0
        var blockDefIDs = Set<UUID>()
        for e in selectedEntities {
            switch e.kind {
            case .line: lines += 1
            case .circle: circles += 1
            case .arc: arcs += 1
            case .text: texts += 1
            case .point: points += 1
            case .blockRef(let defID, _, _, _, _, _):
                blocks += 1
                blockDefIDs.insert(defID)
            case .hatch: hatches += 1
            case .dimension: dims += 1
            case .leader: leaders += 1
            case .pipe: pipes += 1
            }
        }
        var blockName: String?
        if blocks > 0, blockDefIDs.count == 1, let defID = blockDefIDs.first {
            blockName = document.blockDefinition(id: defID)?.name
        }
        func common<T: Equatable>(_ values: [T]) -> T? {
            guard let first = values.first else { return nil }
            return values.allSatisfy { $0 == first } ? first : nil
        }
        return SelectionSummary(
            count: selectedEntities.count,
            lineCount: lines, circleCount: circles, arcCount: arcs, textCount: texts,
            pointCount: points, blockCount: blocks, hatchCount: hatches, dimCount: dims,
            leaderCount: leaders, pipeCount: pipes,
            commonBlockName: blockName,
            commonColorIndex: common(selectedEntities.map(\.style.colorIndex)),
            commonLineType: common(selectedEntities.map(\.style.lineType)),
            commonLineWeight: common(selectedEntities.map(\.style.lineWeight)),
            commonLayer: common(selectedEntities.map(\.layer))
        )
    }

    // MARK: - 選択オブジェクトの属性変更(プロパティパネルから)

    /// スタイル・レイヤの一括変更。changeでコピーを書き換える。変更が無ければfalse
    @discardableResult
    private func updateSelection(name: String, change: (inout Entity) -> Void) -> Bool {
        guard !selectedEntities.isEmpty else { return false }
        let before = selectedEntities
        var after = before
        for i in after.indices { change(&after[i]) }
        guard after != before else { return false }
        commandStack.run(UpdateEntitiesCommand(name: name, before: before, after: after))
        selectionDidChange()
        return true
    }

    func applyColorIndex(_ index: Int?) {
        updateSelection(name: "色変更") { $0.style.colorIndex = index }
    }

    func applyLineType(_ type: Int?) {
        updateSelection(name: "線種変更") { $0.style.lineType = type }
    }

    func applyLineWeight(_ weight: Double?) {
        updateSelection(name: "太さ変更") { $0.style.lineWeight = weight }
    }

    // MARK: - レイヤ間の移動・複写(M4.1)

    /// 選択をレイヤへ移動(同id・属性維持でレイヤだけ変更。Undo可)
    func moveSelectionToLayer(_ address: LayerAddress) {
        let count = selectedEntities.count  // 移動先が非表示/ロックだと選択が減るため先に取る
        guard count > 0 else { return }
        updateSelection(name: "レイヤへ移動") { $0.layer = address }
        onInfo?("\(count)個を \(layerDisplayName(address)) へ移動しました(⌘Zで取り消し)")
    }

    /// 選択をレイヤへ複写(同位置に複製を作り、指定レイヤへ。Undo可)
    func copySelectionToLayer(_ address: LayerAddress) {
        guard !selectedEntities.isEmpty else { return }
        let copies = selectedEntities.map { entity -> Entity in
            var copy = entity.duplicated(by: .zero)
            copy.layer = address
            return copy
        }
        commandStack.run(AddEntitiesCommand(name: "レイヤへ複写", entities: copies))
        if document.isSelectable(address) {
            // 複写先を新しい選択にする(そのまま移動などを続けられる)
            selection = Set(copies.map(\.id))
            selectionDidChange()
            onInfo?("\(copies.count)個を \(layerDisplayName(address)) へ複写しました(⌘Zで取り消し)")
        } else {
            // 非表示・ロック先への複写は選択を引き継がない(見えない選択を作らない)
            selection = []
            selectionDidChange()
            onInfo?("\(copies.count)個を \(layerDisplayName(address)) へ複写しました(非表示/ロック中のレイヤです。⌘Zで取り消し)")
        }
    }

    /// レイヤの表示名: 「0-3 空調配管」/ 名前が無ければ「0-3」
    func layerDisplayName(_ address: LayerAddress) -> String {
        let name = document.layer(at: address).name
        return name.isEmpty ? address.description : "\(address.description) \(name)"
    }

    // MARK: - 移動・複写(M4)

    func beginEditOperation(_ kind: EditOpKind) {
        guard !selection.isEmpty else { return }
        cancelGripDrag()
        // 作図ツール中なら選択ツールへ戻してから開始
        if tools.kind != .select { tools.select(.select) }
        editOp.angleConstraint = tools.angleConstraint  // パレットの角度拘束を移動・複写にも効かせる
        editOp.begin(kind, hasSelection: true)
        // 接続追随の候補(配管だけ)をひろっておく
        followerCandidates = (kind == .move && pipeFollowConnections)
            ? document.entities.filter { if case .pipe = $0.kind { return true }; return false }
            : []
        ghostTransform = nil
        ghostFollowers = []
        onEditOpChanged?(kind)
        onInfo?(editOp.hint)
        needsOverlayRedraw?()
    }

    /// 移動・複写の角度プロパティ(度)。コマンドプロパティカードから設定
    func setEditRotation(_ degrees: Double) {
        editOp.rotationDegrees = degrees
        // ゴーストを現在のカーソル位置で更新
        ghostTransform = editOp.previewTransform(cursor: editOp.lastCursor)
        onInfo?(editOp.hint)
        needsOverlayRedraw?()
    }

    /// 編集操作中のクリック(スナップ有効)
    func editClick() {
        guard editOp.isActive, let cursor = cursorScreen else { return }
        let effective = snappedScreen ?? cursor
        let world = transform.toWorld(effective)
        if let result = editOp.click(at: world) {
            commitEditTransform(result)  // 結果メッセージはコミット側が出す
            if !editOp.isActive { onEditOpChanged?(nil) }
        } else if editOp.isActive {
            onInfo?(editOp.hint)
        }
        ghostTransform = editOp.previewTransform(cursor: world)
        needsOverlayRedraw?()
    }

    /// 移動で接続が切れないよう、取り付いている配管の更新後の姿を求める(M7.3)。
    /// 対象が配管を含まないときや設定OFFのときは空
    private func connectionFollowers(delta: Vec2) -> [Entity] {
        guard pipeFollowConnections, delta.length > 1e-9 else { return [] }
        guard !followerCandidates.isEmpty else { return [] }
        return PipeConnections.followers(movingIDs: selection, delta: delta,
                                         in: followerCandidates)
    }

    /// 伸縮(グリップ編集)で変形した配管に接続している配管の追随後の姿。M7.6
    /// 変形前後の芯線を渡すので、平行移動でない伸縮でも接続が保たれる
    private func stretchFollowers(original: Entity, preview: Entity) -> [Entity] {
        guard pipeFollowConnections, !followerCandidates.isEmpty,
              case .pipe(let before, let attrs) = original.kind,
              case .pipe(let after, _) = preview.kind, before != after else { return [] }
        let change = PipeConnections.PipeChange(before: before, after: after,
                                               radius: max(attrs.outerDiameter / 2, 0))
        return PipeConnections.followers(changes: [change], movingIDs: [original.id],
                                         in: followerCandidates)
    }

    /// 配管エンティティか
    private func isPipe(_ entity: Entity) -> Bool {
        if case .pipe = entity.kind { return true }
        return false
    }

    /// 移動ゴースト中の追随プレビュー
    private func updateGhostFollowers() {
        guard case .move = editOp.kind, case .translate(let delta)? = ghostTransform else {
            ghostFollowers = []
            return
        }
        ghostFollowers = connectionFollowers(delta: delta)
    }

    private func commitEditTransform(_ result: EditTransform) {
        guard !selection.isEmpty else { return }
        switch (editOp.kind, result) {
        case (.move, .translate(let delta)):
            let followers = connectionFollowers(delta: delta)
            if followers.isEmpty {
                commandStack.run(TranslateEntitiesCommand(ids: selection, delta: delta))
                // 追随が効くはずの状況で0本なら、接続が見つからなかったことを伝える
                // (作図時に芯線へスナップできていないと接続とみなせない)
                let hadPipes = !followerCandidates.isEmpty && pipeFollowConnections
                onInfo?(hadPipes
                        ? "\(selection.count)個を移動しました — 接続している配管は見つかりませんでした(⌘Zで取り消し)"
                        : "\(selection.count)個を移動しました(⌘Zで取り消し)")
            } else {
                commandStack.run(TranslateWithFollowersCommand(ids: selection, delta: delta,
                                                               followers: followers))
                onInfo?("\(selection.count)個を移動しました — 接続している配管\(followers.count)本が伸縮して追随(⌘Zで取り消し)")
            }
        case (.copy, .translate(let delta)):
            let copies = selectedEntities.map { $0.duplicated(by: delta) }
            commandStack.run(AddEntitiesCommand(name: "複写", entities: copies))
            onInfo?("\(copies.count)個を複写しました — 続けてクリックで連続配置 / escで終了")
        case (.rotate, .rotate(let center, let angle)):
            commandStack.run(RotateEntitiesCommand(ids: selection, center: center, angle: angle))
            onInfo?(String(format: "%d個を %.1f° 回転しました(⌘Zで取り消し)", selection.count, angle * 180 / .pi))
        case (.rotateCopy, .rotate(let center, let angle)):
            let copies = selectedEntities.map {
                $0.duplicated(by: .zero).rotated(around: center, byRadians: angle)
            }
            commandStack.run(AddEntitiesCommand(name: "回転複写", entities: copies))
            onInfo?(String(format: "%d個を %.1f° 回転複写しました — 続けてクリックで連続配置 / escで終了", copies.count, angle * 180 / .pi))
        case (.move, .moveRotated(_, _, let angle)):
            commandStack.run(TransformEntitiesCommand(name: "回転移動", ids: selection) { $0.applying(result) })
            onInfo?(String(format: "%d個を %.0f° 回転しながら移動しました(⌘Zで取り消し)", selection.count, angle * 180 / .pi))
        case (.copy, .moveRotated(_, _, let angle)):
            let copies = selectedEntities.map { $0.duplicated(by: .zero).applying(result) }
            commandStack.run(AddEntitiesCommand(name: "回転複写配置", entities: copies))
            onInfo?(String(format: "%d個を %.0f° 回転しながら複写しました — 続けてクリックで連続配置 / escで終了", copies.count, angle * 180 / .pi))
        case (.mirror, .mirror):
            commandStack.run(TransformEntitiesCommand(name: "反転", ids: selection) { $0.applying(result) })
            onInfo?("\(selection.count)個を基準線で反転しました(⌘Zで取り消し)")
        case (.mirrorCopy, .mirror):
            let copies = selectedEntities.map { $0.duplicated(by: .zero).applying(result) }
            commandStack.run(AddEntitiesCommand(name: "反転複写", entities: copies))
            onInfo?("\(copies.count)個を反転複写しました — 別の基準線で連続 / escで終了")
        case (.scale, .scale(_, let factor)):
            commandStack.run(TransformEntitiesCommand(name: "拡大縮小", ids: selection) { $0.applying(result) })
            onInfo?(String(format: "%d個を %.4g倍 に拡大縮小しました(⌘Zで取り消し)", selection.count, factor))
        default:
            break
        }
    }

    func cancelEditOperation() {
        guard editOp.isActive else { return }
        editOp.cancel()
        ghostTransform = nil
        ghostFollowers = []
        followerCandidates = []
        onEditOpChanged?(nil)
        publishSelectionHint()
        needsOverlayRedraw?()
    }

    /// 角度拘束の変更(ツールバーのパレットから。作図と編集の両方に効く)
    func setAngleConstraint(_ constraint: AngleConstraint) {
        tools.angleConstraint = constraint
        editOp.angleConstraint = constraint
    }

    // MARK: - 伸縮(グリップ編集。M4.9)

    struct GripDragState {
        let grip: Grip
        let original: Entity   // ドラッグ開始時のスナップショット
        let downScreen: Vec2   // マウスダウンしたスクリーン座標(移動判定の基準)
        var current: Vec2      // グリップの現在位置(ワールド)
        var preview: Entity    // プレビュー(確定時にこれを採用)
        var moved = false      // 3px以上ドラッグしたか
        var sticky = false     // ボタンを離した後の「クリックで確定」モード
    }

    private(set) var gripDrag: GripDragState?

    /// 配管の頂点を掴んだときに継手の角度を保つ「伸縮」で動かす(M7.1)。
    /// 切ると従来どおり頂点だけが自由に動く(角度も変わる)
    var pipePreserveAngles = true {
        didSet { onPipeStretchChanged?(pipePreserveAngles) }
    }
    var onPipeStretchChanged: ((Bool) -> Void)?

    /// 配管を移動したとき、取り付いている配管の端を管軸方向へ伸縮させて接続を保つ(M7.3)
    var pipeFollowConnections = true

    /// 移動ゴースト中・伸縮中に追随して伸縮する配管(プレビュー表示用)
    private(set) var ghostFollowers: [Entity] = []

    /// 追随計算の対象になりうる配管(移動開始時にひろっておく。
    /// ドラッグ中は図面が変わらないので毎回の全走査を避ける)
    private var followerCandidates: [Entity] = []
    private(set) var gripNumericBuffer = ""

    /// いま表示すべきグリップ(選択ツール・非編集中・少数選択のときだけ)
    func currentGrips() -> [Grip] {
        guard tools.kind == .select, !editOp.isActive, pendingBlockifyName == nil,
              gripDrag == nil, !selectedEntities.isEmpty,
              selectedEntities.count <= GripEngine.selectionLimit else { return [] }
        return selectedEntities.flatMap { GripEngine.grips(for: $0) }
    }

    /// グリップのヒット判定(スクリーン座標。半径8px)
    func gripHit(atScreen p: Vec2) -> Grip? {
        var best: Grip?
        var bestDist = 8.0
        for g in currentGrips() {
            let d = transform.toScreen(g.point).distance(to: p)
            if d < bestDist {
                bestDist = d
                best = g
            }
        }
        return best
    }

    func beginGripDrag(_ grip: Grip, atScreen p: Vec2) {
        guard let entity = document.entity(id: grip.entityID) else { return }
        gripDrag = GripDragState(grip: grip, original: entity, downScreen: p,
                                 current: grip.point, preview: entity)
        gripNumericBuffer = ""
        ghostFollowers = []
        // 接続追随の候補(配管だけ)をひろっておく(伸縮中は図面が変わらない)M7.6
        followerCandidates = (pipeFollowConnections && isPipe(entity))
            ? document.entities.filter { if case .pipe = $0.kind { return true }; return false }
            : []
        // 自分自身の旧位置に吸着して動かせなくなるのを防ぐため、索引から除外
        snapEngine.rebuild(from: document, excluding: [grip.entityID])
        onInfo?(gripHint)
        needsOverlayRedraw?()
    }

    /// ドラッグ中の移動(CanvasViewから)
    func gripDragMoved(toScreen p: Vec2) {
        if var state = gripDrag, !state.moved,
           state.downScreen.distance(to: p) > 3 {
            state.moved = true
            gripDrag = state
        }
        // スナップ計算→updateGripPreview→再描画はmouseMoved経由で行う
        mouseMoved(toScreen: p)
    }

    /// mouseMoved内から呼ぶ: グリップ編集中のプレビュー更新
    private func updateGripPreview() {
        guard var state = gripDrag, let cursor = cursorScreen else { return }
        let effective = snappedScreen ?? cursor
        let world = gripConstrained(transform.toWorld(effective), state: state)
        state.current = world
        state.preview = GripEngine.apply(state.grip.kind, to: state.original, at: world,
                                         preserveAngles: pipePreserveAngles)
        gripDrag = state
        ghostFollowers = stretchFollowers(original: state.original, preview: state.preview)
    }

    /// 線の端点グリップに角度拘束(パレット連動)を効かせる(固定端からの方向を丸める)
    private func gripConstrained(_ p: Vec2, state: GripDragState) -> Vec2 {
        guard GripEngine.supportsAngleConstraint(state.grip.kind),
              let step = tools.angleConstraint.step,
              let fixed = GripEngine.fixedPoint(for: state.grip.kind, of: state.original)
        else { return p }
        let d = p - fixed
        let len = d.length
        guard len > 1e-9 else { return p }
        let snapped = (atan2(d.y, d.x) / step).rounded() * step
        return Vec2(fixed.x + cos(snapped) * len, fixed.y + sin(snapped) * len)
    }

    /// ボタン解放(CanvasViewから)。動いていれば確定、その場ならクリック確定モードへ
    func gripDragReleased() {
        guard var state = gripDrag else { return }
        if state.moved {
            commitGripDrag()
        } else {
            state.sticky = true
            gripDrag = state
            onInfo?(gripHint)
        }
    }

    /// クリック確定モード中のクリック(CanvasViewから)
    func gripStickyClick() {
        commitGripDrag()
    }

    func commitGripDrag() {
        guard let state = gripDrag else { return }
        gripDrag = nil
        gripNumericBuffer = ""
        if state.preview != state.original {
            let name = state.grip.kind == .position ? "移動" : "伸縮"
            // 接続している配管も一緒に更新する(1回のUndoで両方戻る)M7.6
            let followers = stretchFollowers(original: state.original, preview: state.preview)
            let followerBefore = followers.compactMap { document.entity(id: $0.id) }
            ghostFollowers = []
            commandStack.run(UpdateEntitiesCommand(name: name,
                                                   before: [state.original] + followerBefore,
                                                   after: [state.preview] + followers))
            selectionDidChange()  // コミットのonChangeでスナップ索引も全体再構築される
            onInfo?(followers.isEmpty
                    ? "\(name)しました(⌘Zで取り消し)"
                    : "\(name)しました — 接続している配管\(followers.count)本が追随(⌘Zで取り消し)")
        } else {
            snapEngine.rebuild(from: document)  // 除外を戻す
            publishSelectionHint()
        }
        needsOverlayRedraw?()
    }

    func cancelGripDrag() {
        guard gripDrag != nil else { return }
        gripDrag = nil
        gripNumericBuffer = ""
        ghostFollowers = []
        followerCandidates = []
        snapEngine.rebuild(from: document)  // 除外を戻す
        publishSelectionHint()
        needsOverlayRedraw?()
    }

    /// グリップ編集中の数値入力(線=固定端からの長さ / 円=半径)
    private func gripKey(_ character: Character) -> Bool {
        guard var state = gripDrag else { return false }
        // 数値入力は固定点のあるグリップ(線=長さ・円=半径)だけ受け付ける
        let numericCapable = GripEngine.fixedPoint(for: state.grip.kind, of: state.original) != nil
        if character.isNumber || character == "." {
            guard numericCapable else { return false }
            gripNumericBuffer.append(character)
            needsOverlayRedraw?()
            return true
        }
        if character == "\r" || character == "\n" {
            defer {
                gripNumericBuffer = ""
                needsOverlayRedraw?()
            }
            guard let value = Double(gripNumericBuffer), value > 1e-6,
                  let fixed = GripEngine.fixedPoint(for: state.grip.kind, of: state.original)
            else { return true }
            // 現在のドラッグ方向(未ドラッグなら元の方向)に沿って長さを適用
            var dir = state.current - fixed
            if dir.length < 1e-9 { dir = state.grip.point - fixed }
            let len = dir.length
            guard len > 1e-9 else { return true }
            let target = Vec2(fixed.x + dir.x / len * value, fixed.y + dir.y / len * value)
            state.current = target
            state.preview = GripEngine.apply(state.grip.kind, to: state.original, at: target,
                                             preserveAngles: pipePreserveAngles)
            gripDrag = state
            commitGripDrag()
            return true
        }
        if character == "\u{7F}" || character == "\u{08}" {  // delete/backspace
            if !gripNumericBuffer.isEmpty {
                gripNumericBuffer.removeLast()
                needsOverlayRedraw?()
                return true
            }
        }
        return false
    }

    private var gripHint: String {
        guard let state = gripDrag else { return "" }
        let commit = state.sticky ? "クリックで確定" : "離すと確定(その場で離すとクリック確定モード)"
        switch state.grip.kind {
        case .lineStart, .lineEnd:
            return "伸縮: 端点を動かす — スナップ・角度拘束有効 / 数値⏎=固定端からの長さ / \(commit) / esc中止"
        case .circleRadius:
            return "伸縮: 半径を変更 — 数値⏎=半径 / \(commit) / esc中止"
        case .arcStart, .arcEnd:
            return "伸縮: 円弧の端を動かす(半径は維持・角度が変化)/ \(commit) / esc中止"
        case .position:
            return "移動: 位置を動かす — スナップ有効 / \(commit) / esc中止"
        case .dimStart, .dimEnd:
            return "寸法: 測定点を動かす(寸法値も追随)— スナップ有効 / \(commit) / esc中止"
        case .dimLine:
            return "寸法: 寸法線の位置(引出し量)を動かす / \(commit) / esc中止"
        case .dimExtension:
            return "寸法: 補助線の長さを調整(2本同時)— 測定点近くまで引くと「測定点まで」/ \(commit) / esc中止"
        case .leaderTip:
            return "引出線: 指示点(矢印の先端)を動かす — スナップ有効 / \(commit) / esc中止"
        case .leaderElbow:
            return "引出線: 文字位置を動かす(引出線が追随)/ \(commit) / esc中止"
        case .pipeSegment:
            return "配管の区間伸縮: この区間だけを平行に動かします — 隣の区間が伸び縮みして吸収し、"
                + "その先の配管は動きません / \(commit) / esc中止"
        case .pipeVertex:
            return pipePreserveAngles
                ? "配管の伸縮: 継手の角度を保ったまま脚が伸び縮みします(歯車メニューで切替可)/ \(commit) / esc中止"
                : "配管: 折れ点を自由に動かす(継手の角度も変わります)/ \(commit) / esc中止"
        }
    }

    // MARK: - 右クリックメニュー(M4)

    /// 現在の状態に応じたコンテキストメニュー。nilならメニューを出さない
    /// (作図ツール中・編集操作中は右クリック=キャンセルの操作感を維持)
    func contextMenu() -> NSMenu? {
        guard tools.kind == .select, !editOp.isActive, gripDrag == nil else { return nil }

        let menu = NSMenu()
        if !selection.isEmpty {
            // 最上段: 複写・移動(一番使うため)
            menu.addItem(menuItem("複写", #selector(menuCopy)))
            menu.addItem(menuItem("移動", #selector(menuMove)))
            menu.addItem(menuItem("回転", #selector(menuRotate)))
            menu.addItem(menuItem("回転複写", #selector(menuRotateCopy)))
            menu.addItem(menuItem("反転", #selector(menuMirror)))
            menu.addItem(menuItem("反転複写", #selector(menuMirrorCopy)))
            menu.addItem(menuItem("拡大縮小", #selector(menuScale)))
            if selectedEntities.contains(where: isPipe) {
                menu.addItem(menuItem("継手を反転(分岐の向き)", #selector(menuFlipFittings)))
            }
            menu.addItem(.separator())
            // レイヤ間の移動・複写(グループ→レイヤの2段サブメニュー)
            menu.addItem(layerSubmenu(title: "レイヤへ移動", action: #selector(menuMoveToLayer(_:))))
            menu.addItem(layerSubmenu(title: "レイヤへ複写", action: #selector(menuCopyToLayer(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("削除", #selector(menuDelete)))
            menu.addItem(.separator())
            // ブロック
            menu.addItem(menuItem("ブロック化…", #selector(menuBlockify)))
            if selectedEntities.contains(where: { if case .blockRef = $0.kind { return true }; return false }) {
                menu.addItem(menuItem("ブロック解除", #selector(menuExplodeBlocks)))
            }
            menu.addItem(.separator())
            menu.addItem(menuItem("選択解除", #selector(menuDeselect)))
        } else {
            menu.addItem(menuItem("すべて選択", #selector(menuSelectAll)))
            menu.addItem(menuItem("全体表示", #selector(menuFit)))
            menu.addItem(menuItem(gridVisible ? "グリッドを隠す" : "グリッドを表示", #selector(menuToggleGrid)))
        }
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// グループ→レイヤの2段サブメニュー。tagにグループ×16+レイヤを入れて選択先を渡す
    private func layerSubmenu(title: String, action: Selector) -> NSMenuItem {
        // 共通レイヤはループの外で1回だけ計算する(大量選択で256回のO(n)走査になるのを防ぐ)
        var commonLayer: LayerAddress?
        if let first = selectedEntities.first?.layer,
           selectedEntities.allSatisfy({ $0.layer == first }) {
            commonLayer = first
        }

        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let groupsMenu = NSMenu()
        for g in 0..<16 {
            let group = document.group(g)
            let groupTitle = group.name.isEmpty
                ? String(format: "グループ%X (%@)", g, group.scaleLabel)
                : String(format: "%X %@ (%@)", g, group.name, group.scaleLabel)
            let groupItem = NSMenuItem(title: groupTitle, action: nil, keyEquivalent: "")
            let layersMenu = NSMenu()
            for l in 0..<16 {
                let address = LayerAddress(g, l)
                let item = NSMenuItem(title: layerDisplayName(address), action: action, keyEquivalent: "")
                item.target = self
                item.tag = g * 16 + l
                // 現在の選択が居るレイヤに印
                if commonLayer == address {
                    item.state = .on
                }
                layersMenu.addItem(item)
            }
            groupItem.submenu = layersMenu
            groupsMenu.addItem(groupItem)
        }
        root.submenu = groupsMenu
        return root
    }

    @objc private func menuCopy() { beginEditOperation(.copy) }
    @objc private func menuMove() { beginEditOperation(.move) }
    @objc private func menuRotate() { beginEditOperation(.rotate) }
    @objc private func menuRotateCopy() { beginEditOperation(.rotateCopy) }
    @objc private func menuMirror() { beginEditOperation(.mirror) }
    @objc private func menuMirrorCopy() { beginEditOperation(.mirrorCopy) }
    @objc private func menuScale() { beginEditOperation(.scale) }
    @objc private func menuFlipFittings() { flipSelectedFittings() }
    @objc private func menuBlockify() { startBlockify() }
    @objc private func menuExplodeBlocks() { explodeSelectedBlocks() }
    @objc private func menuDelete() { deleteSelection() }
    @objc private func menuDeselect() { clearSelection() }
    @objc private func menuSelectAll() { selectAll() }
    @objc private func menuFit() {
        if let size = viewSizeProvider?() { fit(viewSize: size) }
    }
    @objc private func menuToggleGrid() { toggleGrid() }
    @objc private func menuMoveToLayer(_ sender: NSMenuItem) {
        moveSelectionToLayer(LayerAddress(sender.tag / 16, sender.tag % 16))
    }
    @objc private func menuCopyToLayer(_ sender: NSMenuItem) {
        copySelectionToLayer(LayerAddress(sender.tag / 16, sender.tag % 16))
    }

    // MARK: - ブロック化・ブロック解除(M4.8)

    /// ブロック化: 名前入力→基準点指示待ちに入る
    private(set) var pendingBlockifyName: String?

    func startBlockify() {
        guard !selection.isEmpty else { return }
        cancelEditOperation()
        let alert = NSAlert()
        alert.messageText = "ブロック化"
        alert.informativeText = "選択中の\(selection.count)個をブロックにします。名前を入力してください。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "例: FCU-1 / 大便器 / 仕切弁50A"
        alert.accessoryView = field
        alert.addButton(withTitle: "次へ(基準点を指示)")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        pendingBlockifyName = name.isEmpty ? "ブロック" : name
        onInfo?("ブロック化: 基準点(挿入点・接続点)をクリック — スナップ有効 / escで中止")
    }

    /// 基準点クリック(CanvasViewから。スナップが効いていればスナップ点)
    func blockifyBasePointClick() {
        guard pendingBlockifyName != nil, let cursor = cursorScreen else { return }
        let effective = snappedScreen ?? cursor
        performBlockify(base: transform.toWorld(effective))
    }

    private func performBlockify(base: Vec2) {
        guard let name = pendingBlockifyName, !selectedEntities.isEmpty else {
            pendingBlockifyName = nil
            return
        }
        pendingBlockifyName = nil

        // 入れ子ブロックは展開して取り込む(定義の中にblockRefを入れない)
        let defs = document.blockDefinitionsByID
        var members: [Entity] = []
        for e in selectedEntities {
            if case .blockRef(let defID, let insert, let rot, let scale, let mir, _) = e.kind,
               let d = defs[defID] {
                // 配置側のスタイル上書きを焼き込んでから取り込む(見た目を維持)
                members.append(contentsOf: d.instantiate(insert: insert, rotation: rot,
                                                         scale: scale, mirrored: mir,
                                                         layer: e.layer,
                                                         overrideStyle: e.style,
                                                         freshIDs: true))
            } else {
                members.append(e)
            }
        }

        // 基準点を原点とするローカル座標へ(定義エンティティは新idにする)
        let localEntities = members.map { member -> Entity in
            let moved = member.translated(by: Vec2(-base.x, -base.y))
            return Entity(layer: moved.layer, style: moved.style, kind: moved.kind)
        }
        let definition = BlockDefinition(name: name, entities: localEntities)

        var worldBounds = BBox.empty
        for m in members { worldBounds.union(m.bounds) }

        let summary = selectionSummary()
        let refLayer = summary?.commonLayer ?? document.current
        let reference = Entity(layer: refLayer,
                               kind: .blockRef(definitionID: definition.id, insert: base,
                                               rotation: 0, scale: 1, mirrored: false,
                                               cachedBounds: worldBounds))

        let memberIDs = selection
        selection = []
        commandStack.run(BlockifyCommand(definition: definition,
                                         memberIDs: memberIDs,
                                         reference: reference))
        selection = [reference.id]
        selectionDidChange()
        onInfo?("ブロック「\(name)」を作成しました(以後は1クリックで塊として選択できます。⌘Zで取り消し)")
    }

    func cancelBlockify() {
        guard pendingBlockifyName != nil else { return }
        pendingBlockifyName = nil
        publishSelectionHint()
    }

    /// 選択中のブロック配置を基本図形へ分解する(定義は残す)
    func explodeSelectedBlocks() {
        let defs = document.blockDefinitionsByID
        var commands: [Command] = []
        var newSelection = Set<EntityID>()
        for e in selectedEntities {
            guard case .blockRef(let defID, let insert, let rot, let scale, let mir, _) = e.kind,
                  let d = defs[defID] else { continue }
            // 配置側のスタイル上書きは分解後も見た目が変わらないよう焼き込む
            let expanded = d.instantiate(insert: insert, rotation: rot, scale: scale,
                                         mirrored: mir, layer: e.layer,
                                         overrideStyle: e.style, freshIDs: true)
            commands.append(ExplodeBlockCommand(reference: e, expanded: expanded))
            newSelection.formUnion(expanded.map(\.id))
        }
        guard !commands.isEmpty else { return }
        selection = []
        commandStack.run(CommandGroup(name: "ブロック解除", commands: commands))
        selection = newSelection
        selectionDidChange()
        onInfo?("\(commands.count)個のブロックを分解しました(⌘Zで取り消し)")
    }

    // MARK: - レイヤ操作(レイヤパネルから)

    func setLayerVisible(_ address: LayerAddress, _ visible: Bool) {
        document.updateLayer(at: address) { $0.isVisible = visible }
    }

    func setLayerLocked(_ address: LayerAddress, _ locked: Bool) {
        document.updateLayer(at: address) { $0.isEditable = !locked }
    }

    func setGroupVisible(_ index: Int, _ visible: Bool) {
        document.updateGroup(index) { $0.isVisible = visible }
    }

    func setGroupLocked(_ index: Int, _ locked: Bool) {
        document.updateGroup(index) { $0.isEditable = !locked }
    }

    /// 書込レイヤの変更(非表示・ロックには書き込めない)。成功でtrue
    @discardableResult
    func setCurrentLayer(_ address: LayerAddress) -> Bool {
        let ok = document.setCurrent(address)
        if !ok {
            onInfo?("\(layerDisplayName(address)) は非表示またはロック中のため書込先にできません")
        }
        return ok
    }

    private func publishLayers() {
        // レイヤ別の要素数(空レイヤを薄く表示するため)
        var counts = [Int](repeating: 0, count: 256)
        for e in document.entities {
            counts[e.layer.group * 16 + e.layer.layer] += 1
        }
        onLayersChanged?(document.groups, document.current, counts)
        // 用紙・縮尺表示も同期(書込グループの変更で縮尺表示が変わるため)
        onDrawingSetupChanged?(document.paperSize, document.currentScale)
    }

    // MARK: - 用紙・縮尺・新規作成(M4.10)

    /// 用紙サイズの変更(用紙枠の表示が変わる。図形はそのまま)
    func setPaperSize(_ size: PaperSize) {
        document.setPaperSize(size)  // onChange経由でキャッシュ破棄・フッター同期
        onInfo?("用紙を \(size.label)(横)にしました — 枠=用紙の作図範囲")
    }

    /// 書込グループの縮尺変更(実寸固定: 図形の実寸は変わらず、用紙が覆う範囲が変わる)
    func setScaleDenominator(_ denominator: Double) {
        guard denominator > 0 else { return }
        document.setCurrentScale(denominator)
        onInfo?("グループ\(String(format: "%X", document.current.group))の縮尺を \(document.currentScaleLabel) にしました(実寸固定 — 用紙枠の範囲が変わります)")
    }

    /// 自由入力の縮尺(1/○の分母)
    func promptCustomScale() {
        let alert = NSAlert()
        alert.messageText = "縮尺(1/○の分母)"
        alert.informativeText = "例: 30 → 1/30、150 → 1/150(書込グループに適用・実寸固定)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.stringValue = String(Int(document.currentScale))
        alert.accessoryView = field
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
              value >= 0.1, value <= 100000 else { return }
        setScaleDenominator(value)
    }

    /// 新規作成(⌘N): 用紙と縮尺を決めてから白紙図面に置き換える
    /// (作図範囲が最初から明確になるように)
    func newDrawingPanel() {
        let alert = NSAlert()
        alert.messageText = "新規図面"
        alert.informativeText = "用紙と縮尺を選んでください。現在の図面は置き換わります(取り消しできません)。"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let paperLabel = NSTextField(labelWithString: "用紙:")
        paperLabel.frame = NSRect(x: 0, y: 32, width: 50, height: 20)
        let paperPopup = NSPopUpButton(frame: NSRect(x: 54, y: 28, width: 110, height: 26))
        for size in PaperSize.allCases {
            paperPopup.addItem(withTitle: "\(size.label)(横)")
        }
        paperPopup.selectItem(at: PaperSize.allCases.firstIndex(of: .a1) ?? 0)

        let scaleLabel = NSTextField(labelWithString: "縮尺:")
        scaleLabel.frame = NSRect(x: 0, y: 4, width: 50, height: 20)
        let scalePopup = NSPopUpButton(frame: NSRect(x: 54, y: 0, width: 110, height: 26))
        let presets: [Double] = [1, 2, 5, 10, 20, 30, 50, 100, 200, 500]
        for d in presets {
            scalePopup.addItem(withTitle: "1/\(Int(d))")
        }
        scalePopup.selectItem(at: presets.firstIndex(of: 50) ?? 0)

        container.addSubview(paperLabel)
        container.addSubview(paperPopup)
        container.addSubview(scaleLabel)
        container.addSubview(scalePopup)
        alert.accessoryView = container
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paper = PaperSize.allCases[max(0, paperPopup.indexOfSelectedItem)]
        let scale = presets[max(0, scalePopup.indexOfSelectedItem)]
        newDrawing(paper: paper, scaleDenominator: scale)
    }

    private func newDrawing(paper: PaperSize, scaleDenominator: Double) {
        // 進行中の操作をすべて中止してから置き換える
        cancelGripDrag()
        cancelBlockify()
        cancelEditOperation()
        tools.cancel()
        selection = []
        document.resetForNewDrawing(paperSize: paper, scaleDenominator: scaleDenominator)
        commandStack.clear()  // 前の図面へのUndoは残さない
        selectionDidChange()
        if let size = viewSizeProvider?() {
            fit(viewSize: size)
        }
        onInfo?("新規図面: \(paper.label)(横)・1/\(Int(scaleDenominator)) — 枠が用紙の作図範囲です")
    }

    /// グリッド間隔の変更(50刻みプリセット/自由入力)。選択したら非表示中でも表示に戻す
    func setGridSpacing(_ mm: Double) {
        gridSpacing = max(1, mm)
        snapEngine.gridSpacing = gridSpacing
        if !gridVisible {
            gridVisible = true
            snapEngine.gridEnabled = true
            onGridChanged?(gridVisible)
        }
        // グリッドはキャッシュに焼き込まれているため破棄が必要
        onDocumentChanged?()
        needsContentRedraw?()
        onGridSpacingChanged?(gridSpacing)
        onInfo?("グリッド間隔を \(Int(gridSpacing))mm にしました(グリッドスナップも連動)")
    }

    /// 自由入力のグリッド間隔(910などのモジュール寸法用)
    func promptGridSpacing() {
        let alert = NSAlert()
        alert.messageText = "グリッド間隔(実寸mm)"
        alert.informativeText = "例: 910(モジュール)、455、303 など"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.stringValue = String(Int(gridSpacing))
        alert.accessoryView = field
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
              value >= 1, value <= 100000 else { return }
        setGridSpacing(value)
    }

    /// 補助線(補助線種・補助線色)の表示切替。
    /// 非表示中は描画・スナップ・選択のすべてから外れる(JWWビューワーと同じ考え方)
    func toggleAuxiliary() {
        document.setShowAuxiliary(!document.showAuxiliary)  // onChange経由でキャッシュ破棄・スナップ再構築
        onAuxiliaryChanged?(document.showAuxiliary)
        onInfo?(document.showAuxiliary
                ? "補助線を表示しました"
                : "補助線を非表示にしました(スナップ・選択からも外れます)")
    }

    /// 初期表示用(SwiftUI側のonAppearから呼ぶ)
    func publishInitialState() {
        publishLayers()
        onSelectionChanged?(selectionSummary())
        onGridChanged?(gridVisible)
        onGridSpacingChanged?(gridSpacing)
        onAuxiliaryChanged?(document.showAuxiliary)
        onDrawingSetupChanged?(document.paperSize, document.currentScale)
    }

    // MARK: - 作図ツール(M3)

    func selectTool(_ kind: ToolKind) {
        cancelGripDrag()
        cancelEditOperation()
        tools.select(kind)
    }

    /// クリック(作図ツール用)。スナップが効いていればスナップ点を使う
    func toolClick(shiftDown: Bool) {
        guard let cursor = cursorScreen else { return }
        let effective = snappedScreen ?? cursor
        // ハッチングの「始点クリックで閉じる」判定にピックボックス幅を渡す
        tools.closeTolerance = hitToleranceMm
        let world = transform.toWorld(effective)
        // 配管の描き始めが既存の接続口なら、その口径・管種・高さを引き継ぐ(M7)。
        // tools.click より先に反映する — 属性は確定時にpipeStyleProviderが読むため
        if tools.kind == .pipe, tools.pipePoints.isEmpty,
           let port = snapEngine.port(at: world, radius: hitToleranceMm) {
            onPipePortPicked?(port)
            let label = port.name.isEmpty ? port.role.rawValue : port.name
            let size = port.sizeLabel.isEmpty ? "" : " \(port.sizeLabel)"
            onInfo?("\(label)\(size)の接続口から作図します")
        }
        tools.click(at: world, shiftDown: shiftDown)
        refreshPreview(shiftDown: shiftDown)
    }

    func toolCancel() {
        if gripDrag != nil {
            cancelGripDrag()
            return
        }
        if pendingBlockifyName != nil {
            cancelBlockify()
            return
        }
        if editOp.isActive {
            cancelEditOperation()
            return
        }
        if tools.kind == .select, !selection.isEmpty {
            clearSelection()
            return
        }
        tools.cancel()
        previewShape = .none
        needsOverlayRedraw?()
    }

    func toolKey(_ character: Character) -> Bool {
        // 伸縮(グリップ編集)中の数値入力を最優先
        if gripDrag != nil {
            return gripKey(character)
        }
        // 編集操作(移動・複写)の数値入力を優先
        if editOp.isActive {
            var committed = false
            let handled = editOp.keyInput(character) { [weak self] result in
                committed = true
                self?.commitEditTransform(result)
                self?.ghostTransform = nil
            }
            if committed, !editOp.isActive { onEditOpChanged?(nil) }
            if handled {
                // コミット時は結果メッセージ(commitEditDelta側)を残す
                if !committed, editOp.isActive {
                    onInfo?(editOp.hint)
                }
                needsOverlayRedraw?()
            }
            return handled
        }
        let handled = tools.keyInput(character)
        if handled {
            // 数値バッジ表示と、⏎確定後のプレビュー更新
            refreshPreview(shiftDown: false)
        }
        return handled
    }

    private func refreshPreview(shiftDown: Bool) {
        guard let cursor = cursorScreen else {
            previewShape = .none
            return
        }
        let effective = snappedScreen ?? cursor
        previewShape = tools.preview(cursor: transform.toWorld(effective), shiftDown: shiftDown)
        needsOverlayRedraw?()
    }

    func undo() {
        commandStack.undo()
    }

    func redo() {
        commandStack.redo()
    }

    // MARK: - 図面読込(JWW: M2〜 / DXF: M5.0)

    func openJwwPanel() {
        let panel = NSOpenPanel()
        panel.title = "図面ファイルを開く(JWW / DXF)"
        var types: [UTType] = []
        if let jwwType = UTType(filenameExtension: "jww") { types.append(jwwType) }
        if let dxfType = UTType(filenameExtension: "dxf") { types.append(dxfType) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "dxf" {
            loadDxf(url: url)
        } else {
            loadJww(url: url)
        }
    }

    /// DXF読込(R12〜2007のモデル空間2D。開く=編集可能に展開)
    func loadDxf(url: URL) {
        onInfo?("DXF読込中… \(url.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: url)
                let start = Date()
                let drawing = try DxfParser(data: data).parse()
                let parseMs = Int(Date().timeIntervalSince(start) * 1000)

                DispatchQueue.main.async {
                    self.selection = []
                    self.cancelGripDrag()
                    self.cancelEditOperation()
                    let stats = DxfReader.importDrawing(drawing, into: self.document)
                    self.commandStack.clear()   // 前の図面へのUndoは残さない
                    self.selectionDidChange()
                    if let size = self.viewSizeProvider?() {
                        self.fit(viewSize: size)
                    }
                    var parts = ["\(stats.entityCount)要素"]
                    if stats.blockRefCount > 0 {
                        parts.append("ブロック配置\(stats.blockRefCount)(定義\(stats.blockDefinitionCount))")
                    }
                    if stats.dimensionCount > 0 { parts.append("寸法\(stats.dimensionCount)") }
                    if stats.paperDetected {
                        parts.append("\(self.document.paperSize.label)・1/\(Int(stats.scaleDenominator))を復元")
                    }
                    let skipped = stats.skippedTypes.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " ")
                    let skippedNote = skipped.isEmpty ? "" : " / 未対応スキップ: \(skipped)"
                    self.onInfo?("\(url.lastPathComponent) — \(parts.joined(separator: " ")) / 解析\(parseMs)ms\(skippedNote)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.onInfo?("DXF読込エラー: \(error.localizedDescription)")
                }
            }
        }
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
                    // 「開く」= 図面全体の置き換え(レイヤ構造ごとJWWの16×16を展開)
                    self.selection = []
                    self.cancelGripDrag()
                    self.cancelEditOperation()
                    let stats = JwwReader.importDrawingWithStats(drawing, into: self.document)
                    self.commandStack.clear()   // 前の図面へのUndoは残さない
                    self.selectionDidChange()
                    if let size = self.viewSizeProvider?() {
                        self.fit(viewSize: size)
                    }
                    var note = "そのまま編集できます"
                    if stats.visibilityRelaxed || stats.locksRelaxed {
                        note = "レイヤ状態が読めなかったため全レイヤを編集可能で展開しました"
                    }
                    self.onInfo?("\(url.lastPathComponent) — 線\(drawing.lines.count) 弧\(drawing.arcs.count) 字\(drawing.texts.count) / 解析\(parseMs)ms / 計\(stats.entityCount)要素(\(note))")
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
        // 空図面は用紙枠に合わせる(新規作成直後に作図範囲が見えるように)
        if box.isEmpty { box = document.paperFrame }
        transform.fit(box.expanded(by: 500), in: Vec2(Double(viewSize.width), Double(viewSize.height)))
        needsContentRedraw?()
        needsOverlayRedraw?()
        publishStatus()
    }

    func mouseMoved(toScreen p: Vec2, shiftDown: Bool = false) {
        // 右端接近の検知(Dock風パネルのトリガ)
        if let size = viewSizeProvider?(), size.width > 0 {
            let near = Double(size.width) - p.x < 16
            if near != lastEdgeProximity {
                lastEdgeProximity = near
                onEdgeProximity?(near)
            }
        }
        guard !uiHovering else { return }
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
        // 作図中プレビューの更新
        if tools.isDrawingToolActive {
            let effective = snappedScreen ?? p
            previewShape = tools.preview(cursor: transform.toWorld(effective), shiftDown: shiftDown)
        } else {
            previewShape = .none
        }
        // 移動・複写・回転のゴースト更新(スナップ点優先)
        if editOp.isActive {
            let effective = snappedScreen ?? p
            ghostTransform = editOp.previewTransform(cursor: transform.toWorld(effective))
            updateGhostFollowers()
        } else {
            ghostTransform = nil
            ghostFollowers = []
        }
        // 伸縮(グリップ編集)中のプレビュー更新
        if gripDrag != nil {
            updateGripPreview()
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
        // テーマは描画キャッシュに焼き込まれているため、キャッシュ破棄が必須
        onDocumentChanged?()
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
        let snapText = snappedKind?.label ?? "—"
        onStatusUpdate?(coords, zoom, snapText)
    }
}

// MARK: - DrawingToolDelegate

extension CanvasController: DrawingToolDelegate {

    func toolDidProduce(_ entity: Entity) {
        commandStack.run(AddEntityCommand(entity: entity))
    }

    func toolDidProduceGroup(_ entities: [Entity], name: String) {
        commandStack.run(AddEntitiesCommand(name: name, entities: entities))
    }

    func toolRequestsText(at point: Vec2, completion: @escaping (String?) -> Void) {
        // クリック位置にインライン入力欄を出す(M5.3。従来のダイアログは廃止)
        toolRequestsText(at: point, fontHeight: tools.textHeight, completion: completion)
    }

    func toolRequestsText(at point: Vec2, fontHeight: Double,
                          completion: @escaping (String?) -> Void) {
        let screen = transform.toScreen(point)
        let fontPx = max(fontHeight * transform.scale, 9)
        if let request = onTextInputRequested {
            request(screen, "", fontPx, completion)
        } else {
            completion(nil)
        }
    }

    func toolStatusChanged(_ hint: String) {
        onInfo?(hint)
    }

    func toolKindChanged(_ kind: ToolKind) {
        previewShape = .none
        needsOverlayRedraw?()
        onToolChanged?(kind)
    }

    func toolHatchPattern() -> HatchPattern {
        hatchPatternProvider?()
            ?? HatchPattern(kind: .horizontal,
                            spacingA: 2 * document.currentScale,
                            spacingB: 1 * document.currentScale,
                            angle: .pi / 4)
    }

    func toolDimensionStyle() -> DimensionToolStyle {
        dimensionStyleProvider?()
            ?? DimensionToolStyle(axis: .horizontal,
                                  attrs: DimAttributes(terminator: .dot,
                                                       textHeight: 2.5 * document.currentScale,
                                                       extensionLength: nil),
                                  colorIndex: nil)
    }

    func toolLeaderStyle() -> LeaderToolStyle {
        leaderStyleProvider?()
            ?? LeaderToolStyle(attrs: LeaderAttributes(textHeight: 3.5 * document.currentScale),
                               colorIndex: nil)
    }

    func toolPipeStyle() -> PipeToolStyle {
        pipeStyleProvider?()
            ?? PipeToolStyle(attrs: PipeAttributes(textHeight: 2.5 * document.currentScale,
                                                   datum: document.levelDatum),
                             style: Style(colorIndex: 2, lineType: 0), z: 0)
    }

    /// 描き始めの点に既存の配管があれば、その区間の管軸方向を返す(枝管の角度合わせ用)M7.7
    func toolReferenceDirection(at point: Vec2) -> Double? {
        let tol = max(hitToleranceMm, PipeNetwork.joinTolerance)
        var best: (Double, Double)?
        for e in document.entities {
            guard case .pipe(let pts, _) = e.kind, pts.count >= 2,
                  document.isEntityVisible(e) else { continue }
            for i in 0..<(pts.count - 1) {
                let a = pts[i].xy, b = pts[i + 1].xy
                let seg = b - a
                guard seg.length > PipeGeometry.planEpsilon else { continue }
                let foot = HitGeometry.closestPointOnSegment(point, a, b)
                let d = foot.distance(to: point)
                guard d <= tol else { continue }
                if best == nil || d < best!.1 { best = (atan2(seg.y, seg.x), d) }
            }
        }
        return best?.0
    }

    /// 高さの基準面(1FL/2FL/GL…)を設定(図面設定)
    func setLevelDatum(_ datum: String) {
        document.setLevelDatum(datum)
        onInfo?("高さの基準面を\(document.levelDatum)にしました(新しい配管の傍記に使われます)")
    }
}

// MARK: - 配管プロパティ・材料集計(M6.0)

extension CanvasController {

    /// 選択中の配管の属性を一括変更する共通処理(styleも変更できる)
    private func updateSelectedPipes(name: String,
                                     change: (inout PipeAttributes, inout Style, Double) -> Void) {
        let doc = document
        let changed = updateSelection(name: name) { entity in
            guard case .pipe(let points, var attrs) = entity.kind else { return }
            let scale = doc.groups[entity.layer.group].scale
            var style = entity.style
            change(&attrs, &style, scale)
            entity.style = style
            entity.kind = .pipe(points: points, attrs: attrs)
        }
        if changed {
            onInfo?("\(name)しました(⌘Zで取り消し)")
        }
    }

    /// 口径(管種+呼び径)の一括変更(継手の規格・寸法も引き直す)
    func applyPipeSize(_ size: PipeSize) {
        let materialLabel = PipeMaster.standard.material(size.material)?.shortLabel ?? size.material
        updateSelectedPipes(name: "配管を\(materialLabel)\(size.label)に変更") { attrs, _, _ in
            attrs.material = size.material
            attrs.materialLabel = materialLabel
            attrs.size = size.size
            attrs.sizeLabel = size.label
            attrs.outerDiameter = size.outerDiameter
            attrs.fittingSeries = FittingMaster.series(material: attrs.material, usage: attrs.usage)
            attrs.fittingDims = FittingMaster.standard.dims(series: attrs.fittingSeries, size: attrs.size)
        }
    }

    /// 用途の一括変更(色・線種も用途の既定に合わせる。継手規格も引き直す)
    func applyPipeUsage(_ usage: PipeUsage) {
        updateSelectedPipes(name: "配管を\(usage.name)に変更") { attrs, style, _ in
            attrs.usage = usage.id
            attrs.usageName = usage.name
            style.colorIndex = usage.colorIndex
            style.lineType = usage.lineType
            attrs.fittingSeries = FittingMaster.series(material: attrs.material, usage: attrs.usage)
            attrs.fittingDims = FittingMaster.standard.dims(series: attrs.fittingSeries, size: attrs.size)
        }
    }

    /// 端部キャップの一括変更(M6.3)
    func applyPipeCapEnds(_ on: Bool) {
        updateSelectedPipes(name: on ? "端部にキャップを付ける" : "端部のキャップを外す") { attrs, _, _ in
            attrs.capEnds = on
        }
    }

    /// 分岐部品(DT/LT/Y)の一括変更(枝管側の属性)。M6.8
    func applyPipeBranchKind(_ kind: String) {
        updateSelectedPipes(name: "分岐部品を\(kind)に変更") { attrs, _, _ in
            attrs.branchKind = kind
        }
    }

    /// 継手反転(分岐の向きを逆にする)。M7.8
    /// 45°の枝管は鏡映して傾きを逆に、直角の枝管は下流側の印を切替、本管は作図方向を逆にする。
    /// 鏡映で端が動いた枝管に接続している配管は伸縮して追随する(設定ON時)
    func flipSelectedFittings() {
        let pipes = selectedEntities.filter(isPipe)
        guard !pipes.isEmpty else {
            onInfo?("継手を反転する配管を選択してください")
            return
        }
        let all = document.entities
        var before: [Entity] = []
        var after: [Entity] = []
        var notes: [String] = []
        var changes: [PipeConnections.PipeChange] = []
        for e in pipes {
            guard let r = PipeFlip.flip(e, in: all) else { continue }
            before.append(e)
            after.append(r.entity)
            switch r.outcome {
            case .mirroredBranch(let aboutFarEnd):
                notes.append(aboutFarEnd ? "45°の枝を反転(接続点が本管上を移動)"
                                         : "45°の枝を反転(反対側の端が移動)")
                if case .pipe(let p0, let a0) = e.kind, case .pipe(let p1, _) = r.entity.kind {
                    changes.append(PipeConnections.PipeChange(before: p0, after: p1,
                                                              radius: max(a0.outerDiameter / 2, 0)))
                }
            case .toggledBranch(let nowReversed):
                notes.append(nowReversed ? "分岐の下流側を作図方向と逆に" : "分岐の下流側を作図方向どおりに")
            case .reversedFlow(let branches):
                notes.append(branches > 0 ? "本管の流れ方向を反転(分岐\(branches)か所)" : "作図方向を反転")
            }
        }
        guard !before.isEmpty else { return }
        if pipeFollowConnections, !changes.isEmpty {
            let movingIDs = Set(before.map(\.id))
            let followers = PipeConnections.followers(changes: changes, movingIDs: movingIDs, in: all)
            for f in followers where !movingIDs.contains(f.id) {
                guard let original = document.entity(id: f.id) else { continue }
                before.append(original)
                after.append(f)
            }
            if !followers.isEmpty { notes.append("接続先\(followers.count)本が追随") }
        }
        commandStack.run(UpdateEntitiesCommand(name: "継手を反転", before: before, after: after))
        selectionDidChange()
        onInfo?("継手を反転: " + notes.joined(separator: " / ") + "(⌘Zで取り消し)")
    }

    /// 90°曲り部品(エルボ/大曲)の一括変更。M6.6
    func applyPipeLongRadius(_ on: Bool) {
        updateSelectedPipes(name: on ? "90°曲りを大曲に変更" : "90°曲りをエルボに変更") { attrs, _, _ in
            attrs.longRadius = on
        }
    }

    /// 傍記の管種表示の一括変更。M6.6
    func applyPipeAnnotateMaterial(_ on: Bool) {
        updateSelectedPipes(name: on ? "傍記に管種を表示" : "傍記の管種を非表示") { attrs, _, _ in
            attrs.annotateMaterial = on
        }
    }

    /// 単線記号の基準寸法(紙面mm)の一括変更。M6.5
    func applyPipeSymbolSize(_ paperMM: Double) {
        updateSelectedPipes(name: String(format: "単線記号サイズを%.1fmmに変更", paperMM)) { attrs, _, scale in
            attrs.symbolSize = max(paperMM, 0.5) * scale
        }
    }

    /// 口径傍記の表示/非表示の一括変更
    func applyPipeAnnotate(_ on: Bool) {
        updateSelectedPipes(name: on ? "口径傍記を表示" : "口径傍記を非表示") { attrs, _, _ in
            attrs.annotate = on
        }
    }

    /// 単線/複線の一括変更(M6.1)
    func applyPipeDoubleLine(_ on: Bool) {
        updateSelectedPipes(name: on ? "配管を複線表示に変更" : "配管を単線表示に変更") { attrs, _, _ in
            attrs.doubleLine = on
        }
    }

    /// 継手自動発生の一括変更
    func applyPipeAutoFittings(_ on: Bool) {
        updateSelectedPipes(name: on ? "継手を自動発生" : "継手を非表示") { attrs, _, _ in
            attrs.autoFittings = on
        }
    }

    /// 高さの一括変更(mm)。全頂点を同じ高さにする(立管は消える)。傍記併記も同時に指定
    func applyPipeLevel(_ level: Double, show: Bool) {
        let doc = document
        let changed = updateSelection(name: String(format: "配管の高さを%@%+.0fに変更",
                                                   doc.levelDatum, level)) { entity in
            guard case .pipe(let points, var attrs) = entity.kind else { return }
            attrs.showLevel = show
            attrs.datum = doc.levelDatum
            // 同じ高さにするので立管(平面同一点の連続頂点)は畳む
            var flat: [Vec3] = []
            for p in points {
                let v = Vec3(p.xy, z: level)
                if let last = flat.last, last.xy.distance(to: v.xy) <= PipeGeometry.planEpsilon { continue }
                flat.append(v)
            }
            entity.kind = .pipe(points: flat, attrs: attrs)
        }
        if changed {
            onInfo?("配管の高さを変更しました(⌘Zで取り消し)")
        }
    }

    /// 高さの入力パネル(選択中の配管に適用)
    func promptPipeLevel() {
        let current = selectedEntities.compactMap { e -> Double? in
            if case .pipe(let pts, _) = e.kind { return pts.first?.z }
            return nil
        }.first ?? 0
        let alert = NSAlert()
        alert.messageText = "配管の高さ"
        alert.informativeText = "芯の高さをmmで入力(基準面 \(document.levelDatum))。全頂点が同じ高さになります。傍記に併記するかも選べます"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.stringValue = String(format: "%.0f", current)
        let check = NSButton(checkboxWithTitle: "傍記に併記(例: 50 FL+2500)", target: nil, action: nil)
        check.state = .on
        let stack = NSStackView(views: [field, check])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        alert.accessoryView = stack
        alert.addButton(withTitle: "適用")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let level = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        applyPipeLevel(level, show: check.state == .on)
    }

    /// 材料集計(選択があれば選択分・なければ図面全体)をパネルで表示
    func showMaterialReport() {
        let hasSelectedPipes = selectedEntities.contains {
            if case .pipe = $0.kind { return true }
            return false
        }
        let targets = hasSelectedPipes ? selectedEntities : document.entities
        let totals = PipeAggregator.aggregate(targets)
        let scopeName = hasSelectedPipes ? "選択中の配管" : "図面全体"
        guard !totals.isEmpty else {
            onInfo?("配管がありません(配管ツールで作図したものが集計対象です)")
            return
        }
        let text = PipeAggregator.reportText(totals)

        let alert = NSAlert()
        alert.messageText = "材料集計 — \(scopeName)"
        alert.informativeText = "配管の延長を用途×管種×呼び径で集計しました(0.1m単位切り上げ)"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text.replacingOccurrences(of: "\t", with: "    ")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "コピーして閉じる")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onInfo?("集計をコピーしました(タブ区切り: Excel等へ貼り付け可)")
        }
    }
}

// MARK: - 文字パレット(M5.3)

extension CanvasController {

    /// 文字種チップの設定を反映(紙面mm→実寸mmは書込グループの縮尺で換算)
    func setTextStyle(paperMm: Double, angleDegrees: Double) {
        tools.textHeight = max(paperMm, 0.5) * document.currentScale
        tools.textAngleDegrees = angleDegrees
    }

    /// ダブルクリック位置の文字をインライン再編集する。文字が無ければfalse(呼び出し側が全体表示へ)
    @discardableResult
    func beginTextEditAtCursor() -> Bool {
        guard tools.kind == .select, !editOp.isActive, gripDrag == nil,
              let cursor = cursorScreen else { return false }
        let world = transform.toWorld(cursor)
        // 最前面の文字を探す(文字以外がヒットしても文字を優先)
        let selectable = SelectionEngine.selectableAddresses(document.groups)
        var target: Entity?
        for e in document.entities.reversed() {
            guard selectable.contains(e.layer),
                  document.showAuxiliary || !e.isAuxiliary,
                  e.hitDistance(to: world) <= hitToleranceMm * 2 else { continue }
            switch e.kind {
            case .text, .leader:
                target = e
            default:
                continue
            }
            break
        }
        guard let target else { return false }
        if case .leader = target.kind {
            beginLeaderEdit(target)
        } else {
            beginTextEdit(target)
        }
        return true
    }

    /// 選択中の文字(1つ)をインライン再編集(プロパティパネルの「内容を編集」から)
    func editSelectedText() {
        guard let e = selectedEntities.first(where: {
            if case .text = $0.kind { return true }
            return false
        }) else { return }
        beginTextEdit(e)
    }

    private func beginTextEdit(_ entity: Entity) {
        guard case .text(let position, let content, let height, _) = entity.kind else { return }
        var screen = transform.toScreen(position)
        // 画面外の文字を編集する場合は入力欄が見える位置に収める
        if let size = viewSizeProvider?(), size.width > 320 {
            screen = Vec2(min(max(screen.x, 10), Double(size.width) - 300),
                          min(max(screen.y, 40), Double(size.height) - 20))
        }
        let fontPx = max(height * transform.scale, 9)
        onTextInputRequested?(screen, content, fontPx) { [weak self] newText in
            guard let self, let newText, !newText.isEmpty, newText != content else { return }
            var after = entity
            if case .text(let p, _, let h, let a) = entity.kind {
                after.kind = .text(position: p, content: newText, height: h, angle: a)
            }
            self.commandStack.run(UpdateEntitiesCommand(name: "文字変更",
                                                        before: [entity], after: [after]))
            self.selectionDidChange()
            self.onInfo?("文字を変更しました(⌘Zで取り消し)")
        }
    }

    /// 選択中の文字のサイズを紙面mmで一括変更(実寸は各文字の所属グループ縮尺で換算)
    func applyTextPaperSize(_ paperMm: Double) {
        let doc = document
        let changed = updateSelection(name: "文字サイズ変更") { entity in
            guard case .text(let p, let content, _, let angle) = entity.kind else { return }
            let scale = doc.groups[entity.layer.group].scale
            entity.kind = .text(position: p, content: content,
                                height: max(paperMm, 0.5) * scale, angle: angle)
        }
        if changed {
            onInfo?(String(format: "文字サイズを紙面%.1fmmにしました(⌘Zで取り消し)", paperMm))
        } else if selectedEntities.contains(where: { if case .text = $0.kind { return true }; return false }) {
            onInfo?(String(format: "選択中の文字はすでに紙面%.1fmmです", paperMm))
        }
    }
}

// MARK: - 寸法プロパティ(M5.4)

extension CanvasController {

    /// 選択中の寸法の属性を一括変更する共通処理
    private func updateSelectedDimensions(name: String,
                                          change: (inout DimAttributes, Double) -> Void) {
        let doc = document
        let changed = updateSelection(name: name) { entity in
            guard case .dimension(let a, let b, let lp, let angle, var attrs) = entity.kind else { return }
            let scale = doc.groups[entity.layer.group].scale
            change(&attrs, scale)
            entity.kind = .dimension(a: a, b: b, linePoint: lp, angle: angle, attrs: attrs)
        }
        if changed {
            onInfo?("\(name)しました(⌘Zで取り消し)")
        }
    }

    /// 端部記号(黒丸/矢印)の一括変更
    func applyDimTerminator(_ terminator: DimTerminator) {
        updateSelectedDimensions(name: "寸法の端部を\(terminator.label)に変更") { attrs, _ in
            attrs.terminator = terminator
        }
    }

    /// 寸法補助線の長さの一括変更(紙面mm。nil=測定点まで、0=なし)
    func applyDimExtension(paperMm: Double?) {
        updateSelectedDimensions(name: "寸法補助線を変更") { attrs, scale in
            attrs.extensionLength = paperMm.map { $0 * scale }
        }
    }

    /// 寸法値の文字サイズの一括変更(紙面mm)
    func applyDimTextSize(paperMm: Double) {
        updateSelectedDimensions(name: "寸法の文字サイズを変更") { attrs, scale in
            attrs.textHeight = max(paperMm, 0.5) * scale
        }
    }
}

// MARK: - 引出線・バルーン(M5.5)

extension CanvasController {

    /// 選択中の引出線の属性を一括変更する共通処理
    private func updateSelectedLeaders(name: String,
                                       change: (inout LeaderAttributes, Double) -> Void) {
        let doc = document
        let changed = updateSelection(name: name) { entity in
            guard case .leader(let tip, let elbow, let content, var attrs) = entity.kind else { return }
            let scale = doc.groups[entity.layer.group].scale
            change(&attrs, scale)
            entity.kind = .leader(tip: tip, elbow: elbow, content: content, attrs: attrs)
        }
        if changed {
            onInfo?("\(name)しました(⌘Zで取り消し)")
        }
    }

    /// 引出線の文字サイズの一括変更(紙面mm。バルーンは枠も追随)
    func applyLeaderTextSize(paperMm: Double) {
        updateSelectedLeaders(name: "引出線の文字サイズを変更") { attrs, scale in
            attrs.textHeight = max(paperMm, 0.5) * scale
        }
    }

    /// 矢印の有無の一括変更
    func applyLeaderArrow(_ on: Bool) {
        updateSelectedLeaders(name: on ? "引出線に矢印を追加" : "引出線の矢印を削除") { attrs, _ in
            attrs.arrow = on
        }
    }

    /// バルーン枠(一重/二重)の一括変更
    func applyLeaderFrame(double: Bool) {
        updateSelectedLeaders(name: double ? "バルーンを二重枠に変更" : "バルーンを一重枠に変更") { attrs, _ in
            attrs.doubleFrame = double
        }
    }

    /// バルーン横サイズの一括変更(紙面mm・直径。nil=文字に合わせて自動)
    func applyLeaderBalloonWidth(paperMm: Double?) {
        updateSelectedLeaders(name: "バルーンの横サイズを変更") { attrs, scale in
            attrs.balloonWidth = paperMm.map { max($0, 1) * scale }
        }
    }

    /// 選択中の引出線(1つ)の文字をインライン再編集
    func editSelectedLeader() {
        guard let e = selectedEntities.first(where: {
            if case .leader = $0.kind { return true }
            return false
        }) else { return }
        beginLeaderEdit(e)
    }

    /// 引出線の文字をインライン再編集(ダブルクリック/パネルの「内容を編集」)
    func beginLeaderEdit(_ entity: Entity) {
        guard case .leader(let tip, let elbow, let content, let attrs) = entity.kind else { return }
        guard let layout = LeaderGeometry.layout(of: entity) else { return }
        // 入力欄は先頭行の位置に出す(内容は「,」区切りのまま編集)
        var screen = transform.toScreen(layout.texts.first?.position ?? elbow)
        if let size = viewSizeProvider?(), size.width > 320 {
            screen = Vec2(min(max(screen.x, 10), Double(size.width) - 300),
                          min(max(screen.y, 40), Double(size.height) - 20))
        }
        let fontPx = max(attrs.textHeight * transform.scale, 9)
        onTextInputRequested?(screen, content, fontPx) { [weak self] newText in
            guard let self, let newText, !newText.isEmpty, newText != content else { return }
            var after = entity
            after.kind = .leader(tip: tip, elbow: elbow, content: newText, attrs: attrs)
            self.commandStack.run(UpdateEntitiesCommand(name: "引出線の文字変更",
                                                        before: [entity], after: [after]))
            self.selectionDidChange()
            self.onInfo?("引出線の文字を変更しました(⌘Zで取り消し)")
        }
    }
}
