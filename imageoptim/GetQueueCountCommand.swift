//
//  GetQueueCountCommand.swift
//  ImageOptim
//
//  The `do queuecount command` verb from ImageOptimVerbs.sdef. Verbs don't get much simpler.
//

import AppKit

@objc(GetQueueCountCommand)
final class GetQueueCountCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let count: Int = MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.model.queue.queueCount ?? 0
        }
        return count
    }
}
