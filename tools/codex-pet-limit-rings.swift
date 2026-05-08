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
private let petFrameFallbackPollInterval: TimeInterval = 2.0
private let petFrameStateDebounceInterval: TimeInterval = 0.035
private let dragFollowInterval: TimeInterval = 1.0 / 60.0
private let dragLiveMismatchTolerance: CGFloat = 96.0
private let stateCheckPulseDuration: TimeInterval = 0.85
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let barsOffsetXDefaultsKey = "CodexPetLimitRings.barsOffsetX"
private let barsOffsetYDefaultsKey = "CodexPetLimitRings.barsOffsetY"
private let barWidthPresetDefaultsKey = "CodexPetLimitRings.barWidthPreset"
private let usageBarPositionStep: CGFloat = 4.0

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
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset_at)
    }
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var previewPath: URL?
    var fallbackSize: CGFloat = 220
    var mouseMonitorEnabled: Bool = true
}

final class LimitStateReader {
    private let logsPath: URL

    init(logsPath: URL) {
        self.logsPath = logsPath
    }

    func readLatest() -> LimitState {
        return readLatestLog()
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
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 2) else {
            return .empty
        }

        let ts = sqlite3_column_int64(statement, 0)
        let tsNanos = sqlite3_column_int64(statement, 1)
        let observedAt = Date(timeIntervalSince1970: TimeInterval(ts) + TimeInterval(tsNanos) / 1_000_000_000.0)
        let body = String(cString: cText)
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data) else {
            return .empty
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
    var barWidth: CGFloat
    var checkPulse: CGFloat

    func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.clear(rect)

        drawProgressPanel(context, in: rect)
        context.restoreGState()
    }

    private enum RingRole {
        case primary
        case secondary
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
            x: rect.midX - panelWidth / 2.0,
            y: 4.0,
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

        context.saveGState()
        let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
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
        percent.draw(at: CGPoint(x: textX, y: y + 7.0))

        if let reset = formatResetCountdown(row.bucket.resetAt) {
            let detail = NSAttributedString(string: reset, attributes: progressDetailAttributes())
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
            .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 0.92)
        ]
    }

}

final class LimitRingView: NSView {
    var state: LimitState = .empty {
        didSet { needsDisplay = true }
    }
    var barWidth: CGFloat = UsageBarWidthPreset.normal.width {
        didSet { needsDisplay = true }
    }
    var checkPulse: CGFloat = 0.0 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(state: state, barWidth: barWidth, checkPulse: checkPulse).draw(in: bounds)
    }
}

