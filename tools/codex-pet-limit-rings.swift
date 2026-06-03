import AppKit
import CoreGraphics
import Darwin
import Foundation
import SQLite3

struct LimitBucket {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }
}

struct LimitState {
    var planType: String?
    var primary: LimitBucket?
    var secondary: LimitBucket?
    var additional: [(name: String, bucket: LimitBucket)]
    var observedAt: Date
    var source: String

    static let empty = LimitState(planType: nil, primary: nil, secondary: nil, additional: [], observedAt: Date(), source: "none")
}

private func goalEffectiveTokens(inputTokens: Int64, cachedTokens: Int64, outputTokens: Int64) -> Int64 {
    max(0, inputTokens - cachedTokens) + max(0, outputTokens)
}

struct UsageCallSummary {
    var observedAt: Date
    var inputTokens: Int64
    var cachedTokens: Int64
    var outputTokens: Int64
    var effectiveTokens: Int64
}

struct UsageTurnSummary {
    var threadID: String
    var turnID: String?
    var windowLabel: String?
    var observedAt: Date
    var inputTokens: Int64
    var cachedTokens: Int64
    var outputTokens: Int64
    var effectiveTokens: Int64
    var calls: [UsageCallSummary]

    var callCount: Int {
        max(calls.count, 1)
    }
}

struct UsageSummaryTotals {
    var effectiveTokens: Int64
}

struct UsageSummary {
    var today: UsageSummaryTotals?
    var latestSession: UsageSummaryTotals?

    var hasTotals: Bool {
        today != nil || latestSession != nil
    }
}

struct LimitDelta {
    var primary: Double?
    var secondary: Double?
}

struct UsageDetails {
    var recentTurns: [UsageTurnSummary]
    var limitDelta: LimitDelta?
    var summary: UsageSummary?

    static let empty = UsageDetails(recentTurns: [], limitDelta: nil, summary: nil)
}

struct ThreadWindowSlot: Codable {
    var threadID: String
    var slot: Int
    var lastSeen: TimeInterval
}

private let limitStatePollInterval: TimeInterval = 20.0
private let petFrameFallbackPollInterval: TimeInterval = 2.0
private let petFrameStateDebounceInterval: TimeInterval = 0.035
private let dragFollowInterval: TimeInterval = 1.0 / 60.0
private let dragLiveMismatchTolerance: CGFloat = 96.0
private let stateCheckPulseDuration: TimeInterval = 0.85
private let usageToastPollInterval: TimeInterval = 2.0
private let usageToastDuration: TimeInterval = 8.0
private let usageToastMaxAge: TimeInterval = 60.0
private let hookUsageStateMaxAge: TimeInterval = 24.0 * 60.0 * 60.0
private let usageToastWidth: CGFloat = 192.0
private let usageMenuRowWidth: CGFloat = 440.0
private let usageMenuRowHeight: CGFloat = 24.0
private let usageBarTopPadding: CGFloat = 132.0
private let usageBarBottomPadding: CGFloat = 56.0
private let usageRingTopPadding: CGFloat = 132.0
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let barsOffsetXDefaultsKey = "CodexPetLimitRings.barsOffsetX"
private let barsOffsetYDefaultsKey = "CodexPetLimitRings.barsOffsetY"
private let barWidthPresetDefaultsKey = "CodexPetLimitRings.barWidthPreset"
private let displayStyleDefaultsKey = "CodexPetLimitRings.displayStyle"
private let turnUsageEnabledDefaultsKey = "CodexPetLimitRings.turnUsageEnabled"
private let usageToastEnabledDefaultsKey = "CodexPetLimitRings.usageToastEnabled"
private let threadWindowSlotsDefaultsKey = "CodexPetLimitRings.threadWindowSlots"
private let threadWindowSlotCount = 10
private let usageBarPositionStep: CGFloat = 4.0

enum UsageDisplayStyle: String, CaseIterable {
    case bars
    case rings

    var title: String {
        switch self {
        case .bars: return "Bars"
        case .rings: return "Rings"
        }
    }
}

private enum UsageBarWidthPreset: String, CaseIterable {
    case short
    case normal
    case wide

    var title: String {
        switch self {
        case .short: return "Short"
        case .normal: return "Normal"
        case .wide: return "Wide"
        }
    }

    var width: CGFloat {
        switch self {
        case .short: return 34.0
        case .normal: return 42.0
        case .wide: return 54.0
        }
    }
}

private enum UsageBarPositionAction: Int {
    case left
    case right
    case up
    case down
    case reset
}

private struct EventPayload: Decodable {
    var type: String
    var plan_type: String?
    var rate_limits: RatePayload?
    var additional_rate_limits: [String: RatePayload]?
}

private struct RatePayload: Decodable {
    var primary: BucketPayload?
    var secondary: BucketPayload?
    var primary_window: BucketPayload?
    var secondary_window: BucketPayload?
}

private struct BucketPayload: Decodable {
    var used_percent: Double?
    var window_minutes: Double?
    var limit_window_seconds: Double?
    var reset_at: Double?

    func toBucket() -> LimitBucket? {
        guard let used = used_percent else { return nil }
        let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
        if let minutes, minutes <= 0 {
            return nil
        }
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset_at)
    }
}

private struct ResponseUsagePayload: Decodable {
    var response: ResponseUsageBodyPayload?
    var usage: UsagePayload?

    var resolvedUsage: UsagePayload? {
        usage ?? response?.usage
    }
}

private struct ResponseUsageBodyPayload: Decodable {
    var usage: UsagePayload?
}

private struct UsagePayload: Decodable {
    var input_tokens: Int64?
    var input_tokens_details: InputTokenDetailsPayload?
    var output_tokens: Int64?
}

private struct InputTokenDetailsPayload: Decodable {
    var cached_tokens: Int64?
}

private struct HookUsageStatePayload: Decodable {
    var records: [HookUsageRecordPayload]?
    var skipped_turns: [HookSkippedTurnPayload]?
}

private struct HookUsageRecordPayload: Decodable {
    var thread_id: String?
    var session_id: String?
    var turn_id: String?
    var observed_at: Double?
    var input_tokens: Int64?
    var cached_tokens: Int64?
    var output_tokens: Int64?
    var effective_tokens: Int64?
    var calls: [HookUsageCallPayload]?
}

private struct HookUsageCallPayload: Decodable {
    var observed_at: Double?
    var input_tokens: Int64?
    var cached_tokens: Int64?
    var output_tokens: Int64?
    var effective_tokens: Int64?
}

private struct HookSkippedTurnPayload: Decodable {
    var thread_id: String?
    var session_id: String?
    var turn_id: String?
    var observed_at: Double?
}

private struct HookUsageSummaryPayload: Decodable {
    var today: HookUsageSummaryTotalsPayload?
    var latest_session: HookUsageSummaryTotalsPayload?
}

private struct HookUsageSummaryTotalsPayload: Decodable {
    var input_tokens: Int64?
    var cached_tokens: Int64?
    var output_tokens: Int64?
    var effective_tokens: Int64?
    var turn_count: Int?
    var call_count: Int?

    func toSummaryTotals() -> UsageSummaryTotals? {
        let inputTokens = input_tokens ?? 0
        let cachedTokens = cached_tokens ?? 0
        let outputTokens = output_tokens ?? 0
        let effectiveTokens = effective_tokens ?? goalEffectiveTokens(
            inputTokens: inputTokens,
            cachedTokens: cachedTokens,
            outputTokens: outputTokens
        )
        let turnCount = turn_count ?? 0
        let callCount = call_count ?? 0
        guard turnCount > 0 || callCount > 0 || effectiveTokens > 0 else {
            return nil
        }
        return UsageSummaryTotals(effectiveTokens: effectiveTokens)
    }
}

private struct TurnUsageSettingsPayload: Encodable {
    var version: Int
    var track_turn_usage: Bool
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var turnUsageStatePath: URL
    var turnUsageSummaryPath: URL
    var turnUsageSettingsPath: URL
    var previewPath: URL?
    var previewStyle: UsageDisplayStyle = .rings
    var previewUsesSampleData: Bool = false
    var previewShowsToasts: Bool = false
    var previewUsesBackground: Bool = false
    var fallbackSize: CGFloat = 220
    var mouseMonitorEnabled: Bool = true
}

final class LimitStateReader {
    private let logsPath: URL
    private let turnUsageStatePath: URL
    private let turnUsageSummaryPath: URL

    private struct UsageSample {
        var threadID: String
        var turnID: String?
        var observedAt: Date
        var inputTokens: Int64
        var cachedTokens: Int64
        var outputTokens: Int64
        var effectiveTokens: Int64

        func callSummary() -> UsageCallSummary {
            UsageCallSummary(
                observedAt: observedAt,
                inputTokens: inputTokens,
                cachedTokens: cachedTokens,
                outputTokens: outputTokens,
                effectiveTokens: effectiveTokens
            )
        }
    }

    private struct UsageAccumulator {
        var threadID: String
        var turnID: String?
        var observedAt: Date
        var inputTokens: Int64
        var cachedTokens: Int64
        var outputTokens: Int64
        var effectiveTokens: Int64
        var calls: [UsageCallSummary]

        var canAggregateOlderSamples: Bool {
            turnID != nil
        }

        mutating func add(_ sample: UsageSample) {
            inputTokens += sample.inputTokens
            cachedTokens += sample.cachedTokens
            outputTokens += sample.outputTokens
            effectiveTokens += sample.effectiveTokens
            calls.append(sample.callSummary())
        }

        func summary() -> UsageTurnSummary {
            UsageTurnSummary(
                threadID: threadID,
                turnID: turnID,
                windowLabel: nil,
                observedAt: observedAt,
                inputTokens: inputTokens,
                cachedTokens: cachedTokens,
                outputTokens: outputTokens,
                effectiveTokens: effectiveTokens,
                calls: calls.sorted { $0.observedAt < $1.observedAt }
            )
        }
    }

    init(logsPath: URL, turnUsageStatePath: URL, turnUsageSummaryPath: URL) {
        self.logsPath = logsPath
        self.turnUsageStatePath = turnUsageStatePath
        self.turnUsageSummaryPath = turnUsageSummaryPath
    }

    func readLatest() -> LimitState {
        return readLatestLog()
    }

    func readUsageDetails() -> UsageDetails {
        let hookTurns = readHookUsageTurns()
        let skippedTurnKeys = readHookSkippedTurnKeys()
        let summary = readHookUsageSummary()
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return hookTurns.isEmpty && summary == nil ? .empty : UsageDetails(recentTurns: hookTurns, limitDelta: nil, summary: summary)
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let db else {
            return hookTurns.isEmpty && summary == nil ? .empty : UsageDetails(recentTurns: hookTurns, limitDelta: nil, summary: summary)
        }
        defer { sqlite3_close(db) }

        let limitDelta = readLimitDelta(db: db)
        return UsageDetails(recentTurns: mergeRecentTurns(hookTurns: hookTurns, sqliteTurns: readRecentTurns(db: db, skippedTurnKeys: skippedTurnKeys)), limitDelta: limitDelta, summary: summary)
    }

    private func readLatestLog() -> LimitState {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ts, ts_nanos, feedback_log_body
        FROM logs INDEXED BY idx_logs_ts
        WHERE target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket event: {"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 40
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        var latest: LimitState?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cText = sqlite3_column_text(statement, 2) else {
                continue
            }
            let ts = sqlite3_column_int64(statement, 0)
            let tsNanos = sqlite3_column_int64(statement, 1)
            let observedAt = Date(timeIntervalSince1970: TimeInterval(ts) + TimeInterval(tsNanos) / 1_000_000_000.0)
            let body = String(cString: cText)
            guard let state = decodeRateLimitState(observedAt: observedAt, body: body) else {
                continue
            }
            guard isDisplayableLimitState(state) else {
                continue
            }

            guard var current = latest else {
                if state.secondary != nil {
                    return state
                }
                latest = state
                continue
            }

            if current.secondary == nil,
               let secondary = state.secondary,
               current.observedAt.timeIntervalSince(state.observedAt) <= hookUsageStateMaxAge {
                current.secondary = secondary
                return current
            }
        }

        return latest ?? .empty
    }

    private func isDisplayableLimitState(_ state: LimitState) -> Bool {
        hasDisplayableWindow(state.primary) || hasDisplayableWindow(state.secondary)
    }

    private func hasDisplayableWindow(_ bucket: LimitBucket?) -> Bool {
        guard let bucket else { return false }
        return (bucket.windowMinutes ?? 0.0) > 0.0
    }

