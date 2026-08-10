import Foundation
import MepCore

/// JWW(Jw_cad)読込 — M2で実装。
/// 移植元: JWWビューワー v16パーサ(JavaScript)。検証結果はdocs/データ構造設計書v0.2 §8参照。
/// 実装予定の要点:
/// - ヘッダ "JwwData" 判定、version(700=ver.7)取得
/// - MFCシリアライズの動的クラス登録テーブル解析(findClassDef相当)
/// - CDataSen(線分)/CDataEnko(円弧)/CDataMoji(文字)/CDataSolid/CDataSunpou(寸法)
/// - Shift-JIS→String変換
/// - グループ別縮尺、レイヤ状態テーブル(位置推定の既知課題あり)
public enum JwwReaderError: Error {
    case notImplemented
    case invalidHeader
}

public struct JwwReader {
    public init() {}

    public func read(url: URL, into document: Document) throws {
        throw JwwReaderError.notImplemented  // M2
    }
}
