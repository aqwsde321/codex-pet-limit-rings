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
            try testSQLiteFallbackSkipsPlanModeTurns()
            print("limit-rings usage tests passed")
        } catch {
            fputs("limit-rings usage tests failed: \(error)\n", stderr)
            exit(1)
        }
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

    private static func insertUsageRow(
        logsPath: URL,
        ts: Int64,
        threadID: String,
        turnID: String,
        inputTokens: Int64,
        cachedTokens: Int64,
        outputTokens: Int64
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(logsPath.path, &db) == SQLITE_OK, let db else {
            throw LimitRingsUsageTestError.sqlite("could not open sqlite database")
        }
        defer { sqlite3_close(db) }

        let body = """
        turn_id=\(turnID) websocket event: {"type":"response.completed","usage":{"input_tokens":\(inputTokens),"input_tokens_details":{"cached_tokens":\(cachedTokens)},"output_tokens":\(outputTokens)}}
        """
        let sql = """
        INSERT INTO logs (ts, ts_nanos, thread_id, target, feedback_log_body)
        VALUES (?, 0, ?, 'codex_api::endpoint::responses_websocket', ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LimitRingsUsageTestError.sqlite("could not prepare usage insert")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, ts)
        sqlite3_bind_text(statement, 2, threadID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, body, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LimitRingsUsageTestError.sqlite("could not insert usage row")
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
