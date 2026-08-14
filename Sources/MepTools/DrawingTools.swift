import Foundation
import MepCore

/// 作図ツールの種類(M4.5: 矩形・円弧・2線・中心線・点を追加)
public enum ToolKind: String, CaseIterable, Sendable {
    case select = "選択"
    case line = "線分"
    case rect = "矩形"
    case circle = "円"
    case arc = "円弧"
    case doubleLine = "2線"
    case centerline = "中心線"
    case point = "点"
    case text = "文字"
    case hatch = "ハッチング"
    case dimension = "寸法"
    case leader = "引出線"
}

/// 引出線ツールの現在設定(プロパティカードの値。紙面mm→実寸mm換算は実装側で行う)
public struct LeaderToolStyle: Sendable {
    public var attrs: LeaderAttributes
    public var colorIndex: Int?

    public init(attrs: LeaderAttributes = LeaderAttributes(), colorIndex: Int? = nil) {
        self.attrs = attrs
        self.colorIndex = colorIndex
    }
}

/// 寸法の方向モード(M5.4)
public enum DimAxisMode: String, CaseIterable, Sendable {
    case horizontal = "水平"
    case vertical = "垂直"
    case aligned = "平行"

    /// 寸法線方向(rad)。平行は測定点2点の方向
    public func angle(from a: Vec2, to b: Vec2) -> Double {
        switch self {
        case .horizontal: return 0
        case .vertical: return .pi / 2
        case .aligned:
            let d = b - a
            return d.length > 1e-9 ? atan2(d.y, d.x) : 0
        }
    }
}

/// 寸法ツールの現在設定(コマンドプロパティカードの値。紙面mm→実寸mm換算は実装側で行う)
public struct DimensionToolStyle: Sendable {
    public var axis: DimAxisMode
    public var attrs: DimAttributes   // 実寸mm換算済み
    public var colorIndex: Int?       // nil=レイヤ既定

    public init(axis: DimAxisMode = .horizontal,
                attrs: DimAttributes = DimAttributes(),
                colorIndex: Int? = nil) {
        self.axis = axis
        self.attrs = attrs
        self.colorIndex = colorIndex
    }
}

/// オーバーレイに描くプレビュー形状(ワールド座標)
public enum PreviewShape {
    case none
    case line(Vec2, Vec2)
    case circle(Vec2, Double)
    case rect(Vec2, Vec2)                                  // 対角2点
    case arc(Vec2, Double, Double, Double)                 // 中心, 半径, 開始角, 終了角(CCW)
    case doubleLine(Vec2, Vec2, Double, Double)            // 基準線a-b, A側/B側オフセット
    case polygon([Vec2], Vec2)                             // ハッチング境界の確定頂点+カーソル
    case dimension(Vec2, Vec2, Vec2, Double, DimAttributes)  // 測定点a,b・寸法線通過点・方向・属性
    case leader(Vec2, Vec2, LeaderAttributes)                // 指示点・文字位置(カーソル)・属性
}

/// 角度拘束モード(常設パレットで切替。⇧押下は一時的に45°拘束)
public enum AngleConstraint: String, CaseIterable, Sendable {
    case free = "自由"
    case deg90 = "90°"
    case deg45 = "45°"
    case deg15 = "15°"

    public var step: Double? {
        switch self {
        case .free: return nil
        case .deg90: return .pi / 2
        case .deg45: return .pi / 4
        case .deg15: return .pi / 12
        }
    }
}

public protocol DrawingToolDelegate: AnyObject {
    /// 作図確定(呼び出し側でUndo可能なコマンドとして実行する)
    func toolDidProduce(_ entity: Entity)
    /// 複数要素の一括確定(矩形・2線など。1回のUndoでまとめて戻る)
    func toolDidProduceGroup(_ entities: [Entity], name: String)
    /// 文字ツール: テキスト入力UIの表示を依頼
    func toolRequestsText(at point: Vec2, completion: @escaping (String?) -> Void)
    /// 文字入力UIの表示依頼(フォント高さ指定版。引出線ツールが使う)
    func toolRequestsText(at point: Vec2, fontHeight: Double,
                          completion: @escaping (String?) -> Void)
    /// 状態ヒントの変化(ステータスバー表示用)
    func toolStatusChanged(_ hint: String)
    /// ツール切替の通知(UI側の選択状態同期用)
    func toolKindChanged(_ kind: ToolKind)
    /// ハッチングの現在設定(プロパティカードの値。印刷寸→実寸の換算は実装側で行う)
    func toolHatchPattern() -> HatchPattern
    /// 寸法の現在設定(プロパティカードの値。紙面mm→実寸mmの換算は実装側で行う)
    func toolDimensionStyle() -> DimensionToolStyle
    /// 引出線の現在設定(プロパティカードの値。紙面mm→実寸mmの換算は実装側で行う)
    func toolLeaderStyle() -> LeaderToolStyle
}

