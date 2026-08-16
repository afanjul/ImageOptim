//
//  Localization.swift
//  ImageOptim
//

import Foundation

/// The backend framework's user-visible strings live in the app's `Localizable.strings`
/// (that's where `NSLocalizedString` used to look them up from), so the lookup has to
/// be pointed at the main bundle explicitly.
public func IOLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: key, bundle: .main, comment: comment)
}
