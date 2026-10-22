import Foundation
import os.log

private let syncLog = Logger(subsystem: "xyz.sakshambhutani.pulseloop2", category: "ColmiSyncEngine")

/// Colmi R02 sync engine: the response-driven history state machine + realtime-HR keepalive +
/// measurement actions. Unlike the fire-and-forget jring, Colmi history is a chain where each reply
/// triggers the next request.
///
/// Stage order (per `docs/ColmiR02-Protocol.md` §5):
///   activity(0..7) → HR(0..7) → stress(0..6) → spo2(bigdata) → sleep(bigdata) → hrv(0..6)
///   → temperature(bigdata) → done.
///
/// **UNVERIFIED (GadgetBridge-derived):** exact reply→stage transitions, per-day iteration counts,
/// and paged terminal conditions. These are the spots to re-check against a real ring.
@MainActor
final class ColmiSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder: ColmiDecoder
    private let encoder = ColmiEncoder()
    private let calendar = Calendar.current

    /// User-chosen all-day measurement config, applied in the connect handshake and updatable live.
    /// Defaults to the previous hard-coded behaviour (all vitals on, HR every 5 min) until the
    /// coordinator pushes the persisted config.
    private var measurementSettings: MeasurementSettings = .allOnDefault

    /// The user's profile for the ring's user-preferences command. `nil` ⇒ send the encoder's neutral
    /// defaults (matches prior behaviour) until the coordinator pushes real values.
    private var userProfile: UserProfileValues?

    init(writer: RingCommandWriter?, decoder: ColmiDecoder) {
        self.writer = writer
        self.decoder = decoder
    }

    // MARK: History state machine

    private enum Stage {
        case idle
        case activity
        case heartRate
        case stress
        case spo2
        case sleep
        case hrv
        case temperature
        case done
    }

    private var stage: Stage = .idle
    private var daysAgo = 0
    /// Page 0 of the paged HR / stress / HRV day currently in flight: how many packets the day spans and
    /// the slot interval. Cleared on every paged request so one day's header never leaks into the next.
    private var pagedHeader: ColmiPagedHistoryHeader?
    /// The midnight of the day currently being synced (for HR/stress/HRV sample timestamps).
    private var syncDay = Calendar.current.startOfDay(for: Date())
    /// Set when a past stress day's packet 1 echoes a different day offset than we asked for — i.e. the
    /// firmware ignored the offset and is replaying another day. That day's samples are dropped and the
    /// stress walk-back stops, so nothing is filed under the wrong date.
    private var stressDayRejected = false
    /// How many past days of stress to request after today (HRV uses the same window).
    static let stressPastDays = 6
    /// A targeted post-workout run: today's HR log → SpO2 big-data → done, skipping the other five
    /// stages. Set by `startVitalsBackfill()`, cleared whenever a run finishes or a full sync starts.
    private var isVitalsBackfill = false
    /// Whether the ring has answered anything in the current run (a history page, an empty-day
    /// marker, or a big-data reply for the stage in flight). A run the stage watchdog walked to the
    /// end with no reply at all synced nothing, so it must not be reported as a finished sync.
    private var receivedReplyThisRun = false
    /// How the last run ended — the `.syncProgress` sentinel `finishSync` published (`"done"` or
    /// `"incomplete"`). nil until a run finishes; an interrupted run doesn't finish.
    private(set) var lastRunOutcome: String?

    static func isHistoryOpcode(_ op: UInt8) -> Bool {
        op == ColmiCommandID.syncActivity
            || op == ColmiCommandID.syncHeartRate
            || op == ColmiCommandID.syncStress
            || op == ColmiCommandID.syncHRV
    }

    /// The paged-history opcode a stage requests; nil for stages that page nothing.
    private static func historyOpcode(for stage: Stage) -> UInt8? {
        switch stage {
        case .activity: return ColmiCommandID.syncActivity
        case .heartRate: return ColmiCommandID.syncHeartRate
        case .stress: return ColmiCommandID.syncStress
        case .hrv: return ColmiCommandID.syncHRV
        case .idle, .spo2, .sleep, .temperature, .done: return nil
        }
    }

    /// The big-data type a stage requests; nil for the paged stages.
    private static func bigDataType(for stage: Stage) -> UInt8? {
        switch stage {
        case .spo2: return ColmiCommandID.bigDataSpo2
        case .sleep: return ColmiCommandID.bigDataSleep
        case .temperature: return ColmiCommandID.bigDataTemperature
        case .idle, .activity, .heartRate, .stress, .hrv, .done: return nil
        }
    }

    // MARK: - Link lifecycle

    /// Auto-reconnect reuses this engine, so a run cut off by the previous link must not carry over.
    func connectionDidStart() {
        stopLinkWork()
    }

    /// The link dropped. Stop everything self-driving *now*: the stage watchdog would otherwise keep
    /// stepping through the reconnect gap, queueing a history request every 10 s and finally reporting
    /// a sync that never happened, and the realtime-HR keepalive would keep queueing its continue
    /// command. Nothing is published: an interrupted run did not finish (the coordinator ends its
    /// progress bar on the disconnect itself), and a workout's stream is restarted on reconnect.
    func connectionDidEnd() {
        stopLinkWork()
    }

    private func stopLinkWork() {
        watchdog?.cancel()
        watchdog = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        realtimeHRActive = false
        manualHRActive = false
        stage = .idle
        daysAgo = 0
        pagedHeader = nil
        stressDayRejected = false
        isVitalsBackfill = false
        receivedReplyThisRun = false
    }

    func runStartup() {
        // Connect-time settings handshake (no history yet — history is on-demand via startHistorySync).
        writer?.enqueue(Data(encoder.phoneName()))
        writer?.enqueue(Data(encoder.setDateTime()))
        writer?.enqueue(Data(userPreferencesCommand()))
        writer?.enqueue(Data(encoder.battery()))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoHRPref)))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoStressPref)))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoSpo2Pref)))
        writer?.enqueue(Data(encoder.readPref(ColmiCommandID.autoHRVPref)))
        writer?.enqueue(Data(encoder.readTempPref()))
        writer?.enqueue(Data(encoder.readGoals()))
        // Enable all-day measurement so the ring actually accumulates data the history sync can
        // return (without these, the metric history comes back empty). The exact intervals/toggles come
        // from the user's persisted config (defaulting to all-on / 5-min HR until the coordinator pushes
        // it via setMeasurementSettings before runStartup).
        enqueueMeasurementCommands(measurementSettings)
        // Kick off a full history sync after the settings handshake.
        startHistorySync()
    }

    // MARK: - Measurement settings

    /// Store the config without sending (the connect handshake's `enqueueMeasurementCommands` will send
    /// it as part of `runStartup`).
    func setMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
    }

    /// Store *and* immediately push the config — the live "Save" path while connected.
    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        enqueueMeasurementCommands(settings)
    }

    /// Translate the device-agnostic settings into Colmi pref commands. HR uses the dedicated `0x16`
    /// command (interval + on/off in one); SpO2/stress/HRV/temp are simple on/off prefs.
    private func enqueueMeasurementCommands(_ s: MeasurementSettings) {
        writer?.enqueue(Data(encoder.autoHeartRate(enabled: s.hrEnabled, intervalMinutes: s.hrIntervalMinutes)))
        writer?.enqueue(Data(encoder.writePref(ColmiCommandID.autoSpo2Pref, enabled: s.spo2Enabled)))
        writer?.enqueue(Data(encoder.writePref(ColmiCommandID.autoStressPref, enabled: s.stressEnabled)))
        writer?.enqueue(Data(encoder.writePref(ColmiCommandID.autoHRVPref, enabled: s.hrvEnabled)))
        writer?.enqueue(Data(encoder.writeTempPref(enabled: s.temperatureEnabled)))
    }

    // MARK: - User profile

    /// Store the profile without sending (the connect handshake sends it via `userPreferencesCommand`).
    func setUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
    }

    /// Store *and* immediately push the profile — the live path when the profile screen saves.
    func applyUserProfile(_ profile: UserProfileValues) {
        userProfile = profile
        writer?.enqueue(Data(userPreferencesCommand()))
    }

    /// Build the user-preferences command from the stored profile, falling back to the encoder's neutral
    /// defaults when no profile has been pushed yet.
    private func userPreferencesCommand() -> [UInt8] {
        guard let p = userProfile else { return encoder.userPreferences() }
        return encoder.userPreferences(
            metric: p.metric, gender: p.gender, age: p.age, heightCm: p.heightCm, weightKg: p.weightKg
        )
    }

    private func startHistorySync() {
        daysAgo = 0
        stage = .activity
        isVitalsBackfill = false
        receivedReplyThisRun = false
        // Zero the ring-history activity days we're about to re-sum, so re-syncs stay idempotent.
        Task { await PulseEventBus.shared.publish(.activitySyncReset(sinceDaysAgo: 7)) }
        requestActivity()
        armWatchdog()
    }

    /// Periodic re-sync while connected (the coordinator's 30-min staleness kick). The ring has no
    /// cursor — a re-run dumps everything it holds — but persistence upserts on (kind, timestamp) and
    /// `startHistorySync` resets the activity days it re-sums, so repeating is safe. Guarded so a kick
    /// can never cut a run already in flight short.
    func syncHistory() {
        guard stage == .idle || stage == .done else { return }
        startHistorySync()
    }

    /// Targeted post-workout backfill: pull only today's HR log and the all-day SpO2 log so samples
    /// the ring recorded while the phone was away land in the just-finished session (via the
    /// finished-session window in `linkSample`). Reuses the normal stage machine + watchdogs. A full
    /// sync already in flight covers the same data, so this is a no-op then.
    func startVitalsBackfill() {
        guard stage == .idle || stage == .done else { return }
        isVitalsBackfill = true
        receivedReplyThisRun = false
        daysAgo = 0
        stage = .heartRate
        requestHeartRate()
        armWatchdog()
    }

    // MARK: History-sync watchdog

    /// If a stage's expected reply never arrives (empty history / non-replying firmware), advance to
    /// the next stage instead of stalling the whole chain. Re-armed on every stage request; cancelled
    /// on each advance and on disconnect/finish.
    private var watchdog: Task<Void, Never>?
    // Not `private` so tests can shorten them.
    var watchdogTimeout: UInt64 = 10_000_000_000          // 10s for most stages
    var activityWatchdogTimeout: UInt64 = 20_000_000_000  // 20s — activity spans 8 days, can be slow

    private func armWatchdog() {
        watchdog?.cancel()
        let expected = stage
        // Activity is the one destructive stage (its days are reset on first bucket), so be extra
        // lenient: give it longer, and re-arm on every bucket so a brief ring pause can't skip days.
        let timeout = (expected == .activity) ? activityWatchdogTimeout : watchdogTimeout
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let self, self.stage == expected else { return }
            self.forceAdvanceStage(from: expected)
        }
    }

    /// Skip a stuck stage and request the next one. Mirrors the normal stage order.
    private func forceAdvanceStage(from stuck: Stage) {
        switch stuck {
        case .activity:
            daysAgo = 0; stage = .heartRate; requestHeartRate()
        case .heartRate:
            if isVitalsBackfill { stage = .spo2; requestSpo2() }
            else { daysAgo = 0; stage = .stress; requestStress() }
        case .stress:
            stage = .spo2; requestSpo2()
        case .spo2:
            if isVitalsBackfill { finishSync() }
            else { stage = .sleep; requestSleep() }
        case .sleep:
            daysAgo = 0; stage = .hrv; requestHRV()
        case .hrv:
            stage = .temperature; requestTemperature()
        case .temperature:
            finishSync()
        case .idle, .done:
            break
        }
        if stage != .done { armWatchdog() }
    }

    /// Generic `RingSyncEngine.handle` — for Colmi, big-data completion and history paging are driven
    /// through the driver's dedicated hooks, so this only needs to react to nothing here.
    func handle(_ event: RingDecodedEvent) {}

    // MARK: Stage requests

    private func requestActivity() {
        syncDay = dayStart(daysAgo)
        writer?.enqueue(Data(encoder.syncActivity(daysAgo: daysAgo)))
    }

    private func requestHeartRate() {
        syncDay = dayStart(daysAgo)
        pagedHeader = nil
        let unix = Int(syncDay.timeIntervalSince1970)
        writer?.enqueue(Data(encoder.syncHeartRate(fromUnix: unix)))
    }

    private func requestStress() {
        syncDay = dayStart(daysAgo)
        pagedHeader = nil
        stressDayRejected = false
        writer?.enqueue(Data(encoder.syncStress(daysAgo: daysAgo)))
    }

    private func requestHRV() {
        syncDay = dayStart(daysAgo)
        pagedHeader = nil
        writer?.enqueue(Data(encoder.syncHRV(daysAgo: daysAgo)))
    }

    private func requestSpo2() { writer?.enqueue(encoder.bigDataSpo2()) }
    private func requestSleep() { writer?.enqueue(encoder.bigDataSleep()) }
    private func requestTemperature() { writer?.enqueue(encoder.bigDataTemperature()) }

    private func dayStart(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    // MARK: Driver hooks (called from ColmiDriver.ingest)

    /// Decode a paged history frame for the current sync-day and advance the machine. Returns the
    /// decoded sample events for the bus.
    func handleHistoryFrame(_ data: Data) -> [RingDecodedEvent] {
        // Only the stage in flight asked for this opcode. Anything else is a late reply to a stage the
        // watchdog already skipped: it would be dated by *this* stage's day (HR pages carry no date), and
        // its terminal page would advance this stage's day. Drop it.
        guard let opcode = data.first, opcode == Self.historyOpcode(for: stage) else {
            syncLog.info("history frame 0x\(String(format: "%02x", data.first ?? 0), privacy: .public) outside its stage; dropped")
            return []
        }
        receivedReplyThisRun = true
        if let header = ColmiPagedHistoryHeader(data) { pagedHeader = header }
        let interval = (pagedHeader?.opcode == data.first) ? pagedHeader?.intervalMinutes : nil
        let bytes = [UInt8](data.prefix(3))
        if stage == .stress, daysAgo > 0, bytes.count == 3, bytes[0] == ColmiCommandID.syncStress,
           bytes[1] == 1, bytes[2] != UInt8(clamping: daysAgo) {
            let echoed = Int(bytes[2])
            syncLog.info("stress day \(self.daysAgo) echoed offset \(echoed); firmware ignores the day offset")
            stressDayRejected = true
        }
        let isRejectedStressDay = stage == .stress && stressDayRejected && data.first == ColmiCommandID.syncStress
        let events = isRejectedStressDay
            ? []
            : decoder.decodeHistory(data, day: syncDay, calendar: calendar, intervalMinutes: interval)
        advanceAfterPagedFrame(data)
        armWatchdog()   // progress made — reset the stall timer
        return events
    }

    /// A reassembled big-data frame completed (`type` = 0x25/0x27/0x2a). Advance to the next stage — but
    /// only when it answers the stage in flight. A late SpO2 reply after the watchdog moved on, or the
    /// all-day SpO2 log a spot check fetches while no sync runs (`startSpO2`), is decoded by the driver
    /// like any other; letting it advance the machine would re-request a stage or start a run from idle.
    func handleBigDataComplete(type: UInt8) {
        guard type == Self.bigDataType(for: stage) else { return }
        receivedReplyThisRun = true
        switch type {
        case ColmiCommandID.bigDataSpo2:
            if isVitalsBackfill { finishSync(); return }
            stage = .sleep
            requestSleep()
            armWatchdog()
        case ColmiCommandID.bigDataSleep:
            stage = .hrv
            daysAgo = 0
            requestHRV()
            armWatchdog()
        case ColmiCommandID.bigDataTemperature:
            finishSync()
        default:
            break
        }
    }

    /// Observe a realtime-HR reply. The keepalive itself is wall-clock driven (see `startHeartRate`);
    /// this only records frame arrival for diagnostics.
    func observedRealtimeHeartRate() {
        guard realtimeHRActive else { return }
        lastRealtimeFrameAt = Date()
    }

    /// Paged stages (activity/HR/stress/HRV) advance day-by-day, then to the next stage. We treat an
    /// empty marker (0xff) OR the final packet as "this day done".
    private func advanceAfterPagedFrame(_ data: Data) {
        let packetNr = ColmiDecoder.historyPacketNumber(data)
        let isEmpty = packetNr == 0xff
        // For paged HR/stress/HRV the day's header (packet 0) announces the packet count, so the day ends
        // on packet `total - 1` (a header announcing a single packet completes the day by itself).
        let dayComplete = isEmpty || isTerminalPacket(data)

        guard dayComplete else { return }

        switch stage {
        case .activity:
            if daysAgo < 7 { daysAgo += 1; requestActivity() }
            else { daysAgo = 0; stage = .heartRate; requestHeartRate() }
        case .heartRate:
            if isVitalsBackfill { stage = .spo2; requestSpo2() }
            else if daysAgo < 7 { daysAgo += 1; requestHeartRate() }
            else { daysAgo = 0; stage = .stress; requestStress() }
        case .stress:
            if !stressDayRejected && daysAgo < Self.stressPastDays { daysAgo += 1; requestStress() }
            else { daysAgo = 0; stage = .spo2; requestSpo2() }
        case .hrv:
            if daysAgo < 6 { daysAgo += 1; requestHRV() }
            else { stage = .temperature; requestTemperature() }
        default:
            break
        }
    }

    /// Terminal packet for paged stages. HR/stress/HRV: the packet numbered `totalPackets - 1` from the
    /// day's header. Without a usable header, the older heuristics stand: stress/HRV finish at packet 4
    /// (GadgetBridge) and HR relies on the watchdog. Activity finishes when `currentPacket ==
    /// totalPackets - 1` (bytes 5/6).
    private func isTerminalPacket(_ data: Data) -> Bool {
        let v = [UInt8](data)
        guard v.count >= 7 else { return false }
        if let header = pagedHeader, header.opcode == v[0] {
            return header.isFinalPacket(Int(v[1]))
        }
        switch v[0] {
        case ColmiCommandID.syncStress, ColmiCommandID.syncHRV:
            return Int(v[1]) == 4
        case ColmiCommandID.syncActivity:
            return Int(v[5]) == Int(v[6]) - 1
        case ColmiCommandID.syncHeartRate:
            // No header seen for this day: fall back to emptiness / the stage watchdog.
            return false
        default:
            return false
        }
    }

    /// End the run. `"done"` is what stamps `Device.lastFullSyncAt` and wakes the coach, so it is only
    /// published when the ring answered something; a run the watchdog walked through in silence (a
    /// link that died without iOS noticing yet) ends with `"incomplete"`, which only clears the bar.
    private func finishSync() {
        stage = .done
        isVitalsBackfill = false
        watchdog?.cancel()
        watchdog = nil
        let outcome = receivedReplyThisRun ? "done" : "incomplete"
        lastRunOutcome = outcome
        if !receivedReplyThisRun { syncLog.info("history run ended with no reply from the ring") }
        Task { await PulseEventBus.shared.publish(.syncProgress(stage: outcome)) }
    }

    // MARK: Realtime HR keepalive

    private var realtimeHRActive = false
    /// When the last realtime `0x1e` frame arrived — diagnostics only (keepalive is wall-clock driven).
    private(set) var lastRealtimeFrameAt: Date?
    /// Wall-clock keepalive: the ring times out realtime HR ~60s after the last continue command,
    /// so re-arm every 25s regardless of whether reply frames are arriving/parsing. (The previous
    /// packet-count keepalive starved itself when frames failed to parse — the stream died at 60s.)
    private var keepaliveTask: Task<Void, Never>?

    func startHeartRate() {
        realtimeHRActive = true
        writer?.enqueue(Data(encoder.realtimeHeartRate(enable: true)))
        syncLog.debug("realtime HR stream: start")
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, self.realtimeHRActive else { return }
                self.writer?.enqueue(Data(self.encoder.realtimeHeartRateContinue()))
                let last = self.lastRealtimeFrameAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
                syncLog.debug("realtime HR keepalive sent (last frame: \(last, privacy: .public))")
            }
        }
    }

    func stopHeartRate() {
        // Stop whichever HR mode is active. Spot uses the manual 0x69 stream; workout uses realtime 0x1e.
        if manualHRActive {
            manualHRActive = false
            writer?.enqueue(Data(encoder.manualHeartRate(enable: false)))
        }
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard realtimeHRActive else { return }
        realtimeHRActive = false
        writer?.enqueue(Data(encoder.realtimeHeartRate(enable: false)))
        syncLog.debug("realtime HR stream: stop")
    }

    /// Spot HR uses the ring's manual single measurement (0x69) — a *continuous* stream that warms up
    /// from 0 to a real bpm. The decoder maps each reply to a sample or `.heartRateComplete`
    /// (no-reading). Realtime 0x1e is reserved for the workout live stream. The coordinator settles
    /// over a short window then calls `stopHeartRate()`, which sends `0x69 02` to stop the stream.
    private var manualHRActive = false
    func measureHeartRateSpot() {
        manualHRActive = true
        writer?.enqueue(Data(encoder.manualHeartRate(enable: true)))
    }

    // On-demand HRV / stress / temperature (`0x69` types 0a/08/0b) — QRing's manual measure screens.
    var streamsSpotVitals: Bool { true }

    func startSpotVital(_ vital: SpotVital) {
        writer?.enqueue(Data(encoder.spotVital(vital, enable: true)))
    }

    /// `0x6A` stops the ring's whole realtime engine, the manual HR stream included, so drop that
    /// bookkeeping with it; the coordinator restarts a running workout's stream right after.
    func stopSpotVital(_ vital: SpotVital, settled: Double?) {
        manualHRActive = false
        let lastRaw = settled.map { Int($0.rounded()) } ?? 0   // ignored for temperature
        writer?.enqueue(Data(encoder.spotVital(vital, enable: false, lastRaw: lastRaw)))
    }

    func syncVitalsHistory() {
        startVitalsBackfill()
    }

    /// Re-request the ring's battery level (0x03), the same command `runStartup` sends on connect. The
    /// reply is decoded to a `.batteryLevel` event by the driver like any other.
    func requestBattery() {
        writer?.enqueue(Data(encoder.battery()))
    }

    // Colmi has no instant single-SpO2 reading; SpO2 is an all-day background metric. A "spot" SpO2
    // fetches the all-day history (enabled on connect) so the latest sample surfaces.
    func startSpO2() {
        writer?.enqueue(encoder.bigDataSpo2())
    }

    func stopSpO2() {}

    func findDevice() {
        writer?.enqueue(Data(encoder.findDevice()))
    }

    func setGoal(steps: Int) {
        // Colmi goals (0x21) write — left minimal; PulseLoop persists the goal regardless.
        // UNVERIFIED: exact goal-write payload; using read-back form is unsafe, so we skip the write.
    }
}
