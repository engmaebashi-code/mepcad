# JWW(Jw_cad)ファイル形式メモ — M8.1 書き出し実装の根拠

同梱フィクスチャ4図面(ver.700)の全バイトを Python で歩き、ヘッダ末尾=図形リスト先頭、
図形リスト末尾=ブロックリスト先頭、末尾 DWORD 0 が一致することを確認した内容。
(`Sources/MepFormats/JwwWriter.swift` はこの順序どおりに書く)

## 全体
```
"JwwData." (8) / DWORD version(700)
ヘッダ(下記) / 図形リスト: WriteCount + オブジェクト列 / ブロックリスト: WriteCount + CDataList列 / DWORD 0
```
- WriteCount: 0xFFFF未満は WORD、以上は WORD 0xFFFF + DWORD(MFC CObList と同じ)
- 文字列(CString, Unicode版 Jw_cad 7+): FF FE FF + 文字数(BYTE / FF+WORD / FF FFFF+DWORD) + UTF-16LE
- オブジェクトのクラスタグ(MFC CArchive::WriteObject):
  初出クラス = WORD 0xFFFF, WORD schema(230), WORD 名前長, 名前(ASCII)。
  2回目以降 = WORD (0x8000 | クラス番号)。番号 ≥ 0x7FFF は WORD 0x7FFF + DWORD (0x80000000|番号)。
  番号はクラス登録とオブジェクト双方が 1 から順に消費する(クラス1→オブジェクト2→次のオブジェクト3…)

## ヘッダ(ver.700)
```
CString memo / DWORD 用紙(0=A0 1=A1 2=A2 3=A3 4=A4 …) / DWORD 書込グループ
16× { DWORD グループ状態, DWORD 書込レイヤ, double 縮尺分母, DWORD プロテクト,
      16× { DWORD レイヤ状態, DWORD プロテクト } }        (状態 0=非表示 1=表示のみ 2=編集可 3=書込)
DWORD×14 dummy / DWORD×5 寸法設定 / DWORD dummy / DWORD 最大線幅(-100=1/100mm)
double×2 印刷原点 / double 印刷倍率 / DWORD 90°回転
DWORD 目盛モード / double 表示最小 / double×2 間隔 / double×2 基準点
CString×256 レイヤ名 / CString×16 グループ名
double 日影高 / double 緯度 / DWORD 9-15フラグ / double 壁日影高 / double×2 天空図
DWORD 2.5D単位 / double×3 画面倍率原点 / double×3 範囲記憶
8× { double×3, DWORD } ズーム記憶 / double×3 DWORD double×2 dummy / double 文字背景 / DWORD 文字描画
double×10 複線間隔 / double 両側複線 / 10×{DWORD 色, DWORD 幅} 画面線色
10×{DWORD, DWORD, double} 印刷線色 / 8×DWORD×4 線種2-9 / 5×DWORD×5 線種11-15 / 4×DWORD×4 線種16-19
DWORD×5 描画フラグ / DWORD×6 印刷フラグ / DWORD×5 作図時間・2.5D / double×5 / double×4 寸法既定
DWORD×2 ソリッド色
257×{DWORD, DWORD} SXF拡張色 / 257×{CString, DWORD, DWORD, double} / 33×DWORD×4 SXF線種 / 33×{CString, DWORD, double×10}
10×{double×3, DWORD} 文字種 / double×3 DWORD×2 現在文字 / double×2 DWORD 文字整理 / double×6 基準点ずれ
```

## 図形
共通 CData(15バイト): DWORD 曲線属性 / BYTE 線種 / WORD 線色 / WORD 線幅 / WORD レイヤ / WORD グループ / WORD フラグ
- CDataSen: double×4 (x1 y1 x2 y2)
- CDataEnko: double 中心x y, 半径, 開始角(rad), 円弧角(rad, 反時計), 傾き, 扁平率 / DWORD 全円フラグ
- CDataTen: double×2 / DWORD 仮点フラグ (線種100のとき DWORD コード, double 角, double 倍率)
- CDataMoji: double 始点x y 終点x y / DWORD 文字種(0=任意) / double 幅 高 間隔 / double 角度(deg) / CString フォント / CString 文字
- CDataSolid: double 点1, 点4, 点2, 点3 (線色10のとき DWORD RGB)
- CDataSunpou: CData + Sen + Moji + WORD + Sen×2 + Ten×4 (入れ子はタグなし)
- CDataBlock: double 基準点x y, 倍率x y, 回転 / DWORD 定義番号
- CDataList: CData + DWORD 番号 / DWORD 参照 / DWORD 時刻 / CString 名前 / WriteCount + オブジェクト列
座標は図寸(紙面mm)。実寸 = 座標 × 所属グループの縮尺分母。
