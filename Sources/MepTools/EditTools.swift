import Foundation
import MepCore

/// 編集操作の種類(右クリックメニューから開始)
public enum EditOpKind: Sendable {
    case move        // 移動: 基準点→移動先(1回で終了)。角度プロパティで回転しながら配置
    case copy        // 複写: 基準点→配置先(escまで連続配置)。角度プロパティで回転しながら配置
    case rotate      // 回転: 基準点→方向1→方向2(または数値角)
    case rotateCopy  // 回転複写: 同上、escまで連続配置
    case mirror      // 反転: 基準線を2点指示して鏡映(移動)
    case mirrorCopy  // 反転複写: 同上、escまで別の基準線で連続
    case scale       // 拡大縮小: 基準点→倍率(数値⏎ or 参照点→距離比ドラッグ)

    public var label: String {
        switch self {
        case .move: return "移動"
        case .copy: return "複写"
        case .rotate: return "回転"
        case .rotateCopy: return "回転複写"
        case .mirror: return "反転"
        case .mirrorCopy: return "反転複写"
        case .scale: return "拡大縮小"
        }
    }

    public var isCopy: Bool { self == .copy || self == .rotateCopy || self == .mirrorCopy }
    var isRotation: Bool { self == .rotate || self == .rotateCopy }
    var isMirror: Bool { self == .mirror || self == .mirrorCopy }
    var isScale: Bool { self == .scale }
    /// 角度プロパティ(回転しながら配置)が使える操作
    public var supportsRotationProperty: Bool { self == .move || self == .copy }
}

/// 編集操作の確定内容(呼び出し側がコマンドに変換する)
public enum EditTransform: Equatable, Sendable {
    case translate(Vec2)
    /// 角度はラジアン・反時計回り正
    case rotate(center: Vec2, angle: Double)
    /// 基準点まわりにangle回転してからdelta移動(回転しながら配置)
    case moveRotated(base: Vec2, delta: Vec2, angle: Double)
    /// 基準線(a-b)に対する鏡映
    case mirror(a: Vec2, b: Vec2)
    /// 基準点まわりの等倍率拡大縮小(factor>0)。ブロックは配置のscaleに合成される
    case scale(center: Vec2, factor: Double)
}

extension Entity {
    /// EditTransformを適用したコピーを返す(idは維持)
    public func applying(_ transform: EditTransform) -> Entity {
        switch transform {
        case .translate(let delta):
            return translated(by: delta)
        case .rotate(let center, let angle):
            return rotated(around: center, byRadians: angle)
        case .moveRotated(let base, let delta, let angle):
            return rotated(around: base, byRadians: angle).translated(by: delta)
        case .mirror(let a, let b):
            return mirrored(acrossLineFrom: a, to: b)
        case .scale(let center, let factor):
            return scaled(by: factor, around: center)
        }
    }
}

/// 移動・複写・回転の状態機械(UI非依存・ユニットテスト対象)。
/// 移動/複写: 基準点→目標点。角度拘束パレット(自由/90/45/15°)が方向に効く。
/// 回転: 基準点→方向1→方向2(2方向のなす角)または数値⏎で角度指定(度・反時計回り正)。
public final class EditOperation {

    public enum Phase: Equatable, Sendable {
        case idle
        case awaitingBase         // 基準点待ち
        case awaitingTarget       // 移動先/配置先待ち(移動・複写)
        case awaitingAngleRef     // 回転の方向1待ち
        case awaitingAngleTarget  // 回転の方向2待ち
        case awaitingMirrorA      // 反転の基準線1点目待ち
        case awaitingMirrorB      // 反転の基準線2点目待ち
        case awaitingScaleRef     // 拡大縮小の参照点待ち(数値⏎でも確定可)
        case awaitingScaleTarget  // 拡大縮小の目標点待ち(距離比=倍率)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var kind: EditOpKind = .move
    public private(set) var basePoint: Vec2?
    /// 回転の方向1の方位角(rad)
    public private(set) var referenceAngle: Double?
    public private(set) var numericBuffer = ""
    /// 数値入力の距離指定で使う「最後のカーソル位置」
    public private(set) var lastCursor: Vec2 = .zero
    /// 角度拘束(ツールバーのパレットと連動。移動・複写の方向/反転の基準線に効く)
    public var angleConstraint: AngleConstraint = .free
    /// 移動・複写の角度プロパティ(度・反時計回り正)。0以外で「回転しながら配置」
    public var rotationDegrees: Double = 0
    /// 反転の基準線1点目
    public private(set) var mirrorA: Vec2?
    /// 拡大縮小の参照距離(基準点→参照点。カーソル距離÷これ=倍率)
    public private(set) var scaleRefDistance: Double?

    public init() {}

    public var isActive: Bool { phase != .idle }

