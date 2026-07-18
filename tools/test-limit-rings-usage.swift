import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LimitRingsUsageTestError: Error, CustomStringConvertible {
    case failed(String)
    case sqlite(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        case .sqlite(let message):
            return message
        }
    }
}

@main
struct LimitRingsUsageTests {
    static func main() {
        do {
            try testDefaultLogsPathPrefersActiveSQLiteDirectory()
            try testDefaultLogsPathFallsBackToLegacyLogsPath()
            try testDefaultCodexCLIPathsIncludeHomebrewLocations()
            try testLimitStateSkipsInvalidRateLimitRows()
            try testLimitStateRejectsExpiredRateLimitRows()
            try testLimitStatePrefersAppServerSnapshot()
            try testLimitStateKeepsRecentAppServerSnapshotDuringTransientFailure()
            try testLimitStateRejectsExpiredCachedAppServerSnapshot()
            try testUsagePositionAdjustment()
            try testUsageStyleOffsetsStayIndependent()
            try testUsageRingPositionCoordinates()
            print("limit-rings usage tests passed")
        } catch {
            fputs("limit-rings usage tests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testUsagePositionAdjustment() throws {
        let origin = CGSize(width: 8, height: -4)
        try expect(
            adjustedUsageOffset(origin, action: .left) == CGSize(width: 4, height: -4),
            "expected left adjustment to move four points"
        )
        try expect(
            adjustedUsageOffset(origin, action: .up) == CGSize(width: 8, height: -8),
            "expected up adjustment to move four points"
        )
        try expect(
            adjustedUsageOffset(origin, action: .reset) == .zero,
            "expected reset adjustment to clear the active style offset"
        )
    }

    private static func testUsageStyleOffsetsStayIndependent() throws {
        let barOffset = CGSize(width: 8, height: -4)
        let ringOffset = CGSize(width: -12, height: 16)
        let movedRing = adjustedUsageOffsets(
            barOffset: barOffset,
            ringOffset: ringOffset,
            displayStyle: .rings,
            action: .right
        )
        try expect(movedRing.bar == barOffset, "expected ring movement to preserve the bar offset")
        try expect(
            movedRing.ring == CGSize(width: -8, height: 16),
            "expected ring movement to adjust only the ring offset"
        )

        let movedBar = adjustedUsageOffsets(
            barOffset: barOffset,
            ringOffset: ringOffset,
            displayStyle: .bars,
            action: .down
        )
        try expect(
            movedBar.bar == CGSize(width: 8, height: 0),
            "expected bar movement to adjust only the bar offset"
        )
        try expect(movedBar.ring == ringOffset, "expected bar movement to preserve the ring offset")
    }

    private static func testUsageRingPositionCoordinates() throws {
        let origin = CGPoint(x: 100, y: 200)
        let upAndRightOffset = CGSize(width: 4, height: -4)
        try expect(
            adjustedUsageRingOrigin(origin, offset: upAndRightOffset, coordinateSpace: .topLeft)
                == CGPoint(x: 104, y: 196),
            "expected top-left coordinates to move the ring up and right"
        )
        try expect(
            adjustedUsageRingOrigin(origin, offset: upAndRightOffset, coordinateSpace: .appKit)
                == CGPoint(x: 104, y: 204),
            "expected AppKit coordinates to move the ring up and right"
        )
    }

    private static func testDefaultLogsPathPrefersActiveSQLiteDirectory() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-default-logs-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let legacyLogsPath = root.appendingPathComponent("logs_2.sqlite")
        let sqliteDir = root.appendingPathComponent("sqlite", isDirectory: true)
        let sqliteLogsPath = sqliteDir.appendingPathComponent("logs_2.sqlite")
        try fileManager.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try Data().write(to: legacyLogsPath)
        try Data().write(to: sqliteLogsPath)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: legacyLogsPath.path
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: sqliteLogsPath.path
        )

        try expect(
            defaultLogsPath(codexHome: root).path == sqliteLogsPath.path,
            "expected active sqlite/ logs_2 path to be preferred"
        )
    }

    private static func testDefaultLogsPathFallsBackToLegacyLogsPath() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-legacy-logs-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let legacyLogsPath = root.appendingPathComponent("logs_2.sqlite")
        try Data().write(to: legacyLogsPath)

