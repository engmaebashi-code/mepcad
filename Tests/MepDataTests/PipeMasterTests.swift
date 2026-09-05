import XCTest
@testable import MepData
@testable import MepCore

/// 配管マスタ(M6.0)のテスト
final class PipeMasterTests: XCTestCase {

    // MARK: - 同梱CSVの読込

    func testStandardMasterLoads() {
        let m = PipeMaster.standard
        XCTAssertGreaterThanOrEqual(m.usages.count, 8)
        XCTAssertGreaterThanOrEqual(m.materials.count, 8)
        XCTAssertGreaterThanOrEqual(m.sizes.count, 80)

        // 用途: 給水=青(2)実線、既定管種HIVP
        let cw = m.usage("CW")
        XCTAssertEqual(cw?.name, "給水")
        XCTAssertEqual(cw?.colorIndex, 2)
        XCTAssertEqual(cw?.lineType, 0)
        XCTAssertEqual(cw?.defaultMaterial, "HIVP")

        // 代表的な外径(JIS)
        XCTAssertEqual(m.size(material: "VP", size: "50")?.outerDiameter ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(m.size(material: "SGP-W", size: "50")?.outerDiameter ?? 0, 60.5, accuracy: 0.01)
        XCTAssertEqual(m.size(material: "SGP-W", size: "50")?.label, "50A")
        XCTAssertEqual(m.size(material: "CUP", size: "20")?.outerDiameter ?? 0, 22.22, accuracy: 0.01)
        XCTAssertEqual(m.size(material: "SU", size: "20")?.label, "20Su")

        // 管種別の呼び径はマスタ記載順(細→太)
        let vp = m.sizes(for: "VP")
        XCTAssertEqual(vp.first?.size, "13")
        XCTAssertEqual(vp.last?.size, "200")
    }

    func testCSVParsingSkipsCommentsAndBlank() {
        let m = PipeMaster(
            usagesCSV: "# comment\n\nCW,給水,2,0,HIVP\n",
            materialsCSV: "HIVP,耐衝撃管,HIVP\n",
            sizesCSV: "HIVP,20,20,26\nHIVP,25,25,32\n")
        XCTAssertEqual(m.usages.count, 1)
        XCTAssertEqual(m.sizes(for: "HIVP").count, 2)
        XCTAssertNil(m.usage("HW"))
    }

    // MARK: - 材料集計

    private func pipe(_ points: [Vec2], usage: String = "給水",
                      material: String = "HIVP", size: String = "20") -> Entity {
        Entity(layer: LayerAddress(0, 0),
               kind: .pipe(points: points.map { Vec3($0, z: 0) },
                           attrs: PipeAttributes(usage: usage, usageName: usage,
                                                 material: material, materialLabel: material,
                                                 size: size, sizeLabel: size,
                                                 outerDiameter: 26)))
    }

    func testAggregateGroupsAndSums() {
        let entities = [
            pipe([Vec2(0, 0), Vec2(3000, 0)]),                       // 給水HIVP20: 3m
            pipe([Vec2(0, 0), Vec2(0, 2000), Vec2(1000, 2000)]),     // 給水HIVP20: 3m
            pipe([Vec2(0, 0), Vec2(5000, 0)], size: "25"),           // 給水HIVP25: 5m
            Entity(layer: LayerAddress(0, 0), kind: .line(a: Vec2(0, 0), b: Vec2(9999, 0))),
        ]
        let totals = PipeAggregator.aggregate(entities)
        XCTAssertEqual(totals.count, 2)
        let t20 = totals.first { $0.sizeLabel == "20" }
        XCTAssertEqual(t20?.totalLengthMm ?? 0, 6000, accuracy: 1e-9)
        XCTAssertEqual(t20?.lengthMeters ?? 0, 6.0, accuracy: 1e-9)
        XCTAssertEqual(t20?.runCount, 2)
        let t25 = totals.first { $0.sizeLabel == "25" }
        XCTAssertEqual(t25?.lengthMeters ?? 0, 5.0, accuracy: 1e-9)
    }

    /// 0.1m単位の切り上げ(拾いの慣例)
    func testLengthRoundsUp() {
        let totals = PipeAggregator.aggregate([pipe([Vec2(0, 0), Vec2(3210, 0)])])
        XCTAssertEqual(totals[0].lengthMeters, 3.3, accuracy: 1e-9)
    }

    func testReportText() {
        let text = PipeAggregator.reportText(
            PipeAggregator.aggregate([pipe([Vec2(0, 0), Vec2(2000, 0)])]))
        XCTAssertTrue(text.contains("用途\t管種\t呼び径\t延長(m)\t本数\tエルボ90°\tエルボ45°"))
        XCTAssertTrue(text.contains("給水\tHIVP\t20\t2.0\t1\t0\t0"))
    }

    /// 立管の延長も集計に含まれる(M6.2)
    func testAggregateIncludesRiserLength() {
        let e = Entity(layer: LayerAddress(0, 0),
                       kind: .pipe(points: [Vec3(0, 0, 0), Vec3(2000, 0, 0),
                                            Vec3(2000, 0, 3000), Vec3(2000, 1000, 3000)],
                                   attrs: PipeAttributes(usageName: "給水", materialLabel: "HIVP",
                                                         sizeLabel: "20")))
        let totals = PipeAggregator.aggregate([e])
        XCTAssertEqual(totals[0].totalLengthMm, 6000, accuracy: 1e-9)   // 2000+3000+1000
        XCTAssertEqual(totals[0].elbow90Count, 2)                       // 立上り根元+天端
    }

    // MARK: - 継手マスタ(M6.3)

    func testFittingMasterLoads() {
        let m = FittingMaster.standard
        XCTAssertGreaterThanOrEqual(m.rows.count, 300)
        XCTAssertTrue(m.seriesList.contains("DV"))
        XCTAssertTrue(m.seriesList.contains("SGP"))
        // DV 100(メーカー図面実寸): DLエルボA=112・45L=80・DT=113・受口深さ50・受口外径124
        let dv100 = m.dims(series: "DV", size: "100")
        XCTAssertEqual(dv100.elbow90A, 112, accuracy: 1e-9)
        XCTAssertEqual(dv100.elbow45A, 80, accuracy: 1e-9)
        XCTAssertEqual(dv100.teeA, 113, accuracy: 1e-9)
        XCTAssertEqual(dv100.socketDepth, 50, accuracy: 1e-9)
        XCTAssertEqual(dv100.socketOD, 124, accuracy: 1e-9)
        XCTAssertFalse(dv100.isEmpty)
        // HI 100(HI-TS実寸): エルボ153・受口84・受口外径130・キャップ138。TSはHIと同寸
        let hi100 = m.dims(series: "HI", size: "100")
        XCTAssertEqual(hi100.elbow90A, 153, accuracy: 1e-9)
        XCTAssertEqual(hi100.socketDepth, 84, accuracy: 1e-9)
        XCTAssertEqual(hi100.socketOD, 130, accuracy: 1e-9)
        XCTAssertEqual(hi100.capLength, 138, accuracy: 1e-9)
        XCTAssertEqual(m.dims(series: "TS", size: "50"), m.dims(series: "HI", size: "50"))
        // 大曲エルボ(LL)・大曲Y(LT)・45°Yも行として持つ
        XCTAssertEqual(m.row(series: "DV", kind: "elbow90LL", size: "100")?.a, 178)
        XCTAssertEqual(m.row(series: "DV", kind: "y45", size: "100")?.a, 194)
        // 未整備(銅管)は空 → 呼び出し側で外径概算
        XCTAssertTrue(m.dims(series: "", size: "20").isEmpty)
        XCTAssertTrue(m.dims(series: "DV", size: "13").isEmpty)   // DVに13は無い
    }

    /// 管種+用途→規格シリーズの標準ルール
    func testFittingSeriesRule() {
        XCTAssertEqual(FittingMaster.series(material: "VP", usage: "S"), "DV")
        XCTAssertEqual(FittingMaster.series(material: "VU", usage: "RW"), "DV")
        XCTAssertEqual(FittingMaster.series(material: "VP", usage: "CW"), "TS")
        XCTAssertEqual(FittingMaster.series(material: "HIVP", usage: "CW"), "HI")
        XCTAssertEqual(FittingMaster.series(material: "HTVP", usage: "HW"), "HT")
        XCTAssertEqual(FittingMaster.series(material: "SGP-W", usage: "FI"), "SGP")
        XCTAssertEqual(FittingMaster.series(material: "CUP", usage: "HW"), "")
    }

    /// 集計にティーズ・キャップ・レデューサの個数が出る
    func testAggregateCountsJunctions() {
        func p(_ pts: [Vec3], od: Double, size: String, caps: Bool = false) -> Entity {
            Entity(layer: LayerAddress(0, 0),
                   kind: .pipe(points: pts,
                               attrs: PipeAttributes(usageName: "給水", materialLabel: "HIVP",
                                                     size: size, sizeLabel: size,
                                                     outerDiameter: od, capEnds: caps)))
        }
        let main = p([Vec3(0, 0, 0), Vec3(4000, 0, 0)], od: 76, size: "65", caps: true)
        let branch = p([Vec3(2000, 0, 0), Vec3(2000, 1500, 0)], od: 60, size: "50")
        let tail = p([Vec3(4000, 0, 0), Vec3(6000, 0, 0)], od: 60, size: "50")
        let totals = PipeAggregator.aggregate([main, branch, tail])
        let t65 = totals.first { $0.sizeLabel == "65" }
        XCTAssertEqual(t65?.teeCount, 1)
        XCTAssertEqual(t65?.reducerCount, 1)   // 65→50の突き合わせ(大きい側)
        XCTAssertEqual(t65?.capCount, 1)       // 始点だけ自由端
        let text = PipeAggregator.reportText(totals)
        XCTAssertTrue(text.contains("ティーズ\tキャップ\tレデューサ"))
    }

    /// エルボの個数も集計される(M6.1)
    func testAggregateCountsElbows() {
        let totals = PipeAggregator.aggregate([
            pipe([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000), Vec2(2000, 2000)]),  // 90°+45°
            pipe([Vec2(0, 0), Vec2(500, 0), Vec2(500, 500)]),                       // 90°
        ])
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].elbow90Count, 2)
        XCTAssertEqual(totals[0].elbow45Count, 1)
    }

    /// 可撓管(曲げ半径あり)は折れ点を曲げるのでエルボを数えない。分岐のチーズは数える(M7.9)
    func testBentPipeCountsNoElbows() {
        func pex(_ pts: [Vec2]) -> Entity {
            Entity(layer: LayerAddress(0, 0),
                   kind: .pipe(points: pts.map { Vec3($0, z: 0) },
                               attrs: PipeAttributes(usage: "給水", usageName: "給水",
                                                     material: "PEX", materialLabel: "PEX",
                                                     size: "13", sizeLabel: "13", outerDiameter: 17,
                                                     bendRadius: 136)))
        }
        let main = pex([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000), Vec2(2000, 2000)])
        let branch = pex([Vec2(500, 0), Vec2(500, 800)])
        let totals = PipeAggregator.aggregate([main, branch])
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].elbow90Count, 0)
        XCTAssertEqual(totals[0].elbow45Count, 0)
        XCTAssertEqual(totals[0].teeCount, 1)
    }

    /// 管種マスタの可撓管には最小曲げ半径の倍率がある(M7.9)
    func testFlexibleMaterialsHaveBendRadiusFactor() {
        let m = PipeMaster.standard
        XCTAssertEqual(m.material("PEX")?.bendRadiusFactor ?? 0, 8, accuracy: 1e-9)
        XCTAssertEqual(m.material("PB")?.bendRadiusFactor ?? 0, 8, accuracy: 1e-9)
        XCTAssertEqual(m.material("VP")?.bendRadiusFactor ?? -1, 0, accuracy: 1e-9)
    }
}