extension DrawingToolDelegate {
    /// 既定実装(テスト用スタブ等が実装しなくても済むように)
    public func toolHatchPattern() -> HatchPattern {
        HatchPattern(kind: .horizontal, spacingA: 100, spacingB: 50, angle: .pi / 4)
    }
    public func toolDimensionStyle() -> DimensionToolStyle {
        DimensionToolStyle()
    }
    public func toolLeaderStyle() -> LeaderToolStyle {
        LeaderToolStyle()
    }
    public func toolRequestsText(at point: Vec2, fontHeight: Double,
                                 completion: @escaping (String?) -> Void) {
        // 既定実装は従来版へ委譲(テスト用スタブ等が実装しなくても済むように)
        toolRequestsText(at: point, completion: completion)
    }
}

/// 作図ツールの状態機械(UI非依存・ユニットテスト対象)。
public final class DrawingToolController {
    public weak var delegate: DrawingToolDelegate?
    public var currentLayer: LayerAddress
    public private(set) var kind: ToolKind = .select
    public private(set) var numericBuffer = ""
    /// 第1点(線分・中心線・2線: 直前の確定点 / 円・円弧: 中心 / 矩形: 第1コーナー)
    private var anchor: Vec2?
    /// 円弧: 始点(中心の次に指示。半径が確定する)
    private var arcStart: Vec2?
    public private(set) var lastCursor: Vec2 = .zero
    /// 文字の既定高さ(実寸mm。文字種チップの紙面mm×縮尺で設定される)
    public var textHeight: Double = 300
    /// 文字の角度(度・反時計回り正。文字パレットから設定)
    public var textAngleDegrees: Double = 0
    /// 2線のA側/B側オフセット(実寸mm・基準線からの距離)。`a,b⏎`で個別、`w⏎`で振分半々。記憶される
    public private(set) var doubleLineOffsetA: Double = 50
    public private(set) var doubleLineOffsetB: Double = 50
    /// 矩形の寸法先行指定(`X,Y⏎`)。設定中はカーソル中心にぶら下がりクリックで配置
    public private(set) var pendingRectSize: Vec2?
    /// 角度拘束モード(ツールバーの常設パレットから設定)
    public var angleConstraint: AngleConstraint = .free
    /// ハッチング境界の確定済み頂点
    public private(set) var hatchPoints: [Vec2] = []
    /// 寸法: 測定点1・2(3クリック目=寸法線位置で確定)
    public private(set) var dimA: Vec2?
    public private(set) var dimB: Vec2?
    /// 引出線: 指示点(2クリック目=文字位置→インライン文字入力で確定)
    public private(set) var leaderTip: Vec2?
    /// 始点クリックで閉じる判定の許容距離(ワールドmm。呼び出し側がピックボックス幅を設定)
    public var closeTolerance: Double = 0

    public init(currentLayer: LayerAddress) {
        self.currentLayer = currentLayer
    }

    public var isDrawingToolActive: Bool { kind != .select }

    // MARK: - ツール切替・キャンセル

    public func select(_ newKind: ToolKind) {
        kind = newKind
        resetPoints()
        numericBuffer = ""
        delegate?.toolKindChanged(kind)
        publishHint()
    }

    private func resetPoints() {
        anchor = nil
        arcStart = nil
        pendingRectSize = nil
        hatchPoints = []
        dimA = nil
        dimB = nil
        leaderTip = nil
    }

    /// esc/右クリック: 作図中なら現在の作図を終了、待機中なら選択ツールへ戻る
    public func cancel() {
        if anchor != nil || arcStart != nil || pendingRectSize != nil
            || !hatchPoints.isEmpty || dimA != nil || leaderTip != nil
            || !numericBuffer.isEmpty {
            resetPoints()
            numericBuffer = ""
        } else if kind != .select {
            kind = .select
            delegate?.toolKindChanged(kind)
        }
        publishHint()
    }

    // MARK: - カーソル・クリック