    private func readRecentTurns(db: OpaquePointer, skippedTurnKeys: Set<String>) -> [UsageTurnSummary] {
        let sql = """
        SELECT ts, ts_nanos, thread_id, feedback_log_body
        FROM logs INDEXED BY idx_logs_ts
        WHERE target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%"usage":{"input_tokens"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 400
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var orderedTurnKeys: [String] = []
        var accumulators: [String: UsageAccumulator] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cBody = sqlite3_column_text(statement, 3) else {
                continue
            }

            let body = String(cString: cBody)
            let threadID = stringColumn(statement, 2) ?? parseDelimitedValue(after: "thread.id=", in: body)
            guard let threadID, !threadID.isEmpty else {
                continue
            }
            let ts = sqlite3_column_int64(statement, 0)
            let tsNanos = sqlite3_column_int64(statement, 1)
            let observedAt = Date(timeIntervalSince1970: TimeInterval(ts) + TimeInterval(tsNanos) / 1_000_000_000.0)
            guard let sample = parseUsageSample(threadID: threadID, observedAt: observedAt, body: body) else {
                continue
            }

            let turnKey = usageGroupKey(threadID: threadID, turnID: sample.turnID, observedAt: sample.observedAt)
            if skippedTurnKeys.contains(turnKey) {
                continue
            }
            if var accumulator = accumulators[turnKey] {
                if accumulator.canAggregateOlderSamples, accumulator.turnID == sample.turnID {
                    accumulator.add(sample)
                    accumulators[turnKey] = accumulator
                }
                continue
            }
            if orderedTurnKeys.count >= 3 {
                continue
            }

            orderedTurnKeys.append(turnKey)
            accumulators[turnKey] = UsageAccumulator(
                threadID: threadID,
                turnID: sample.turnID,
                observedAt: sample.observedAt,
                inputTokens: sample.inputTokens,
                cachedTokens: sample.cachedTokens,
                outputTokens: sample.outputTokens,
                effectiveTokens: sample.effectiveTokens,
                calls: [sample.callSummary()]
            )
        }

        return orderedTurnKeys.compactMap { accumulators[$0]?.summary() }
    }

    private func usageGroupKey(threadID: String, turnID: String?, observedAt: Date) -> String {
        [
            threadID,
            turnID ?? String(observedAt.timeIntervalSince1970)
        ].joined(separator: "|")
    }

    private func mergeRecentTurns(hookTurns: [UsageTurnSummary], sqliteTurns: [UsageTurnSummary]) -> [UsageTurnSummary] {
        var turnsByKey: [String: UsageTurnSummary] = [:]
        for turn in sqliteTurns {
            turnsByKey[usageGroupKey(threadID: turn.threadID, turnID: turn.turnID, observedAt: turn.observedAt)] = turn
        }
        for turn in hookTurns {
            let key = usageGroupKey(threadID: turn.threadID, turnID: turn.turnID, observedAt: turn.observedAt)
            if let existing = turnsByKey[key] {
                turnsByKey[key] = preferredTurn(existing: existing, candidate: turn)
            } else {
                turnsByKey[key] = turn
            }
        }
        return Array(turnsByKey.values.sorted { $0.observedAt > $1.observedAt }.prefix(3))
    }

    private func preferredTurn(existing: UsageTurnSummary, candidate: UsageTurnSummary) -> UsageTurnSummary {
        if candidate.calls.count != existing.calls.count {
            return candidate.calls.count > existing.calls.count ? candidate : existing
        }

        let existingTokens = existing.effectiveTokens
        let candidateTokens = candidate.effectiveTokens
        return candidateTokens >= existingTokens ? candidate : existing
    }

    private func readHookUsageTurns() -> [UsageTurnSummary] {
        guard FileManager.default.fileExists(atPath: turnUsageStatePath.path),
              let data = try? Data(contentsOf: turnUsageStatePath),
              let state = try? JSONDecoder().decode(HookUsageStatePayload.self, from: data),
              let records = state.records else {
            return []
        }

        var seenKeys = Set<String>()
        var turns: [UsageTurnSummary] = []
        for record in records.sorted(by: { ($0.observed_at ?? 0) > ($1.observed_at ?? 0) }) {
            let threadID = record.thread_id ?? record.session_id
            guard let threadID, !threadID.isEmpty else {
                continue
            }

            let observedAt = Date(timeIntervalSince1970: record.observed_at ?? Date().timeIntervalSince1970)
            guard Date().timeIntervalSince(observedAt) <= hookUsageStateMaxAge else {
                continue
            }
            let key = usageGroupKey(threadID: threadID, turnID: record.turn_id, observedAt: observedAt)
            guard !seenKeys.contains(key) else {
                continue
            }
            seenKeys.insert(key)

            let calls = hookCalls(from: record, observedAt: observedAt)
            let inputTokens = record.input_tokens ?? calls.reduce(Int64(0)) { $0 + $1.inputTokens }
            let cachedTokens = record.cached_tokens ?? calls.reduce(Int64(0)) { $0 + $1.cachedTokens }
            let outputTokens = record.output_tokens ?? calls.reduce(Int64(0)) { $0 + $1.outputTokens }
            let effectiveTokens = record.effective_tokens ?? calls.reduce(Int64(0)) { $0 + $1.effectiveTokens }
            turns.append(UsageTurnSummary(
                threadID: threadID,
                turnID: record.turn_id,
                windowLabel: nil,
                observedAt: observedAt,
                inputTokens: inputTokens,
                cachedTokens: cachedTokens,
                outputTokens: outputTokens,
                effectiveTokens: effectiveTokens,
                calls: calls
            ))

            if turns.count >= 3 {
                break
            }
        }
        return turns
    }

    private func readHookSkippedTurnKeys() -> Set<String> {
        guard FileManager.default.fileExists(atPath: turnUsageStatePath.path),
              let data = try? Data(contentsOf: turnUsageStatePath),
              let state = try? JSONDecoder().decode(HookUsageStatePayload.self, from: data),
              let skippedTurns = state.skipped_turns else {
            return []
        }

        var keys = Set<String>()
        for skippedTurn in skippedTurns {
            let threadID = skippedTurn.thread_id ?? skippedTurn.session_id
            guard let threadID, !threadID.isEmpty,
                  let turnID = skippedTurn.turn_id, !turnID.isEmpty else {
                continue
            }
            let observedAt = Date(timeIntervalSince1970: skippedTurn.observed_at ?? Date().timeIntervalSince1970)
            guard Date().timeIntervalSince(observedAt) <= hookUsageStateMaxAge else {
                continue
            }
            keys.insert(usageGroupKey(threadID: threadID, turnID: turnID, observedAt: observedAt))
        }
        return keys
    }

    private func readHookUsageSummary() -> UsageSummary? {
        guard FileManager.default.fileExists(atPath: turnUsageSummaryPath.path),
              let data = try? Data(contentsOf: turnUsageSummaryPath),
              let payload = try? JSONDecoder().decode(HookUsageSummaryPayload.self, from: data) else {
            return nil
        }

        let summary = UsageSummary(
            today: payload.today?.toSummaryTotals(),
            latestSession: payload.latest_session?.toSummaryTotals()
        )
        return summary.hasTotals ? summary : nil
    }

    private func hookCalls(from record: HookUsageRecordPayload, observedAt: Date) -> [UsageCallSummary] {
        let calls = record.calls?.compactMap { call -> UsageCallSummary? in
            guard let inputTokens = call.input_tokens,
                  let outputTokens = call.output_tokens else {
                return nil
            }
            return UsageCallSummary(
                observedAt: Date(timeIntervalSince1970: call.observed_at ?? observedAt.timeIntervalSince1970),
                inputTokens: inputTokens,
                cachedTokens: call.cached_tokens ?? 0,
                outputTokens: outputTokens,
                effectiveTokens: call.effective_tokens ?? goalEffectiveTokens(
                    inputTokens: inputTokens,
                    cachedTokens: call.cached_tokens ?? 0,
                    outputTokens: outputTokens
                )
            )
        } ?? []

        if !calls.isEmpty {
            return calls.sorted { $0.observedAt < $1.observedAt }
        }

        return [UsageCallSummary(
            observedAt: observedAt,
            inputTokens: record.input_tokens ?? 0,
            cachedTokens: record.cached_tokens ?? 0,
            outputTokens: record.output_tokens ?? 0,
            effectiveTokens: record.effective_tokens ?? goalEffectiveTokens(
                inputTokens: record.input_tokens ?? 0,
                cachedTokens: record.cached_tokens ?? 0,
                outputTokens: record.output_tokens ?? 0
            )
        )]
    }

    private func readLimitDelta(db: OpaquePointer) -> LimitDelta? {
        let sql = """
        SELECT ts, ts_nanos, feedback_log_body
        FROM logs INDEXED BY idx_logs_ts
        WHERE target = 'codex_api::endpoint::responses_websocket'
          AND feedback_log_body LIKE '%websocket event: {"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 2
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var states: [LimitState] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cText = sqlite3_column_text(statement, 2) else {
                continue
            }
            let ts = sqlite3_column_int64(statement, 0)
            let tsNanos = sqlite3_column_int64(statement, 1)
            let observedAt = Date(timeIntervalSince1970: TimeInterval(ts) + TimeInterval(tsNanos) / 1_000_000_000.0)
            let body = String(cString: cText)
            if let state = decodeRateLimitState(observedAt: observedAt, body: body) {
                states.append(state)
            }
        }

        guard states.count >= 2 else { return nil }
        let latest = states[0]
        let previous = states[1]
        return LimitDelta(
            primary: delta(latest.primary, previous.primary),
            secondary: delta(latest.secondary, previous.secondary)
        )
    }

    private func delta(_ latest: LimitBucket?, _ previous: LimitBucket?) -> Double? {
        guard let latest, let previous else { return nil }
        return latest.remainingPercent - previous.remainingPercent
    }

    private func decodeRateLimitState(observedAt: Date, body: String) -> LimitState? {
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data) else {
            return nil
        }

        let primary = (payload.rate_limits?.primary ?? payload.rate_limits?.primary_window)?.toBucket()
        let secondary = (payload.rate_limits?.secondary ?? payload.rate_limits?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [:])
            .compactMap { name, payload -> (String, LimitBucket)? in
                guard let bucket = (payload.primary ?? payload.primary_window ?? payload.secondary ?? payload.secondary_window)?.toBucket() else {
                    return nil
                }
                return (name, bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: observedAt, source: "log")
    }

    private func parseUsageSample(threadID: String, observedAt: Date, body: String) -> UsageSample? {
        guard let json = extractJSONEnvelope(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ResponseUsagePayload.self, from: data),
              let usage = payload.resolvedUsage,
              let inputTokens = usage.input_tokens,
              let outputTokens = usage.output_tokens else {
            return nil
        }

        let cachedTokens = usage.input_tokens_details?.cached_tokens ?? 0
        return UsageSample(
            threadID: threadID,
            turnID: parseDelimitedValue(after: "turn_id=", in: body)
                ?? parseDelimitedValue(after: "turn.id=", in: body)
                ?? parseDelimitedValue(after: "submission.id=", in: body),
            observedAt: observedAt,
            inputTokens: inputTokens,
            cachedTokens: cachedTokens,
            outputTokens: outputTokens,
            effectiveTokens: goalEffectiveTokens(inputTokens: inputTokens, cachedTokens: cachedTokens, outputTokens: outputTokens)
        )
    }

    private func parseDelimitedValue(after marker: String, in body: String) -> String? {
        guard let markerRange = body.range(of: marker) else {
            return nil
        }

        var index = markerRange.upperBound
        if index < body.endIndex, body[index] == "\"" {
            index = body.index(after: index)
            let start = index
            while index < body.endIndex, body[index] != "\"" {
                index = body.index(after: index)
            }
            guard start < index else { return nil }
            return String(body[start..<index])
        }

        let start = index
        while index < body.endIndex {
            let char = body[index]
            if char == "}" || char == ")" || char == "]" || char == "," || char == " " || char == "\t" || char == "\n" {
                break
            }
            index = body.index(after: index)
        }

        guard start < index else { return nil }
        return String(body[start..<index])
    }

    private func stringColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }

        return extractJSON(from: body, start: start)
    }

    private func extractJSONEnvelope(from body: String) -> String? {
        if let markerRange = body.range(of: "websocket event: "),
           let start = body[markerRange.upperBound...].firstIndex(of: "{") {
            return extractJSON(from: body, start: start)
        }

        guard let start = body.range(of: "{\"type\":\"response.")?.lowerBound ?? body.firstIndex(of: "{") else {
            return nil
        }

        return extractJSON(from: body, start: start)
    }

    private func extractJSON(from body: String, start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaping = false
        var endIndex: String.Index?
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = body.index(after: index)
                        break
                    }
                }
            }
            index = body.index(after: index)
        }

        guard let endIndex else { return nil }
        return String(body[start..<endIndex])
    }
}

