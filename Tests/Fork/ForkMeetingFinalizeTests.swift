// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The final pass's decisions (`ForkMeetingFinalPass`): which way it goes,
/// which tracks it makes, when its copy may replace the master, how it
/// reports; and the bounded wait the app uses when it quits.
enum ForkMeetingFinalizeTests {
    typealias Pass = ForkMeetingFinalPass

    static func run(_ suite: TestSuite) {
        route(suite)
        layout(suite)
        verification(suite)
        progress(suite)
        boundedWait(suite)
        wiring(suite)
    }

    private static let gigabyte: Int64 = 1_000_000_000

    private static func route(_ suite: TestSuite) {
        let master = 600_000_000 as Int64
        suite.expect(Pass.route(freeBytes: 10 * gigabyte, masterBytes: master) == .copy,
                     "with room, the copy with the mixed track is written")
        suite.expect(Pass.route(freeBytes: master + master / 10 + ForkMeetingDisk.minimumFreeBytesToContinue,
                                masterBytes: master) == .copy
                        && Pass.route(freeBytes: master + master / 10 + ForkMeetingDisk.minimumFreeBytesToContinue - 1,
                                      masterBytes: master) == .promoteMaster,
                     "the copy needs the master's size, a tenth more, and the stop floor kept free")
        suite.expect(Pass.route(freeBytes: 0, masterBytes: master) == .promoteMaster,
                     "a full disk makes the master the final file, no copy tried")
        suite.expect(Pass.route(freeBytes: nil, masterBytes: master) == .copy,
                     "an unknown free space is not a full disk: the copy is tried on a draft that cannot harm the master")
    }

    private static func layout(_ suite: TestSuite) {
        suite.expect(Pass.layout(audioTracks: 2) == Pass.Layout(mixed: [0, 1], copied: [.meeting, .microphone]),
                     "two sources: both mixed, both kept, the meeting first then the microphone, by their order")
        suite.expect(Pass.layout(audioTracks: 1) == Pass.Layout(mixed: [0], copied: [.meeting]),
                     "no microphone: the mix is the meeting's sound alone, so every final file reads the same way")
        suite.expect(Pass.layout(audioTracks: 0) == Pass.Layout(mixed: [], copied: [])
                        && !Pass.layout(audioTracks: 0).hasMix,
                     "a silent master gets no mix, and so no M4A")
        suite.expect(Pass.layout(audioTracks: 3) == Pass.Layout(mixed: [0, 1], copied: [.meeting, .microphone, .extra]),
                     "a track beyond the two is kept, never mixed, never dropped")
        suite.expect(Pass.role(at: 0) == .meeting && Pass.role(at: 1) == .microphone && Pass.role(at: 7) == .extra,
                     "a source's role is its place among the master's audio tracks")
        suite.expect(Pass.mixVolume(sources: 2) < 1 && Pass.mixVolume(sources: 2) * 2 < 1.5
                        && Pass.mixVolume(sources: 1) == 1,
                     "two voices are lowered in the mix so they do not clip together; a single one is left as is")
    }

    private static func verification(_ suite: TestSuite) {
        suite.expect(Pass.isWhole(seconds: 3600, masterSeconds: 3600)
                        && Pass.isWhole(seconds: 3564, masterSeconds: 3600),
                     "a copy playing 99 % of the master or more holds the meeting")
        suite.expect(!Pass.isWhole(seconds: 3563, masterSeconds: 3600)
                        && !Pass.isWhole(seconds: 1800, masterSeconds: 3600),
                     "a copy cut short never replaces the master")
        suite.expect(!Pass.isWhole(seconds: nil, masterSeconds: 3600) && !Pass.isWhole(seconds: 0, masterSeconds: 3600)
                        && !Pass.isWhole(seconds: .nan, masterSeconds: 3600),
                     "a copy that does not open, or plays nothing, is never whole")
        suite.expect(Pass.isWhole(seconds: 12, masterSeconds: nil),
                     "with no master to compare with, a file that plays is whole")
    }

