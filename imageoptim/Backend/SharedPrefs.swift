//
//  SharedPrefs.swift
//  ImageOptim
//

import Foundation

/// Preferences shared between the app and the ImageOptimize share extension.
public enum SharedPrefs {
    public static let suiteName = "56Q6SR3DF7.O2MS.ImageOptim"

    public static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// The whole `dictionaryRepresentation` is massive, so only the interesting bits get copied.
    private static let sharedKeys = [
        PrefKey.advPngEnabled, PrefKey.level, PrefKey.gifsicleEnabled,
        PrefKey.jpegOptimEnabled, PrefKey.jpegTranEnabled, PrefKey.jpegTranStripAll,
        PrefKey.oxiPngEnabled,
        PrefKey.pngCrushEnabled, PrefKey.pngOutEnabled,
        PrefKey.pngOutRemoveChunks, PrefKey.zopfliEnabled,
        PrefKey.pngMinQuality, PrefKey.jpegOptimMaxQuality, PrefKey.gifQuality,
    ]

    @MainActor private static var observer: (any NSObjectProtocol)?

    /// Mirrors the app's settings into the shared suite, now and on every change.
    @MainActor
    public static func startMirroring(from defaults: UserDefaults) {
        guard let shared = Self.defaults() else { return }

        copy(from: defaults, to: shared)

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        // the notification's object is the very `defaults` observed here, which keeps
        // the (non-Sendable) UserDefaults out of the @Sendable closure's captures
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { notification in
            guard let changed = notification.object as? UserDefaults, let shared = Self.defaults() else { return }
            copy(from: changed, to: shared)
        }
    }

    private static func copy(from defaults: UserDefaults, to shared: UserDefaults) {
        for key in sharedKeys {
            if let value = defaults.object(forKey: key) {
                shared.set(value, forKey: key)
            } else {
                shared.removeObject(forKey: key)
            }
        }
    }
}