struct PetFramesTopLeft {
    var mascot: CGRect
    var overlay: CGRect
    var usedLiveOverlay: Bool
}

final class PetFrameReader {
    private let globalStatePath: URL

    init(globalStatePath: URL) {
        self.globalStatePath = globalStatePath
    }

    func readPetFramesTopLeft(preferLiveOverlay: Bool = false, liveReference: CGRect? = nil) -> PetFramesTopLeft? {
        guard let data = try? Data(contentsOf: globalStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isAvatarOverlayOpen(root),
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = number(bounds["x"]),
              let y = number(bounds["y"]),
              let overlayWidth = number(bounds["width"]),
              let overlayHeight = number(bounds["height"]),
              let mascotPayload = bounds["mascot"] as? [String: Any],
              let left = number(mascotPayload["left"]),
              let top = number(mascotPayload["top"]),
              let width = number(mascotPayload["width"]),
              let height = number(mascotPayload["height"]) else {
            return nil
        }

        let persistedOverlay = CGRect(x: x, y: y, width: overlayWidth, height: overlayHeight)
        let liveOverlay = preferLiveOverlay ? liveCodexOverlayBounds(matching: liveReference ?? persistedOverlay, expectedSize: persistedOverlay.size) : nil
        let overlay = liveOverlay ?? persistedOverlay
        let mascot = CGRect(x: overlay.minX + left, y: overlay.minY + top, width: width, height: height)
        return PetFramesTopLeft(mascot: mascot, overlay: overlay, usedLiveOverlay: liveOverlay != nil)
    }

    func readPetFrameTopLeft(preferLiveOverlay: Bool = false) -> CGRect? {
        readPetFramesTopLeft(preferLiveOverlay: preferLiveOverlay)?.mascot
    }

    private func isAvatarOverlayOpen(_ root: [String: Any]) -> Bool {
        if let isOpen = root["electron-avatar-overlay-open"] as? Bool {
            return isOpen
        }
        if let isOpen = root["electron-avatar-overlay-open"] as? NSNumber {
            return isOpen.boolValue
        }
        return true
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }

    private func liveCodexOverlayBounds(matching reference: CGRect, expectedSize: CGSize) -> CGRect? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windows.compactMap { window -> CGRect? in
            let maxWidthDelta = max(80.0, expectedSize.width * 0.55)
            let maxHeightDelta = max(80.0, expectedSize.height * 0.55)
            guard (window[kCGWindowOwnerName as String] as? String) == "Codex",
                  let layer = number(window[kCGWindowLayer as String]),
                  layer > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]),
                  let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]),
                  let height = number(bounds["Height"]),
                  width >= 40.0,
                  height >= 40.0,
                  abs(width - expectedSize.width) <= maxWidthDelta,
                  abs(height - expectedSize.height) <= maxHeightDelta else {
                return nil
            }

            return CGRect(x: x, y: y, width: width, height: height)
        }
        .min {
            liveOverlayScore($0, reference: reference, expectedSize: expectedSize) < liveOverlayScore($1, reference: reference, expectedSize: expectedSize)
        }
    }

    private func liveOverlayScore(_ rect: CGRect, reference: CGRect, expectedSize: CGSize) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let distanceScore = distanceSquared(center, to: reference)
        let widthDelta = rect.width - expectedSize.width
        let heightDelta = rect.height - expectedSize.height
        return distanceScore + (widthDelta * widthDelta + heightDelta * heightDelta) * 8.0
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }
}

struct LimitRingRenderer {
    var state: LimitState
    var displayStyle: UsageDisplayStyle
    var barWidth: CGFloat
    var barOffset: CGSize
    var checkPulse: CGFloat
    var usageToastTurns: [UsageTurnSummary]
    var previewUsesBackground: Bool = false