    /// カーソル移動。プレビュー形状(ワールド座標)を返す
    public func preview(cursor: Vec2, shiftDown: Bool) -> PreviewShape {
        lastCursor = cursor
        switch kind {
        case .line, .centerline:
            guard let a = anchor else { return .none }
            return .line(a, constrained(from: a, to: cursor, active: shiftDown))
        case .doubleLine:
            guard let a = anchor else { return .none }
            return .doubleLine(a, constrained(from: a, to: cursor, active: shiftDown),
                               doubleLineOffsetA, doubleLineOffsetB)
        case .rect:
            if let a = anchor { return .rect(a, cursor) }
            if let size = pendingRectSize {
                // 寸法先行指定: カーソル中心にぶら下がる
                return .rect(Vec2(cursor.x - size.x / 2, cursor.y - size.y / 2),
                             Vec2(cursor.x + size.x / 2, cursor.y + size.y / 2))
            }
            return .none
        case .circle:
            guard let c = anchor else { return .none }
            return .circle(c, c.distance(to: cursor))
        case .arc:
            guard let c = anchor else { return .none }
            if let s = arcStart {
                let a1 = atan2(s.y - c.y, s.x - c.x)
                let a2 = atan2(cursor.y - c.y, cursor.x - c.x)
                return .arc(c, c.distance(to: s), a1, a2)
            }
            return .circle(c, c.distance(to: cursor))
        case .hatch:
            guard !hatchPoints.isEmpty else { return .none }
            return .polygon(hatchPoints, cursor)
        case .dimension:
            guard let a = dimA else { return .none }
            guard let b = dimB else { return .line(a, cursor) }
            let style = delegate?.toolDimensionStyle() ?? DimensionToolStyle()
            return .dimension(a, b, cursor, style.axis.angle(from: a, to: b), style.attrs)
        case .leader:
            guard let tip = leaderTip else { return .none }
            let style = delegate?.toolLeaderStyle() ?? LeaderToolStyle()
            return .leader(tip, cursor, style.attrs)
        default:
            return .none
        }
    }

    public func click(at p: Vec2, shiftDown: Bool) {
        switch kind {
        case .select:
            break

        case .line:
            clickLineLike(at: p, shiftDown: shiftDown) { a, b in self.commitLine(a, b) }

        case .centerline:
            // 中心線: 一点鎖1で作図(機器・ダクトの芯押さえ)
            clickLineLike(at: p, shiftDown: shiftDown) { a, b in
                self.commitLine(a, b, style: Style(lineType: 4))
            }

        case .doubleLine:
            clickLineLike(at: p, shiftDown: shiftDown) { a, b in
                self.commitDoubleLine(a, b)
            }

        case .rect:
            if let size = pendingRectSize, anchor == nil {
                // 寸法先行指定: クリック位置を中心に配置(escまで連続配置)
                commitRect(Vec2(p.x - size.x / 2, p.y - size.y / 2),
                           Vec2(p.x + size.x / 2, p.y + size.y / 2))
            } else if let a = anchor {
                commitRect(a, p)
                anchor = nil
            } else {
                anchor = p
            }

        case .circle:
            if let c = anchor {
                let r = c.distance(to: p)
                if r > 0.01 { commitCircle(c, r) }
                anchor = nil
            } else {
                anchor = p
            }

        case .arc:
            if anchor == nil {
                anchor = p                      // 中心
            } else if arcStart == nil {
                if let c = anchor, c.distance(to: p) > 0.01 {
                    arcStart = p                // 始点(半径が決まる)
                }
            } else if let c = anchor, let s = arcStart {
                commitArc(center: c, start: s, endDirection: p)
                resetPoints()
            }

        case .point:
            delegate?.toolDidProduce(Entity(layer: currentLayer, kind: .point(position: p)))

        case .text:
            delegate?.toolRequestsText(at: p) { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                self.delegate?.toolDidProduce(
                    Entity(layer: self.currentLayer,
                           kind: .text(position: p, content: text,
                                       height: self.textHeight,
                                       angle: self.textAngleDegrees * .pi / 180)))
            }

        case .hatch:
            // 始点の近くをクリック(スナップで正確に合う)か⏎で閉じて確定
            if hatchPoints.count >= 3, let first = hatchPoints.first,
               p.distance(to: first) <= max(closeTolerance, 1e-9) {
                commitHatch()
            } else if hatchPoints.last.map({ $0.distance(to: p) > 1e-9 }) ?? true {
                hatchPoints.append(p)
            }

        case .dimension:
            if dimA == nil {
                dimA = p
            } else if dimB == nil {
                if let a = dimA, a.distance(to: p) > 0.01 { dimB = p }
            } else if let a = dimA, let b = dimB {
                commitDimension(a: a, b: b, linePoint: p)
                dimA = nil
                dimB = nil
            }

        case .leader:
            if leaderTip == nil {
                leaderTip = p
            } else if let tip = leaderTip, tip.distance(to: p) > 0.01 {
                // 文字位置が決まったらその場でインライン文字入力(入力と連動)
                let style = delegate?.toolLeaderStyle() ?? LeaderToolStyle()
                let elbow = p
                leaderTip = nil
                delegate?.toolRequestsText(at: elbow, fontHeight: style.attrs.textHeight) { [weak self] text in
                    guard let self, let text, !text.isEmpty else { return }
                    self.delegate?.toolDidProduce(
                        Entity(layer: self.currentLayer,
                               style: Style(colorIndex: style.colorIndex),
                               kind: .leader(tip: tip, elbow: elbow,
                                             content: text, attrs: style.attrs)))
                }
            }
        }
        numericBuffer = ""
        publishHint()
    }

