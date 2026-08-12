import Foundation
import MepCore

/// 編集操作の種類(右クリックメニュー最上段の複写・移動)
public enum EditOpKind: Sendable {
    case move   // 移動: 基準点→移動先(1回で終了)
    case copy   // 複写: 基準点→配置先(escまで連続配置)

    public var label: String {
        switch self {
        case .move: return "移動"
        case .copy: return "複写"
        }
    }
}

/// 移動・複写の状態機械(UI非依存・ユニットテスト対象)。
/// 基準点→目標点の2クリックで確定。複写は連続配置に対応する。
/// 数値入力にも対応: "dx,dy"=相対移動量、単独数値=カーソル方向へ指定距離。
public final class EditOperation {

    public enum Phase: Equatable, Sendable {
        case idle
        case awaitingBase    // 基準点待ち
        case awaitingTarget  // 目標点待ち
    }

    public private(set) var phase: Phase = .idle
    public private(set) var kind: EditOpKind = .move
    public private(set) var basePoint: Vec2?
    public private(set) var numericBuffer = ""
    /// 数値入力の距離指定で使う「最後のカーソル位置」
    public private(set) var lastCursor: Vec2 = .zero

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// 操作を開始する(選択が空なら開始しない)
    public func begin(_ kind: EditOpKind, hasSelection: Bool) {
        guard hasSelection else { return }
        self.kind = kind
        phase = .awaitingBase
        basePoint = nil
        numericBuffer = ""
    }

    public func cancel() {
        phase = .idle
        basePoint = nil
        numericBuffer = ""
    }

    /// クリック処理。移動量が確定したらdeltaを返す(呼び出し側がコマンド実行)。
    /// 複写は確定後もawaitingTargetに留まり連続配置できる。移動は確定で終了する。
    public func click(at p: Vec2) -> Vec2? {
        numericBuffer = ""
        switch phase {
        case .idle:
            return nil
        case .awaitingBase:
            basePoint = p
            phase = .awaitingTarget
            return nil
        case .awaitingTarget:
            guard let base = basePoint else { return nil }
            let delta = p - base
            if kind == .move {
                phase = .idle
                basePoint = nil
            }
            // 複写: 基準点は変えず、次のクリックでも同じ基準から配置できる
            return delta
        }
    }

    /// プレビュー用の移動量(基準点が決まっていれば cursor - base)
    public func previewDelta(cursor: Vec2) -> Vec2? {
        lastCursor = cursor
        guard phase == .awaitingTarget, let base = basePoint else { return nil }
        return cursor - base
    }

    // MARK: - 数値入力("dx,dy"=相対 / 単独数値=カーソル方向へ距離)

    /// キー入力。処理した場合true。⏎で確定したdeltaはonCommitで返す
    @discardableResult
    public func keyInput(_ character: Character, onCommit: (Vec2) -> Void) -> Bool {
        guard phase == .awaitingTarget else { return false }
        if character.isNumber || character == "." || character == "," || character == "-" {
            numericBuffer.append(character)
            return true
        }
        if character == "\r" || character == "\n" {
            if let delta = parseNumericDelta() {
                if kind == .move {
                    phase = .idle
                    basePoint = nil
                }
                numericBuffer = ""
                onCommit(delta)
            } else {
                numericBuffer = ""
            }
            return true
        }
        if character == "\u{7F}" || character == "\u{08}" {  // delete/backspace
            if !numericBuffer.isEmpty {
                numericBuffer.removeLast()
                return true
            }
        }
        return false
    }

    private func parseNumericDelta() -> Vec2? {
        guard let base = basePoint, !numericBuffer.isEmpty else { return nil }
        let comps = numericBuffer.split(separator: ",").map(String.init)
        if comps.count == 2, let dx = Double(comps[0]), let dy = Double(comps[1]) {
            return Vec2(dx, dy)
        }
        if comps.count == 1, let dist = Double(comps[0]), abs(dist) > 0.001 {
            let dir = lastCursor - base
            let len = dir.length
            guard len > 1e-9 else { return nil }
            return dir * (dist / len)
        }
        return nil
    }

    // MARK: - ステータスヒント

    public var hint: String {
        let num = numericBuffer.isEmpty ? "" : "  入力: \(numericBuffer)"
        switch phase {
        case .idle:
            return ""
        case .awaitingBase:
            return "\(kind.label): 基準点を指示"
        case .awaitingTarget:
            let cont = kind == .copy ? "(クリックで連続配置 / esc終了)" : ""
            return "\(kind.label): \(kind == .move ? "移動先" : "配置先")を指示\(cont) — 数値=距離 / x,y=相対 / ⏎確定" + num
        }
    }
}
