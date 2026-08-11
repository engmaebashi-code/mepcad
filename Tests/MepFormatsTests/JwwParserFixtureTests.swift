import XCTest
@testable import MepFormats

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

            // 性能目標: 2秒以内(設計書§8)
            XCTAssertLessThan(elapsed, 2.0, "\(fileName): 解析時間")
        }
        try XCTSkipIf(tested == 0, "サンプルJWWファイルがFixturesにありません(READMEの手順でコピーしてください)")
    }
}
