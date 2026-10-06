//
//  Settings.swift
//  ImageOptim
//

import Foundation

/// The `UserDefaults` keys. These strings are part of the app's on-disk state
/// and are shared with the share extension, so they must not be renamed.
public enum PrefKey {
    public static let lossyEnabled = "LossyEnabled"
    public static let lossyUsed = "LossyUsed"

    /// The AdvPNG level setting is reused as the general "optimization level" for all tools.
    public static let level = "AdvPngLevel"

    public static let advPngEnabled = "AdvPngEnabled"
    public static let pngCrushEnabled = "PngCrush2Enabled"
    public static let oxiPngEnabled = "OptiPngEnabled"
    /// Named after PNGOUT, which used to own this setting; it applies to every PNG tool now.
    public static let removePngChunks = "PngOutRemoveChunks"
    public static let zopfliEnabled = "ZopfliEnabled"
    public static let pngMinQuality = "PngMinQuality"

    public static let guetzliEnabled = "GuetzliEnabled"
    public static let jpegOptimEnabled = "JpegOptimEnabled"
    public static let jpegOptimMaxQuality = "JpegOptimMaxQuality"
    public static let jpegTranEnabled = "JpegTranEnabled"
    public static let jpegTranStripAll = "JpegTranStripAll"
    public static let jpegTranStripAllSetByGuetzli = "JpegTranStripAllSetByGuetzli"

    public static let gifsicleEnabled = "GifsicleEnabled"
    public static let gifQuality = "GifQuality"

    public static let svgoEnabled = "SvgoEnabled"
    public static let svgCleanerEnabled = "SvgcleanerEnabled"

    public static let webpEnabled = "WebpEnabled"
    public static let avifEnabled = "AvifEnabled"
    public static let jxlEnabled = "JxlEnabled"
    public static let heicToJpegEnabled = "HeicToJpegEnabled"

    public static let preserveOriginal = "PreserveOriginal"
    public static let outputFolderPath = "OutputFolderPath"
    public static let filenamePrefix = "FilenamePrefix"
    public static let filenameSuffix = "FilenameSuffix"

    public static let preservePermissions = "PreservePermissions"
    public static let preserveDates = "PreserveDates"

    public static let runLowPriority = "RunLowPriority"
    public static let runConcurrentFiles = "RunConcurrentFiles"
    public static let runConcurrentDirscans = "RunConcurrentDirscans"
    public static let runConcurrentFileops = "RunConcurrentFileops"
    public static let bounceDock = "BounceDock"
}

/// An immutable snapshot of the preferences, taken when a job is enqueued.
///
/// The Objective-C version passed `NSUserDefaults` down into every worker and read
/// the keys in the worker's initialiser, i.e. at exactly this moment — so snapshotting
/// keeps the behaviour identical while making the settings `Sendable`.
public struct Settings: Sendable {
    public var lossyEnabled = false
    public var level = 4

    public var advPngEnabled = true
    public var pngCrushEnabled = false
    public var oxiPngEnabled = true
    public var removePngChunks = true
    public var zopfliEnabled = true
    public var pngMinQuality = 80

    public var guetzliEnabled = false
    public var jpegOptimEnabled = true
    public var jpegOptimMaxQuality = 80
    public var jpegTranEnabled = true
    public var jpegTranStripAll = true

    public var gifsicleEnabled = true
    public var gifQuality = 80

    public var svgoEnabled = false
    public var svgCleanerEnabled = true

    public var webpEnabled = true
    public var avifEnabled = true
    public var jxlEnabled = true
    public var heicToJpegEnabled = true

    public var preserveOriginal = false
    public var outputFolderPath = ""
    public var filenamePrefix = ""
    public var filenameSuffix = ""

    public var preservePermissions = true
    public var preserveDates = false

    public var runLowPriority = false

    public init() {}

    public init(defaults: UserDefaults) {
        lossyEnabled = defaults.bool(forKey: PrefKey.lossyEnabled)
        level = defaults.integer(forKey: PrefKey.level)

        advPngEnabled = defaults.bool(forKey: PrefKey.advPngEnabled)
        pngCrushEnabled = defaults.bool(forKey: PrefKey.pngCrushEnabled)
        oxiPngEnabled = defaults.bool(forKey: PrefKey.oxiPngEnabled)
        removePngChunks = defaults.bool(forKey: PrefKey.removePngChunks)
        zopfliEnabled = defaults.bool(forKey: PrefKey.zopfliEnabled)
        pngMinQuality = defaults.integer(forKey: PrefKey.pngMinQuality)

        guetzliEnabled = defaults.bool(forKey: PrefKey.guetzliEnabled)
        jpegOptimEnabled = defaults.bool(forKey: PrefKey.jpegOptimEnabled)
        jpegOptimMaxQuality = defaults.integer(forKey: PrefKey.jpegOptimMaxQuality)
        jpegTranEnabled = defaults.bool(forKey: PrefKey.jpegTranEnabled)
        jpegTranStripAll = defaults.bool(forKey: PrefKey.jpegTranStripAll)

        gifsicleEnabled = defaults.bool(forKey: PrefKey.gifsicleEnabled)
        gifQuality = defaults.integer(forKey: PrefKey.gifQuality)

        svgoEnabled = defaults.bool(forKey: PrefKey.svgoEnabled)
        svgCleanerEnabled = defaults.bool(forKey: PrefKey.svgCleanerEnabled)

        webpEnabled = defaults.object(forKey: PrefKey.webpEnabled) != nil ? defaults.bool(forKey: PrefKey.webpEnabled) : true
        avifEnabled = defaults.object(forKey: PrefKey.avifEnabled) != nil ? defaults.bool(forKey: PrefKey.avifEnabled) : true
        jxlEnabled = defaults.object(forKey: PrefKey.jxlEnabled) != nil ? defaults.bool(forKey: PrefKey.jxlEnabled) : true
        heicToJpegEnabled = defaults.object(forKey: PrefKey.heicToJpegEnabled) != nil ? defaults.bool(forKey: PrefKey.heicToJpegEnabled) : true

        preserveOriginal = defaults.bool(forKey: PrefKey.preserveOriginal)
        outputFolderPath = defaults.string(forKey: PrefKey.outputFolderPath) ?? ""
        filenamePrefix = defaults.string(forKey: PrefKey.filenamePrefix) ?? ""
        filenameSuffix = defaults.string(forKey: PrefKey.filenameSuffix) ?? ""

        preservePermissions = defaults.bool(forKey: PrefKey.preservePermissions)
        preserveDates = defaults.bool(forKey: PrefKey.preserveDates)

        runLowPriority = defaults.bool(forKey: PrefKey.runLowPriority)
    }
}
