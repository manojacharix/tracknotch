import Foundation
import SQLite3

/// Read-only access to another app's SQLite database (Codex, Cursor).
///
/// Those databases run in WAL mode. When the owning app quits cleanly, SQLite
/// deletes the -wal/-shm sidecar files, and a SQLITE_OPEN_READONLY connection
/// cannot recreate them, so every query fails with "unable to open database
/// file". In that case nobody is writing, so we fall back to `immutable=1`,
/// which reads the main file directly without touching the sidecars.
enum SQLiteReadOnly {
    static func open(_ path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if let db = openAndProbe(path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX) {
            return db
        }

        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { return nil }
        return openAndProbe(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI)
    }

    /// sqlite3_open_v2 is lazy and succeeds even when reads will fail,
    /// so run a trivial query to confirm the connection is usable.
    private static func openAndProbe(_ filename: String, flags: Int32) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        let ok = sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_OK
        if !ok { sqlite3_close(db); return nil }
        return db
    }
}
