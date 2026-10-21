import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Decoder fixes from the 2026-10-22 RY02KA firmware audit: live-calorie units, the sleep "gap" code,
/// sleep stages on patched firmware that no longer invents them, and corrupt-night rejection.
final class ColmiFirmwareAuditTests: XCTestCase {

    private var calendar: Calendar { Calendar.current }

    /// A `0x27` sleep big-data frame holding one night: `[days=1][daysAgo][2N+4][start][end][(stage, min)…]`.
    private func sleepFrame(start: Int, end: Int, segments: [(UInt8, UInt8)], daysAgo: UInt8 = 0) -> Data {
        var day: [UInt8] = [daysAgo, UInt8(segments.count * 2 + 4),
                            UInt8(start & 0xff), UInt8(start >> 8), UInt8(end & 0xff), UInt8(end >> 8)]
        for (stage, minutes) in segments { day += [stage, minutes] }
        let payload: [UInt8] = [0x01] + day
        let len = payload.count
        return Data([ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleep,
                     UInt8(len & 0xff), UInt8((len >> 8) & 0xff), 0, 0] + payload)
    }

    private func stages(_ events: [RingDecodedEvent]) -> [SleepStage]? {
        guard events.count == 1, case let .sleepTimeline(_, stages) = events[0] else { return nil }
        return stages
    }

    // MARK: Live activity calories

