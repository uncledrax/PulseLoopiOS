import XCTest
@testable import PulseLoop

/// Patched RY02KA firmware runs the all-day HR setting faster than it reads, and logs stress / HRV every
/// 6 minutes: the Measurement screen shows what the ring actually does.
final class ColmiPatchedIntervalTests: XCTestCase {

    func testPatchLevelParsing() {
        XCTAssertEqual(ColmiFirmware.ry02kaPatchLevel(firmwareRevision: "RY02KA_3.00.31_PATCH2"), 2)
        XCTAssertEqual(ColmiFirmware.ry02kaPatchLevel(firmwareRevision: " RY02KA_3.00.31_PATCH12\n"), 12)
        XCTAssertNil(ColmiFirmware.ry02kaPatchLevel(firmwareRevision: "RY02KA_3.00.31_250603"))
        XCTAssertNil(ColmiFirmware.ry02kaPatchLevel(firmwareRevision: "RT02R_3.11.00_PATCH3"))
    }

    func testHeartRateIntervalOnPatch2AndLater() {
        for revision in ["RY02KA_3.00.31_PATCH2", "RY02KA_3.00.31_PATCH3"] {
            XCTAssertEqual(ColmiFirmware.loggedHeartRateIntervalSeconds(settingMinutes: 5, firmwareRevision: revision), 180)
            XCTAssertEqual(ColmiFirmware.loggedHeartRateIntervalSeconds(settingMinutes: 10, firmwareRevision: revision), 360)
            XCTAssertEqual(ColmiFirmware.loggedHeartRateIntervalSeconds(settingMinutes: 60, firmwareRevision: revision), 2160)
            XCTAssertEqual(ColmiFirmware.loggedStressAndHRVIntervalMinutes(firmwareRevision: revision), 6)
        }
    }

    func testStockPatch1AndOtherRingsKeepTheSetting() {
        for revision in ["RY02KA_3.00.31_PATCH1", "RY02KA_3.00.31_250603", "RT02R_3.11.00_PATCH3", nil] as [String?] {
            XCTAssertNil(ColmiFirmware.loggedHeartRateIntervalSeconds(settingMinutes: 5, firmwareRevision: revision))
            XCTAssertNil(ColmiFirmware.loggedStressAndHRVIntervalMinutes(firmwareRevision: revision))
        }
    }

    func testIntervalLabels() {
        XCTAssertEqual(ColmiFirmware.intervalLabel(seconds: 180), "3 min")
        XCTAssertEqual(ColmiFirmware.intervalLabel(seconds: 2160), "36 min")
        XCTAssertEqual(ColmiFirmware.intervalLabel(seconds: 36), "36 s")
    }

    func testSleepStageDetectionIsUnchanged() {
        XCTAssertTrue(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_PATCH3"))
        XCTAssertFalse(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_PATCH2"))
        XCTAssertFalse(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_250603"))
    }
}
