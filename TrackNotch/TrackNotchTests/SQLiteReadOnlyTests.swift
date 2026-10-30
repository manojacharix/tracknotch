import XCTest
import SQLite3
@testable import TrackNotch

/// Codex (and Cursor) keep their state in WAL-mode SQLite files. When the app
/// quits cleanly, SQLite deletes the -wal/-shm sidecars, and a plain
/// SQLITE_OPEN_READONLY connection can no longer read the database
/// ("unable to open database file"). SQLiteReadOnly must still read it.
final class SQLiteReadOnlyTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String { dir.appendingPathComponent("state.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        for sql in ["PRAGMA journal_mode=WAL",
                    "CREATE TABLE threads (id INTEGER)",
                    "INSERT INTO threads VALUES (1), (2), (3)",
                    "PRAGMA wal_checkpoint(TRUNCATE)"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)

        // Match what Codex leaves on disk after a clean quit: main file only.
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func count(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM threads", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func testReadsWALDatabaseWhenSidecarsAreMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath + "-shm"))

        let db = try XCTUnwrap(SQLiteReadOnly.open(dbPath))
        defer { sqlite3_close(db) }
        XCTAssertEqual(count(db), 3)
    }

    func testReadsWALDatabaseWhileWriterIsOpen() throws {
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO threads VALUES (4)", nil, nil, nil), SQLITE_OK)

        let db = try XCTUnwrap(SQLiteReadOnly.open(dbPath))
        defer { sqlite3_close(db) }
        XCTAssertEqual(count(db), 4)
    }

    func testReturnsNilForMissingFile() {
        XCTAssertNil(SQLiteReadOnly.open(dir.appendingPathComponent("nope.sqlite").path))
    }
}
