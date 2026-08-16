//
//  Formatters.swift
//  ImageOptim
//

import Foundation

/// Only ever used from table cells, so main-actor isolation keeps the
/// (non-Sendable) formatters shareable without any locking.
@MainActor
enum Formatters {
    /// Grouped byte count without a unit — matches the NSByteCountFormatter configured in the old xib.
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useBytes
        formatter.includesUnit = false
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    /// Percentages that are already on a 0…100 scale, hence the multiplier of 1.
    private static let savingsPercent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.multiplier = 1
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    /// `ByteCountFormatter`/`NumberFormatter` are slow enough (they allocate and box through
    /// `NSNumber`) to show up while scrolling: three of these calls run for every visible row,
    /// on every frame the table redraws. The results are pure functions of their input, and rows
    /// keep asking for the same value, so they are memoised. The caches are dropped wholesale
    /// once they grow large rather than evicting entries one by one — the hit rate is what
    /// matters here, not the exact contents.
    private static let cacheLimit = 4096
    private static var sizeCache: [Int: String] = [:]
    private static var savingsCache: [Int: String] = [:]

    static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        if let cached = sizeCache[bytes] {
            return cached
        }
        let formatted = byteCount.string(fromByteCount: Int64(bytes))
        if sizeCache.count >= cacheLimit {
            sizeCache.removeAll(keepingCapacity: true)
        }
        sizeCache[bytes] = formatted
        return formatted
    }

    /// The old SavingsFormatter: nothing for negative values, and a plain "0%" for a rounding-error saving.
    static func savings(_ percent: Double?) -> String {
        guard let percent, percent >= 0 else { return "" }
        if percent < 1.0 / 1024.0 {
            return "0%"
        }
        // Only one decimal place is ever displayed, so that is all the cache needs to distinguish.
        let key = Int((percent * 10).rounded())
        if let cached = savingsCache[key] {
            return cached
        }
        let formatted = savingsPercent.string(from: percent as NSNumber) ?? ""
        if savingsCache.count >= cacheLimit {
            savingsCache.removeAll(keepingCapacity: true)
        }
        savingsCache[key] = formatted
        return formatted
    }
}