    /// 寸法の確定(3クリック目=寸法線位置)
    private func commitDimension(a: Vec2, b: Vec2, linePoint: Vec2) {
        let style = delegate?.toolDimensionStyle() ?? DimensionToolStyle()
        let angle = style.axis.angle(from: a, to: b)
        // 水平/垂直で測定点の投影が重なる(=長さ0)寸法は作らない
        let u = Vec2(cos(angle), sin(angle))
        let span = abs((b.x - a.x) * u.x + (b.y - a.y) * u.y)
        guard span > 0.01 else { return }
        delegate?.toolDidProduce(
            Entity(layer: currentLayer,
                   style: Style(colorIndex: style.colorIndex),
                   kind: .dimension(a: a, b: b, linePoint: linePoint,
                                    angle: angle, attrs: style.attrs)))
    }

    /// ハッチングの確定(境界を閉じてエンティティ化。確定後は次の領域へ)
    public func commitHatch() {
        guard kind == .hatch, hatchPoints.count >= 3 else { return }
        let pattern = delegate?.toolHatchPattern()
            ?? HatchPattern(kind: .horizontal, spacingA: 100, spacingB: 50, angle: .pi / 4)
        delegate?.toolDidProduce(Entity(layer: currentLayer,
                                        kind: .hatch(boundary: hatchPoints, pattern: pattern)))
        hatchPoints = []
        publishHint()
    }

    /// 線分系(線分・中心線・2線)の共通クリック処理: 連続作図(前の終点が次の始点)
    private func clickLineLike(at p: Vec2, shiftDown: Bool, commit: (Vec2, Vec2) -> Void) {
        if let a = anchor {
            let b = constrained(from: a, to: p, active: shiftDown)
            commit(a, b)
            anchor = b
        } else {
            anchor = p
        }
    }

    // MARK: - 数値入力

    /// キー入力。処理した場合true(未処理はビューが他用途に使う)
    @discardableResult
    public func keyInput(_ character: Character) -> Bool {
        let numericCapable: Bool
        switch kind {
        case .line, .centerline, .circle, .arc:
            numericCapable = anchor != nil
        case .rect:
            numericCapable = true   // 寸法(X,Y)は第1コーナー前でも指定できる
        case .doubleLine:
            numericCapable = true   // 振分は始点前でも変更できる
        case .hatch:
            numericCapable = hatchPoints.count >= 3   // ⏎=閉じて確定
        default:
            numericCapable = false
        }
        guard numericCapable else { return false }

        if character.isNumber || character == "." || character == "," || character == "-" {
            numericBuffer.append(character)
            publishHint()
            return true
        }
        if character == "\r" || character == "\n" {
            if kind == .hatch {
                commitHatch()
            } else {
                applyNumericInput()
            }
            return true
        }
        if character == "\u{7F}" || character == "\u{08}" {  // delete/backspace
            if !numericBuffer.isEmpty {
                numericBuffer.removeLast()
                publishHint()
                return true
            }
        }
        return false
    }