    private static func progress(_ suite: TestSuite) {
        suite.expect(Pass.progress(copy: 0.5, extractsAudio: false) == 0.5
                        && Pass.progress(copy: 1, extractsAudio: false) == 1,
                     "without an M4A, the copy is the whole job")
        suite.expect(Pass.progress(copy: 1, extractsAudio: true) == Pass.copyShare
                        && Pass.progress(copy: 1, audio: 1, extractsAudio: true) == 1
                        && Pass.progress(copy: 0.5, extractsAudio: true) < 0.5,
                     "with an M4A, the gauge keeps the last part for it and reaches the end only when it is made")
        suite.expect(Pass.progress(copy: 1.7, extractsAudio: false) == 1 && Pass.progress(copy: -1, extractsAudio: false) == 0,
                     "a sample time past the master's length never takes the gauge past its ends")
        suite.expect(Pass.shouldPublish(0, last: nil) && !Pass.shouldPublish(0.004, last: 0)
                        && Pass.shouldPublish(0.011, last: 0) && Pass.shouldPublish(1, last: 0.995)
                        && !Pass.shouldPublish(1, last: 1),
                     "the gauge moves by whole percents and always reaches its end, once")
    }

    private static func boundedWait(_ suite: TestSuite) {
        let quick = ForkMeetingBoundedWait.run(timeout: 2) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done() }
        }
        suite.expect(quick, "a file closed in time ends the wait at once")

        let started = Date()
        let late = ForkMeetingBoundedWait.run(timeout: 0.2) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { done() }
        }
        let waited = Date().timeIntervalSince(started)
        suite.expect(!late && waited >= 0.19 && waited < 0.9,
                     "a file that does not close in time is given up at the bound, not waited for")

        let twice = ForkMeetingBoundedWait.run(timeout: 1) { done in
            done()
            done()
        }
        suite.expect(twice, "a work that answers at once, or twice, counts once")

        let never = ForkMeetingBoundedWait.run(timeout: 0) { _ in }
        suite.expect(!never, "a work that never answers does not hold the quit")
        suite.expect(ForkMeetingBoundedWait.quitTimeout == 3, "the app gives the writer three seconds when it quits")
    }

    private static func wiring(_ suite: TestSuite) {
        let finalizer = source("Sources/Vorssaint/Fork/Meetings/ForkMeetingFinalizer.swift")
        let run = finalizer.components(separatedBy: "private func run(_ job: Job) async -> Outcome {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let removal = run.range(of: "manager.removeItem(at: paths.master)")
        let copied = run.range(of: "try await copy(job, paths: paths, masterSeconds: masterSeconds)")
        suite.expect(removal != nil && copied != nil && copied!.upperBound < removal!.lowerBound,
                     "the master is removed only after the copy is written, verified and in place")
        let copy = finalizer.components(separatedBy: "private func copy(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let verified = copy.range(of: "ForkMeetingFinalPass.isWhole(seconds: seconds, masterSeconds: masterSeconds)")
        let replaced = copy.range(of: "try ForkMeetingStore.replace(paths.final, with: paths.draft)")
        suite.expect(verified != nil && replaced != nil && verified!.upperBound < replaced!.lowerBound
                        && copy.contains("await Self.playableSeconds(at: paths.draft)"),
                     "the draft replaces the final file only once a fresh asset plays it whole")
        let seconds = finalizer.components(separatedBy: "static func playableSeconds(at url: URL) async -> Double? {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(seconds.contains("let asset = AVURLAsset(url: url"),
                     "every check reads a new asset, never one that cached an earlier answer")
        suite.expect(!finalizer.contains("asyncAfter") && !finalizer.contains("Task.sleep")
                        && !finalizer.contains("Thread.sleep"),
                     "the final pass never waits for a file with a fixed delay")
        suite.expect(!finalizer.contains("endedAt"),
                     "the final pass never writes an end time: the recording's own, written when it closed, stands")
    }

    static func source(_ path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }
}
