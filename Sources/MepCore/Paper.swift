import Foundation

// MARK: - 用紙サイズ(M4.10)
//
// Jw_cadと同じくA判の横置きを基準にする。rawValueはJWWヘッダの用紙コード
// (メモ文字列直後のDWORD。0=A0 … 4=A4。サンプル4図面の実バイトで検証)と一致させる。
// 2A以上・特殊サイズ(10m等)はv1では扱わない(読めない場合は既定にフォールバック)。

public enum PaperSize: Int, CaseIterable, Codable, Sendable {
    case a0 = 0
    case a1 = 1
    case a2 = 2
    case a3 = 3
    case a4 = 4

    public var label: String {
        switch self {
        case .a0: return "A0"
        case .a1: return "A1"
        case .a2: return "A2"
        case .a3: return "A3"
        case .a4: return "A4"
        }
    }

    /// 横置きの紙面サイズ(mm)
    public var widthMm: Double {
        switch self {
        case .a0: return 1189
        case .a1: return 841
        case .a2: return 594
        case .a3: return 420
        case .a4: return 297
        }
    }

    public var heightMm: Double {
        switch self {
        case .a0: return 841
        case .a1: return 594
        case .a2: return 420
        case .a3: return 297
        case .a4: return 210
        }
    }

    /// JWWヘッダの用紙コードから(0〜4以外=対応外はnil)
    public init?(jwwCode: Int) {
        self.init(rawValue: jwwCode)
    }
}

// MARK: - Documentの用紙・縮尺

extension Document {

    /// 書込グループの縮尺分母(1/50なら50)
    public var currentScale: Double {
        groups[current.group].scale
    }

    /// 「1/50」形式の縮尺表記(書込グループ)
    public var currentScaleLabel: String {
        groups[current.group].scaleLabel
    }

    /// 用紙枠(ワールド=実寸mm)。用紙中心=原点(JWW座標系と同じ)。
    /// 実寸幅 = 紙面mm × 書込グループの縮尺分母
    public var paperFrame: BBox {
        let w = paperSize.widthMm * currentScale
        let h = paperSize.heightMm * currentScale
        return BBox(minX: -w / 2, minY: -h / 2, maxX: w / 2, maxY: h / 2)
    }
}