        try expect(
            defaultLogsPath(codexHome: root).path == legacyLogsPath.path,
            "expected legacy logs_2 path to remain supported"
        )
    }

    private static func testDefaultCodexCLIPathsIncludeHomebrewLocations() throws {
        let paths = defaultCodexCLIPaths(
            home: URL(fileURLWithPath: "/Users/tester"),
            environment: [:]
        )

        try expect(paths.contains("/opt/homebrew/bin/codex"), "expected Apple Silicon Homebrew Codex CLI path")
        try expect(paths.contains("/usr/local/bin/codex"), "expected Intel Homebrew Codex CLI path")
    }

    private static func testLimitStateSkipsInvalidRateLimitRows() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-limits-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        try createLogsDatabase(at: logsPath)

        let now = Int64(Date().timeIntervalSince1970)
        try insertInvalidRateLimitRow(logsPath: logsPath, ts: now + 1)
        try insertRateLimitRow(logsPath: logsPath, ts: now, primaryUsed: 15, secondaryUsed: 26)

        let state = LimitStateReader(logsPath: logsPath).readLatest()

        try expect(state.primary?.remainingPercent == 85, "expected invalid primary row to be skipped")
        try expect(state.secondary?.remainingPercent == 74, "expected invalid secondary row to be skipped")
    }

    private static func testLimitStateRejectsExpiredRateLimitRows() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-expired-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        try createLogsDatabase(at: logsPath)

        let now = Int64(Date().timeIntervalSince1970)
        try insertRateLimitRow(
            logsPath: logsPath,
            ts: now - 10,
            primaryUsed: 3,
            secondaryUsed: 31,
            primaryResetAt: now - 1,
            secondaryResetAt: now + 604800
        )

        let state = LimitStateReader(logsPath: logsPath).readLatest()

        try expect(state.primary == nil, "expected expired primary limit data to be rejected")
        try expect(state.secondary == nil, "expected stale secondary from expired event to be rejected")
        try expect(state.source == "none", "expected expired rate limit state to be empty")
    }

    private static func testLimitStatePrefersAppServerSnapshot() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-app-server-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        try createLogsDatabase(at: logsPath)

        let now = Int64(Date().timeIntervalSince1970)
        try insertRateLimitRow(logsPath: logsPath, ts: now, primaryUsed: 3, secondaryUsed: 31)

        let appServerState = LimitState(
            planType: "pro",
            primary: LimitBucket(usedPercent: 10, windowMinutes: 300, resetAt: Double(now + 3600)),
            secondary: LimitBucket(usedPercent: 53, windowMinutes: 10080, resetAt: Double(now + 604800)),
            additional: [],
            observedAt: Date(),
            source: "app-server"
        )
        let state = LimitStateReader(
            logsPath: logsPath,
            appServerStateProvider: { appServerState }
        ).readLatest()

        try expect(state.primary?.remainingPercent == 90, "expected app-server primary value to override log fallback")
        try expect(state.secondary?.remainingPercent == 47, "expected app-server secondary value to override log fallback")
        try expect(state.source == "app-server", "expected app-server source")
    }

    private static func testLimitStateKeepsRecentAppServerSnapshotDuringTransientFailure() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-app-server-cache-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        try createLogsDatabase(at: logsPath)

        let now = Date()
        var nextState: LimitState? = LimitState(
            planType: "pro",
            primary: LimitBucket(usedPercent: 12, windowMinutes: 300, resetAt: now.addingTimeInterval(3600).timeIntervalSince1970),
            secondary: LimitBucket(usedPercent: 34, windowMinutes: 10080, resetAt: now.addingTimeInterval(604800).timeIntervalSince1970),
            additional: [],
            observedAt: now,
            source: "app-server"
        )
        let reader = LimitStateReader(
            logsPath: logsPath,
            appServerStateProvider: { nextState }
        )

        _ = reader.readLatest()
        nextState = nil
        let cached = reader.readLatest()

        try expect(cached.primary?.remainingPercent == 88, "expected recent primary snapshot during transient failure")
        try expect(cached.secondary?.remainingPercent == 66, "expected recent secondary snapshot during transient failure")
        try expect(cached.source == "cached", "expected cached source during transient failure")
    }

    private static func testLimitStateRejectsExpiredCachedAppServerSnapshot() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-expired-app-server-cache-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        try createLogsDatabase(at: logsPath)

        let now = Date()
        let cacheMaxAge: TimeInterval = 30 * 60
        var nextState: LimitState? = LimitState(
            planType: "pro",
            primary: LimitBucket(usedPercent: 12, windowMinutes: 300, resetAt: now.addingTimeInterval(3600).timeIntervalSince1970),
            secondary: nil,
            additional: [],
            observedAt: now.addingTimeInterval(-cacheMaxAge - 1),
            source: "app-server"
        )
        let reader = LimitStateReader(
            logsPath: logsPath,
            appServerStateProvider: { nextState }
        )

        _ = reader.readLatest()
        nextState = nil
        let expired = reader.readLatest()

        try expect(expired.primary == nil, "expected expired app-server cache to be discarded")
        try expect(expired.source == "none", "expected no cached source after cache expiry")
    }

    private static func createLogsDatabase(at path: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else {
            throw LimitRingsUsageTestError.sqlite("could not open sqlite database")
        }
        defer { sqlite3_close(db) }

        try exec(db, """
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            ts_nanos INTEGER NOT NULL,
            thread_id TEXT,
            target TEXT NOT NULL,
            feedback_log_body TEXT NOT NULL
        );
        CREATE INDEX idx_logs_ts ON logs(ts, ts_nanos, id);
        """)
    }

    private static func insertInvalidRateLimitRow(logsPath: URL, ts: Int64) throws {
        let body = """
        websocket event: {"type":"codex.rate_limits","plan_type":"pro","rate_limits":{"allowed":true,"limit_reached":false,"primary":{"used_percent":0,"window_minutes":0,"reset_at":\(ts)},"secondary":null},"additional_rate_limits":{}}
        """
        try insertLogRow(logsPath: logsPath, ts: ts, threadID: "thread-rate", body: body)
    }

    private static func insertRateLimitRow(logsPath: URL, ts: Int64, primaryUsed: Int, secondaryUsed: Int) throws {
        try insertRateLimitRow(
            logsPath: logsPath,
            ts: ts,
            primaryUsed: primaryUsed,
            secondaryUsed: secondaryUsed,
            primaryResetAt: ts + 3600,
            secondaryResetAt: ts + 604800
        )
    }

    private static func insertRateLimitRow(
        logsPath: URL,
        ts: Int64,
        primaryUsed: Int,
        secondaryUsed: Int,
        primaryResetAt: Int64,
        secondaryResetAt: Int64
    ) throws {
        let body = """
        websocket event: {"type":"codex.rate_limits","plan_type":"pro","rate_limits":{"allowed":true,"limit_reached":false,"primary":{"used_percent":\(primaryUsed),"window_minutes":300,"reset_at":\(primaryResetAt)},"secondary":{"used_percent":\(secondaryUsed),"window_minutes":10080,"reset_at":\(secondaryResetAt)}},"additional_rate_limits":{}}
        """
        try insertLogRow(logsPath: logsPath, ts: ts, threadID: "thread-rate", body: body)
    }

    private static func insertLogRow(logsPath: URL, ts: Int64, threadID: String, body: String) throws {
        try insertLogRow(
            logsPath: logsPath,
            ts: ts,
            target: "codex_api::endpoint::responses_websocket",
            threadID: threadID,
            body: body
        )
    }

    private static func insertLogRow(logsPath: URL, ts: Int64, target: String, threadID: String, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(logsPath.path, &db) == SQLITE_OK, let db else {
            throw LimitRingsUsageTestError.sqlite("could not open sqlite database")
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO logs (ts, ts_nanos, thread_id, target, feedback_log_body)
        VALUES (?, 0, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LimitRingsUsageTestError.sqlite("could not prepare log insert")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, ts)
        sqlite3_bind_text(statement, 2, threadID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, target, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, body, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LimitRingsUsageTestError.sqlite("could not insert log row")
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        defer { sqlite3_free(errorMessage) }
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw LimitRingsUsageTestError.sqlite(message)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw LimitRingsUsageTestError.failed(message)
        }
    }

}
