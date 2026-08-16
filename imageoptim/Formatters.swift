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

    static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        return byteCount.string(fromByteCount: Int64(bytes))
    }

    /// The old SavingsFormatter: nothing for negative values, and a plain "0%" for a rounding-error saving.
    static func savings(_ percent: Double?) -> String {
        guard let percent, percent >= 0 else { return "" }
        if percent < 1.0 / 1024.0 {
            return "0%"
        }
        return savingsPercent.string(from: percent as NSNumber) ?? ""
    }
}
