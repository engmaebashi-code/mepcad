import Foundation

/// 線種テーブル(Jw_cad標準の9種に準拠)。
/// 内部コードは0始まり: JWWのlntp(1〜9)− 1 に一致させ、往復変換を無劣化にする。
/// 名前とパターンを一箇所に置き、レンダラとUI(メニューのプレビュー)が同じ定義を使う。
public enum LineTypeTable {
    public static let count = 9

    public static let names: [String] = [
        "実線",       // 0 (JWW lntp1)
        "点線1",      // 1 (lntp2)
        "点線2",      // 2 (lntp3)
        "点線3",      // 3 (lntp4)
        "一点鎖1",    // 4 (lntp5)
        "一点鎖2",    // 5 (lntp6)
        "二点鎖1",    // 6 (lntp7)
        "二点鎖2",    // 7 (lntp8)
        "補助線種",   // 8 (lntp9) — Jw_cadでは印刷されない線種(印刷対応はM5で考慮)
    ]

    /// 破線パターン(px。[描画長, 空き, ...] 空配列=実線)
    public static let dashPatterns: [[Double]] = [
        [],                        // 実線
        [1.5, 2.5],                // 点線1(細かい点)
        [3.5, 3],                  // 点線2
        [7, 3.5],                  // 点線3
        [11, 3, 2, 3],             // 一点鎖1
        [17, 4, 3, 4],             // 一点鎖2
        [11, 3, 2, 3, 2, 3],       // 二点鎖1
        [17, 4, 3, 4, 3, 4],       // 二点鎖2
        [1, 3.5],                  // 補助線種(まばらな点)
    ]

    public static func name(_ index: Int) -> String {
        guard index >= 0, index < names.count else { return "線種\(index)" }
        return names[index]
    }

    public static func dashPattern(_ index: Int) -> [Double] {
        guard index >= 0, index < dashPatterns.count else { return [] }
        return dashPatterns[index]
    }

    /// 補助線種の内部コード
    public static let auxiliaryLineType = 8
    /// 補助線色のパレット番号(Jw_cadの補助線色に対応)
    public static let auxiliaryColorIndex = 9
}

extension Entity {
    /// 補助線か(補助線種または補助線色)。Jw_cadでは印刷されない作業用の線で、
    /// 表示/非表示をまとめて切り替えられる(Document.showAuxiliary)。
    public var isAuxiliary: Bool {
        style.lineType == LineTypeTable.auxiliaryLineType
            || style.colorIndex == LineTypeTable.auxiliaryColorIndex
    }
}