    func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.clear(rect)
        if previewUsesBackground {
            context.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1.0).cgColor)
            context.fill(rect)
        }

        switch displayStyle {
        case .bars:
            drawProgressPanel(context, in: rect)
        case .rings:
            drawRings(context, in: rect)
        }
        if !usageToastTurns.isEmpty {
            drawUsageToast(context, in: rect, turns: usageToastTurns)
        }
        context.restoreGState()
    }

    private enum RingRole {
        case primary
        case secondary
    }

    private func drawRings(_ context: CGContext, in rect: CGRect) {
        let ringAreaHeight = max(1.0, rect.height - usageRingTopPadding)
        let center = CGPoint(x: rect.midX, y: ringAreaHeight / 2.0)
        let minSide = min(rect.width, ringAreaHeight)
        let urgency = max(urgency(for: state.primary), urgency(for: state.secondary))
        let phase = Double(1.0 - checkPulse)
        let breathe = max(CGFloat((sin(phase * 2.0 * .pi) + 1.0) * 0.5), checkPulse)
        let pulse = CGFloat(1.0 + urgency * 0.025 * breathe)
        let outerRadius = (minSide * 0.5 - 16.0) * pulse
        let innerRadius = outerRadius - 13.0

        drawHalo(context, center: center, radius: outerRadius, urgency: CGFloat(urgency), breathe: breathe)
        drawTicks(context, center: center, radius: outerRadius + 5.0)

        if let primary = state.primary {
            drawRing(
                context,
                center: center,
                radius: outerRadius,
                lineWidth: 7.0,
                bucket: primary,
                color: color(forRemaining: primary.remainingPercent, role: .primary),
                trackAlpha: 0.20,
                phase: phase
            )
        } else {
            drawMissingRing(context, center: center, radius: outerRadius, lineWidth: 7.0)
        }

        if let secondary = state.secondary {
            drawRing(
                context,
                center: center,
                radius: innerRadius,
                lineWidth: 4.5,
                bucket: secondary,
                color: color(forRemaining: secondary.remainingPercent, role: .secondary),
                trackAlpha: 0.14,
                phase: phase + 0.18
            )
        }

        drawModelLimitDots(context, center: center, radius: outerRadius + 11.0)
        drawFixedRingReadouts(context, center: center, outerRadius: outerRadius)
    }

    private func urgency(for bucket: LimitBucket?) -> Double {
        guard let bucket else { return 0.0 }
        return min(max((45.0 - bucket.remainingPercent) / 45.0, 0.0), 1.0)
    }

    private func drawHalo(_ context: CGContext, center: CGPoint, radius: CGFloat, urgency: CGFloat, breathe: CGFloat) {
        context.saveGState()
        let color = NSColor(calibratedRed: 0.23 + urgency * 0.55, green: 0.85 - urgency * 0.30, blue: 0.78 - urgency * 0.48, alpha: 0.22 + urgency * 0.16)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 14.0 + urgency * breathe * 5.0, color: color.withAlphaComponent(0.55).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.20).cgColor)
        context.setLineWidth(8.0)
        context.addArc(center: center, radius: radius + 3.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.045).cgColor)
        context.setLineWidth(1.0)
        context.addArc(center: center, radius: radius + 13.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawTicks(_ context: CGContext, center: CGPoint, radius: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        for i in 0..<24 {
            guard i % 2 == 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 24.0 * CGFloat.pi * 2.0
            let inner = radius - 1.5
            let outer = radius + 2.5
            context.move(to: point(center: center, radius: inner, angle: angle))
            context.addLine(to: point(center: center, radius: outer, angle: angle))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawRing(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        bucket: LimitBucket,
        color: NSColor,
        trackAlpha: CGFloat,
        phase: Double
    ) {
        let start = -CGFloat.pi / 2.0
        let remaining = CGFloat(bucket.remainingPercent / 100.0)
        let end = start + max(remaining, 0.018) * CGFloat.pi * 2.0

        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor(calibratedWhite: 0.0, alpha: 0.22).cgColor)
        context.addArc(center: center, radius: radius + 1.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: trackAlpha).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        context.setShadow(offset: .zero, blur: 10.0, color: color.withAlphaComponent(0.42).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.30).cgColor)
        context.setLineWidth(lineWidth + 6.0)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        context.setShadow(offset: .zero, blur: 4.0, color: color.withAlphaComponent(0.52).cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        let glintAngle = start + CGFloat(phase.truncatingRemainder(dividingBy: 1.0)) * CGFloat.pi * 2.0
        let glint = point(center: center, radius: radius, angle: glintAngle)
        context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.38).cgColor)
        context.fillEllipse(in: CGRect(x: glint.x - 1.8, y: glint.y - 1.8, width: 3.6, height: 3.6))
        context.restoreGState()
    }

    private func drawMissingRing(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 1.74, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawProgressPanel(_ context: CGContext, in rect: CGRect) {
        let rows = progressRows()
        guard !rows.isEmpty else { return }

        let panelWidth = min(max(barWidth + 72.0, rect.width - 10.0), 136.0)
        let rowHeight: CGFloat = 18.0
        let rowGap: CGFloat = 3.0
        let verticalPadding: CGFloat = 6.0
        let panelHeight = verticalPadding * 2.0 + CGFloat(rows.count) * rowHeight + CGFloat(max(rows.count - 1, 0)) * rowGap
        let panelRect = CGRect(
            x: rect.midX - panelWidth / 2.0 + barOffset.width,
            y: 4.0 - barOffset.height,
            width: panelWidth,
            height: panelHeight
        )
        for (index, row) in rows.enumerated() {
            let y = panelRect.maxY - verticalPadding - rowHeight - CGFloat(index) * (rowHeight + rowGap)
            drawProgressRow(context, row: row, y: y, panelRect: panelRect)
        }
    }

    private func progressRows() -> [(bucket: LimitBucket, role: RingRole)] {
        var rows: [(LimitBucket, RingRole)] = []
        if let primary = state.primary {
            rows.append((primary, .primary))
        }
        if let secondary = state.secondary {
            rows.append((secondary, .secondary))
        }
        return rows
    }

    private func drawProgressRow(
        _ context: CGContext,
        row: (bucket: LimitBucket, role: RingRole),
        y: CGFloat,
        panelRect: CGRect
    ) {
        let color = color(forRemaining: row.bucket.remainingPercent, role: row.role)
        let barHeight: CGFloat = 6.0
        let textGap: CGFloat = 7.0
        let textWidth: CGFloat = 34.0
        let barX = panelRect.midX - (barWidth + textGap + textWidth) / 2.0
        let barY = y + 6.5
        let textX = barX + barWidth + textGap
        let fillWidth = max(row.bucket.remainingPercent <= 0 ? 0 : 3.0, barWidth * CGFloat(row.bucket.remainingPercent / 100.0))

        let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        context.saveGState()
        drawCheckSweep(context, barRect: barRect, color: color)
        context.setFillColor(NSColor(calibratedWhite: 0.30, alpha: 0.30).cgColor)
        context.addPath(CGPath(roundedRect: barRect, cornerWidth: barHeight / 2.0, cornerHeight: barHeight / 2.0, transform: nil))
        context.fillPath()
        context.setFillColor(color.withAlphaComponent(0.94).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: barX, y: barY, width: fillWidth, height: barHeight), cornerWidth: barHeight / 2.0, cornerHeight: barHeight / 2.0, transform: nil))
        context.fillPath()
        drawBarBorder(context, barRect: barRect, color: color)
        context.restoreGState()

        let percent = NSAttributedString(string: formatPercent(row.bucket.remainingPercent), attributes: progressPercentAttributes(color: color))
        let detail = formatResetCountdown(row.bucket.resetAt).map {
            NSAttributedString(string: $0, attributes: progressDetailAttributes())
        }
        percent.draw(at: CGPoint(x: textX, y: y + 7.0))

        if let detail {
            detail.draw(at: CGPoint(x: textX, y: y - 0.5))
        }
    }

    private func drawBarBorder(_ context: CGContext, barRect: CGRect, color: NSColor) {
        let borderRect = barRect.insetBy(dx: -0.8, dy: -0.8)
        let radius = borderRect.height / 2.0
        context.setStrokeColor(color.withAlphaComponent(0.24 + 0.22 * checkPulse).cgColor)
        context.setLineWidth(1.0)
        context.addPath(CGPath(roundedRect: borderRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }

    private func drawCheckSweep(_ context: CGContext, barRect: CGRect, color: NSColor) {
        guard checkPulse > 0.01 else { return }
        let pulseRect = barRect.insetBy(dx: -1.6, dy: -1.6)
        let radius = pulseRect.height / 2.0
        let phase = 1.0 - checkPulse
        let sweepWidth = max(12.0, barRect.width * 0.46)
        let sweepStart = pulseRect.minX - sweepWidth + (pulseRect.width + sweepWidth * 2.0) * phase
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor.clear.cgColor,
            color.withAlphaComponent(0.42 * checkPulse).cgColor,
            NSColor(calibratedWhite: 1.0, alpha: 0.60 * checkPulse).cgColor,
            color.withAlphaComponent(0.46 * checkPulse).cgColor,
            NSColor.clear.cgColor
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.30, 0.50, 0.70, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            return
        }

        context.saveGState()
        context.setShadow(offset: .zero, blur: 5.0, color: color.withAlphaComponent(0.46 * checkPulse).cgColor)
        context.addPath(CGPath(roundedRect: pulseRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: sweepStart, y: pulseRect.midY),
            end: CGPoint(x: sweepStart + sweepWidth, y: pulseRect.midY),
            options: []
        )
        context.restoreGState()
    }

    private func drawFixedRingReadouts(_ context: CGContext, center: CGPoint, outerRadius: CGFloat) {
        let columnGap: CGFloat = 5.0
        var rowItems: [(percent: NSAttributedString, detail: NSAttributedString?, percentSize: CGSize, detailSize: CGSize, color: NSColor, width: CGFloat, height: CGFloat)] = []

        for row in progressRows().prefix(2) {
            let color = color(forRemaining: row.bucket.remainingPercent, role: row.role)
            let percent = NSAttributedString(string: formatPercent(row.bucket.remainingPercent), attributes: fixedReadoutPercentAttributes(color: color))
            let detail = formatResetCountdown(row.bucket.resetAt).map {
                NSAttributedString(string: $0, attributes: fixedReadoutDetailAttributes())
            }
            let percentSize = percent.size()
            let detailSize = detail?.size() ?? .zero
            let width = max(44.0, ceil(max(percentSize.width, detailSize.width) + 15.0))
            let height = max(30.0, ceil(percentSize.height + (detail == nil ? 0.0 : detailSize.height) + 7.0))
            rowItems.append((percent, detail, percentSize, detailSize, color, width, height))
        }

        guard !rowItems.isEmpty else { return }

        let totalWidth = rowItems.map(\.width).reduce(0.0, +) + CGFloat(rowItems.count - 1) * columnGap
        let maxHeight = rowItems.map(\.height).max() ?? 30.0
        let y = max(6.0, center.y - outerRadius + 4.0)
        var x = center.x - totalWidth / 2.0

        for item in rowItems {
            let rect = CGRect(x: x, y: y + (maxHeight - item.height) / 2.0, width: item.width, height: item.height)
            drawFixedRingReadoutBadge(context, item: item, rect: rect)
            x += item.width + columnGap
        }
    }

    private func drawFixedRingReadoutBadge(
        _ context: CGContext,
        item: (percent: NSAttributedString, detail: NSAttributedString?, percentSize: CGSize, detailSize: CGSize, color: NSColor, width: CGFloat, height: CGFloat),
        rect: CGRect
    ) {
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
        context.setShadow(offset: CGSize(width: 0.0, height: -1.0), blur: 7.0, color: NSColor.black.withAlphaComponent(0.24).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 0.66).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(item.color.withAlphaComponent(0.34).cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        if let detail = item.detail {
            let totalHeight = item.percentSize.height + item.detailSize.height - 1.0
            let detailY = rect.midY - totalHeight / 2.0 - 0.5
            let percentY = detailY + item.detailSize.height - 1.0
            item.percent.draw(at: CGPoint(x: rect.midX - item.percentSize.width / 2.0, y: percentY))
            detail.draw(at: CGPoint(x: rect.midX - item.detailSize.width / 2.0, y: detailY))
        } else {
            item.percent.draw(at: CGPoint(x: rect.midX - item.percentSize.width / 2.0, y: rect.midY - item.percentSize.height / 2.0 + 0.5))
        }
        context.restoreGState()
    }

    private func drawUsageToast(_ context: CGContext, in rect: CGRect, turns: [UsageTurnSummary]) {
        let cards = turns.prefix(3).map { turn -> (rows: [NSAttributedString], sizes: [CGSize], height: CGFloat) in
            let rows = usageToastCardRows(for: turn)
            let sizes = rows.map { $0.size() }
            let contentHeight = sizes.map(\.height).reduce(0.0, +) + CGFloat(max(0, rows.count - 1)) * 1.0
            return (rows, sizes, ceil(contentHeight + 11.0))
        }
        guard !cards.isEmpty else { return }

        let cardGap: CGFloat = 5.0
        let contentWidth = cards.flatMap(\.sizes).map(\.width).max() ?? 0.0
        let width = min(max(126.0, ceil(contentWidth + 14.0)), rect.width - 8.0)
        let stackHeight = cards.map(\.height).reduce(0.0, +) + CGFloat(cards.count - 1) * cardGap
        let stackBottom: CGFloat
        switch displayStyle {
        case .bars:
            let petTop = rect.height - usageBarTopPadding
            stackBottom = max(6.0, min(rect.height - stackHeight - 6.0, petTop + 8.0))
        case .rings:
            let ringTop = rect.height - usageRingTopPadding
            let firstCardHeight = cards.first?.height ?? 0.0
            let previousStart = ringTop - firstCardHeight - 8.0
            stackBottom = max(6.0, min(rect.height - stackHeight - 6.0, previousStart))
        }

        context.saveGState()
        var cardBottom = stackBottom
        for card in cards {
            let badgeRect = CGRect(x: rect.midX - width / 2.0, y: cardBottom, width: width, height: card.height)
            drawUsageToastCard(context, rect: badgeRect, rows: card.rows, sizes: card.sizes)
            cardBottom += card.height + cardGap
        }
        context.restoreGState()
    }

    private func usageToastCardRows(for turn: UsageTurnSummary) -> [NSAttributedString] {
        let text = NSMutableAttributedString(string: "")
        text.append(NSAttributedString(string: "\(shortUsageID(for: turn)) ", attributes: toastDetailAttributes()))
        text.append(NSAttributedString(string: "\(turn.callCount)c", attributes: toastMetricAttributes(color: toastUsedColor(), size: 9.0)))
        text.append(NSAttributedString(string: "  ", attributes: toastDetailAttributes()))
        appendUsageMetric("Used ", formatTokenCount(turn.effectiveTokens), color: toastUsedColor(), size: 9.0, to: text)
        return [text]
    }

    private func drawUsageToastCard(_ context: CGContext, rect: CGRect, rows: [NSAttributedString], sizes: [CGSize]) {
        let path = CGPath(roundedRect: rect, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
        context.setShadow(offset: CGSize(width: 0.0, height: -1.0), blur: 9.0, color: NSColor.black.withAlphaComponent(0.24).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.72).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        var rowY = rect.maxY - 5.5
        for (row, size) in zip(rows, sizes) {
            rowY -= size.height
            row.draw(at: CGPoint(x: rect.minX + 7.0, y: rowY))
            rowY -= 1.0
        }
    }

    private func shortUsageID(for turn: UsageTurnSummary) -> String {
        guard let turnID = turn.turnID, !turnID.isEmpty else {
            return turn.windowLabel ?? compactID(turn.threadID)
        }
        if let windowLabel = turn.windowLabel, !windowLabel.isEmpty {
            return "\(windowLabel)/\(compactID(turnID))"
        }
        return "\(compactID(turn.threadID))/\(compactID(turnID))"
    }

    private func compactID(_ id: String) -> String {
        let compact = id.replacingOccurrences(of: "-", with: "")
        guard compact.count > 4 else {
            return compact
        }
        return String(compact.suffix(4))
    }

    private func appendUsageMetric(_ label: String, _ value: String, color: NSColor, size: CGFloat = 8.2, to text: NSMutableAttributedString) {
        text.append(NSAttributedString(string: label, attributes: toastMetricLabelAttributes()))
        text.append(NSAttributedString(string: value, attributes: toastMetricAttributes(color: color, size: size)))
    }

    private func drawModelLimitDots(_ context: CGContext, center: CGPoint, radius: CGFloat) {
        let dots = Array(state.additional.prefix(8))
        guard dots.count > 0 else { return }
        context.saveGState()
        for (index, item) in dots.enumerated() {
            let angle = -CGFloat.pi / 2.0 + CGFloat(index) / CGFloat(max(dots.count, 1)) * CGFloat.pi * 2.0
            let dot = point(center: center, radius: radius, angle: angle)
            let color = color(forRemaining: item.bucket.remainingPercent, role: .primary)
            context.setShadow(offset: .zero, blur: 5.0, color: color.withAlphaComponent(0.35).cgColor)
            context.setFillColor(color.withAlphaComponent(0.82).cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - 2.4, y: dot.y - 2.4, width: 4.8, height: 4.8))
        }
        context.restoreGState()
    }

    private func color(forRemaining remaining: Double, role: RingRole) -> NSColor {
        if remaining <= 12 {
            return NSColor(calibratedRed: 1.00, green: 0.26, blue: 0.22, alpha: 0.96)
        }
        if remaining <= 30 {
            return NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 0.96)
        }
        if role == .secondary {
            return NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.00, alpha: 0.90)
        }
        return NSColor(calibratedRed: 0.24, green: 0.92, blue: 0.74, alpha: 0.96)
    }

    private func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private func formatTokenCount(_ tokens: Int64) -> String {
        let value = Double(tokens)
        guard value >= 1_000 else {
            return "\(tokens)"
        }

        let thousands = value / 1_000.0
        if thousands >= 100 {
            return String(format: "%.0fk", thousands)
        }
        if abs(thousands.rounded() - thousands) < 0.05 {
            return "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fk", thousands)
    }

    private func formatResetCountdown(_ resetAt: TimeInterval?) -> String? {
        guard var resetAt else { return nil }
        if resetAt > 10_000_000_000 {
            resetAt /= 1000.0
        }

        let seconds = max(0, resetAt - Date().timeIntervalSince1970)
        if seconds <= 0 {
            return "soon"
        }
        if seconds < 60 {
            return "<1m"
        }
        if seconds >= 2.0 * 24.0 * 60.0 * 60.0 {
            return "\(Int(ceil(seconds / (24.0 * 60.0 * 60.0))))d"
        }

        let minutes = Int(ceil(seconds / 60.0))
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            if hours >= 6 || remainingMinutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(remainingMinutes)m"
        }

        let days = hours / 24
        let remainingHours = hours % 24
        if days >= 7 || remainingHours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(remainingHours)h"
    }

    private func progressPercentAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 10.0, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.94)
        ]
    }

    private func progressDetailAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 8.2, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.54, alpha: 0.92)
        ]
    }

    private func fixedReadoutPercentAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 10.6, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.96)
        ]
    }

    private func fixedReadoutDetailAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 8.4, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.72)
        ]
    }

    private func toastDetailAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 8.2, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.70)
        ]
    }

    private func toastMetricLabelAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 8.2, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.48)
        ]
    }

    private func toastMetricAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color
        ]
    }

    private func toastUsedColor() -> NSColor {
        NSColor(calibratedRed: 0.24, green: 0.92, blue: 0.74, alpha: 0.96)
    }

}

final class LimitRingView: NSView {
    var state: LimitState = .empty {
        didSet { needsDisplay = true }
    }
    var displayStyle: UsageDisplayStyle = .bars {
        didSet { needsDisplay = true }
    }
    var barWidth: CGFloat = UsageBarWidthPreset.normal.width {
        didSet { needsDisplay = true }
    }
    var barOffset: CGSize = .zero {
        didSet { needsDisplay = true }
    }
    var checkPulse: CGFloat = 0.0 {
        didSet { needsDisplay = true }
    }
    var usageToastTurns: [UsageTurnSummary] = [] {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(state: state, displayStyle: displayStyle, barWidth: barWidth, barOffset: barOffset, checkPulse: checkPulse, usageToastTurns: usageToastTurns).draw(in: bounds)
    }
}

