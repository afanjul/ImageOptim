//
//  Log.swift
//  ImageOptim
//

import Foundation
import Synchronization

public enum IOLog {
    /// When the app is launched from the command line to optimize files and quit,
    /// chatty per-file logging is suppressed.
    public static let logsHidden = Atomic<Bool>(false)

    public static var hideLogs: Bool {
        get { logsHidden.load(ordering: .relaxed) }
        set { logsHidden.store(newValue, ordering: .relaxed) }
    }
}

public func IODebug(_ message: @autoclosure () -> String) {
    if !IOLog.hideLogs {
        NSLog("%@", message())
    }
}

public func IOWarn(_ message: @autoclosure () -> String) {
    NSLog("%@", message())
}