    func testLiveCaloriesAreSmallCaloriesFromTheRing() {
        // 109,152 cal = what RY02KA's accumulator holds after 3,411 steps at ~32 cal/step (emulated).
        let raw = 109_152
        let frame = ColmiPacket.frame([
            ColmiCommandID.notification, ColmiCommandID.notifLiveActivity,
            0x00, 0x0d, 0x53,                                              // 3,411 steps (big-endian)
            UInt8(raw >> 16), UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff), // calories
            0x00, 0x08, 0xcb,                                              // 2,251 m
        ])
        guard case let .activityUpdate(_, steps, distance, calories) = ColmiDecoder().decodeNormal(frame).first else {
            return XCTFail("expected activityUpdate")
        }
        XCTAssertEqual(steps, 3411)
        XCTAssertEqual(distance, 2251)
        XCTAssertEqual(calories, 109.152, accuracy: 0.001)
    }

    func testAFullDayOfLiveCaloriesPassesTheBridge() {
        // 2,400 kcal of ring-counted calories: the old ÷10 made this 240,000 "kcal", over the bridge's
        // 10,000 ceiling, so every live update (steps too) was dropped for the rest of the day.
        let raw = 2_400_000
        let frame = ColmiPacket.frame([
            ColmiCommandID.notification, ColmiCommandID.notifLiveActivity,
            0x00, 0x4e, 0x20,
            UInt8(raw >> 16), UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff),
            0x00, 0x1f, 0x40,
        ])
        let decoded = ColmiDecoder().decodeNormal(frame)
        XCTAssertEqual(decoded.flatMap { RingEventBridge.events(for: $0) }.count, 1)
    }

    // MARK: Sleep stage codes

    func testGapCodeIsAwakeNotUnknown() {
        XCTAssertEqual(ColmiDecoder.sleepStage(0x00), .awake)
        XCTAssertEqual(ColmiDecoder.sleepStage(0x05), .awake)
        XCTAssertEqual(ColmiDecoder.sleepStage(0x02), .light)
        XCTAssertEqual(ColmiDecoder.sleepStage(0x09), .unknown)
    }

    func testUnmeasuredStagesDecodeAsAsleepUnspecified() {
        for code: UInt8 in [0x02, 0x03, 0x04] {
            XCTAssertEqual(ColmiDecoder.sleepStage(code, stagesUnmeasured: true), .unknown)
        }
        XCTAssertEqual(ColmiDecoder.sleepStage(0x05, stagesUnmeasured: true), .awake)
        XCTAssertEqual(ColmiDecoder.sleepStage(0x00, stagesUnmeasured: true), .awake)
    }

    func testFirmwareRevisionDetection() {
        XCTAssertTrue(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_PATCH3"))
        XCTAssertTrue(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_PATCH12\n"))
        XCTAssertFalse(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_PATCH2"))
        XCTAssertFalse(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RY02KA_3.00.31_250603"))
        XCTAssertFalse(ColmiFirmware.reportsUnmeasuredSleepStages(firmwareRevision: "RT02R_3.11.00_PATCH3"))
    }

    @MainActor
    func testDriverFollowsTheFirmwareRevisionAcrossReconnects() {
        final class NullWriter: RingCommandWriter {
            nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
            func enqueue(_ command: Data) {}
        }
        let writer = NullWriter()
        let driver = ColmiDriver(writer: writer)
        let notifyV2 = CBUUID(string: ColmiUUIDs.notifyV2)
        let night = sleepFrame(start: 1380, end: 60, segments: [(0x02, 40), (0x03, 30), (0x05, 5), (0x02, 5)])

        driver.connectionDidStart()
        driver.firmwareRevisionDidUpdate("RY02KA_3.00.31_PATCH3")
        driver.firmwareRevisionDidUpdate("V1.0")   // 2A28 arriving second must not clear it
        XCTAssertEqual(stages(driver.ingest(night, from: notifyV2)).map { Set($0) }, [.unknown, .awake])

        driver.connectionDidStart()                // reflashed to stock, reconnect
        driver.firmwareRevisionDidUpdate("RY02KA_3.00.31_250603")
        XCTAssertEqual(stages(driver.ingest(night, from: notifyV2)).map { Set($0) }, [.light, .deep, .awake])
    }

    // MARK: Corrupt nights

    func testNightWhoseSegmentsCoverItsSpanIsKept() {
        // 23:00 → 07:29 = 509 min, the audit's emulated night.
        let durations: [UInt8] = [12, 28, 18, 21, 37, 17, 31, 33, 14, 28, 27, 29, 54, 26, 35, 16, 38, 2, 28, 15]
        let codes: [UInt8] = [2, 3, 2, 3, 2, 4, 2, 3, 4, 2, 0, 4, 2, 3, 2, 4, 3, 5, 2, 2]
        let frame = sleepFrame(start: 1380, end: 449, segments: Array(zip(codes, durations)))
        let decoded = stages(ColmiDecoder().decodeBigData(frame, calendar: calendar))
        XCTAssertEqual(decoded?.count, 509)
        XCTAssertEqual(decoded?.filter { $0 == .awake }.count, 29, "27 min gap + 2 min awake")
    }

    func testNightWhoseSegmentsDontCoverItsSpanIsDropped() {
        // RY02KA overruns its 40-segment arrays on restless nights: only 421 of 509 minutes survive.
        let frame = sleepFrame(start: 1380, end: 449, segments: [(0x02, 200), (0x05, 21), (0x03, 200)])
        XCTAssertTrue(ColmiDecoder().decodeBigData(frame, calendar: calendar).isEmpty)
    }

    func testSpanCheckAllowsRoundingSlack() {
        XCTAssertTrue(ColmiDecoder.segmentsMatchSpan(minutes: 404, start: 150, end: 554))
        XCTAssertTrue(ColmiDecoder.segmentsMatchSpan(minutes: 60, start: 480, end: 540))
        XCTAssertTrue(ColmiDecoder.segmentsMatchSpan(minutes: 508, start: 1380, end: 449))
        XCTAssertFalse(ColmiDecoder.segmentsMatchSpan(minutes: 421, start: 1380, end: 449))
    }
}

/// How the app presents a night recorded as asleep / awake only.
@MainActor
final class UnstagedSleepPresentationTests: XCTestCase {

    private func lastNight() -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: yesterday)!
    }

    func testUnstagedNightSummaryAndScore() throws {
        let context = try TestSupport.makeContext()
        let stages = Array(repeating: SleepStage.unknown, count: 460) + Array(repeating: .awake, count: 20)
        TestSupport.insertSleep(nightStart: lastNight(), stages: stages, into: context)
        let summary = try XCTUnwrap(SleepService.latestSleep(context: context))

        XCTAssertEqual(summary.unstagedMinutes, 460)
        XCTAssertTrue(summary.stagesUnmeasured)
        XCTAssertEqual(summary.deepMinutes, 0)

        let score = SleepScore.calculate(summary)
        XCTAssertGreaterThanOrEqual(score.score, 85, "8 h in bed with 4% awake shouldn't be scored down for 'no deep sleep'")
        XCTAssertEqual(score.awakePct, 4)

        let coach = SleepInsights.dayCoach(summary, score: score.score, awakePct: score.awakePct,
                                           deepPct: score.deepPct, activitySteps: nil)
        XCTAssertFalse((coach.headline + coach.body + coach.chips.joined()).lowercased().contains("deep"))
        XCTAssertTrue(coach.chips.contains("Stages not measured"))
    }

    func testStagedNightIsUnchanged() throws {
        let context = try TestSupport.makeContext()
        let stages = Array(repeating: SleepStage.light, count: 300) + Array(repeating: .deep, count: 90)
            + Array(repeating: .rem, count: 60) + Array(repeating: .awake, count: 30)
        TestSupport.insertSleep(nightStart: lastNight(), stages: stages, into: context)
        let summary = try XCTUnwrap(SleepService.latestSleep(context: context))
        XCTAssertEqual(summary.unstagedMinutes, 0)
        XCTAssertFalse(summary.stagesUnmeasured)
    }

    func testAverageStagesSkipUnstagedNights() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertSleep(nightStart: lastNight(), stages: Array(repeating: .unknown, count: 400), into: context)
        let summary = try XCTUnwrap(SleepService.latestSleep(context: context))
        XCTAssertNil(SleepInsights.averageStages([summary]))
    }

    func testHypnogramNamesUnstagedSleep() {
        XCTAssertEqual(SleepStage.unknown.chartName, "Asleep")
        XCTAssertEqual(SleepStage.rem.chartName, "REM")
        XCTAssertEqual(SleepHypnogramView.accessibilitySummary(stages: [(stage: .unknown, minutes: 420), (stage: .awake, minutes: 5)]),
                       "Asleep 7 hours, Awake 5 minutes")
        XCTAssertEqual(SleepHypnogramView.readoutText(stage: .unknown, startMinute: 0, durationMinutes: 30, startTs: nil),
                       "ASLEEP · 0:00 – 0:30")
    }
}