    private func applyNumericInput() {
        let buffer = numericBuffer
        numericBuffer = ""
        defer { publishHint() }
        guard !buffer.isEmpty else { return }
        let comps = buffer.split(separator: ",").map(String.init)

        switch kind {
        case .line:
            guard let a = anchor, let b = numericTarget(from: a, comps: comps) else { return }
            commitLine(a, b)
            anchor = b

        case .centerline:
            guard let a = anchor, let b = numericTarget(from: a, comps: comps) else { return }
            commitLine(a, b, style: Style(lineType: 4))
            anchor = b

        case .doubleLine:
            // `a,b`=A側/B側オフセット、単独数値=振分半々(w/2ずつ)
            if comps.count == 2, let oa = Double(comps[0]), let ob = Double(comps[1]),
               oa > 0.001, ob > 0.001 {
                doubleLineOffsetA = oa
                doubleLineOffsetB = ob
            } else if comps.count == 1, let w = Double(comps[0]), w > 0.01 {
                doubleLineOffsetA = w / 2
                doubleLineOffsetB = w / 2
            }

        case .rect:
            // `X,Y⏎`=寸法指定(第1コーナー前なら先行指定、後ならそこから作図)。単独数値=正方形
            if comps.count == 2, let w = Double(comps[0]), let h = Double(comps[1]),
               abs(w) > 0.01, abs(h) > 0.01 {
                applyRectSize(Vec2(abs(w), abs(h)))
            } else if comps.count == 1, let w = Double(comps[0]), abs(w) > 0.01 {
                applyRectSize(Vec2(abs(w), abs(w)))
            }

        case .circle:
            guard let c = anchor, comps.count == 1,
                  let r = Double(comps[0]), r > 0.001 else { return }
            commitCircle(c, r)
            anchor = nil

        case .arc:
            // 中心決定後の単独数値=半径(始点はカーソル方向に取る)
            guard let c = anchor, arcStart == nil, comps.count == 1,
                  let r = Double(comps[0]), r > 0.001 else { return }
            let dir = lastCursor - c
            let len = dir.length
            guard len > 1e-9 else { return }
            arcStart = c + dir * (r / len)

        default:
            break
        }
    }

    /// 矩形の寸法入力: 第1コーナー確定済みならそこから作図、未確定なら寸法先行指定にする
    private func applyRectSize(_ size: Vec2) {
        if let a = anchor {
            commitRect(a, Vec2(a.x + size.x, a.y + size.y))
            anchor = nil
        } else {
            pendingRectSize = size
        }
    }

    /// "dx,dy"=相対座標 / 単独数値=拘束方向へ距離、の共通解釈
    private func numericTarget(from a: Vec2, comps: [String]) -> Vec2? {
        if comps.count == 2, let dx = Double(comps[0]), let dy = Double(comps[1]) {
            return Vec2(a.x + dx, a.y + dy)
        }
        if comps.count == 1, let dist = Double(comps[0]), abs(dist) > 0.001 {
            let target = constrained(from: a, to: lastCursor, active: false)
            let dir = target - a
            let len = dir.length
            guard len > 1e-9 else { return nil }
            return a + dir * (dist / len)
        }
        return nil
    }

    // MARK: - 内部

    /// 角度拘束: 常設モード優先、モードが自由のときは⇧押下で一時的に45°
    private func constrained(from a: Vec2, to p: Vec2, active shiftDown: Bool) -> Vec2 {
        let step: Double?
        if let s = angleConstraint.step {
            step = s
        } else if shiftDown {
            step = .pi / 4
        } else {
            step = nil
        }
        guard let step else { return p }
        let d = p - a
        let len = d.length
        guard len > 1e-9 else { return p }
        let snapped = (atan2(d.y, d.x) / step).rounded() * step
        return Vec2(a.x + cos(snapped) * len, a.y + sin(snapped) * len)
    }

    private func commitLine(_ a: Vec2, _ b: Vec2, style: Style = .byLayer) {
        guard a.distance(to: b) > 0.01 else { return }
        delegate?.toolDidProduce(Entity(layer: currentLayer, style: style, kind: .line(a: a, b: b)))
    }

    private func commitCircle(_ c: Vec2, _ r: Double) {
        delegate?.toolDidProduce(Entity(layer: currentLayer, kind: .circle(center: c, radius: r)))
    }

    private func commitRect(_ p1: Vec2, _ p2: Vec2) {
        guard abs(p2.x - p1.x) > 0.01, abs(p2.y - p1.y) > 0.01 else { return }
        let corners = [p1, Vec2(p2.x, p1.y), p2, Vec2(p1.x, p2.y)]
        let lines = (0..<4).map { i in
            Entity(layer: currentLayer,
                   kind: .line(a: corners[i], b: corners[(i + 1) % 4]))
        }
        delegate?.toolDidProduceGroup(lines, name: "矩形")
    }