    /// 操作を開始する(選択が空なら開始しない)
    public func begin(_ kind: EditOpKind, hasSelection: Bool) {
        guard hasSelection else { return }
        self.kind = kind
        phase = kind.isMirror ? .awaitingMirrorA : .awaitingBase
        basePoint = nil
        referenceAngle = nil
        mirrorA = nil
        scaleRefDistance = nil
        rotationDegrees = 0
        numericBuffer = ""
    }

    public func cancel() {
        phase = .idle
        basePoint = nil
        referenceAngle = nil
        mirrorA = nil
        scaleRefDistance = nil
        numericBuffer = ""
    }

    /// クリック処理。変換が確定したら返す(呼び出し側がコマンド実行)。
    /// 複写系は確定後も継続し連続配置できる。移動・回転は確定で終了する。
    public func click(at p: Vec2) -> EditTransform? {
        numericBuffer = ""
        switch phase {
        case .idle:
            return nil

        case .awaitingBase:
            basePoint = p
            if kind.isRotation {
                phase = .awaitingAngleRef
            } else if kind.isScale {
                phase = .awaitingScaleRef
            } else {
                phase = .awaitingTarget
            }
            return nil

        case .awaitingTarget:
            guard let base = basePoint else { return nil }
            let target = constrained(from: base, to: p)
            let delta = target - base
            let result: EditTransform = abs(rotationDegrees) > 1e-9
                ? .moveRotated(base: base, delta: delta, angle: rotationDegrees * .pi / 180)
                : .translate(delta)
            if kind == .move {
                finishIfSingleShot()
            }
            return result

        case .awaitingAngleRef:
            guard let base = basePoint else { return nil }
            let d = p - base
            guard d.length > 1e-9 else { return nil }
            referenceAngle = atan2(d.y, d.x)
            phase = .awaitingAngleTarget
            return nil

        case .awaitingAngleTarget:
            guard let base = basePoint, let ref = referenceAngle else { return nil }
            let d = p - base
            guard d.length > 1e-9 else { return nil }
            let angle = normalized(atan2(d.y, d.x) - ref)
            if kind == .rotate {
                finishIfSingleShot()
            }
            return .rotate(center: base, angle: angle)

        case .awaitingMirrorA:
            mirrorA = p
            phase = .awaitingMirrorB
            return nil

        case .awaitingMirrorB:
            guard let a = mirrorA else { return nil }
            let b = constrained(from: a, to: p)
            guard a.distance(to: b) > 1e-9 else { return nil }
            if kind == .mirror {
                finishIfSingleShot()
            } else {
                // 反転複写: 次は別の基準線を指示できるよう1点目からやり直す
                mirrorA = nil
                phase = .awaitingMirrorA
            }
            return .mirror(a: a, b: b)

        case .awaitingScaleRef:
            guard let base = basePoint else { return nil }
            let dist = base.distance(to: p)
            guard dist > 1e-9 else { return nil }
            scaleRefDistance = dist
            phase = .awaitingScaleTarget
            return nil

        case .awaitingScaleTarget:
            guard let base = basePoint, let ref = scaleRefDistance, ref > 1e-9 else { return nil }
            let dist = base.distance(to: p)
            guard dist > 1e-9 else { return nil }
            finishIfSingleShot()
            return .scale(center: base, factor: dist / ref)
        }
    }

    /// プレビュー用の変換(基準点などが決まっていれば)
    public func previewTransform(cursor: Vec2) -> EditTransform? {
        lastCursor = cursor
        switch phase {
        case .awaitingTarget:
            guard let base = basePoint else { return nil }
            let target = constrained(from: base, to: cursor)
            let delta = target - base
            if abs(rotationDegrees) > 1e-9 {
                return .moveRotated(base: base, delta: delta, angle: rotationDegrees * .pi / 180)
            }
            return .translate(delta)
        case .awaitingAngleTarget:
            guard let base = basePoint, let ref = referenceAngle else { return nil }
            let d = cursor - base
            guard d.length > 1e-9 else { return nil }
            return .rotate(center: base, angle: normalized(atan2(d.y, d.x) - ref))
        case .awaitingMirrorB:
            guard let a = mirrorA else { return nil }
            let b = constrained(from: a, to: cursor)
            guard a.distance(to: b) > 1e-9 else { return nil }
            return .mirror(a: a, b: b)
        case .awaitingScaleTarget:
            guard let base = basePoint, let ref = scaleRefDistance, ref > 1e-9 else { return nil }
            let dist = base.distance(to: cursor)
            guard dist > 1e-9 else { return nil }
            return .scale(center: base, factor: dist / ref)
        default:
            return nil
        }
    }

    // MARK: - 数値入力