final class LimitRingsApp: NSObject, NSMenuDelegate {
    private let config: LimitRingsConfig
    private let stateReader: LimitStateReader
    private let frameReader: PetFrameReader
    private let panel: NSPanel
    private let ringView: LimitRingView
    private let stateQueue = DispatchQueue(label: "codex-pet-limit-rings.state-reader")
    private var statusItem: NSStatusItem?
    private var summaryItem: NSMenuItem?
    private var recentUsageHeaderItem: NSMenuItem?
    private var recentUsageSummaryItem: NSMenuItem?
    private var recentUsageItems: [NSMenuItem] = []
    private var limitDeltaSeparatorItem: NSMenuItem?
    private var limitDeltaItem: NSMenuItem?
    private var turnUsageItem: NSMenuItem?
    private var usageToastItem: NSMenuItem?
    private var showRingsItem: NSMenuItem?
    private var displayStyleItems: [NSMenuItem] = []
    private var barControlsSeparatorItem: NSMenuItem?
    private var positionMenuItem: NSMenuItem?
    private var barWidthMenuItem: NSMenuItem?
    private var positionControl: NSSegmentedControl?
    private var positionLabel: NSTextField?
    private var barWidthItems: [NSMenuItem] = []
    private var stateTimer: Timer?
    private var usageTimer: Timer?
    private var frameTimer: Timer?
    private var dragFollowTimer: Timer?
    private var usageToastTimer: Timer?
    private var stateCheckPulseTimer: Timer?
    private var stateCheckPulseStartedAt: Date?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var globalStateSource: DispatchSourceFileSystemObject?
    private var pendingGlobalStateWatcherRestart: DispatchWorkItem?
    private var pendingFrameUpdate: DispatchWorkItem?
    private var currentPetFrameAppKit: CGRect?
    private var currentPetOverlayTopLeft: CGRect?
    private var currentPetOverlayFrameAppKit: CGRect?
    private var isTrackingMouseDrag = false
    private var dragMouseToPetOriginOffsetAppKit: CGPoint?
    private var dragMouseToOverlayOriginOffsetAppKit: CGPoint?
    private var holdDraggedFrameUntil: Date?
    private var ringsVisible: Bool
    private var displayStyle: UsageDisplayStyle
    private var usageBarOffset: CGSize
    private var barWidthPreset: UsageBarWidthPreset
    private var turnUsageEnabled: Bool
    private var usageToastEnabled: Bool
    private var usageDetails: UsageDetails = .empty
    private var stateReadInFlight = false
    private var usageReadInFlight = false
    private var hasPrimedUsageToast = false
    private var lastUsageToastSignatures: [String: String] = [:]
    private var threadWindowSlots: [String: ThreadWindowSlot] = [:]

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(
            logsPath: config.logsPath,
            turnUsageStatePath: config.turnUsageStatePath,
            turnUsageSummaryPath: config.turnUsageSummaryPath
        )
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.turnUsageEnabled = UserDefaults.standard.object(forKey: turnUsageEnabledDefaultsKey) as? Bool ?? false
        self.usageToastEnabled = UserDefaults.standard.object(forKey: usageToastEnabledDefaultsKey) as? Bool ?? true
        self.displayStyle = UsageDisplayStyle(rawValue: UserDefaults.standard.string(forKey: displayStyleDefaultsKey) ?? "") ?? .rings
        self.usageBarOffset = CGSize(
            width: CGFloat(UserDefaults.standard.double(forKey: barsOffsetXDefaultsKey)),
            height: CGFloat(UserDefaults.standard.double(forKey: barsOffsetYDefaultsKey))
        )
        self.barWidthPreset = UsageBarWidthPreset(rawValue: UserDefaults.standard.string(forKey: barWidthPresetDefaultsKey) ?? "") ?? .normal
        self.threadWindowSlots = Self.loadThreadWindowSlots()
        self.panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = ringView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        super.init()
        ringView.displayStyle = displayStyle
        ringView.barWidth = barWidthPreset.width
        ringView.barOffset = usageBarOffset
        writeTurnUsageSettings()
    }

    deinit {
        stateTimer?.invalidate()
        usageTimer?.invalidate()
        frameTimer?.invalidate()
        dragFollowTimer?.invalidate()
        usageToastTimer?.invalidate()
        stateCheckPulseTimer?.invalidate()
        pendingGlobalStateWatcherRestart?.cancel()
        pendingFrameUpdate?.cancel()
        globalStateSource?.cancel()
        [mouseDownMonitor, mouseDragMonitor, mouseUpMonitor].compactMap { $0 }.forEach {
            NSEvent.removeMonitor($0)
        }
    }

    func run() {
        installStatusMenu()
        updateState()
        updateFrame()
        installGlobalStateWatcher()
        updateRingVisibility()

        stateTimer = Timer.scheduledTimer(withTimeInterval: limitStatePollInterval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
        updateUsageTimer()
        frameTimer = Timer.scheduledTimer(withTimeInterval: petFrameFallbackPollInterval, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
        if config.mouseMonitorEnabled {
            installDragFollow()
        }
    }

    private func updateState(showToast: Bool = true) {
        guard !stateReadInFlight else { return }
        stateReadInFlight = true
        let shouldReadUsage = turnUsageEnabled
        stateQueue.async { [weak self] in
            guard let self else { return }
            let state = self.stateReader.readLatest()
            let usageDetails = shouldReadUsage ? self.stateReader.readUsageDetails() : .empty
            DispatchQueue.main.async {
                self.ringView.state = state
                if shouldReadUsage, self.turnUsageEnabled {
                    self.applyUsageDetails(usageDetails, showToast: showToast)
                }
                self.updateSummaryMenuItem()
                self.stateReadInFlight = false
                self.triggerStateCheckPulse()
            }
        }
    }

    private func updateUsageDetails() {
        guard turnUsageEnabled, !usageReadInFlight else { return }
        usageReadInFlight = true
        stateQueue.async { [weak self] in
            guard let self else { return }
            let usageDetails = self.stateReader.readUsageDetails()
            DispatchQueue.main.async {
                if self.turnUsageEnabled {
                    self.applyUsageDetails(usageDetails, showToast: true)
                }
                self.usageReadInFlight = false
            }
        }
    }

    private func updateUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = nil
        guard turnUsageEnabled else { return }
        usageTimer = Timer.scheduledTimer(withTimeInterval: usageToastPollInterval, repeats: true) { [weak self] _ in
            self?.updateUsageDetails()
        }
    }

    private func writeTurnUsageSettings() {
        let payload = TurnUsageSettingsPayload(version: 1, track_turn_usage: turnUsageEnabled)
        do {
            let data = try JSONEncoder().encode(payload)
            let directory = config.turnUsageSettingsPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let lockFD = open(turnUsageLifecycleLockPath.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if lockFD >= 0 {
                defer {
                    flock(lockFD, LOCK_UN)
                    close(lockFD)
                }
                fchmod(lockFD, S_IRUSR | S_IWUSR)
                flock(lockFD, LOCK_EX)
            }
            try data.write(to: config.turnUsageSettingsPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.turnUsageSettingsPath.path)
            if !turnUsageEnabled {
                clearTurnUsageQueueFiles()
            }
        } catch {
            fputs("codex-pet-limit-rings: failed to write turn usage settings: \(error)\n", stderr)
        }
    }

    private var turnUsageLifecycleLockPath: URL {
        config.turnUsageSettingsPath
            .deletingLastPathComponent()
            .appendingPathComponent("turn-usage-lifecycle.lock")
    }

    private func clearTurnUsageQueueFiles() {
        let directory = config.turnUsageSettingsPath.deletingLastPathComponent()
        removeFileIfPresent(directory.appendingPathComponent("turn-usage-queue.jsonl"))
        removeFileIfPresent(directory.appendingPathComponent("turn-usage-queue.jsonl.tmp"))
    }

    private func removeFileIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            fputs("codex-pet-limit-rings: failed to remove \(url.path): \(error)\n", stderr)
        }
    }

    private func triggerStateCheckPulse() {
        stateCheckPulseStartedAt = Date()
        stateCheckPulseTimer?.invalidate()

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            self?.updateStateCheckPulse(timer)
        }
        stateCheckPulseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateStateCheckPulse(timer)
    }

    private func updateStateCheckPulse(_ timer: Timer) {
        guard let stateCheckPulseStartedAt else {
            timer.invalidate()
            stateCheckPulseTimer = nil
            ringView.checkPulse = 0.0
            return
        }

        let elapsed = Date().timeIntervalSince(stateCheckPulseStartedAt)
        guard elapsed < stateCheckPulseDuration else {
            timer.invalidate()
            if stateCheckPulseTimer === timer {
                stateCheckPulseTimer = nil
            }
            self.stateCheckPulseStartedAt = nil
            ringView.checkPulse = 0.0
            return
        }

        ringView.checkPulse = CGFloat(1.0 - elapsed / stateCheckPulseDuration)
    }

    private func installGlobalStateWatcher() {
        pendingGlobalStateWatcherRestart?.cancel()
        pendingGlobalStateWatcherRestart = nil
        globalStateSource?.cancel()
        globalStateSource = nil

        let descriptor = open(config.globalStatePath.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleGlobalStateWatcherRestart(after: 1.0)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.globalStateSource?.data ?? []
            self.scheduleFrameUpdateFromGlobalState()
            if events.contains(.delete) || events.contains(.rename) {
                self.scheduleGlobalStateWatcherRestart(after: 0.2)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        globalStateSource = source
        source.resume()
    }

    private func scheduleGlobalStateWatcherRestart(after delay: TimeInterval) {
        pendingGlobalStateWatcherRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGlobalStateWatcherRestart = nil
            self.installGlobalStateWatcher()
            self.scheduleFrameUpdateFromGlobalState()
        }
        pendingGlobalStateWatcherRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleFrameUpdateFromGlobalState() {
        pendingFrameUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFrameUpdate = nil
            self.updateFrame()
        }
        pendingFrameUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + petFrameStateDebounceInterval, execute: work)
    }

    private func updateFrame(preferLiveOverlay: Bool = false) {
        if let holdDraggedFrameUntil, Date() < holdDraggedFrameUntil {
            return
        }
        holdDraggedFrameUntil = nil
        if isTrackingMouseDrag && !preferLiveOverlay {
            return
        }

        let liveReference = preferLiveOverlay ? currentPetOverlayTopLeft : nil
        guard let petFrames = frameReader.readPetFramesTopLeft(preferLiveOverlay: preferLiveOverlay, liveReference: liveReference) else {
            currentPetFrameAppKit = nil
            currentPetOverlayTopLeft = nil
            currentPetOverlayFrameAppKit = nil
            isTrackingMouseDrag = false
            dragMouseToPetOriginOffsetAppKit = nil
            dragMouseToOverlayOriginOffsetAppKit = nil
            stopDragFollowTimer()
            panel.orderOut(nil)
            return
        }

        if preferLiveOverlay,
           isTrackingMouseDrag,
           !petFrames.usedLiveOverlay,
           currentPetFrameAppKit != nil {
            return
        }

        applyPetFrames(petFrames)
    }

    private func applyPetFrames(_ petFrames: PetFramesTopLeft) {
        currentPetFrameAppKit = appKitRectFromTopLeft(petFrames.mascot)
        currentPetOverlayTopLeft = petFrames.overlay
        currentPetOverlayFrameAppKit = appKitRectFromTopLeft(petFrames.overlay)
        setPanelFrame(forPetFrameTopLeft: petFrames.mascot)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
    }

    private func setPanelFrame(forPetFrameTopLeft petFrame: CGRect) {
        let size = overlaySize(for: petFrame)
        let topLeft: CGPoint
        switch displayStyle {
        case .bars:
            topLeft = CGPoint(
                x: petFrame.midX - size.width / 2,
                y: petFrame.minY - usageBarTopPadding
            )
        case .rings:
            let side = ringOverlaySide(for: petFrame)
            topLeft = CGPoint(
                x: petFrame.midX - size.width / 2,
                y: petFrame.midY - side / 2 - usageRingTopPadding
            )
        }
        let origin = appKitOriginFromTopLeft(topLeft, size: size)

        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func setPanelFrame(forPetFrameAppKit petFrame: CGRect) {
        let size = overlaySize(for: petFrame)
        let origin: CGPoint
        switch displayStyle {
        case .bars:
            origin = CGPoint(
                x: petFrame.midX - size.width / 2,
                y: petFrame.maxY + usageBarTopPadding - size.height
            )
        case .rings:
            let side = ringOverlaySide(for: petFrame)
            origin = CGPoint(x: petFrame.midX - size.width / 2, y: petFrame.midY - side / 2)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func overlaySize(for petFrame: CGRect) -> CGSize {
        switch displayStyle {
        case .bars:
            return progressOverlaySize(for: petFrame)
        case .rings:
            return ringOverlaySize(for: petFrame)
        }
    }

    private func progressOverlaySize(for petFrame: CGRect) -> CGSize {
        CGSize(
            width: max(132.0, ringOverlaySide(for: petFrame), barWidthPreset.width + 72.0, usageToastWidth + 8.0),
            height: petFrame.height + usageBarBottomPadding + usageBarTopPadding
        )
    }

    private func ringOverlaySize(for petFrame: CGRect) -> CGSize {
        let side = ringOverlaySide(for: petFrame)
        return CGSize(width: max(side, usageToastWidth + 8.0), height: side + usageRingTopPadding)
    }

    private var ringOverlayPadding: CGFloat {
        38.0
    }

    private func ringOverlaySide(for petFrame: CGRect) -> CGFloat {
        max(petFrame.width, petFrame.height) + ringOverlayPadding * 2.0
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Codex Pet Usage Overlay"
        }

        let menu = NSMenu()
        menu.delegate = self
        let summary = NSMenuItem(title: "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())
        installUsageDetailsMenuItems(in: menu)
        menu.addItem(.separator())

        let turnUsageItem = NSMenuItem(title: "Track Turn Usage", action: #selector(toggleTurnUsage(_:)), keyEquivalent: "")
        turnUsageItem.target = self
        menu.addItem(turnUsageItem)
        self.turnUsageItem = turnUsageItem

        let usageToastItem = NSMenuItem(title: "Show Usage Toasts", action: #selector(toggleUsageToasts(_:)), keyEquivalent: "")
        usageToastItem.target = self
        menu.addItem(usageToastItem)
        self.usageToastItem = usageToastItem

        let showItem = NSMenuItem(title: "Show Usage Overlay", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(makeDisplayStyleMenuItem())
        let barControlsSeparator = NSMenuItem.separator()
        menu.addItem(barControlsSeparator)
        barControlsSeparatorItem = barControlsSeparator
        menu.addItem(makeBarWidthMenuItem())
        menu.addItem(makePositionMenuItem())
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateSummaryMenuItem()
        updateUsageDetailsMenuItems()
        updateTurnUsageMenuItem()
        updateUsageToastMenuItem()
        updateShowRingsMenuItem()
        updateDisplayStyleMenuItems()
        updateBarWidthMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateSummaryMenuItem()
        updateTurnUsageMenuItem()
        updateUsageToastMenuItem()
        updateShowRingsMenuItem()
        updateDisplayStyleMenuItems()
        updateBarWidthMenuItems()
        updateState(showToast: false)
    }

    private func refreshUsageDetailsNow() {
        guard turnUsageEnabled else {
            clearUsageDetails()
            return
        }
        applyUsageDetails(stateReader.readUsageDetails(), showToast: false)
    }

    private func applyUsageDetails(_ usageDetails: UsageDetails, showToast: Bool) {
        guard turnUsageEnabled else {
            clearUsageDetails()
            return
        }
        let labeledUsageDetails = applyWindowLabels(to: usageDetails)
        self.usageDetails = labeledUsageDetails
        updateUsageDetailsMenuItems()
        if showToast, usageToastEnabled {
            updateUsageToast(from: labeledUsageDetails)
        }
    }

    private func clearUsageDetails() {
        usageToastTimer?.invalidate()
        usageToastTimer = nil
        usageDetails = .empty
        ringView.usageToastTurns = []
        hasPrimedUsageToast = false
        lastUsageToastSignatures = [:]
        updateUsageDetailsMenuItems()
    }

    private func applyWindowLabels(to usageDetails: UsageDetails) -> UsageDetails {
        var changed = false
        let turns = usageDetails.recentTurns.map { turn -> UsageTurnSummary in
            var turn = turn
            turn.windowLabel = windowLabel(forThreadID: turn.threadID, observedAt: turn.observedAt, changed: &changed)
            return turn
        }
        if changed {
            saveThreadWindowSlots()
        }
        return UsageDetails(recentTurns: turns, limitDelta: usageDetails.limitDelta, summary: usageDetails.summary)
    }

    private func windowLabel(forThreadID threadID: String, observedAt: Date, changed: inout Bool) -> String {
        let lastSeen = observedAt.timeIntervalSince1970
        if var entry = threadWindowSlots[threadID] {
            if lastSeen > entry.lastSeen {
                entry.lastSeen = lastSeen
                threadWindowSlots[threadID] = entry
                changed = true
            }
            return "W\(entry.slot)"
        }

        let slot: Int
        let usedSlots = Set(threadWindowSlots.values.map(\.slot))
        if let freeSlot = (0..<threadWindowSlotCount).first(where: { !usedSlots.contains($0) }) {
            slot = freeSlot
        } else if let evicted = threadWindowSlots.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            slot = evicted.slot
            threadWindowSlots.removeValue(forKey: evicted.threadID)
        } else {
            slot = 0
        }

        threadWindowSlots[threadID] = ThreadWindowSlot(threadID: threadID, slot: slot, lastSeen: lastSeen)
        changed = true
        return "W\(slot)"
    }

    private static func loadThreadWindowSlots() -> [String: ThreadWindowSlot] {
        guard let data = UserDefaults.standard.data(forKey: threadWindowSlotsDefaultsKey),
              let slots = try? JSONDecoder().decode([ThreadWindowSlot].self, from: data) else {
            return [:]
        }

        var result: [String: ThreadWindowSlot] = [:]
        var usedSlots = Set<Int>()
        for slot in slots.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            guard (0..<threadWindowSlotCount).contains(slot.slot),
                  !slot.threadID.isEmpty,
                  !usedSlots.contains(slot.slot) else {
                continue
            }
            result[slot.threadID] = slot
            usedSlots.insert(slot.slot)
            if result.count >= threadWindowSlotCount {
                break
            }
        }
        return result
    }

    private func saveThreadWindowSlots() {
        let slots = threadWindowSlots.values.sorted {
            if $0.slot == $1.slot {
                return $0.lastSeen > $1.lastSeen
            }
            return $0.slot < $1.slot
        }
        guard let data = try? JSONEncoder().encode(slots) else {
            return
        }
        UserDefaults.standard.set(data, forKey: threadWindowSlotsDefaultsKey)
    }

    private func updateUsageToast(from usageDetails: UsageDetails) {
        let turns = Array(usageDetails.recentTurns.prefix(3))
        guard !turns.isEmpty else {
            if !hasPrimedUsageToast {
                hasPrimedUsageToast = true
            }
            return
        }

        let signatures = Dictionary(uniqueKeysWithValues: turns.map { (usageToastKey(for: $0), usageToastSignature(for: $0)) })
        let currentKeys = Set(signatures.keys)
        lastUsageToastSignatures = lastUsageToastSignatures.filter { currentKeys.contains($0.key) }
        if !hasPrimedUsageToast {
            hasPrimedUsageToast = true
            lastUsageToastSignatures = signatures
            return
        }
        let now = Date()
        let changedTurns = turns.filter { turn in
            let key = usageToastKey(for: turn)
            let age = now.timeIntervalSince(turn.observedAt)
            return age <= usageToastMaxAge
                && lastUsageToastSignatures[key] != signatures[key]
        }
        guard !changedTurns.isEmpty else {
            return
        }

        for turn in changedTurns {
            let key = usageToastKey(for: turn)
            lastUsageToastSignatures[key] = signatures[key]
        }
        showUsageToast(changedTurns)
    }

    private func usageToastKey(for turn: UsageTurnSummary) -> String {
        [
            turn.threadID,
            turn.turnID ?? String(turn.observedAt.timeIntervalSince1970)
        ].joined(separator: "|")
    }

    private func usageToastSignature(for turn: UsageTurnSummary) -> String {
        [
            turn.threadID,
            turn.turnID ?? String(turn.observedAt.timeIntervalSince1970),
            String(turn.callCount),
            String(turn.inputTokens),
            String(turn.cachedTokens),
            String(turn.outputTokens),
            String(turn.effectiveTokens)
        ].joined(separator: "|")
    }

    private func showUsageToast(_ turns: [UsageTurnSummary]) {
        usageToastTimer?.invalidate()
        let updatedTurns = latestToastTurnsByThread(turns).sorted { $0.observedAt < $1.observedAt }
        guard !updatedTurns.isEmpty else {
            return
        }
        ringView.usageToastTurns = Array(updatedTurns.suffix(3))
        if ringsVisible, currentPetFrameAppKit != nil {
            panel.orderFrontRegardless()
        }

        let timer = Timer(timeInterval: usageToastDuration, repeats: false) { [weak self] _ in
            self?.ringView.usageToastTurns = []
            self?.usageToastTimer = nil
        }
        usageToastTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func latestToastTurnsByThread(_ turns: [UsageTurnSummary]) -> [UsageTurnSummary] {
        var seenThreadIDs = Set<String>()
        var result: [UsageTurnSummary] = []
        for turn in turns.sorted(by: { $0.observedAt > $1.observedAt }) {
            guard !seenThreadIDs.contains(turn.threadID) else {
                continue
            }
            seenThreadIDs.insert(turn.threadID)
            result.append(turn)
        }
        return result
    }

    private func installUsageDetailsMenuItems(in menu: NSMenu) {
        let header = makeUsageMenuLabelItem(height: usageMenuRowHeight, textInset: 16.0)
        setUsageMenuItem(header, attributedText: menuHeaderText("Recent turns"), hidden: false)
        menu.addItem(header)
        recentUsageHeaderItem = header

        let summary = makeUsageMenuLabelItem(height: usageMenuRowHeight, textInset: 16.0)
        menu.addItem(summary)
        recentUsageSummaryItem = summary

        recentUsageItems = (0..<3).map { _ in
            let item = makeUsageMenuLabelItem(height: usageMenuRowHeight, textInset: 16.0)
            menu.addItem(item)
            return item
        }

        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        limitDeltaSeparatorItem = separator

        let delta = NSMenuItem(title: "Limit delta waiting", action: nil, keyEquivalent: "")
        delta.isEnabled = false
        menu.addItem(delta)
        limitDeltaItem = delta
    }

    private func makeUsageMenuLabelItem(height: CGFloat, textInset: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: usageMenuRowWidth, height: height))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: textInset, y: 3.0, width: usageMenuRowWidth - textInset - 12.0, height: height - 5.0)
        label.lineBreakMode = .byTruncatingTail
        label.allowsDefaultTighteningForTruncation = true
        view.addSubview(label)
        item.view = view
        return item
    }

    private func setUsageMenuItem(_ item: NSMenuItem, attributedText: NSAttributedString, hidden: Bool) {
        if let label = item.view?.subviews.compactMap({ $0 as? NSTextField }).first {
            label.attributedStringValue = attributedText
        } else {
            item.attributedTitle = attributedText
        }
        item.isHidden = hidden
    }

    private func makeDisplayStyleMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Display Style", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Display Style")
        displayStyleItems = UsageDisplayStyle.allCases.map { style in
            let styleItem = NSMenuItem(title: style.title, action: #selector(setDisplayStyle(_:)), keyEquivalent: "")
            styleItem.target = self
            styleItem.representedObject = style.rawValue
            submenu.addItem(styleItem)
            return styleItem
        }
        item.submenu = submenu
        return item
    }

    private func makePositionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        positionMenuItem = item
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 50))

        let label = NSTextField(labelWithString: "Position")
        label.frame = NSRect(x: 32, y: 30, width: 152, height: 15)
        label.font = NSFont.menuFont(ofSize: 12.0)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)
        positionLabel = label

        let control = NSSegmentedControl(
            labels: ["←", "→", "↑", "↓", "↺"],
            trackingMode: .momentary,
            target: self,
            action: #selector(adjustUsageBarsFromSegment(_:))
        )
        control.frame = NSRect(x: 30, y: 6, width: 146, height: 24)
        control.controlSize = .small
        control.segmentStyle = .rounded
        control.setWidth(28.0, forSegment: UsageBarPositionAction.left.rawValue)
        control.setWidth(28.0, forSegment: UsageBarPositionAction.right.rawValue)
        control.setWidth(28.0, forSegment: UsageBarPositionAction.up.rawValue)
        control.setWidth(28.0, forSegment: UsageBarPositionAction.down.rawValue)
        control.setWidth(34.0, forSegment: UsageBarPositionAction.reset.rawValue)
        view.addSubview(control)
        positionControl = control

        item.view = view
        return item
    }

    private func makeBarWidthMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Bar Width", action: nil, keyEquivalent: "")
        barWidthMenuItem = item
        let submenu = NSMenu(title: "Bar Width")
        barWidthItems = UsageBarWidthPreset.allCases.map { preset in
            let widthItem = NSMenuItem(title: preset.title, action: #selector(setBarWidthPreset(_:)), keyEquivalent: "")
            widthItem.target = self
            widthItem.representedObject = preset.rawValue
            submenu.addItem(widthItem)
            return widthItem
        }
        item.submenu = submenu
        return item
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3.0, y: 10.8, width: 12.0, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()
        NSBezierPath(roundedRect: NSRect(x: 3.0, y: 5.0, width: 9.0, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func updateSummaryMenuItem() {
        guard let summaryItem else { return }
        let primary = ringView.state.primary.map { "Short \(formatPercent($0.remainingPercent))" }
        let secondary = ringView.state.secondary.map { "Weekly \(formatPercent($0.remainingPercent))" }
        let pieces = [primary, secondary].compactMap { $0 }
        if pieces.isEmpty {
            summaryItem.title = "Waiting for Codex limit data"
        } else {
            let source = ringView.state.source.hasPrefix("log") ? "Local" : "Cached"
            summaryItem.title = "\(source) \(formatAge(since: ringView.state.observedAt)) " + pieces.joined(separator: " | ")
        }
    }

    private func updateUsageDetailsMenuItems() {
        guard turnUsageEnabled else {
            recentUsageHeaderItem?.isHidden = true
            if let recentUsageSummaryItem {
                setUsageMenuItem(recentUsageSummaryItem, attributedText: NSAttributedString(string: ""), hidden: true)
            }
            recentUsageItems.forEach {
                setUsageMenuItem($0, attributedText: NSAttributedString(string: ""), hidden: true)
            }
            limitDeltaSeparatorItem?.isHidden = true
            limitDeltaItem?.title = ""
            limitDeltaItem?.isHidden = true
            statusItem?.menu?.update()
            return
        }

        recentUsageHeaderItem?.isHidden = false
        if let recentUsageSummaryItem {
            if let summary = usageDetails.summary {
                setUsageMenuItem(recentUsageSummaryItem, attributedText: usageSummaryRow(for: summary), hidden: false)
            } else {
                setUsageMenuItem(recentUsageSummaryItem, attributedText: NSAttributedString(string: ""), hidden: true)
            }
        }
        let turns = Array(usageDetails.recentTurns.prefix(3))
        if turns.isEmpty {
            for (index, item) in recentUsageItems.enumerated() {
                let text = index == 0 ? menuMutedText("Waiting for usage data") : NSAttributedString(string: "")
                setUsageMenuItem(item, attributedText: text, hidden: index > 0)
            }
        } else {
            for index in 0..<recentUsageItems.count {
                let item = recentUsageItems[index]
                guard index < turns.count else {
                    setUsageMenuItem(item, attributedText: NSAttributedString(string: ""), hidden: true)
                    continue
                }

                setUsageMenuItem(item, attributedText: usageMenuRow(for: turns[index]), hidden: false)
            }
        }

        limitDeltaSeparatorItem?.isHidden = false
        if let limitDelta = usageDetails.limitDelta {
            limitDeltaItem?.title = "Limit delta  Short \(formatPercentDelta(limitDelta.primary)) | Weekly \(formatPercentDelta(limitDelta.secondary))"
            limitDeltaItem?.isHidden = false
        } else {
            limitDeltaItem?.title = "Limit delta waiting"
            limitDeltaItem?.isHidden = false
        }
        statusItem?.menu?.update()
    }

    private func updateTurnUsageMenuItem() {
        turnUsageItem?.state = turnUsageEnabled ? .on : .off
        updateUsageToastMenuItem()
    }

    private func updateUsageToastMenuItem() {
        usageToastItem?.state = usageToastEnabled ? .on : .off
        usageToastItem?.isEnabled = turnUsageEnabled
    }

    private func updateShowRingsMenuItem() {
        showRingsItem?.state = ringsVisible ? .on : .off
    }

    private func updateDisplayStyleMenuItems() {
        for item in displayStyleItems {
            item.state = (item.representedObject as? String) == displayStyle.rawValue ? .on : .off
        }
        updateLayoutControlAvailability()
    }

    private func updateBarWidthMenuItems() {
        for item in barWidthItems {
            item.state = (item.representedObject as? String) == barWidthPreset.rawValue ? .on : .off
        }
    }

    private func updateLayoutControlAvailability() {
        let usesBars = displayStyle == .bars
        barControlsSeparatorItem?.isHidden = !usesBars
        barWidthMenuItem?.isHidden = !usesBars
        positionMenuItem?.isHidden = !usesBars
        positionControl?.isEnabled = usesBars
        positionLabel?.textColor = .secondaryLabelColor
    }

    private func updateRingVisibility() {
        updateShowRingsMenuItem()
        if ringsVisible, currentPetFrameAppKit != nil {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func setRingsVisible(_ visible: Bool) {
        ringsVisible = visible
        UserDefaults.standard.set(visible, forKey: ringsVisibleDefaultsKey)
        updateRingVisibility()
    }

    private func saveUsageBarLayout() {
        UserDefaults.standard.set(Double(usageBarOffset.width), forKey: barsOffsetXDefaultsKey)
        UserDefaults.standard.set(Double(usageBarOffset.height), forKey: barsOffsetYDefaultsKey)
        UserDefaults.standard.set(barWidthPreset.rawValue, forKey: barWidthPresetDefaultsKey)
    }

    private func applyUsageBarLayout() {
        ringView.barWidth = barWidthPreset.width
        ringView.barOffset = usageBarOffset
        saveUsageBarLayout()
        if let currentPetFrameAppKit {
            setPanelFrame(forPetFrameAppKit: currentPetFrameAppKit)
            if ringsVisible {
                panel.orderFrontRegardless()
            }
        }
        updateBarWidthMenuItems()
    }

    private func applyDisplayStyle() {
        ringView.displayStyle = displayStyle
        UserDefaults.standard.set(displayStyle.rawValue, forKey: displayStyleDefaultsKey)
        if let currentPetFrameAppKit {
            setPanelFrame(forPetFrameAppKit: currentPetFrameAppKit)
            if ringsVisible {
                panel.orderFrontRegardless()
            }
        }
        updateDisplayStyleMenuItems()
    }

    @objc private func toggleRings(_ sender: NSMenuItem) {
        setRingsVisible(!ringsVisible)
    }

    @objc private func toggleTurnUsage(_ sender: NSMenuItem) {
        turnUsageEnabled.toggle()
        UserDefaults.standard.set(turnUsageEnabled, forKey: turnUsageEnabledDefaultsKey)
        writeTurnUsageSettings()
        updateTurnUsageMenuItem()
        updateUsageTimer()
        if turnUsageEnabled {
            refreshUsageDetailsNow()
        } else {
            clearUsageDetails()
        }
    }

    @objc private func toggleUsageToasts(_ sender: NSMenuItem) {
        usageToastEnabled.toggle()
        UserDefaults.standard.set(usageToastEnabled, forKey: usageToastEnabledDefaultsKey)
        updateUsageToastMenuItem()
        usageToastTimer?.invalidate()
        usageToastTimer = nil
        ringView.usageToastTurns = []
        hasPrimedUsageToast = false
        lastUsageToastSignatures = [:]
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        refreshUsageDetailsNow()
        updateState(showToast: false)
        updateFrame()
        updateRingVisibility()
    }

    @objc private func setDisplayStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = UsageDisplayStyle(rawValue: rawValue) else {
            return
        }
        displayStyle = style
        applyDisplayStyle()
    }

    @objc private func adjustUsageBarsFromSegment(_ sender: NSSegmentedControl) {
        guard displayStyle == .bars else { return }
        guard let action = UsageBarPositionAction(rawValue: sender.selectedSegment) else {
            return
        }

        switch action {
        case .left:
            usageBarOffset.width -= usageBarPositionStep
        case .right:
            usageBarOffset.width += usageBarPositionStep
        case .up:
            usageBarOffset.height -= usageBarPositionStep
        case .down:
            usageBarOffset.height += usageBarPositionStep
        case .reset:
            usageBarOffset = .zero
        }
        applyUsageBarLayout()
    }

    @objc private func setBarWidthPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = UsageBarWidthPreset(rawValue: rawValue) else {
            return
        }
        barWidthPreset = preset
        applyUsageBarLayout()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func installDragFollow() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.beginDragFollowIfNeeded(at: NSEvent.mouseLocation)
            }
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.continueDragFollow(at: NSEvent.mouseLocation)
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endDragFollow()
            }
        }
    }

    private func beginDragFollowIfNeeded(at mouse: CGPoint) {
        guard ringsVisible else { return }
        updateFrame()
        guard isLikelyPetDragStart(at: mouse) else { return }
        guard let petFrame = currentPetFrameAppKit,
              let overlayFrame = currentPetOverlayFrameAppKit else { return }
        dragMouseToPetOriginOffsetAppKit = CGPoint(x: petFrame.minX - mouse.x, y: petFrame.minY - mouse.y)
        dragMouseToOverlayOriginOffsetAppKit = CGPoint(x: overlayFrame.minX - mouse.x, y: overlayFrame.minY - mouse.y)
        isTrackingMouseDrag = true
        holdDraggedFrameUntil = nil
        startDragFollowTimer()
        updateDragFrame(at: mouse)
    }

    private func continueDragFollow(at mouse: CGPoint) {
        if !isTrackingMouseDrag {
            beginDragFollowIfNeeded(at: mouse)
        }
        guard isTrackingMouseDrag else { return }
        guard isPrimaryMouseButtonPressed() else {
            endDragFollow()
            return
        }
        updateDragFrame(at: mouse)
    }

    private func endDragFollow() {
        guard isTrackingMouseDrag else { return }
        isTrackingMouseDrag = false
        dragMouseToPetOriginOffsetAppKit = nil
        dragMouseToOverlayOriginOffsetAppKit = nil
        stopDragFollowTimer()
        holdDraggedFrameUntil = Date().addingTimeInterval(0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.updateFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateFrame()
        }
    }

    private func isPrimaryMouseButtonPressed() -> Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    private func updateDragFrame(at mouse: CGPoint) {
        guard isTrackingMouseDrag else { return }
        guard isPrimaryMouseButtonPressed() else {
            endDragFollow()
            return
        }

        let predictedPetFrame = predictedDragPetFrame(at: mouse)
        let predictedOverlayFrame = predictedDragOverlayFrame(at: mouse)
        let liveReference = predictedOverlayFrame.flatMap { topLeftRectFromAppKit($0) } ?? currentPetOverlayTopLeft

        if let petFrames = frameReader.readPetFramesTopLeft(preferLiveOverlay: true, liveReference: liveReference),
           petFrames.usedLiveOverlay {
            let livePetFrame = appKitRectFromTopLeft(petFrames.mascot)
            if let predictedPetFrame {
                guard dragLiveFrameIsClose(livePetFrame, to: predictedPetFrame) else {
                    applyPredictedDragFrame(petFrame: predictedPetFrame, overlayFrame: predictedOverlayFrame)
                    return
                }
            }
            applyPetFrames(petFrames)
            return
        }

        if let predictedPetFrame {
            applyPredictedDragFrame(petFrame: predictedPetFrame, overlayFrame: predictedOverlayFrame)
        }
    }

    private func predictedDragPetFrame(at mouse: CGPoint) -> CGRect? {
        guard let currentPetFrameAppKit,
              let offset = dragMouseToPetOriginOffsetAppKit else {
            return nil
        }
        return CGRect(
            x: mouse.x + offset.x,
            y: mouse.y + offset.y,
            width: currentPetFrameAppKit.width,
            height: currentPetFrameAppKit.height
        )
    }

    private func predictedDragOverlayFrame(at mouse: CGPoint) -> CGRect? {
        guard let currentPetOverlayFrameAppKit,
              let offset = dragMouseToOverlayOriginOffsetAppKit else {
            return nil
        }
        return CGRect(
            x: mouse.x + offset.x,
            y: mouse.y + offset.y,
            width: currentPetOverlayFrameAppKit.width,
            height: currentPetOverlayFrameAppKit.height
        )
    }

    private func applyPredictedDragFrame(petFrame: CGRect, overlayFrame: CGRect?) {
        currentPetFrameAppKit = petFrame
        if let overlayFrame {
            currentPetOverlayFrameAppKit = overlayFrame
            currentPetOverlayTopLeft = topLeftRectFromAppKit(overlayFrame)
        }
        setPanelFrame(forPetFrameAppKit: petFrame)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
    }

    private func dragLiveFrameIsClose(_ liveFrame: CGRect, to predictedFrame: CGRect) -> Bool {
        let dx = liveFrame.midX - predictedFrame.midX
        let dy = liveFrame.midY - predictedFrame.midY
        let tolerance = max(dragLiveMismatchTolerance, max(predictedFrame.width, predictedFrame.height) * 0.85)
        return (dx * dx + dy * dy) <= tolerance * tolerance
    }

    private func startDragFollowTimer() {
        guard dragFollowTimer == nil else { return }
        let timer = Timer(timeInterval: dragFollowInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isTrackingMouseDrag, self.isPrimaryMouseButtonPressed() else {
                self.endDragFollow()
                return
            }
            self.updateDragFrame(at: NSEvent.mouseLocation)
        }
        dragFollowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDragFollowTimer() {
        dragFollowTimer?.invalidate()
        dragFollowTimer = nil
    }

    private func isLikelyPetDragStart(at mouse: CGPoint) -> Bool {
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -8, dy: -8).contains(mouse) {
            return true
        }
        return false
    }

    private func appKitOriginFromTopLeft(_ topLeft: CGPoint, size: CGSize) -> CGPoint {
        let topLeftRect = CGRect(origin: topLeft, size: size)
        guard let screen = screenForTopLeftRect(topLeftRect) else {
            return CGPoint(x: topLeft.x, y: max(0, config.fallbackSize - topLeft.y))
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = topLeft.x - screenTopLeftFrame.minX
        let localY = topLeft.y - screenTopLeftFrame.minY
        return CGPoint(x: screen.frame.minX + localX, y: screen.frame.maxY - localY - size.height)
    }

    private func appKitRectFromTopLeft(_ rect: CGRect) -> CGRect {
        guard let screen = screenForTopLeftRect(rect) else {
            return rect
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = rect.minX - screenTopLeftFrame.minX
        let localY = rect.minY - screenTopLeftFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func topLeftRectFromAppKit(_ rect: CGRect) -> CGRect? {
        guard let screen = screenForAppKitRect(rect) else {
            return nil
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = rect.minX - screen.frame.minX
        let localY = screen.frame.maxY - rect.maxY
        return CGRect(
            x: screenTopLeftFrame.minX + localX,
            y: screenTopLeftFrame.minY + localY,
            width: rect.width,
            height: rect.height
        )
    }

    private func screenForTopLeftRect(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { topLeftFrame(for: $0).contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: topLeftFrame(for: $0)) < distanceSquared(center, to: topLeftFrame(for: $1))
        }
    }

    private func screenForAppKitRect(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { $0.frame.contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: $0.frame) < distanceSquared(center, to: $1.frame)
        }
    }

    private func topLeftFrame(for screen: NSScreen) -> CGRect {
        let primaryMaxY = (primaryScreen() ?? NSScreen.screens.first)?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private func formatPercentDelta(_ delta: Double?) -> String {
        guard let delta else { return "--" }
        if abs(delta) < 0.05 {
            return "0.0%"
        }
        return String(format: "%+.1f%%", delta)
    }

    private func formatTokenCount(_ tokens: Int64) -> String {
        let value = Double(tokens)
        guard value >= 1_000 else {
            return "\(tokens)"
        }

        let thousands = value / 1_000.0
        if thousands >= 100 {
            return String(format: "%.0fk", thousands)
        }
        if abs(thousands.rounded() - thousands) < 0.05 {
            return "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fk", thousands)
    }

    private func menuUsageID(for turn: UsageTurnSummary) -> String {
        let thread = compactThreadID(turn.threadID)
        let prefix: String
        if let windowLabel = turn.windowLabel, !windowLabel.isEmpty {
            prefix = "\(windowLabel)/\(thread)"
        } else {
            prefix = thread
        }
        guard let turnID = turn.turnID, !turnID.isEmpty else {
            return prefix
        }
        return "\(prefix)/\(compactThreadID(turnID))"
    }

    private func compactThreadID(_ threadID: String) -> String {
        let compact = threadID.replacingOccurrences(of: "-", with: "")
        guard compact.count > 4 else {
            return compact
        }
        return String(compact.suffix(4))
    }

    private func usageMenuRow(for turn: UsageTurnSummary) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: menuUsageID(for: turn), attributes: menuMonospaceAttributes(color: .secondaryLabelColor, weight: .semibold)))
        text.append(NSAttributedString(string: "  ", attributes: menuMonospaceAttributes(color: .secondaryLabelColor)))
        text.append(NSAttributedString(string: "\(turn.callCount)c", attributes: menuMonospaceAttributes(color: menuUsedColor(), weight: .semibold)))
        text.append(NSAttributedString(string: "  ", attributes: menuMonospaceAttributes(color: .secondaryLabelColor)))
        appendMenuMetric("Used ", formatTokenCount(turn.effectiveTokens), color: menuUsedColor(), to: text)
        return text
    }

    private func usageSummaryRow(for summary: UsageSummary) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Used  ", attributes: menuMonospaceAttributes(color: .secondaryLabelColor, weight: .semibold)))
        var appendedMetric = false
        if let today = summary.today {
            appendMenuMetric("Today ", formatTokenCount(today.effectiveTokens), color: menuUsedColor(), to: text)
            appendedMetric = true
        }
        if let latestSession = summary.latestSession {
            if appendedMetric {
                text.append(NSAttributedString(string: "  |  ", attributes: menuMonospaceAttributes(color: .secondaryLabelColor)))
            }
            appendMenuMetric("This chat ", formatTokenCount(latestSession.effectiveTokens), color: menuUsedColor(), to: text)
        }
        return text
    }

    private func appendMenuMetric(_ label: String, _ value: String, color: NSColor, to text: NSMutableAttributedString) {
        text.append(NSAttributedString(string: label, attributes: menuMonospaceAttributes(color: .secondaryLabelColor, weight: .medium)))
        text.append(NSAttributedString(string: value, attributes: menuMonospaceAttributes(color: color, weight: .semibold)))
    }

    private func menuHeaderText(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.0, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.74)
            ]
        )
    }

    private func menuMutedText(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.menuFont(ofSize: 12.0),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    private func menuMonospaceAttributes(color: NSColor, weight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 11.6, weight: weight),
            .foregroundColor: color
        ]
    }

    private func menuUsedColor() -> NSColor {
        NSColor(calibratedRed: 0.00, green: 0.62, blue: 0.52, alpha: 1.0)
    }

    private func formatAge(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 {
            return "<1m ago"
        }

        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        return "\(hours / 24)d ago"
    }
}

