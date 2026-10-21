import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Header-driven paged history (HR / stress / HRV) for the QRing-protocol Colmi family.
///
/// Each paged day opens with page 0 = `[cmd, 0x00, totalPackets, intervalMinutes]`. The byte layouts
/// below are the ones the RY02KA firmware's own history senders emit: HR `15 00 18 05` then packets
/// 1…23 (packet 1 = 4-byte timestamp + 9 slots, the rest 13 slots), stress/HRV `37|39 00 05 1e` then
/// packets 1…4 (packet 1 = echoed day offset + 12 slots, the rest 13 slots), and `cmd ff` for an
/// empty day.
@MainActor
final class ColmiHistoryHeaderTests: XCTestCase {

    private final class RecordingWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        private(set) var frames: [Data] = []
        func enqueue(_ command: Data) { frames.append(command) }
    }

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func page(_ bytes: [UInt8]) -> Data { ColmiPacket.frame(bytes) }

    /// One full stock HR day: header + packets 1…23, every slot holding `bpm`.
    private func stockHRDay(bpm: UInt8 = 60) -> [Data] {
        var frames = [page([ColmiCommandID.syncHeartRate, 0x00, 24, 5])]
        frames.append(page([ColmiCommandID.syncHeartRate, 1, 0, 0, 0, 0] + Array(repeating: bpm, count: 9)))
        for n in 2...23 {
            frames.append(page([ColmiCommandID.syncHeartRate, UInt8(n)] + Array(repeating: bpm, count: 13)))
        }
        return frames
    }

    private func minutes(_ events: [RingDecodedEvent], from day: Date) -> [Int] {
        events.compactMap { event -> Int? in
            switch event {
            case .historyMeasurement(_, _, let ts), .stressSample(_, let ts), .hrvSample(_, let ts):
                return Int(ts.timeIntervalSince(day) / 60)
            default:
                return nil
            }
        }
    }

    // MARK: Header parsing

    func testParsesFirmwareHeaders() {
        XCTAssertEqual(ColmiPagedHistoryHeader(page([0x15, 0x00, 0x18, 0x05])),
                       ColmiPagedHistoryHeader(opcode: 0x15, totalPackets: 24, intervalMinutes: 5))
        XCTAssertEqual(ColmiPagedHistoryHeader(page([0x37, 0x00, 0x05, 0x1e]))?.intervalMinutes, 30)
        XCTAssertEqual(ColmiPagedHistoryHeader(page([0x39, 0x00, 0x05, 0x1e]))?.totalPackets, 5)
    }

    func testRejectsNonHeadersAndImplausibleValues() {
        XCTAssertNil(ColmiPagedHistoryHeader(page([0x15, 0xff])))                 // empty-day reply
        XCTAssertNil(ColmiPagedHistoryHeader(page([0x15, 0x01, 0x18, 0x05])))     // a data packet
        XCTAssertNil(ColmiPagedHistoryHeader(page([0x43, 0x00, 0x18, 0x05])))     // not a paged opcode
        XCTAssertNil(ColmiPagedHistoryHeader(page([0x15, 0x00, 0x00, 0x05])))     // zero packets
        XCTAssertNil(ColmiPagedHistoryHeader(page([0x15, 0x00, 0x18, 0x00])))     // zero interval
        XCTAssertNil(ColmiPagedHistoryHeader(page([0x15, 0x00, 0x18, 0x78])))     // > 60 min
        var corrupt = [UInt8](page([0x15, 0x00, 0x18, 0x05])); corrupt[15] ^= 0xff
        XCTAssertNil(ColmiPagedHistoryHeader(Data(corrupt)))                      // bad checksum
    }

    func testFinalPacketIsTotalMinusOne() {
        let header = ColmiPagedHistoryHeader(opcode: 0x15, totalPackets: 24, intervalMinutes: 5)
        XCTAssertFalse(header.isFinalPacket(22))
        XCTAssertTrue(header.isFinalPacket(23))
        XCTAssertTrue(ColmiPagedHistoryHeader(opcode: 0x15, totalPackets: 1, intervalMinutes: 5).isFinalPacket(0))
    }

    // MARK: Decoder spacing

    func testHRDefaultSpacingIsUnchanged() {
        let day = utc.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        let decoder = ColmiDecoder()
        let p1 = decoder.decodeHistory(page([0x15, 1, 0, 0, 0, 0, 70, 71]), day: day, calendar: utc)
        XCTAssertEqual(minutes(p1, from: day), [0, 5])
        let p2 = decoder.decodeHistory(page([0x15, 2, 72]), day: day, calendar: utc)
        XCTAssertEqual(minutes(p2, from: day), [45])                     // 9 slots × 5 min
        let p3 = decoder.decodeHistory(page([0x15, 3, 0, 73]), day: day, calendar: utc)
        XCTAssertEqual(minutes(p3, from: day), [9 * 5 + 13 * 5 + 5])
    }

    func testHRUsesAnnouncedInterval() {
        let day = utc.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        let decoder = ColmiDecoder()
        let p1 = decoder.decodeHistory(page([0x15, 1, 0, 0, 0, 0, 70, 71]), day: day, calendar: utc, intervalMinutes: 3)
        XCTAssertEqual(minutes(p1, from: day), [0, 3])
        let p2 = decoder.decodeHistory(page([0x15, 2, 72]), day: day, calendar: utc, intervalMinutes: 3)
        XCTAssertEqual(minutes(p2, from: day), [27])                     // 9 slots × 3 min
    }

    func testStressAndHRVSpacing() {
        let day = utc.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        let decoder = ColmiDecoder()
        // Stock 30-minute log: packet 1 = day offset + 12 slots, packet 2 starts at slot 12 (06:00).
        XCTAssertEqual(minutes(decoder.decodeHistory(page([0x37, 1, 0, 40, 41]), day: day, calendar: utc), from: day), [0, 30])
        XCTAssertEqual(minutes(decoder.decodeHistory(page([0x39, 2, 55]), day: day, calendar: utc), from: day), [360])
        // A 6-minute log announced in the header.
        XCTAssertEqual(minutes(decoder.decodeHistory(page([0x39, 2, 55]), day: day, calendar: utc, intervalMinutes: 6),
                               from: day), [72])
    }

    // MARK: Sync engine paging

    /// Drive a fresh engine through the eight (empty) activity days so the HR stage is in flight.
    private func engineAtHeartRateStage(_ writer: RecordingWriter) -> ColmiSyncEngine {
        let engine = ColmiSyncEngine(writer: writer, decoder: ColmiDecoder())
        engine.syncHistory()
        for _ in 0...7 { _ = engine.handleHistoryFrame(page([ColmiCommandID.syncActivity, 0xff])) }
        return engine
    }

    private func lastHRRequestDay(_ writer: RecordingWriter) -> Date? {
        guard let f = writer.frames.last, f.first == ColmiCommandID.syncHeartRate, f.count >= 5 else { return nil }
        let b = [UInt8](f)
        let ts = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    func testHeartRateDayCompletesOnAnnouncedFinalPacketAndRequestsYesterday() {
        let writer = RecordingWriter()
        let engine = engineAtHeartRateStage(writer)
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(lastHRRequestDay(writer), today, "HR stage should start with today")

        let day = stockHRDay()
        for frame in day.dropLast() { _ = engine.handleHistoryFrame(frame) }
        XCTAssertEqual(lastHRRequestDay(writer), today, "no new request before the final packet")

        let events = engine.handleHistoryFrame(day.last!)
        XCTAssertFalse(events.isEmpty)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)
        XCTAssertEqual(lastHRRequestDay(writer), yesterday, "final packet should immediately request the previous day")
    }

    func testHeartRateWithoutHeaderKeepsWaitingForWatchdog() {
        let writer = RecordingWriter()
        let engine = engineAtHeartRateStage(writer)
        let before = writer.frames.count
        for frame in stockHRDay().dropFirst() { _ = engine.handleHistoryFrame(frame) }   // no page 0
        XCTAssertEqual(writer.frames.count, before, "without a header the old behaviour (watchdog) stands")
    }

    func testEmptyHeartRateDayStillAdvances() {
        let writer = RecordingWriter()
        let engine = engineAtHeartRateStage(writer)
        _ = engine.handleHistoryFrame(page([ColmiCommandID.syncHeartRate, 0xff]))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))
        XCTAssertEqual(lastHRRequestDay(writer), yesterday)
    }

    func testVitalsBackfillMovesToSpo2OnFinalPacket() {
        let writer = RecordingWriter()
        let engine = ColmiSyncEngine(writer: writer, decoder: ColmiDecoder())
        engine.startVitalsBackfill()
        for frame in stockHRDay() { _ = engine.handleHistoryFrame(frame) }
        XCTAssertEqual(writer.frames.last?.first, ColmiCommandID.bigDataV2, "backfill continues to the SpO2 big-data log")
    }

    func testAnnouncedIntervalReachesDecodedTimestamps() {
        let writer = RecordingWriter()
        let engine = engineAtHeartRateStage(writer)
        let today = Calendar.current.startOfDay(for: Date())
        _ = engine.handleHistoryFrame(page([ColmiCommandID.syncHeartRate, 0x00, 38, 3]))
        let events = engine.handleHistoryFrame(page([ColmiCommandID.syncHeartRate, 2, 80]))
        XCTAssertEqual(minutes(events, from: today), [27])
    }

}
