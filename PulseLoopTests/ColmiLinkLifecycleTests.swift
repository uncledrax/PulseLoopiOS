import XCTest
import CoreBluetooth
@testable import PulseLoop

/// The Colmi stack across a dropped link. Auto-reconnect reuses the same driver and engine, and the
/// engine's stage watchdog is self-driving, so a run cut off by the link must stop with it — not keep
/// queueing history requests through the reconnect gap and then report a sync that never happened.
/// Replies that don't answer the stage in flight (a late page after the watchdog moved on, the SpO2
/// log a spot check fetches) are decoded but must not move the machine.
@MainActor
final class ColmiLinkLifecycleTests: XCTestCase {

    private final class RecordingWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        private(set) var frames: [Data] = []
        func enqueue(_ command: Data) { frames.append(command) }
    }

    private func page(_ bytes: [UInt8]) -> Data { ColmiPacket.frame(bytes) }

    private func empty(_ opcode: UInt8) -> Data { page([opcode, 0xff]) }

    /// History requests in send order, as their opcode (paged) or big-data type.
    private func requests(_ writer: RecordingWriter) -> [UInt8] {
        writer.frames.compactMap { frame -> UInt8? in
            guard let op = frame.first else { return nil }
            if op == ColmiCommandID.bigDataV2 { return frame.count > 1 ? frame[1] : nil }
            return ColmiSyncEngine.isHistoryOpcode(op) ? op : nil
        }
    }

    private func engine(_ writer: RecordingWriter, watchdogNanoseconds: UInt64? = nil) -> ColmiSyncEngine {
        let engine = ColmiSyncEngine(writer: writer, decoder: ColmiDecoder())
        if let watchdogNanoseconds {
            engine.watchdogTimeout = watchdogNanoseconds
            engine.activityWatchdogTimeout = watchdogNanoseconds
        }
        return engine
    }

    /// Answer every stage with an empty day / an empty big-data reply, walking a full run to its end.
    private func answerFullRun(_ engine: ColmiSyncEngine) {
        for _ in 0...7 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncActivity)) }
        for _ in 0...7 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncHeartRate)) }
        for _ in 0...ColmiSyncEngine.stressPastDays { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncStress)) }
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSpo2)
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSleep)
        for _ in 0...6 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncHRV)) }
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataTemperature)
    }

    /// Poll the main actor until `condition` holds or `seconds` pass.
    private func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Run outcome

    func testAnsweredRunEndsDone() {
        let writer = RecordingWriter()
        let engine = engine(writer)
        engine.syncHistory()
        answerFullRun(engine)
        XCTAssertEqual(engine.lastRunOutcome, "done")
    }

    func testRunTheWatchdogWalksInSilenceEndsIncomplete() async {
        let writer = RecordingWriter()
        let engine = engine(writer, watchdogNanoseconds: 5_000_000)
        engine.syncHistory()
        await waitUntil(seconds: 5) { engine.lastRunOutcome != nil }
        XCTAssertEqual(engine.lastRunOutcome, "incomplete",
                       "no reply at all is not a finished sync — it must not stamp lastFullSyncAt")
        XCTAssertEqual(requests(writer).last, ColmiCommandID.bigDataTemperature, "the watchdog walked every stage")
    }

    // MARK: Disconnect

    func testDisconnectStopsTheStageWatchdog() async {
        let writer = RecordingWriter()
        let engine = engine(writer, watchdogNanoseconds: 5_000_000)
        engine.syncHistory()
        engine.connectionDidEnd()
        let sent = writer.frames.count
        try? await Task.sleep(nanoseconds: 300_000_000)   // ~60 watchdog periods
        XCTAssertEqual(writer.frames.count, sent, "nothing is queued while the link is down")
        XCTAssertNil(engine.lastRunOutcome, "an interrupted run is neither done nor incomplete")
    }

    func testFramesArrivingAfterDisconnectDontMoveTheMachine() {
        let writer = RecordingWriter()
        let engine = engine(writer)
        engine.syncHistory()
        engine.connectionDidEnd()
        let sent = writer.frames.count
        XCTAssertTrue(engine.handleHistoryFrame(empty(ColmiCommandID.syncActivity)).isEmpty)
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSleep)
        XCTAssertEqual(writer.frames.count, sent)
    }

    func testReconnectStartsAFreshRunFromActivity() {
        let writer = RecordingWriter()
        let engine = engine(writer)
        engine.syncHistory()
        for _ in 0...7 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncActivity)) }
        _ = engine.handleHistoryFrame(page([ColmiCommandID.syncHeartRate, 0x00, 39, 3]))   // mid-HR when the link drops
        engine.connectionDidEnd()
        engine.connectionDidStart()

        let before = requests(writer).count
        engine.syncHistory()   // the 30-minute kick is refused while a run is in flight; this one isn't
        XCTAssertEqual(requests(writer).dropFirst(before).first, ColmiCommandID.syncActivity)
        answerFullRun(engine)
        XCTAssertEqual(engine.lastRunOutcome, "done")
    }

    // MARK: Replies outside their stage

    func testLatePageFromASkippedStageIsDropped() {
        let writer = RecordingWriter()
        let engine = engine(writer)
        engine.syncHistory()
        for _ in 0...7 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncActivity)) }
        let sent = requests(writer).count   // HR day 0 requested

        // A stress page lands during HR (and an activity terminal page): neither is decoded under HR's
        // day nor advances HR's day.
        XCTAssertTrue(engine.handleHistoryFrame(page([ColmiCommandID.syncStress, 1, 0] + Array(repeating: 40, count: 12))).isEmpty)
        XCTAssertTrue(engine.handleHistoryFrame(empty(ColmiCommandID.syncActivity)).isEmpty)
        XCTAssertEqual(requests(writer).count, sent)

        _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncHeartRate))
        XCTAssertEqual(requests(writer).last, ColmiCommandID.syncHeartRate, "HR's own reply still advances it")
        XCTAssertEqual(requests(writer).count, sent + 1)
    }

    func testLateBigDataReplyDoesNotRerequestAStage() {
        let writer = RecordingWriter()
        let engine = engine(writer)
        engine.syncHistory()
        for _ in 0...7 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncActivity)) }
        for _ in 0...7 { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncHeartRate)) }
        for _ in 0...ColmiSyncEngine.stressPastDays { _ = engine.handleHistoryFrame(empty(ColmiCommandID.syncStress)) }
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSpo2)   // → sleep requested
        let sent = requests(writer).count
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSpo2)   // a second, late SpO2 reply
        XCTAssertEqual(requests(writer).count, sent, "sleep isn't requested twice")
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataTemperature)   // not asked for yet
        XCTAssertNil(engine.lastRunOutcome, "a stray temperature reply doesn't end the run early")
    }

    func testSpotSpo2FetchWhileIdleStartsNothing() {
        let writer = RecordingWriter()
        let engine = engine(writer)
        engine.startSpO2()
        let sent = writer.frames.count
        engine.handleBigDataComplete(type: ColmiCommandID.bigDataSpo2)
        XCTAssertEqual(writer.frames.count, sent, "the all-day SpO2 reply must not kick off sleep → HRV → temperature")
    }

    // MARK: Driver

    func testPartialBigDataFrameDoesNotSurviveTheLink() {
        let driver = ColmiDriver(writer: RecordingWriter())
        let notifyV2 = CBUUID(string: ColmiUUIDs.notifyV2)
        // One 60-minute night, 23:00 → 00:00 (two 30-minute segments).
        let payload: [UInt8] = [0x01, 0x00, 0x08, 0x64, 0x05, 0x00, 0x00,
                                ColmiCommandID.sleepLight, 30, ColmiCommandID.sleepDeep, 30]
        let frame = [ColmiCommandID.bigDataV2, ColmiCommandID.bigDataSleep, UInt8(payload.count), 0, 0, 0] + payload
        let firstHalf = Data(frame.prefix(9)), secondHalf = Data(frame.dropFirst(9))

        XCTAssertTrue(driver.ingest(firstHalf, from: notifyV2).isEmpty)
        driver.connectionDidEnd()
        driver.connectionDidStart()
        let afterReconnect = driver.ingest(secondHalf, from: notifyV2)
        XCTAssertFalse(afterReconnect.contains { if case .sleepTimeline = $0 { return true }; return false },
                       "the previous link's half frame is gone, so this chunk completes nothing")

        let whole = driver.ingest(Data(frame), from: notifyV2)
        XCTAssertTrue(whole.contains { if case .sleepTimeline = $0 { return true }; return false })
    }
}
