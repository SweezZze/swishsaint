// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// What the store, the system events and the updater decide around a
/// meeting: the free space read, what a reading means, whether a meeting is
/// in the way of an update; and the rules the store's code must keep.
enum ForkMeetingStoreTests {
    static func run(_ suite: TestSuite) {
        freeSpace(suite)
        diskSignal(suite)
        activity(suite)
        storeWiring(suite)
        updateWiring(suite)
    }

    private static func freeSpace(_ suite: TestSuite) {
        typealias Space = ForkMeetingFreeSpace
        suite.expect(Space.resolve(important: 80_000_000_000, available: 20_000_000_000) == 80_000_000_000,
                     "the capacity for important usage, purgeable space included, is the one used")
        suite.expect(Space.resolve(important: nil, available: 5_000_000_000) == 5_000_000_000
                        && Space.resolve(important: 0, available: 5_000_000_000) == 5_000_000_000,
                     "a volume that does not answer it, or answers zero, falls back to the plain capacity")
        suite.expect(Space.resolve(important: nil, available: nil) == nil
                        && Space.resolve(important: 0, available: nil) == nil,
                     "a reading that fails is unknown, never a zero made up")
        suite.expect(Space.resolve(important: 0, available: 0) == 0 && Space.resolve(important: nil, available: 0) == 0,
                     "a disk really full says so")
    }

    private static func diskSignal(_ suite: TestSuite) {
        let standard = ForkMeetingQuality.standard
        suite.expect(ForkMeetingDiskSignal.reading(freeBytes: nil, quality: standard) == nil,
                     "a failed reading of the disk says nothing: it never stops a meeting")
        suite.expect(ForkMeetingDiskSignal.reading(freeBytes: 50_000_000_000, quality: standard) == nil,
                     "with room, nothing is said")
        suite.expect(ForkMeetingDiskSignal.reading(freeBytes: 1_500_000_000, quality: standard)
                        == .low(freeBytes: 1_500_000_000),
                     "under two gigabytes, the reading goes to the pill with its bytes")
        suite.expect(ForkMeetingDiskSignal.reading(freeBytes: 400_000_000, quality: standard) == .critical
                        && ForkMeetingDiskSignal.reading(freeBytes: 0, quality: standard) == .critical,
                     "under the stop floor, the meeting stops while its file can still be closed")
    }

    private static func activity(_ suite: TestSuite) {
        let before = ForkMeetingActivity.tally
        suite.expect(!ForkMeetingActivity.isBusy, "nothing records or finishes at first")
        ForkMeetingActivity.setRecording(true)
        suite.expect(ForkMeetingActivity.isBusy, "a recording holds updates")
        ForkMeetingActivity.beginFinalizing()
        ForkMeetingActivity.setRecording(false)
        suite.expect(ForkMeetingActivity.isBusy,
                     "the next meeting's stop does not free the app while a final pass still runs")
        ForkMeetingActivity.beginFinalizing()
        ForkMeetingActivity.endFinalizing()
        suite.expect(ForkMeetingActivity.isBusy, "every final pass queued is counted")
        ForkMeetingActivity.endFinalizing()
        suite.expect(!ForkMeetingActivity.isBusy, "once both are done, the app is free")
        ForkMeetingActivity.endFinalizing()
        suite.expect(ForkMeetingActivity.tally == before, "an end too many never makes the count negative")
    }

    private static func storeWiring(_ suite: TestSuite) {
        let store = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Meetings/ForkMeetingStore.swift")
        let apply = store.components(separatedBy: "private func apply(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(apply.contains("ForkMeetingSidecar.read(at: url)")
                        && apply.contains("guard let next = ForkMeetingSidecar.rewriting(read, with: patch) else {")
                        && apply.contains("return false"),
                     "every write reads the file first and leaves a corrupt or later one as it is")
        let write = store.components(separatedBy: "private func writeSidecar(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(write.contains("try data.write(to: draft)") && write.contains("try Self.replace(target, with: draft)")
                        && !write.contains("removeItem(at: target)"),
                     "meeting.json is written to a draft that replaces it, never removed then written")
        suite.expect(store.components(separatedBy: "queue.async").count >= 3 && store.contains("queue.sync { apply(patch"),
                     "every write of meeting.json goes through the store's one serial queue")
        let scan = store.components(separatedBy: "private func recover(root: URL").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let claimed = scan.range(of: "guard claim(folder) else { continue }")
        let probed = scan.range(of: "await recover(folder")
        suite.expect(scan.contains("!isMadeHere(folder)") && claimed != nil && probed != nil
                        && claimed!.upperBound < probed!.lowerBound,
                     "the launch never touches a meeting this process records, nor opens one another copy of the app holds")
        suite.expect(store.contains("guard !opening else {") && store.contains("if let known = made[id] {"),
                     "a second start while a folder is being made is refused, the same meeting asked twice gets one folder")
        let free = store.components(separatedBy: "static func freeBytes(at url: URL) -> Int64? {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(free.contains("ForkMeetingFreeSpace.resolve") && !free.contains("?? 0"),
                     "the free space read is never a zero made up")
    }

    private static func updateWiring(_ suite: TestSuite) {
        let service = ForkMeetingFinalizeTests.source("Sources/Vorssaint/Fork/Update/ForkUpdateService.swift")
        let install = service.components(separatedBy: "func install(_ candidate: ForkUpdateSupport.Candidate) {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        let guarded = install.range(of: "guard !ForkMeetingActivity.isBusy else {")
        let download = install.range(of: "state = .downloading")
        suite.expect(guarded != nil && download != nil && guarded!.upperBound < download!.lowerBound,
                     "an update is not downloaded while a meeting records or finishes")
        let swap = install.range(of: "self.replaceRunningApp(with: newApp)")
        let recheck = install.range(of: "guard !ForkMeetingActivity.isBusy else {", options: .backwards)
        suite.expect(swap != nil && recheck != nil && recheck!.lowerBound > guarded!.lowerBound
                        && recheck!.upperBound < swap!.lowerBound,
                     "a meeting started during the download still holds the app from quitting")
        suite.expect(service.contains("forName: ForkMeetingActivity.didBecomeIdle")
                        && service.contains("ForkUpdateStrings.current.afterMeeting"),
                     "the update waits for the meeting's end, and says so")
    }
}
