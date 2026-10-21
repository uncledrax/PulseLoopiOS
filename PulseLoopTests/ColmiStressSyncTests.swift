import XCTest
@testable import PulseLoop

/// Multi-day stress history for the QRing-protocol Colmi family. The stress stage walks today and six
/// days back, like HRV, using the day offset in byte 1 of `0x37` (the field the firmware's stress
/// sender reads and echoes in packet 1). A past day whose packet 1 echoes a different offset is dropped
/// and the walk stops, so firmware that ignores the offset can't file today's samples under earlier dates.
@MainActor
final class ColmiStressSyncTests: XCTestCase {

    private final class RecordingWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        private(set) var frames: [Data] = []
        func enqueue(_ command: Data) { frames.append(command) }
    }

    private func page(_ bytes: [UInt8]) -> Data { ColmiPacket.frame(bytes) }

    /// Drive a fresh engine through eight empty activity days and eight empty HR days.
    private func engineAtStressStage(_ writer: RecordingWriter) -> ColmiSyncEngine {
        let engine = ColmiSyncEngine(writer: writer, decoder: ColmiDecoder())
        engine.syncHistory()
        for _ in 0...7 { _ = engine.handleHistoryFrame(page([ColmiCommandID.syncActivity, 0xff])) }
        for _ in 0...7 { _ = engine.handleHistoryFrame(page([ColmiCommandID.syncHeartRate, 0xff])) }
        return engine
    }

    /// One stock stress day as the RY02KA firmware sends it: header `37 00 05 1e`, packet 1 = echoed
    /// day offset + 12 slots, packets 2…4 = 13, 13 and 10 slots (48 half-hours), zero-padded.
    private func stockStressDay(echo: UInt8, value: UInt8 = 40) -> [Data] {
        [page([0x37, 0x00, 0x05, 0x1e]),
         page([0x37, 1, echo] + Array(repeating: value, count: 12)),
         page([0x37, 2] + Array(repeating: value, count: 13)),
         page([0x37, 3] + Array(repeating: value, count: 13)),
         page([0x37, 4] + Array(repeating: value, count: 10))]
    }

    private func lastRequest(_ writer: RecordingWriter) -> [UInt8] { [UInt8](writer.frames.last ?? Data()) }

    private func stressStamps(_ events: [RingDecodedEvent]) -> [Date] {
        events.compactMap { event -> Date? in
            if case .stressSample(_, let ts) = event { return ts }
            return nil
        }
    }

    private func dayStart(_ daysAgo: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
    }

    func testStressRequestCarriesDayOffset() {
        let enc = ColmiEncoder()
        XCTAssertEqual(ColmiPacket.frame(enc.syncStress()), ColmiPacket.frame([ColmiCommandID.syncStress]),
                       "today's request is unchanged on the wire")
        XCTAssertEqual(enc.syncStress(daysAgo: 3), [ColmiCommandID.syncStress, 3])
    }

    func testStressWalksBackSixDaysThenMovesToSpo2() {
        let writer = RecordingWriter()
        let engine = engineAtStressStage(writer)
        for d in 0...6 {
            XCTAssertEqual(Array(lastRequest(writer).prefix(2)), [ColmiCommandID.syncStress, UInt8(d)],
                           "stress day \(d) requested")
            for frame in stockStressDay(echo: UInt8(d)) { _ = engine.handleHistoryFrame(frame) }
        }
        XCTAssertEqual(lastRequest(writer).first, ColmiCommandID.bigDataV2, "after seven days the sync moves on to SpO2")
    }

    func testPastStressSamplesLandOnTheirOwnDay() {
        let writer = RecordingWriter()
        let engine = engineAtStressStage(writer)
        for frame in stockStressDay(echo: 0) { _ = engine.handleHistoryFrame(frame) }
        var events: [RingDecodedEvent] = []
        for frame in stockStressDay(echo: 1, value: 55) { events += engine.handleHistoryFrame(frame) }
        let stamps = stressStamps(events)
        XCTAssertEqual(stamps.count, 48)
        XCTAssertEqual(stamps.first, dayStart(1))
        XCTAssertTrue(stamps.allSatisfy { Calendar.current.isDate($0, inSameDayAs: dayStart(1)) })
    }

    func testFirmwareThatIgnoresTheOffsetIsNotFiledUnderPastDays() {
        let writer = RecordingWriter()
        let engine = engineAtStressStage(writer)
        for frame in stockStressDay(echo: 0) { _ = engine.handleHistoryFrame(frame) }
        var events: [RingDecodedEvent] = []
        for frame in stockStressDay(echo: 0) { events += engine.handleHistoryFrame(frame) }   // asked for day 1
        XCTAssertTrue(events.isEmpty, "a day echoing the wrong offset is dropped")
        XCTAssertEqual(lastRequest(writer).first, ColmiCommandID.bigDataV2, "the walk-back stops and the sync moves on")
    }

    func testEmptyPastStressDayStillAdvances() {
        let writer = RecordingWriter()
        let engine = engineAtStressStage(writer)
        for frame in stockStressDay(echo: 0) { _ = engine.handleHistoryFrame(frame) }
        _ = engine.handleHistoryFrame(page([ColmiCommandID.syncStress, 0xff]))
        XCTAssertEqual(Array(lastRequest(writer).prefix(2)), [ColmiCommandID.syncStress, 2])
    }

    func testSixMinuteStressDayFromPatchedFirmware() {
        // Patched RY02KA firmware: header `37 00 14 06`, packet 1 = echo + 12 slots, packets 2…19 = 13
        // slots each, the last holding 7 (240 six-minute slots).
        let writer = RecordingWriter()
        let engine = engineAtStressStage(writer)
        for frame in stockStressDay(echo: 0) { _ = engine.handleHistoryFrame(frame) }
        var frames = [page([0x37, 0x00, 0x14, 0x06]), page([0x37, 1, 1] + Array(repeating: 30, count: 12))]
        for n in 2...19 { frames.append(page([0x37, UInt8(n)] + Array(repeating: 30, count: n == 19 ? 7 : 13))) }
        var events: [RingDecodedEvent] = []
        for frame in frames { events += engine.handleHistoryFrame(frame) }
        let minutes = stressStamps(events).map { Int($0.timeIntervalSince(dayStart(1)) / 60) }
        XCTAssertEqual(minutes, Array(stride(from: 0, to: 1440, by: 6)))
        XCTAssertEqual(Array(lastRequest(writer).prefix(2)), [ColmiCommandID.syncStress, 2],
                       "day completes on packet 19 and the next day is requested")
    }

    func testVitalsBackfillStillSkipsStress() {
        let writer = RecordingWriter()
        let engine = ColmiSyncEngine(writer: writer, decoder: ColmiDecoder())
        engine.startVitalsBackfill()
        _ = engine.handleHistoryFrame(page([ColmiCommandID.syncHeartRate, 0xff]))
        XCTAssertFalse(writer.frames.contains { $0.first == ColmiCommandID.syncStress })
        XCTAssertEqual(lastRequest(writer).first, ColmiCommandID.bigDataV2)
    }
}
