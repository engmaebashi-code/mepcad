import XCTest
@testable import MepFormats
@testable import MepCore

/// JS版v16パーサの解析結果(expected.json)とSwift移植版の出力を突合する回帰テスト。
///
/// 使い方: サンプルJWWファイル(1階空調設備.jww 等)を
///   Tests/MepFormatsTests/Fixtures/
/// にコピーしてから ⌘U。ファイルが無い項目はスキップされる。
final class JwwParserFixtureTests: XCTestCase {

    struct Expected: Decodable {
        let version: UInt32
        let lineCount: Int
        let arcCount: Int
        let solidCount: Int
        let textCount: Int
        let lineBBox: [Double]
        let firstLines: [Double]
        let firstTexts: [String]
        let scales: [Double]
    }

    private func fixturesURL() throws -> URL {
        // resources: .copy("Fixtures") でバンドルに入る
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixturesフォルダがバンドルにありません")
        }
        return url
    }

    func testAgainstJsParserResults() throws {
        let fixtures = try fixturesURL()
        let expectedData = try Data(contentsOf: fixtures.appendingPathComponent("expected.json"))
        let expected = try JSONDecoder().decode([String: Expected].self, from: expectedData)

        var tested = 0
        for (fileName, exp) in expected.sorted(by: { $0.key < $1.key }) {
            let jwwURL = fixtures.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: jwwURL.path) else {
                print("skip(ファイルなし): \(fileName)")
                continue
            }
            tested += 1
            let data = try Data(contentsOf: jwwURL)
            let start = Date()
            let drawing = try JwwParser(data: data).parse()
            let elapsed = Date().timeIntervalSince(start)
            print("\(fileName): 線\(drawing.lines.count) 弧\(drawing.arcs.count) ソリッド\(drawing.solids.count) 字\(drawing.texts.count) — \(Int(elapsed * 1000))ms")

            XCTAssertEqual(drawing.version, exp.version, "\(fileName): version")
            XCTAssertEqual(drawing.lines.count, exp.lineCount, "\(fileName): 線分数")
            XCTAssertEqual(drawing.arcs.count, exp.arcCount, "\(fileName): 円弧数")
            XCTAssertEqual(drawing.solids.count, exp.solidCount, "\(fileName): ソリッド数")
            XCTAssertEqual(drawing.texts.count, exp.textCount, "\(fileName): 文字数")
            XCTAssertEqual(drawing.scales, exp.scales, "\(fileName): 縮尺")

            // 先頭3本の線分座標(順序も含めた移植の忠実性チェック)
            for i in 0..<min(3, drawing.lines.count) {
                let l = drawing.lines[i]
                XCTAssertEqual(l.x1, exp.firstLines[i * 4], accuracy: 0.001, "\(fileName): line\(i).x1")
                XCTAssertEqual(l.y1, exp.firstLines[i * 4 + 1], accuracy: 0.001, "\(fileName): line\(i).y1")
                XCTAssertEqual(l.x2, exp.firstLines[i * 4 + 2], accuracy: 0.001, "\(fileName): line\(i).x2")
                XCTAssertEqual(l.y2, exp.firstLines[i * 4 + 3], accuracy: 0.001, "\(fileName): line\(i).y2")
            }

            // 先頭3件の文字(Shift-JISデコード確認)
            for i in 0..<min(3, drawing.texts.count) {
                XCTAssertEqual(drawing.texts[i].text, exp.firstTexts[i], "\(fileName): text\(i)")
            }

            // 線分のみのBBox(JS版と同じ計算)
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for l in drawing.lines {
                minX = min(minX, min(l.x1, l.x2)); maxX = max(maxX, max(l.x1, l.x2))
                minY = min(minY, min(l.y1, l.y2)); maxY = max(maxY, max(l.y1, l.y2))
            }
            XCTAssertEqual(minX, exp.lineBBox[0], accuracy: 1.0, "\(fileName): bbox.minX")
            XCTAssertEqual(minY, exp.lineBBox[1], accuracy: 1.0, "\(fileName): bbox.minY")
            XCTAssertEqual(maxX, exp.lineBBox[2], accuracy: 1.0, "\(fileName): bbox.maxX")
            XCTAssertEqual(maxY, exp.lineBBox[3], accuracy: 1.0, "\(fileName): bbox.maxY")

            // 性能目標: 2秒以内(設計書§8)。Debugビルドは未最適化のため緩和
            #if DEBUG
            XCTAssertLessThan(elapsed, 15.0, "\(fileName): 解析時間(Debug)")
            #else
            XCTAssertLessThan(elapsed, 2.0, "\(fileName): 解析時間")
            #endif
        }
        try XCTSkipIf(tested == 0, "サンプルJWWファイルがFixturesにありません(READMEの手順でコピーしてください)")
    }

    /// M4.2: レイヤ/グループ状態の読み取り(グループブロック方式)の妥当性検証。
    /// 旧実装は位置推定がズレて選択機能を全滅させたため、実ファイルでの検証を必須にする。
    func testLayerStatesFromFixtures() throws {
        let fixtures = try fixturesURL()
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jww" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(files.isEmpty, "サンプルJWWファイルがありません")

        for url in files {
            let name = url.lastPathComponent
            let drawing = try JwwParser(data: Data(contentsOf: url)).parse()

            // 状態が読めていること・値が正規範囲(0〜3)であること
            let layerStates = try XCTUnwrap(drawing.layerStates, "\(name): レイヤ状態が読めない")
            let groupStates = try XCTUnwrap(drawing.groupStates, "\(name): グループ状態が読めない")
            XCTAssertEqual(layerStates.count, 256, name)
            XCTAssertTrue(layerStates.allSatisfy { $0 <= 3 }, "\(name): レイヤ状態に範囲外の値")
            XCTAssertTrue(groupStates.allSatisfy { $0 <= 3 }, "\(name): グループ状態に範囲外の値")
            // 書込グループは高々1つ
            XCTAssertLessThanOrEqual(groupStates.filter { $0 == 3 }.count, 1, name)

            // 展開して「見える」「選択できる」が成立すること(安全網に頼らずに)
            let doc = Document()
            let stats = JwwReader.importDrawingWithStats(drawing, into: doc)
            XCTAssertFalse(stats.visibilityRelaxed, "\(name): 表示の安全網が発動(状態解釈が怪しい)")
            XCTAssertFalse(stats.locksRelaxed, "\(name): ロックの安全網が発動(状態解釈が怪しい)")
            XCTAssertTrue(doc.entities.contains { doc.isVisible($0.layer) }, "\(name): 見える要素が無い")
            XCTAssertTrue(doc.entities.contains { doc.isSelectable($0.layer) }, "\(name): 選択できる要素が無い")
            XCTAssertTrue(doc.isSelectable(doc.current), "\(name): 書込レイヤが書込不能")
        }
    }
}