final class LimitRingsApp: NSObject {
    private let config: LimitRingsConfig
    private let stateReader: LimitStateReader
    private let frameReader: PetFrameReader
    private let panel: NSPanel
    private let ringView: LimitRingView
    private let stateQueue = DispatchQueue(label: "codex-pet-limit-rings.state-reader")
    private var statusItem: NSStatusItem?
    private var summaryItem: NSMenuItem?
    private var showRingsItem: NSMenuItem?
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
    private var usageBarOffset: CGSize
    private var barWidthPreset: UsageBarWidthPreset
    private var stateReadInFlight = false

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(logsPath: config.logsPath)
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.usageBarOffset = CGSize(
            width: CGFloat(UserDefaults.standard.double(forKey: barsOffsetXDefaultsKey)),
            height: CGFloat(UserDefaults.standard.double(forKey: barsOffsetYDefaultsKey))
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
        ringView.barWidth = barWidthPreset.width
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
        let size = progressOverlaySize(for: petFrame)
        let topLeft = CGPoint(
            x: petFrame.midX - size.width / 2 + usageBarOffset.width,
            y: petFrame.minY - 6.0 + usageBarOffset.height
        )
        let origin = appKitOriginFromTopLeft(topLeft, size: size)

        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func setPanelFrame(forPetFrameAppKit petFrame: CGRect) {
        let size = progressOverlaySize(for: petFrame)
        let origin = CGPoint(
            x: petFrame.midX - size.width / 2 + usageBarOffset.width,
            y: petFrame.minY - 56.0 - usageBarOffset.height
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func progressOverlaySize(for petFrame: CGRect) -> CGSize {
        CGSize(
            width: max(132.0, petFrame.width + 18.0, barWidthPreset.width + 72.0),
            height: petFrame.height + 62.0
        )
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Codex Pet Usage Bars"
        }

        let menu = NSMenu()
        let summary = NSMenuItem(title: "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Usage Bars", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(makePositionMenuItem())
        menu.addItem(makeBarWidthMenuItem())
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
        updateBarWidthMenuItems()
    }

    private func makePositionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 52))

        let label = NSTextField(labelWithString: "Position")
        label.frame = NSRect(x: 12, y: 30, width: 212, height: 16)
        label.font = NSFont.menuFont(ofSize: 12.0)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        let control = NSSegmentedControl(
            labels: ["Left", "Right", "Up", "Down", "Reset"],
            trackingMode: .momentary,
            target: self,
            action: #selector(adjustUsageBarsFromSegment(_:))
        )
        control.frame = NSRect(x: 10, y: 6, width: 216, height: 24)
        control.controlSize = .small
        control.segmentStyle = .rounded
        control.setWidth(38.0, forSegment: UsageBarPositionAction.left.rawValue)
        control.setWidth(44.0, forSegment: UsageBarPositionAction.right.rawValue)
        control.setWidth(30.0, forSegment: UsageBarPositionAction.up.rawValue)
        control.setWidth(42.0, forSegment: UsageBarPositionAction.down.rawValue)
        control.setWidth(50.0, forSegment: UsageBarPositionAction.reset.rawValue)
        view.addSubview(control)

        item.view = view
        return item
    }

    private func makeBarWidthMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Bar Width", action: nil, keyEquivalent: "")
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
            let source = ringView.state.source == "log" ? "Local" : "Cached"
            summaryItem.title = "\(source) \(formatAge(since: ringView.state.observedAt)) " + pieces.joined(separator: " | ")
        }
    }

    private func updateShowRingsMenuItem() {
        showRingsItem?.state = ringsVisible ? .on : .off
    }

    private func updateBarWidthMenuItems() {
        for item in barWidthItems {
            item.state = (item.representedObject as? String) == barWidthPreset.rawValue ? .on : .off
        }
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
        saveUsageBarLayout()
        if let currentPetFrameAppKit {
            setPanelFrame(forPetFrameAppKit: currentPetFrameAppKit)
            if ringsVisible {
                panel.orderFrontRegardless()
            }
        }
        updateBarWidthMenuItems()
    }

    @objc private func toggleRings(_ sender: NSMenuItem) {
        setRingsVisible(!ringsVisible)
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        updateState()
        updateFrame()
        updateRingVisibility()
    }

    @objc private func adjustUsageBarsFromSegment(_ sender: NSSegmentedControl) {
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
    let state = LimitStateReader(logsPath: config.logsPath).readLatest()
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    LimitRingRenderer(state: state, barWidth: UsageBarWidthPreset.normal.width, checkPulse: 0.55).draw(in: CGRect(origin: .zero, size: size))
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
            Usage: codex-pet-limit-rings [--preview PATH] [--codex-home PATH] [--logs PATH] [--state PATH] [--no-mouse-monitor]

            Draws transparent Codex rate-limit usage bars under the current pet using local Codex logs.
            """)
            exit(0)
        case "--preview":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.previewPath = URL(fileURLWithPath: value)
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
    let logs2 = codexHome.appendingPathComponent("logs_2.sqlite")
    if FileManager.default.fileExists(atPath: logs2.path) {
        return logs2
    }
    return codexHome.appendingPathComponent("logs_1.sqlite")
}

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
