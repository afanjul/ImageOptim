//
//  ResultsDB.swift
//  ImageOptim
//

import Foundation
import SQLite3

/// A 128-bit hash identifying "this exact file, optimized with these exact settings".
///
/// The four words are the MD5 digest reinterpreted as native-endian `UInt32`s, and they are
/// formatted into SQL as `x'%08x%08x%08x%08x'` — both details have to match the Objective-C
/// version byte for byte, otherwise every user's existing results cache would silently miss.
public struct ResultHash: Sendable, Hashable {
    var words: (UInt32, UInt32, UInt32, UInt32)

    public init(digest: some Sequence<UInt8>) {
        let bytes = Array(digest)
        precondition(bytes.count >= 16)
        words = bytes.withUnsafeBytes { raw in
            (
                raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self),
                raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            )
        }
    }

    var isZero: Bool {
        words.0 == 0 && words.1 == 0 && words.2 == 0 && words.3 == 0
    }

    var sqlLiteral: String {
        String(format: "x'%08x%08x%08x%08x'", words.0, words.1, words.2, words.3)
    }

    public static func == (a: Self, b: Self) -> Bool { a.words == b.words }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(words.0)
        hasher.combine(words.1)
        hasher.combine(words.2)
        hasher.combine(words.3)
    }
}

/// Remembers which files could not be optimized any further, so that re-running the
/// same files with the same settings is instant.
public actor ResultsDB {
    /// The connection outlives the actor's isolation: a `deinit` can't touch actor state,
    /// so closing it is the box's job.
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer?

        init(_ db: OpaquePointer?) { self.db = db }

        deinit {
            if let db {
                sqlite3_close(db)
            }
        }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.db }

    public init?() {
        guard let cachesPath = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "net.pornel.ImageOptim"
        let cachesWithBundlePath = cachesPath.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: cachesWithBundlePath, withIntermediateDirectories: true)

        // Migrate the pre-sandbox location
        let legacy = cachesPath.appendingPathComponent("ImageOptimResults.db")
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: cachesWithBundlePath.appendingPathComponent("Results.db"))
        }

        let dbPath = cachesWithBundlePath.appendingPathComponent("Results.db")
        IODebug("Results cache is in \(dbPath.path)")

        var handle: OpaquePointer?
        guard sqlite3_open(dbPath.path, &handle) == SQLITE_OK else {
            IOWarn("Failed to open db: \(String(cString: sqlite3_errmsg(handle)))")
            sqlite3_close(handle)
            return nil
        }
        connection = Connection(handle)

        Task { await self.createTables() }
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS results(inputs_hashsh BLOB(16) NOT NULL PRIMARY KEY, size INT NOT NULL, status INT NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS results_size ON results(size)
            """)
    }

    public func setUnoptimizableFile(hash: ResultHash, size: Int) {
        assert(!hash.isZero)
        exec("INSERT INTO results(inputs_hashsh, size, status) VALUES(\(hash.sqlLiteral), \(size), 1)")
    }

    public func hasResult(hash: ResultHash) -> Bool {
        assert(!hash.isZero)
        return exists("SELECT 1 FROM results WHERE inputs_hashsh = \(hash.sqlLiteral) LIMIT 1")
    }

    public func hasResult(fileSize: Int) -> Bool {
        exists("SELECT 1 FROM results WHERE size = \(fileSize) LIMIT 1")
    }

    // MARK: - sqlite plumbing

    @discardableResult
    private func exec(_ query: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, query, nil, nil, &err) == SQLITE_OK else {
            IOWarn("Query failed: \(err.map { String(cString: $0) } ?? "?") in \(query)")
            sqlite3_free(err)
            return false
        }
        return true
    }

    private func exists(_ query: String) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            IOWarn("Query failed: \(String(cString: sqlite3_errmsg(db))) in \(query)")
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