func renderPreview(config: LimitRingsConfig) -> Bool {
    let state = config.previewUsesSampleData
        ? samplePreviewLimitState()
        : LimitStateReader(
            logsPath: config.logsPath,
            turnUsageStatePath: config.turnUsageStatePath,
            turnUsageSummaryPath: config.turnUsageSummaryPath
        ).readLatest()
    let toastTurns = config.previewShowsToasts ? samplePreviewUsageTurns() : []
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let image = NSImage(size: size)
    image.lockFocus()
    LimitRingRenderer(
        state: state,
        displayStyle: config.previewStyle,
        barWidth: UsageBarWidthPreset.normal.width,
        barOffset: .zero,
        checkPulse: 0.55,
        usageToastTurns: toastTurns,
        previewUsesBackground: config.previewUsesBackground
    ).draw(in: CGRect(origin: .zero, size: size))
    image.unlockFocus()

    guard let previewPath = config.previewPath,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try FileManager.default.createDirectory(at: previewPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: previewPath)
        return true
    } catch {
        fputs("codex-pet-limit-rings: could not write preview: \(error)\n", stderr)
        return false
    }
}

private func samplePreviewLimitState() -> LimitState {
    let now = Date()
    let timestamp = now.timeIntervalSince1970
    return LimitState(
        planType: "pro",
        primary: LimitBucket(usedPercent: 24.0, windowMinutes: 300.0, resetAt: timestamp + 2.0 * 60.0 * 60.0 + 38.0 * 60.0),
        secondary: LimitBucket(usedPercent: 44.0, windowMinutes: 7.0 * 24.0 * 60.0, resetAt: timestamp + 4.0 * 24.0 * 60.0 * 60.0),
        additional: [
            (name: "gpt-5.1", bucket: LimitBucket(usedPercent: 12.0, windowMinutes: nil, resetAt: nil)),
            (name: "gpt-5.1-codex", bucket: LimitBucket(usedPercent: 67.0, windowMinutes: nil, resetAt: nil))
        ],
        observedAt: now,
        source: "preview"
    )
}

