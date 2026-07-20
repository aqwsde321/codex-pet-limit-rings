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

private let limitStatePollInterval: TimeInterval = 20.0
private let appServerLimitStateTimeout: TimeInterval = 8.0
private let appServerLimitStateFailureRetryInterval: TimeInterval = 60.0
private let limitStateFallbackMaxAge: TimeInterval = 30.0 * 60.0
private let rateLimitWindowMergeMaxAge: TimeInterval = 24.0 * 60.0 * 60.0
private let petFrameFallbackPollInterval: TimeInterval = 2.0
private let petFrameStateDebounceInterval: TimeInterval = 0.035
private let dragFollowInterval: TimeInterval = 1.0 / 60.0
private let dragLiveMismatchTolerance: CGFloat = 96.0
private let stateCheckPulseDuration: TimeInterval = 0.85
private let usageBarTopPadding: CGFloat = 132.0
private let usageBarBottomPadding: CGFloat = 56.0
private let usageRingTopPadding: CGFloat = 132.0
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let barsOffsetXDefaultsKey = "CodexPetLimitRings.barsOffsetX"
private let barsOffsetYDefaultsKey = "CodexPetLimitRings.barsOffsetY"
private let ringsOffsetXDefaultsKey = "CodexPetLimitRings.ringsOffsetX"
private let ringsOffsetYDefaultsKey = "CodexPetLimitRings.ringsOffsetY"
private let barWidthPresetDefaultsKey = "CodexPetLimitRings.barWidthPreset"
private let displayStyleDefaultsKey = "CodexPetLimitRings.displayStyle"
private let usagePositionStep: CGFloat = 4.0

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

enum UsagePositionAction: Int {
    case left
    case right
    case up
    case down
    case reset
}

enum UsageCoordinateSpace {
    case topLeft
    case appKit
}

func adjustedUsageOffset(_ offset: CGSize, action: UsagePositionAction) -> CGSize {
    var offset = offset
    switch action {
    case .left:
        offset.width -= usagePositionStep
    case .right:
        offset.width += usagePositionStep
    case .up:
        offset.height -= usagePositionStep
    case .down:
        offset.height += usagePositionStep
    case .reset:
        offset = .zero
    }
    return offset
}

func adjustedUsageOffsets(
    barOffset: CGSize,
    ringOffset: CGSize,
    displayStyle: UsageDisplayStyle,
    action: UsagePositionAction
) -> (bar: CGSize, ring: CGSize) {
    switch displayStyle {
    case .bars:
        return (adjustedUsageOffset(barOffset, action: action), ringOffset)
    case .rings:
        return (barOffset, adjustedUsageOffset(ringOffset, action: action))
    }
}

func adjustedUsageRingOrigin(
    _ origin: CGPoint,
    offset: CGSize,
    coordinateSpace: UsageCoordinateSpace
) -> CGPoint {
    let yOffset: CGFloat
    switch coordinateSpace {
    case .topLeft:
        yOffset = offset.height
    case .appKit:
        yOffset = -offset.height
    }
    return CGPoint(x: origin.x + offset.width, y: origin.y + yOffset)
}

