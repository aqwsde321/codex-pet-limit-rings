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
            try testLimitStateSkipsInvalidRateLimitRows()
            try testLimitStateRejectsExpiredRateLimitRows()
            try testLimitStatePrefersAppServerSnapshot()
            try testSQLiteFallbackSkipsPlanModeTurns()
            try testUsageDetailsRejectsStaleTurnUsage()
            print("limit-rings usage tests passed")
        } catch {
            fputs("limit-rings usage tests failed: \(error)\n", stderr)
            exit(1)
        }
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

    private static func testLimitStateSkipsInvalidRateLimitRows() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-limits-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        let statePath = root.appendingPathComponent("turn-usage.json")
        let summaryPath = root.appendingPathComponent("turn-usage-summary.json")
        try createLogsDatabase(at: logsPath)

        let now = Int64(Date().timeIntervalSince1970)
        try insertInvalidRateLimitRow(logsPath: logsPath, ts: now + 1)
        try insertRateLimitRow(logsPath: logsPath, ts: now, primaryUsed: 15, secondaryUsed: 26)

        let state = LimitStateReader(
            logsPath: logsPath,
            turnUsageStatePath: statePath,
            turnUsageSummaryPath: summaryPath
        ).readLatest()

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
        let statePath = root.appendingPathComponent("turn-usage.json")
        let summaryPath = root.appendingPathComponent("turn-usage-summary.json")
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

        let state = LimitStateReader(
            logsPath: logsPath,
            turnUsageStatePath: statePath,
            turnUsageSummaryPath: summaryPath
        ).readLatest()

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
        let statePath = root.appendingPathComponent("turn-usage.json")
        let summaryPath = root.appendingPathComponent("turn-usage-summary.json")
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
            turnUsageStatePath: statePath,
            turnUsageSummaryPath: summaryPath,
            appServerStateProvider: { appServerState }
        ).readLatest()

        try expect(state.primary?.remainingPercent == 90, "expected app-server primary value to override log fallback")
        try expect(state.secondary?.remainingPercent == 47, "expected app-server secondary value to override log fallback")
        try expect(state.source == "app-server", "expected app-server source")
    }

    private static func testSQLiteFallbackSkipsPlanModeTurns() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-usage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        let statePath = root.appendingPathComponent("turn-usage.json")
        let summaryPath = root.appendingPathComponent("turn-usage-summary.json")
        try createLogsDatabase(at: logsPath)

        let now = Int64(Date().timeIntervalSince1970)
        try insertUsageRow(
            logsPath: logsPath,
            ts: now + 1,
            threadID: "thread-a",
            turnID: "turn-plan",
            inputTokens: 1000,
            cachedTokens: 200,
            outputTokens: 50
        )
        try insertUsageRow(
            logsPath: logsPath,
            ts: now,
            threadID: "thread-a",
            turnID: "turn-normal",
            inputTokens: 100,
            cachedTokens: 40,
            outputTokens: 10
        )

        let unfiltered = LimitStateReader(
            logsPath: logsPath,
            turnUsageStatePath: root.appendingPathComponent("missing-turn-usage.json"),
            turnUsageSummaryPath: summaryPath
        ).readUsageDetails()
        try expect(
            unfiltered.recentTurns.map(\.turnID) == ["turn-plan", "turn-normal"],
            "expected SQLite fallback to read both turns without skip markers"
        )

        let stateJSON = """
        {"version":1,"records":[],"skipped_turns":[{"thread_id":"thread-a","turn_id":"turn-plan","observed_at":\(Date().timeIntervalSince1970)}]}
        """
        try stateJSON.write(to: statePath, atomically: true, encoding: .utf8)

        let filtered = LimitStateReader(
            logsPath: logsPath,
            turnUsageStatePath: statePath,
            turnUsageSummaryPath: summaryPath
        ).readUsageDetails()

        try expect(
            filtered.recentTurns.map(\.turnID) == ["turn-normal"],
            "expected Plan mode skip marker to hide the matching SQLite fallback turn"
        )
        let normalTurn = try unwrap(filtered.recentTurns.first, "expected one non-plan fallback turn")
        try expect(normalTurn.inputTokens == 100, "expected normal turn input token total")
        try expect(normalTurn.cachedTokens == 40, "expected normal turn cached token total")
        try expect(normalTurn.outputTokens == 10, "expected normal turn output token total")
        try expect(normalTurn.effectiveTokens == 70, "expected goal-style effective token total")
    }

    private static func testUsageDetailsRejectsStaleTurnUsage() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-limit-rings-stale-usage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let logsPath = root.appendingPathComponent("logs_2.sqlite")
        let statePath = root.appendingPathComponent("turn-usage.json")
        let summaryPath = root.appendingPathComponent("turn-usage-summary.json")
        try createLogsDatabase(at: logsPath)

        let staleTimestamp = Int64(Date().timeIntervalSince1970) - 2 * 24 * 60 * 60
        try insertUsageRow(
            logsPath: logsPath,
            ts: staleTimestamp,
            threadID: "thread-old-sqlite",
            turnID: "turn-old-sqlite",
            inputTokens: 1000,
            cachedTokens: 200,
            outputTokens: 50
        )

        let stateJSON = """
        {"version":1,"records":[{"thread_id":"thread-old-hook","turn_id":"turn-old-hook","observed_at":\(Double(staleTimestamp)),"input_tokens":1000,"cached_tokens":200,"output_tokens":50}],"skipped_turns":[]}
        """
        try stateJSON.write(to: statePath, atomically: true, encoding: .utf8)

        let summaryJSON = """
        {"version":1,"updated_at":\(Double(staleTimestamp)),"today":{"effective_tokens":850,"turn_count":1,"call_count":1},"latest_session":{"effective_tokens":850,"turn_count":1,"call_count":1}}
        """
        try summaryJSON.write(to: summaryPath, atomically: true, encoding: .utf8)

        let details = LimitStateReader(
            logsPath: logsPath,
            turnUsageStatePath: statePath,
            turnUsageSummaryPath: summaryPath
        ).readUsageDetails()

        try expect(details.recentTurns.isEmpty, "expected stale SQLite and hook turn usage to be hidden")
        try expect(details.summary == nil, "expected stale turn usage summary to be hidden")
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

    private static func insertUsageRow(
        logsPath: URL,
        ts: Int64,
        threadID: String,
        turnID: String,
        inputTokens: Int64,
        cachedTokens: Int64,
        outputTokens: Int64
    ) throws {
        let body = """
        turn_id=\(turnID) websocket event: {"type":"response.completed","usage":{"input_tokens":\(inputTokens),"input_tokens_details":{"cached_tokens":\(cachedTokens)},"output_tokens":\(outputTokens)}}
        """
        try insertLogRow(logsPath: logsPath, ts: ts, threadID: threadID, body: body)
    }

    private static func insertLogRow(logsPath: URL, ts: Int64, threadID: String, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(logsPath.path, &db) == SQLITE_OK, let db else {
            throw LimitRingsUsageTestError.sqlite("could not open sqlite database")
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO logs (ts, ts_nanos, thread_id, target, feedback_log_body)
        VALUES (?, 0, ?, 'codex_api::endpoint::responses_websocket', ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LimitRingsUsageTestError.sqlite("could not prepare log insert")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, ts)
        sqlite3_bind_text(statement, 2, threadID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, body, -1, sqliteTransient)
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

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw LimitRingsUsageTestError.failed(message)
        }
        return value
    }
}