    private func commitDoubleLine(_ a: Vec2, _ b: Vec2) {
        guard a.distance(to: b) > 0.01, doubleLineOffsetA > 0.001, doubleLineOffsetB > 0.001 else { return }
        let d = b - a
        let len = d.length
        // 左向き単位法線。A側=進行方向左、B側=右
        let n = Vec2(-d.y / len, d.x / len)
        let offsetA = n * doubleLineOffsetA
        let offsetB = n * (-doubleLineOffsetB)
        let lines = [
            Entity(layer: currentLayer, kind: .line(a: a + offsetA, b: b + offsetA)),
            Entity(layer: currentLayer, kind: .line(a: a + offsetB, b: b + offsetB)),
        ]
        delegate?.toolDidProduceGroup(lines, name: "2線")
    }

    private func commitArc(center: Vec2, start: Vec2, endDirection p: Vec2) {
        let r = center.distance(to: start)
        guard r > 0.01 else { return }
        let a1 = atan2(start.y - center.y, start.x - center.x)
        let a2 = atan2(p.y - center.y, p.x - center.x)
        guard abs(a1 - a2) > 1e-9 else { return }
        delegate?.toolDidProduce(Entity(layer: currentLayer,
                                        kind: .arc(center: center, radius: r,
                                                   startAngle: a1, endAngle: a2)))
    }

    private func publishHint() {
        delegate?.toolStatusChanged(hint)
    }

    public var hint: String {
        let num = numericBuffer.isEmpty ? "" : "  入力: \(numericBuffer)"
        let constraint = angleConstraint == .free ? "" : " [\(angleConstraint.rawValue)拘束]"
        switch kind {
        case .select:
            return "クリック=選択 / 左→右ドラッグ=窓選択 / 右→左=交差選択 / 右クリック=メニュー"
        case .line:
            return anchor == nil
                ? "線分: 始点を指示" + constraint
                : "線分: 次点を指示 — 数値=距離 / x,y=相対 / ⏎確定 / esc終了" + constraint + num
        case .centerline:
            return anchor == nil
                ? "中心線: 始点を指示(一点鎖線で作図)" + constraint
                : "中心線: 次点を指示 — 数値=距離 / x,y=相対 / esc終了" + constraint + num
        case .doubleLine:
            let ab = String(format: "A%.0f/B%.0f", doubleLineOffsetA, doubleLineOffsetB)
            return anchor == nil
                ? "2線(\(ab)): 始点を指示 — a,b⏎=振分指定 / w⏎=半々" + constraint + num
                : "2線(\(ab)): 次点を指示 — a,b⏎=振分変更 / esc終了" + constraint + num
        case .rect:
            if let size = pendingRectSize {
                return String(format: "矩形 %.0f×%.0f: クリックで配置(中心基準・連続配置可 / esc解除)", size.x, size.y) + num
            }
            return anchor == nil
                ? "矩形: 第1コーナーを指示 — X,Y⏎=寸法先行指定(カーソル配置)" + num
                : "矩形: 対角コーナーを指示 — X,Y⏎でも可(単独数値=正方形)" + num
        case .circle:
            return anchor == nil
                ? "円: 中心を指示"
                : "円: 半径を指示(数値入力→⏎でも可)" + num
        case .arc:
            if anchor == nil { return "円弧: 中心を指示" }
            if arcStart == nil { return "円弧: 始点を指示(半径が決まる。数値⏎=半径)" + num }
            return "円弧: 終点方向を指示(始点から反時計回り)"
        case .point:
            return "点: 配置位置をクリック"
        case .text:
            return "文字: 配置位置をクリック(その場で入力 — ⏎確定 / esc中止。サイズ・角度は左上のカード)"
        case .hatch:
            if hatchPoints.isEmpty {
                return "ハッチング: 領域の頂点を順にクリック(スナップ有効)— パターンは左上のカードで設定"
            }
            return "ハッチング: 次の頂点を指示(\(hatchPoints.count)点)— 始点クリックか⏎で閉じて確定 / esc中止"
        case .dimension:
            if dimA == nil { return "寸法: 測定点1を指示(端点スナップ有効)— 方向・端部は左上のカード" }
            if dimB == nil { return "寸法: 測定点2を指示" }
            return "寸法: 寸法線の位置をクリック(引出し量が決まる)/ esc中止"
        case .leader:
            if leaderTip == nil {
                return "引出線: 指示点(矢印の先端)をクリック — タイプ・矢印は左上のカード"
            }
            return "引出線: 文字位置をクリック → その場で文字を入力(⏎確定 / esc中止)"
        }
    }
}