private func samplePreviewUsageTurns() -> [UsageTurnSummary] {
    let now = Date()
    let calls = [
        UsageCallSummary(observedAt: now, inputTokens: 9_200, cachedTokens: 2_400, outputTokens: 1_100, effectiveTokens: 7_900),
        UsageCallSummary(observedAt: now, inputTokens: 9_600, cachedTokens: 2_700, outputTokens: 1_100, effectiveTokens: 8_000)
    ]
    return [
        UsageTurnSummary(
            threadID: "thread-preview-0001",
            turnID: "turn-preview-a327",
            windowLabel: "W0",
            observedAt: now,
            inputTokens: 18_800,
            cachedTokens: 5_100,
            outputTokens: 2_200,
            effectiveTokens: 15_900,
            calls: calls
        )
    ]
}

func parseConfig() -> LimitRingsConfig? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
    var config = LimitRingsConfig(
        codexHome: codexHome,
        globalStatePath: codexHome.appendingPathComponent(".codex-global-state.json"),
        logsPath: defaultLogsPath(codexHome: codexHome),
        turnUsageStatePath: defaultTurnUsageStatePath(codexHome: codexHome),
        turnUsageSummaryPath: defaultTurnUsageSummaryPath(codexHome: codexHome),
        turnUsageSettingsPath: defaultTurnUsageSettingsPath(codexHome: codexHome),
        previewPath: nil
    )

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: codex-pet-limit-rings [--preview PATH] [--preview-style rings|bars] [--preview-sample] [--preview-toasts] [--preview-background] [--codex-home PATH] [--logs PATH] [--turn-usage-state PATH] [--turn-usage-summary PATH] [--state PATH] [--no-mouse-monitor]

            Draws a transparent Codex rate-limit overlay near the current pet using local Codex logs.
            """)
            exit(0)
        case "--preview":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.previewPath = URL(fileURLWithPath: value)
        case "--preview-style":
            guard let value = args.first,
                  let style = UsageDisplayStyle(rawValue: value) else {
                return nil
            }
            args.removeFirst()
            config.previewStyle = style
        case "--preview-sample":
            config.previewUsesSampleData = true
        case "--preview-toasts":
            config.previewShowsToasts = true
        case "--preview-background":
            config.previewUsesBackground = true
        case "--codex-home":
            guard let value = args.first else { return nil }
            args.removeFirst()
            let url = URL(fileURLWithPath: value)
            config.codexHome = url
            config.globalStatePath = url.appendingPathComponent(".codex-global-state.json")
            config.logsPath = defaultLogsPath(codexHome: url)
            config.turnUsageStatePath = defaultTurnUsageStatePath(codexHome: url)
            config.turnUsageSummaryPath = defaultTurnUsageSummaryPath(codexHome: url)
            config.turnUsageSettingsPath = defaultTurnUsageSettingsPath(codexHome: url)
        case "--logs":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.logsPath = URL(fileURLWithPath: value)
        case "--turn-usage-state":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.turnUsageStatePath = URL(fileURLWithPath: value)
        case "--turn-usage-summary":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.turnUsageSummaryPath = URL(fileURLWithPath: value)
        case "--state":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.globalStatePath = URL(fileURLWithPath: value)
        case "--size":
            guard let value = args.first, let size = Double(value) else { return nil }
            args.removeFirst()
            config.fallbackSize = CGFloat(size)
        case "--no-mouse-monitor", "--no-drag-follow":
            config.mouseMonitorEnabled = false
        default:
            fputs("codex-pet-limit-rings: unknown argument \(arg)\n", stderr)
            return nil
        }
    }

    return config
}

func defaultLogsPath(codexHome: URL) -> URL {
    let logs2 = codexHome.appendingPathComponent("logs_2.sqlite")
    if FileManager.default.fileExists(atPath: logs2.path) {
        return logs2
    }
    return codexHome.appendingPathComponent("logs_1.sqlite")
}

func defaultTurnUsageStatePath(codexHome: URL) -> URL {
    codexHome.appendingPathComponent("codex-pet-limit-rings/turn-usage.json")
}

func defaultTurnUsageSummaryPath(codexHome: URL) -> URL {
    codexHome.appendingPathComponent("codex-pet-limit-rings/turn-usage-summary.json")
}

func defaultTurnUsageSettingsPath(codexHome: URL) -> URL {
    codexHome.appendingPathComponent("codex-pet-limit-rings/settings.json")
}

// LIMIT_RINGS_MAIN_BEGIN
guard let config = parseConfig() else {
    fputs("codex-pet-limit-rings: invalid arguments. Use --help.\n", stderr)
    exit(2)
}

if config.previewPath != nil {
    exit(renderPreview(config: config) ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rings = LimitRingsApp(config: config)
rings.run()
app.run()
