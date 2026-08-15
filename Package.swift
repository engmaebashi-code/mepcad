// swift-tools-version: 5.9
// MepCad — macOS向け 空調・衛生設備用 2D CAD
import PackageDescription

let package = Package(
    name: "mepcad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MepCad", targets: ["MepCad"]),
        .library(name: "MepCore", targets: ["MepCore"]),
    ],
    targets: [
        // 幾何・エンティティ・ドキュメント・Undo(プラットフォーム非依存)
        .target(name: "MepCore"),
        // JWW/DXF/ネイティブ形式(M2でJwwReaderを実装)
        .target(name: "MepFormats", dependencies: ["MepCore"]),
        // 設備マスタ(配管の用途・管種・呼び径)と材料集計。マスタの源泉はCSV(M6.0)
        .target(name: "MepData",
                dependencies: ["MepCore"],
                resources: [.copy("Resources")]),
        // ビューポート・表示リスト・Core Graphics描画
        .target(name: "MepRender", dependencies: ["MepCore"]),
        // 入力ツール・スナップエンジン
        .target(name: "MepTools", dependencies: ["MepCore", "MepRender"]),
        // アプリ本体(SwiftUI + AppKitキャンバス)
        .executableTarget(
            name: "MepCad",
            dependencies: ["MepCore", "MepFormats", "MepData", "MepRender", "MepTools"]
        ),
        .testTarget(name: "MepCoreTests", dependencies: ["MepCore"]),
        .testTarget(
            name: "MepFormatsTests",
            dependencies: ["MepFormats", "MepCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MepDataTests", dependencies: ["MepData", "MepCore"]),
        .testTarget(name: "MepToolsTests", dependencies: ["MepTools", "MepCore"]),
    ]
)
