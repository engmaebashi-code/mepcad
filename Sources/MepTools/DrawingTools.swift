import Foundation
import MepCore

/// 作図ツールの種類(M3: 選択はプレースホルダ、M4で実装)
public enum ToolKind: String, CaseIterable, Sendable {
    case select = "選択"
    case line = "線分"
    case circle = "円"
    case text = "文字"
}

/// オーバーレイに描くプレビュー形状(ワールド座標)
public enum PreviewShape {
    case none
    case line(Vec2, Vec2)
    case circle(Vec2, Double)
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
    /// 文字ツール: テキスト入力UIの表示を依頼
    func toolRequestsText(at point: Vec2, completion: @escaping (String?) -> Void)
    /// 状態ヒントの変化(ステータスバー表示用)
    func toolStatusChanged(_ hint: String)
    /// ツール切替の通知(UI側の選択状態同期用)
    func toolKindChanged(_ kind: ToolKind)
}

/// 作図ツールの状態機械(UI非依存・ユニットテスト対象)。
/// 実装構成設計書§5の Tool プロトコル相当を、M3では1クラスに集約して実装する。
public final class DrawingToolController {
    public weak var delegate: DrawingToolDelegate?
    public var currentLayer: LayerAddress
    public private(set) var kind: ToolKind = .select
    public private(set) var numericBuffer = ""
    /// 線分: 直前の確定点(連続作図) / 円: 中心
    private var anchor: Vec2?
    public private(set) var lastCursor: Vec2 = .zero
    /// 文字の既定高さ(実寸mm。1/50印刷で紙面6mm相当)
    public var textHeight: Double = 300
    /// 角度拘束モード(ツールバーの常設パレットから設定)
    public var angleConstraint: AngleConstraint = .free

    public init(currentLayer: LayerAddress) {
        self.currentLayer = currentLayer
    }

    public var isDrawingToolActive: Bool { kind != .select }

    // MARK: - ツール切替・キャンセル

    public func select(_ newKind: ToolKind) {
        kind = newKind
        anchor = nil
        numericBuffer = ""
        delegate?.toolKindChanged(kind)
        publishHint()
    }

    /// esc/右クリック: 作図中なら現在の連続作図を終了、待機中なら選択ツールへ戻る
    public func cancel() {
        if anchor != nil || !numericBuffer.isEmpty {
            anchor = nil
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
        guard let a = anchor else { return .none }
        switch kind {
        case .line:
            return .line(a, constrained(from: a, to: cursor, active: shiftDown))
        case .circle:
            return .circle(a, a.distance(to: cursor))
        default:
            return .none
        }
    }

    public func click(at p: Vec2, shiftDown: Bool) {
        switch kind {
        case .select:
            break
        case .line:
            if let a = anchor {
                let b = constrained(from: a, to: p, active: shiftDown)
                commitLine(a, b)
                anchor = b  // 連続作図(前の終点が次の始点)
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
        case .text:
            delegate?.toolRequestsText(at: p) { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                self.delegate?.toolDidProduce(
                    Entity(layer: self.currentLayer,
                           kind: .text(position: p, content: text,
                                       height: self.textHeight, angle: 0)))
            }
        }
        numericBuffer = ""
        publishHint()
    }

    // MARK: - 数値入力

    /// キー入力。処理した場合true(未処理はビューが他用途に使う)
    @discardableResult
    public func keyInput(_ character: Character) -> Bool {
        guard kind == .line || kind == .circle, anchor != nil else { return false }
        if character.isNumber || character == "." || character == "," || character == "-" {
            numericBuffer.append(character)
            publishHint()
            return true
        }
        if character == "\r" || character == "\n" {
            applyNumericInput()
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
            guard let a = anchor else { return }
            if comps.count == 2, let dx = Double(comps[0]), let dy = Double(comps[1]) {
                // 相対座標入力 "dx,dy"
                let b = Vec2(a.x + dx, a.y + dy)
                commitLine(a, b)
                anchor = b
            } else if comps.count == 1, let dist = Double(comps[0]), abs(dist) > 0.001 {
                // 距離入力: 角度拘束を適用した後のカーソル方向へ指定距離
                // (プレビューで見えている拘束済みの線と同じ方向に確定させる)
                let target = constrained(from: a, to: lastCursor, active: false)
                let dir = target - a
                let len = dir.length
                guard len > 1e-9 else { return }
                let b = a + dir * (dist / len)
                commitLine(a, b)
                anchor = b
            }
        case .circle:
            guard let c = anchor, comps.count == 1,
                  let r = Double(comps[0]), r > 0.001 else { return }
            commitCircle(c, r)
            anchor = nil
        default:
            break
        }
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

    private func commitLine(_ a: Vec2, _ b: Vec2) {
        guard a.distance(to: b) > 0.01 else { return }
        delegate?.toolDidProduce(Entity(layer: currentLayer, kind: .line(a: a, b: b)))
    }

    private func commitCircle(_ c: Vec2, _ r: Double) {
        delegate?.toolDidProduce(Entity(layer: currentLayer, kind: .circle(center: c, radius: r)))
    }

    private func publishHint() {
        delegate?.toolStatusChanged(hint)
    }

    public var hint: String {
        let num = numericBuffer.isEmpty ? "" : "  入力: \(numericBuffer)"
        switch kind {
        case .select:
            return "ツールバーで作図ツールを選択(選択・編集はM4)"
        case .line:
            let constraint = angleConstraint == .free ? "" : " [\(angleConstraint.rawValue)拘束]"
            return anchor == nil
                ? "線分: 始点を指示" + constraint
                : "線分: 次点を指示 — 数値=距離 / x,y=相対 / ⏎確定 / esc終了" + constraint + num
        case .circle:
            return anchor == nil
                ? "円: 中心を指示"
                : "円: 半径を指示(数値入力→⏎でも可)" + num
        case .text:
            return "文字: 配置位置をクリック"
        }
    }
}
