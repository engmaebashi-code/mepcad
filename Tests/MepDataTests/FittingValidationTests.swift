import XCTest
@testable import MepData
@testable import MepCore

/// 継手マスタの妥当性検査・型番(M7)
final class FittingValidationTests: XCTestCase {

    /// 同梱の標準マスタは破綻ゼロ(CSVを触ったときの回帰止め)
    func testStandardMasterHasNoIssues() {
        let issues = FittingMaster.standard.validate(with: PipeMaster.standard)
        XCTAssertTrue(issues.isEmpty,
                      "fittings.csvに問題があります:\n"
                      + issues.map(\.description).joined(separator: "\n"))
    }

    /// A寸法が受口深さより小さい行は弾く(受口が継手からはみ出す=幾何として成立しない)
    func testDetectsSocketLongerThanA() {
        let m = FittingMaster(csv: """
        # test
        DV,elbow90,100,40,50,124
        """)
        XCTAssertEqual(m.issues.count, 1)
        XCTAssertTrue(m.issues[0].message.contains("受口深さ"))
        XCTAssertEqual(m.issues[0].line, 2)
    }

    /// 非正の寸法・列不足・数値でない値
    func testDetectsBrokenValues() {
        let m = FittingMaster(csv: """
        DV,elbow90,100,0,50,124
        DV,elbow45,100,60,0,124
        DV,tee,100
        DV,cap,100,x,50,124
        """)
        XCTAssertEqual(m.issues.count, 4)   // A非正 / 受口深さ非正 / 列不足 / 数値不正
        XCTAssertTrue(m.issues.contains { $0.message.contains("列が足りません") })
        XCTAssertTrue(m.issues.contains { $0.message.contains("数値として読めません") })
    }

    /// キーの重複を報告する(先の行が使われる)
    func testDetectsDuplicateKey() {
        let m = FittingMaster(csv: """
        DV,elbow90,100,112,50,124
        DV,elbow90,100,999,50,124
        """)
        XCTAssertEqual(m.issues.count, 1)
        XCTAssertTrue(m.issues[0].message.contains("重複"))
        XCTAssertEqual(m.row(series: "DV", kind: "elbow90", size: "100")?.a, 112)
    }

    /// 受口外径が管外径以下なら配管マスタとの突き合わせで見つかる
    func testDetectsSocketThinnerThanPipe() {
        let m = FittingMaster(csv: "DV,elbow90,100,112,50,100")   // VP100の外径114より小さい
        XCTAssertTrue(m.issues.isEmpty)                            // 単体では気づけない
        let issues = m.validate(with: PipeMaster.standard)
        XCTAssertTrue(issues.contains { $0.message.contains("管外径") })
    }

    /// 型番(7列目)が読める。省略しても従来どおり読める
    func testPartNumberColumn() {
        XCTAssertEqual(FittingMaster.standard.row(series: "DV", kind: "elbow90", size: "100")?
                        .partNumber, "2151 DL-100")
        XCTAssertEqual(FittingMaster.standard.row(series: "HI", kind: "tee", size: "20")?
                        .partNumber, "6013 T-20")
        let legacy = FittingMaster(csv: "DV,elbow90,100,112,50,124")
        XCTAssertEqual(legacy.rows.first?.partNumber, "")
        XCTAssertEqual(legacy.rows.first?.a, 112)
    }

    /// 集計表に型番の列が出る
    func testReportWithPartNumbers() {
        let attrs = PipeAttributes(usage: "S", usageName: "汚水", material: "VP",
                                   materialLabel: "VP", size: "100", sizeLabel: "100",
                                   outerDiameter: 114, fittingSeries: "DV")
        let pipe = Entity(layer: LayerAddress(0, 0),
                          kind: .pipe(points: [Vec3(0, 0, 0), Vec3(3000, 0, 0),
                                               Vec3(3000, 3000, 0)],
                                      attrs: attrs))
        let totals = PipeAggregator.aggregate([pipe])
        XCTAssertEqual(totals.first?.series, "DV")
        let text = PipeAggregator.reportText(totals, master: FittingMaster.standard)
        XCTAssertTrue(text.contains("エルボ90°\t型番"))
        XCTAssertTrue(text.contains("2151 DL-100"))
    }
}