func usageProgressPanelOriginY(visibleRowCount: Int, barOffsetY: CGFloat) -> CGFloat {
    let missingRowCount = max(2 - visibleRowCount, 0)
    return 4.0 - barOffsetY + CGFloat(missingRowCount) * 21.0
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

private struct AppServerInitializeRequest: Encodable {
    var id = 1
    var method = "initialize"
    var params = AppServerInitializeParams()
}

private struct AppServerInitializeParams: Encodable {
    var clientInfo = AppServerClientInfo()
    var capabilities = AppServerInitializeCapabilities()
}

private struct AppServerClientInfo: Encodable {
    var name = "codex-pet-limit-rings"
    var title: String? = "Codex Pet Limit Rings"
    var version = "0"
}

private struct AppServerInitializeCapabilities: Encodable {
    var experimentalApi = true
    var requestAttestation = false
    var optOutNotificationMethods: [String]? = [
        "thread/started",
        "thread/status/changed",
        "thread/closed"
    ]
}

private struct AppServerRateLimitReadRequest: Encodable {
    var id = 2
    var method = "account/rateLimits/read"
}

private struct AppServerResponseID: Decodable {
    var id: Int?
}

private struct AppServerRateLimitReadResponse: Decodable {
    var id: Int?
    var result: AppServerRateLimitResult?
}

private struct AppServerRateLimitResult: Decodable {
    var rateLimits: AppServerRateLimitSnapshot
    var rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?

    func toLimitState(observedAt: Date) -> LimitState? {
        let selected = rateLimitsByLimitId?["codex"] ?? rateLimits
        let primary = selected.primary?.toBucket()
        let secondary = selected.secondary?.toBucket()
        guard primary != nil || secondary != nil else {
            return nil
        }

        let additional = (rateLimitsByLimitId ?? [:])
            .compactMap { limitID, snapshot -> (String, LimitBucket)? in
                guard limitID != selected.limitId,
                      limitID != "codex",
                      let bucket = (snapshot.primary ?? snapshot.secondary)?.toBucket() else {
                    return nil
                }
                return (snapshot.limitName ?? limitID, bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(
            planType: selected.planType,
            primary: primary,
            secondary: secondary,
            additional: additional,
            observedAt: observedAt,
            source: "app-server"
        )
    }
}

private struct AppServerRateLimitSnapshot: Decodable {
    var limitId: String?
    var limitName: String?
    var primary: AppServerRateLimitWindow?
    var secondary: AppServerRateLimitWindow?
    var planType: String?
}

private struct AppServerRateLimitWindow: Decodable {
    var usedPercent: Double?
    var windowDurationMins: Double?
    var resetsAt: Double?

    func toBucket() -> LimitBucket? {
        guard let used = usedPercent else { return nil }
        if let minutes = windowDurationMins, minutes <= 0 {
            return nil
        }
        return LimitBucket(usedPercent: used, windowMinutes: windowDurationMins, resetAt: resetsAt)
    }
}

func defaultCodexCLIPaths(home: URL, environment: [String: String]) -> [String] {
    [
        environment["CODEX_PET_LIMIT_RINGS_CODEX_CLI"],
        environment["CODEX_CLI"],
        "/Applications/Codex.app/Contents/Resources/codex",
        home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ].compactMap { $0 }
}

private final class AppServerLimitStateReader {
    private let codexHome: URL
    private var lastFailureAt: Date?

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    func readLatest() -> LimitState? {
        let now = Date()
        if let lastFailureAt,
           now.timeIntervalSince(lastFailureAt) < appServerLimitStateFailureRetryInterval {
            return nil
        }

        guard let state = readLatestSnapshot() else {
            lastFailureAt = now
            return nil
        }

        lastFailureAt = nil
        return state
    }

    private func readLatestSnapshot() -> LimitState? {
        guard let codexCLI = findCodexCLI() else {
            return nil
        }

        let process = Process()
        process.executableURL = codexCLI
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var buffer = ""
        var resolved = false
        var state: LimitState?

        func resolve(_ candidate: LimitState?) {
            lock.lock()
            defer { lock.unlock() }
            guard !resolved else { return }
            state = candidate
            resolved = true
            semaphore.signal()
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }

            lock.lock()
            buffer += chunk
            let lines = AppServerLimitStateReader.drainLines(from: &buffer)
            lock.unlock()

            for line in lines {
                guard AppServerLimitStateReader.responseID(in: line, decoder: decoder) == 2 else {
                    continue
                }
                resolve(AppServerLimitStateReader.decodeRateLimitState(from: line, decoder: decoder))
                break
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in
            resolve(nil)
        }

        do {
            try process.run()
            try write(AppServerInitializeRequest(), to: stdin.fileHandleForWriting, encoder: encoder)
            try write(AppServerRateLimitReadRequest(), to: stdin.fileHandleForWriting, encoder: encoder)
        } catch {
            return nil
        }

        let timeout = DispatchTime.now() + .milliseconds(Int(appServerLimitStateTimeout * 1000.0))
        _ = semaphore.wait(timeout: timeout)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdin.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func write<T: Encodable>(_ payload: T, to handle: FileHandle, encoder: JSONEncoder) throws {
        var data = try encoder.encode(payload)
        data.append(0x0a)
        handle.write(data)
    }

    private func findCodexCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        return defaultCodexCLIPaths(home: home, environment: environment).map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func drainLines(from buffer: inout String) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    private static func responseID(in line: String, decoder: JSONDecoder) -> Int? {
        guard let data = line.data(using: .utf8),
              let response = try? decoder.decode(AppServerResponseID.self, from: data) else {
            return nil
        }
        return response.id
    }

    private static func decodeRateLimitState(from line: String, decoder: JSONDecoder) -> LimitState? {
        guard let data = line.data(using: .utf8),
              let response = try? decoder.decode(AppServerRateLimitReadResponse.self, from: data),
              response.id == 2 else {
            return nil
        }
        return response.result?.toLimitState(observedAt: Date())
    }
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var previewPath: URL?
    var previewStyle: UsageDisplayStyle = .rings
    var previewUsesSampleData: Bool = false
    var previewUsesBackground: Bool = false
    var fallbackSize: CGFloat = 220
    var mouseMonitorEnabled: Bool = true
}

final class LimitStateReader {
    private let logsPath: URL
    private let appServerStateProvider: (() -> LimitState?)?
    private var lastAppServerState: LimitState?

    init(
        logsPath: URL,
        codexHome: URL? = nil,
        appServerStateProvider: (() -> LimitState?)? = nil
    ) {
        self.logsPath = logsPath
        if let appServerStateProvider {
            self.appServerStateProvider = appServerStateProvider
        } else if let codexHome {
            let appServerReader = AppServerLimitStateReader(codexHome: codexHome)
            self.appServerStateProvider = { appServerReader.readLatest() }
        } else {
            self.appServerStateProvider = nil
        }
    }

    func readLatest() -> LimitState {
        if let state = appServerStateProvider?() {
            lastAppServerState = state
            return state
        }
        let logState = readLatestLog()
        if isDisplayableLimitState(logState) {
            return logState
        }
        let now = Date()
        if var cached = lastAppServerState,
           now.timeIntervalSince(cached.observedAt) <= limitStateFallbackMaxAge,
           isCurrentLimitState(cached, now: now) {
            cached.source = "cached"
            return cached
        }
        return logState
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

        let now = Date()
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
            guard isCurrentLimitState(state, now: now) else {
                return .empty
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
               isCurrentBucket(secondary, observedAt: state.observedAt, now: now),
               current.observedAt.timeIntervalSince(state.observedAt) <= rateLimitWindowMergeMaxAge {
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

    private func isCurrentLimitState(_ state: LimitState, now: Date) -> Bool {
        if let primary = state.primary, hasDisplayableWindow(primary) {
            return isCurrentBucket(primary, observedAt: state.observedAt, now: now)
        }
        if let secondary = state.secondary, hasDisplayableWindow(secondary) {
            return isCurrentBucket(secondary, observedAt: state.observedAt, now: now)
        }
        return false
    }

    private func isCurrentBucket(_ bucket: LimitBucket, observedAt: Date, now: Date) -> Bool {
        if let resetAt = bucket.resetAt {
            return resetAt > now.timeIntervalSince1970
        }
        let windowAge = bucket.windowMinutes.map { $0 * 60.0 } ?? limitStateFallbackMaxAge
        return now.timeIntervalSince(observedAt) <= max(windowAge, limitStateFallbackMaxAge)
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

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
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
    // ponytail: anchor-only bounds에는 팻 크기가 없음, Codex가 크기를 저장하거나 기본 크기를 바꾸면 재검토
    private let anchorOnlyMascotSize = CGSize(width: 80, height: 87)

    init(globalStatePath: URL) {
        self.globalStatePath = globalStatePath
    }

    func readPetFramesTopLeft(preferLiveOverlay: Bool = false, liveReference: CGRect? = nil) -> PetFramesTopLeft? {
        guard let data = try? Data(contentsOf: globalStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isAvatarOverlayOpen(root),
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = number(bounds["x"]),
              let y = number(bounds["y"]) else {
            return nil
        }

        if let anchorPayload = bounds["anchor"] as? [String: Any],
           let anchorX = number(anchorPayload["x"]),
           let anchorY = number(anchorPayload["y"]),
           let anchorWidth = number(anchorPayload["width"]),
           let anchorHeight = number(anchorPayload["height"]) {
            let mascot = CGRect(x: anchorX, y: anchorY, width: anchorWidth, height: anchorHeight)
            return PetFramesTopLeft(mascot: mascot, overlay: mascot, usedLiveOverlay: false)
        }

        if let overlayWidth = number(bounds["width"]),
           let overlayHeight = number(bounds["height"]),
           let mascotPayload = bounds["mascot"] as? [String: Any],
           let left = number(mascotPayload["left"]),
           let top = number(mascotPayload["top"]),
           let width = number(mascotPayload["width"]),
           let height = number(mascotPayload["height"]) {
            let persistedOverlay = CGRect(x: x, y: y, width: overlayWidth, height: overlayHeight)
            let liveOverlay = preferLiveOverlay ? liveCodexOverlayBounds(matching: liveReference ?? persistedOverlay, expectedSize: persistedOverlay.size) : nil
            let overlay = liveOverlay ?? persistedOverlay
            let mascot = CGRect(x: overlay.minX + left, y: overlay.minY + top, width: width, height: height)
            return PetFramesTopLeft(mascot: mascot, overlay: overlay, usedLiveOverlay: liveOverlay != nil)
        }

        let mascot = CGRect(origin: CGPoint(x: x, y: y), size: anchorOnlyMascotSize)
        return PetFramesTopLeft(mascot: mascot, overlay: mascot, usedLiveOverlay: false)
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

        if rows.isEmpty {
            drawNoDataText(context, centeredAt: CGPoint(x: rect.midX + barOffset.width, y: 18.0 - barOffset.height))
            return
        }

        let panelWidth = min(max(barWidth + 72.0, rect.width - 10.0), 136.0)
        let rowHeight: CGFloat = 18.0
        let rowGap: CGFloat = 3.0
        let verticalPadding: CGFloat = 6.0
        let panelHeight = verticalPadding * 2.0 + CGFloat(rows.count) * rowHeight + CGFloat(max(rows.count - 1, 0)) * rowGap
        let panelRect = CGRect(
            x: rect.midX - panelWidth / 2.0 + barOffset.width,
            y: usageProgressPanelOriginY(visibleRowCount: rows.count, barOffsetY: barOffset.height),
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

        guard !rowItems.isEmpty else {
            drawNoDataText(context, centeredAt: CGPoint(x: center.x, y: max(12.0, center.y - outerRadius + 17.0)))
            return
        }

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

    private func drawNoDataText(_ context: CGContext, centeredAt center: CGPoint) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0.0, height: -1.0), blur: 3.0, color: NSColor.black.withAlphaComponent(0.62).cgColor)
        let text = NSAttributedString(string: "NO DATA", attributes: noDataAttributes())
        let size = text.size()
        text.draw(at: CGPoint(x: center.x - size.width / 2.0, y: center.y - size.height / 2.0 + 0.5))
        context.restoreGState()
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

    private func noDataAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 8.6, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.68)
        ]
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
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(state: state, displayStyle: displayStyle, barWidth: barWidth, barOffset: barOffset, checkPulse: checkPulse).draw(in: bounds)
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
    private var showRingsItem: NSMenuItem?
    private var displayStyleItems: [NSMenuItem] = []
    private var barWidthMenuItem: NSMenuItem?
    private var barWidthItems: [NSMenuItem] = []
    private var stateTimer: Timer?
    private var frameTimer: Timer?
    private var dragFollowTimer: Timer?
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
    private var usageRingOffset: CGSize
    private var barWidthPreset: UsageBarWidthPreset
    private var stateReadInFlight = false

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(
            logsPath: config.logsPath,
            codexHome: config.codexHome
        )
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.displayStyle = UsageDisplayStyle(rawValue: UserDefaults.standard.string(forKey: displayStyleDefaultsKey) ?? "") ?? .rings
        self.usageBarOffset = CGSize(
            width: CGFloat(UserDefaults.standard.double(forKey: barsOffsetXDefaultsKey)),
            height: CGFloat(UserDefaults.standard.double(forKey: barsOffsetYDefaultsKey))
        )
        self.usageRingOffset = CGSize(
            width: CGFloat(UserDefaults.standard.double(forKey: ringsOffsetXDefaultsKey)),
            height: CGFloat(UserDefaults.standard.double(forKey: ringsOffsetYDefaultsKey))
        )
        self.barWidthPreset = UsageBarWidthPreset(rawValue: UserDefaults.standard.string(forKey: barWidthPresetDefaultsKey) ?? "") ?? .normal
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
    }

    deinit {
        stateTimer?.invalidate()
        frameTimer?.invalidate()
        dragFollowTimer?.invalidate()
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
        frameTimer = Timer.scheduledTimer(withTimeInterval: petFrameFallbackPollInterval, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
        if config.mouseMonitorEnabled {
            installDragFollow()
        }
    }

    private func updateState() {
        guard !stateReadInFlight else { return }
        stateReadInFlight = true
        stateQueue.async { [weak self] in
            guard let self else { return }
            let state = self.stateReader.readLatest()
            DispatchQueue.main.async {
                self.ringView.state = state
                self.updateSummaryMenuItem()
                self.stateReadInFlight = false
                self.triggerStateCheckPulse()
            }
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
            topLeft = adjustedUsageRingOrigin(
                CGPoint(
                    x: petFrame.midX - size.width / 2,
                    y: petFrame.midY - side / 2 - usageRingTopPadding
                ),
                offset: usageRingOffset,
                coordinateSpace: .topLeft
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
            origin = adjustedUsageRingOrigin(
                CGPoint(
                    x: petFrame.midX - size.width / 2,
                    y: petFrame.midY - side / 2
                ),
                offset: usageRingOffset,
                coordinateSpace: .appKit
            )
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
            width: max(132.0, ringOverlaySide(for: petFrame), barWidthPreset.width + 72.0),
            height: petFrame.height + usageBarBottomPadding + usageBarTopPadding
        )
    }

    private func ringOverlaySize(for petFrame: CGRect) -> CGSize {
        let side = ringOverlaySide(for: petFrame)
        return CGSize(width: side, height: side + usageRingTopPadding)
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
        let showItem = NSMenuItem(title: "Show Usage Overlay", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(makeDisplayStyleMenuItem())
        let layoutControlsSeparator = NSMenuItem.separator()
        menu.addItem(layoutControlsSeparator)
        menu.addItem(makeBarWidthMenuItem())
        menu.addItem(makePositionMenuItem())
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
        updateDisplayStyleMenuItems()
        updateBarWidthMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
        updateDisplayStyleMenuItems()
        updateBarWidthMenuItems()
        updateState()
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 50))

        let label = NSTextField(labelWithString: "Position")
        label.frame = NSRect(x: 32, y: 30, width: 152, height: 15)
        label.font = NSFont.menuFont(ofSize: 12.0)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        let control = NSSegmentedControl(
            labels: ["←", "→", "↑", "↓", "↺"],
            trackingMode: .momentary,
            target: self,
            action: #selector(adjustUsageOverlayFromSegment(_:))
        )
        control.frame = NSRect(x: 30, y: 6, width: 146, height: 24)
        control.controlSize = .small
        control.segmentStyle = .rounded
        control.setWidth(28.0, forSegment: UsagePositionAction.left.rawValue)
        control.setWidth(28.0, forSegment: UsagePositionAction.right.rawValue)
        control.setWidth(28.0, forSegment: UsagePositionAction.up.rawValue)
        control.setWidth(28.0, forSegment: UsagePositionAction.down.rawValue)
        control.setWidth(34.0, forSegment: UsagePositionAction.reset.rawValue)
        view.addSubview(control)

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
            let source: String
            switch ringView.state.source {
            case "app-server":
                source = "Codex"
            case let value where value.hasPrefix("log"):
                source = "Local"
            default:
                source = "Cached"
            }
            summaryItem.title = "\(source) \(formatAge(since: ringView.state.observedAt)) " + pieces.joined(separator: " | ")
        }
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
        barWidthMenuItem?.isHidden = !usesBars
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

    private func saveUsageLayout() {
        UserDefaults.standard.set(Double(usageBarOffset.width), forKey: barsOffsetXDefaultsKey)
        UserDefaults.standard.set(Double(usageBarOffset.height), forKey: barsOffsetYDefaultsKey)
        UserDefaults.standard.set(Double(usageRingOffset.width), forKey: ringsOffsetXDefaultsKey)
        UserDefaults.standard.set(Double(usageRingOffset.height), forKey: ringsOffsetYDefaultsKey)
        UserDefaults.standard.set(barWidthPreset.rawValue, forKey: barWidthPresetDefaultsKey)
    }

    private func applyUsageLayout() {
        ringView.barWidth = barWidthPreset.width
        ringView.barOffset = usageBarOffset
        saveUsageLayout()
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

    @objc private func refreshNow(_ sender: NSMenuItem) {
        updateState()
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

    @objc private func adjustUsageOverlayFromSegment(_ sender: NSSegmentedControl) {
        guard let action = UsagePositionAction(rawValue: sender.selectedSegment) else {
            return
        }

        let adjustedOffsets = adjustedUsageOffsets(
            barOffset: usageBarOffset,
            ringOffset: usageRingOffset,
            displayStyle: displayStyle,
            action: action
        )
        usageBarOffset = adjustedOffsets.bar
        usageRingOffset = adjustedOffsets.ring
        applyUsageLayout()
    }

    @objc private func setBarWidthPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = UsageBarWidthPreset(rawValue: rawValue) else {
            return
        }
        barWidthPreset = preset
        applyUsageLayout()
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
            codexHome: config.codexHome
        ).readLatest()
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let image = NSImage(size: size)
    image.lockFocus()
    LimitRingRenderer(
        state: state,
        displayStyle: config.previewStyle,
        barWidth: UsageBarWidthPreset.normal.width,
        barOffset: .zero,
        checkPulse: 0.55,
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

func parseConfig() -> LimitRingsConfig? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
    var config = LimitRingsConfig(
        codexHome: codexHome,
        globalStatePath: codexHome.appendingPathComponent(".codex-global-state.json"),
        logsPath: defaultLogsPath(codexHome: codexHome),
        previewPath: nil
    )

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: codex-pet-limit-rings [--preview PATH] [--preview-style rings|bars] [--preview-sample] [--preview-background] [--codex-home PATH] [--logs PATH] [--state PATH] [--no-mouse-monitor]

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
        case "--preview-background":
            config.previewUsesBackground = true
        case "--codex-home":
            guard let value = args.first else { return nil }
            args.removeFirst()
            let url = URL(fileURLWithPath: value)
            config.codexHome = url
            config.globalStatePath = url.appendingPathComponent(".codex-global-state.json")
            config.logsPath = defaultLogsPath(codexHome: url)
        case "--logs":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.logsPath = URL(fileURLWithPath: value)
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
    if let logs2 = newestExistingPath([
        codexHome.appendingPathComponent("sqlite/logs_2.sqlite"),
        codexHome.appendingPathComponent("logs_2.sqlite"),
    ]) {
        return logs2
    }
    if let logs1 = newestExistingPath([
        codexHome.appendingPathComponent("sqlite/logs_1.sqlite"),
        codexHome.appendingPathComponent("logs_1.sqlite"),
    ]) {
        return logs1
    }

    return codexHome.appendingPathComponent("logs_1.sqlite")
}

private func newestExistingPath(_ candidates: [URL]) -> URL? {
    var newest: (url: URL, modifiedAt: Date)?
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path)
        let modifiedAt = (attributes?[.modificationDate] as? Date) ?? .distantPast
        if newest == nil || modifiedAt > newest!.modifiedAt {
            newest = (candidate, modifiedAt)
        }
    }
    return newest?.url
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
