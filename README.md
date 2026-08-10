# MepCad(仮称)

macOS向け 空調・衛生(機械設備)用 2D CAD。

設計資料は `docs/` にあります(企画設計書・データ構造設計書・実装構成設計書・機能仕分けチェックリスト・UIモックアップ)。

## 現在の状態: Phase 1 / M1

- 5モジュール構成(MepCore / MepFormats / MepRender / MepTools / MepCad)
- キャンバス: パン(スクロール/ドラッグ)・ズーム(ピンチ/⌘スクロール、カーソル中心)・全体表示(ダブルクリック)
- 十字カーソル+ピックボックス(標準矢印は非表示)、スナップマーク(端点・中点・中心・グリッド)
- デモ図面(機械室風)を起動時に表示
- ライト/ダーク背景切替(ツールバーの月/太陽ボタン)
- Undo/Redo基盤(CommandStack)・レイヤモデル実装済み(UIはM4)

## ビルド・実行方法

1. Xcode(15以降)でこのフォルダの `Package.swift` を開く
   (Finderからフォルダごと Xcode にドロップでもOK)
2. スキームで **MepCad**、実行先に **My Mac** を選択
3. ⌘R で実行 / ⌘U でユニットテスト(MepCoreTests)

コマンドラインの場合:

```
swift run MepCad     # アプリ起動
swift test           # テスト実行
```

## GitHubへの登録(初回のみ)

GitHubで空リポジトリ `engmaebashi-code/mepcad` を作成してから:

```
cd mepcad
git init
git add -A
git commit -m "M1: プロジェクト骨組み+キャンバス操作基盤"
git branch -M main
git remote add origin https://github.com/engmaebashi-code/mepcad.git
git push -u origin main
```

## M1の確認ポイント(フィードバック募集)

- [ ] 十字カーソルとピックボックスの追従は滑らかか
- [ ] ピンチズームの感度・カーソル中心ズームの挙動は自然か
- [ ] スクロールでのパンの方向・速度は好みに合うか
- [ ] スナップマーク(オレンジ菱形)の吸着感は適切か
- [ ] ダーク背景の色味はCADとして見やすいか

## 次のマイルストーン

- M2: JwwReader移植(v16 JS→Swift)+サンプル4図面の下敷き表示
- M3: 線分・円・文字の作図+数値入力+Undo/Redo接続
- M4: レイヤパネル+選択・編集+右クリックメニュー
- M5: 保存/読込(.mepcad)+印刷 → Phase 1完了

## 既知の制限(M1)

- 作図・選択はまだできません(表示と操作感の確認が目的)
- 文字描画は簡易(サイズ・角度の精密対応はM3)
- ドラッグ=パンは仮仕様(M3で選択に割り当て直し、パンはスペース+ドラッグへ)