    /// 移動・複写: "dx,dy"=相対 / 単独数値=拘束方向へ距離。
    /// 回転・回転複写: 単独数値=角度(度・反時計回り正。負で時計回り)。
    @discardableResult
    public func keyInput(_ character: Character, onCommit: (EditTransform) -> Void) -> Bool {
        let capable: Bool
        switch phase {
        case .awaitingTarget:
            capable = true
        case .awaitingAngleRef, .awaitingAngleTarget:
            capable = true   // 回転は方向1の指示前でも数値角で確定できる
        case .awaitingScaleRef, .awaitingScaleTarget:
            capable = true   // 拡大縮小は参照点の指示前でも数値倍率で確定できる
        default:
            capable = false
        }
        guard capable else { return false }

        if character.isNumber || character == "." || character == "," || character == "-" {
            numericBuffer.append(character)
            return true
        }
        if character == "\r" || character == "\n" {
            if let transform = parseNumeric() {
                if kind == .move || kind == .rotate || kind == .scale {
                    finishIfSingleShot()
                }
                numericBuffer = ""
                onCommit(transform)
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

    private func parseNumeric() -> EditTransform? {
        guard let base = basePoint, !numericBuffer.isEmpty else { return nil }
        let comps = numericBuffer.split(separator: ",").map(String.init)

        if kind.isRotation {
            guard comps.count == 1, let degrees = Double(comps[0]), abs(degrees) > 1e-9 else { return nil }
            return .rotate(center: base, angle: degrees * .pi / 180)
        }

        if kind.isScale {
            // 単独数値=倍率(正のみ。例 2 / 0.5 / 1.25)
            guard comps.count == 1, let factor = Double(comps[0]), factor > 1e-6 else { return nil }
            return .scale(center: base, factor: factor)
        }

        var delta: Vec2?
        if comps.count == 2, let dx = Double(comps[0]), let dy = Double(comps[1]) {
            delta = Vec2(dx, dy)
        } else if comps.count == 1, let dist = Double(comps[0]), abs(dist) > 0.001 {
            let target = constrained(from: base, to: lastCursor)
            let dir = target - base
            let len = dir.length
            guard len > 1e-9 else { return nil }
            delta = dir * (dist / len)
        }
        guard let delta else { return nil }
        if abs(rotationDegrees) > 1e-9 {
            return .moveRotated(base: base, delta: delta, angle: rotationDegrees * .pi / 180)
        }
        return .translate(delta)
    }

    // MARK: - 内部

    private func finishIfSingleShot() {
        phase = .idle
        basePoint = nil
        referenceAngle = nil
        mirrorA = nil
        scaleRefDistance = nil
    }

    /// 角度拘束(パレット連動)。移動・複写の方向を丸める
    private func constrained(from a: Vec2, to p: Vec2) -> Vec2 {
        guard let step = angleConstraint.step else { return p }
        let d = p - a
        let len = d.length
        guard len > 1e-9 else { return p }
        let snapped = (atan2(d.y, d.x) / step).rounded() * step
        return Vec2(a.x + cos(snapped) * len, a.y + sin(snapped) * len)
    }

    /// -π..π に正規化
    private func normalized(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }

    // MARK: - ステータスヒント

    public var hint: String {
        let num = numericBuffer.isEmpty ? "" : "  入力: \(numericBuffer)"
        let constraint = (!kind.isRotation && angleConstraint != .free)
            ? " [\(angleConstraint.rawValue)拘束]" : ""
        switch phase {
        case .idle:
            return ""
        case .awaitingBase:
            if kind.isScale {
                return "\(kind.label): 基準点(拡大縮小の中心)を指示"
            }
            return kind.isRotation
                ? "\(kind.label): 基準点(回転中心)を指示"
                : "\(kind.label): 基準点を指示"
        case .awaitingTarget:
            let cont = kind == .copy ? "(クリックで連続配置 / esc終了)" : ""
            let rot = abs(rotationDegrees) > 1e-9 ? String(format: " [回転%.0f°]", rotationDegrees) : ""
            return "\(kind.label)\(rot): \(kind == .move ? "移動先" : "配置先")を指示\(cont) — 数値=距離 / x,y=相対 / ⏎確定" + constraint + num
        case .awaitingAngleRef:
            return "\(kind.label): 方向1を指示(または角度を数値⏎ 例: 90=反時計回り90°)" + num
        case .awaitingAngleTarget:
            let cont = kind == .rotateCopy ? "(クリックで連続配置 / esc終了)" : ""
            return "\(kind.label): 方向2を指示\(cont) — 数値⏎=角度(度)" + num
        case .awaitingMirrorA:
            return "\(kind.label): 基準線の1点目を指示(この線に対して鏡映)"
        case .awaitingMirrorB:
            let cont = kind == .mirrorCopy ? "(確定後、別の基準線で連続 / esc終了)" : ""
            return "\(kind.label): 基準線の2点目を指示\(cont)" + constraint
        case .awaitingScaleRef:
            return "\(kind.label): 参照点を指示(基準点からの距離が倍率1になる)— または倍率を数値⏎ 例: 2 / 0.5" + num
        case .awaitingScaleTarget:
            return "\(kind.label): 目標点を指示(参照距離との比が倍率。ゴーストで確認)— 数値⏎=倍率" + num
        }
    }
}
