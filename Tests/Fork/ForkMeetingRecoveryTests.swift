// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The table of the plan, §5.6, and the rule above it: never a silent removal.
enum ForkMeetingRecoveryTests {
    typealias Plan = ForkMeetingRecoveryPlan
    typealias Media = ForkMeetingRecoveryPlan.Media

    static func run(_ suite: TestSuite) {
        crashed(suite)
        finalPassCut(suite)
        leftAlone(suite)
        patches(suite)
        inspection(suite)
        nothingLost(suite)
    }

    private static func sidecar(_ state: ForkMeetingSidecar.State?, stopReason: ForkMeetingStopReason? = nil,
                                schema: Int? = 1) -> Result<ForkMeetingSidecar, ForkMeetingSidecarFault> {
        var meeting = ForkMeetingSidecar()
        meeting.schema = schema
        meeting.state = state
        meeting.stopReason = stopReason
        meeting.recordedSeconds = 600
        return .success(meeting)
    }

    private static func facts(_ state: ForkMeetingSidecar.State?, stopReason: ForkMeetingStopReason? = nil,
                              master: Media? = nil, final: Media? = nil, drafts: Bool = false) -> Plan.Facts {
        Plan.Facts(sidecar: sidecar(state, stopReason: stopReason), master: master, final: final, hasDrafts: drafts)
    }

    private static func crashed(_ suite: TestSuite) {
        suite.expect(Plan.plan(facts(.recording, master: Media(duration: 2220)))
                        == .finalize(stopReason: .crash, recovered: true, discardDrafts: false),
                     "recording, with a readable master: final pass, recovered, stopped by a crash")
        suite.expect(Plan.plan(facts(.recording, stopReason: .quit, master: Media(duration: 2220)))
                        == .finalize(stopReason: .quit, recovered: true, discardDrafts: false),
                     "a quit already noted stays the reason")
        suite.expect(Plan.plan(facts(.interrupted, stopReason: .quit, master: Media(duration: 2220)))
                        == .finalize(stopReason: .quit, recovered: true, discardDrafts: false),
                     "a meeting interrupted by a quit is recovered from its master at the next launch")
        suite.expect(Plan.plan(facts(.recording, master: Media(duration: nil))) == .markInterrupted(stopReason: .crash)
                        && Plan.plan(facts(.recording)) == .markInterrupted(stopReason: .crash),
                     "recording, with a master unreadable or gone: interrupted, folder kept")
        suite.expect(Plan.plan(facts(.recording, master: Media(duration: 0.4))) == .markInterrupted(stopReason: .crash),
                     "a master under a second holds nothing worth a final pass")
        suite.expect(Plan.plan(facts(.recording, master: Media(duration: 1))) == .finalize(stopReason: .crash, recovered: true,
                                                                                          discardDrafts: false),
                     "a master of a second is recovered")
    }

    private static func finalPassCut(_ suite: TestSuite) {
        suite.expect(Plan.plan(facts(.finalizing, stopReason: .user, master: Media(duration: 3000), drafts: true))
                        == .finalize(stopReason: .user, recovered: false, discardDrafts: true),
                     "finalizing with a draft: the draft goes, the final pass runs again; the meeting itself had ended well")
        suite.expect(Plan.plan(facts(.finalizing, stopReason: .user, master: Media(duration: 3000),
                                     final: Media(duration: 2990)))
                        == .complete(removeMaster: true, discardDrafts: false),
                     "the final file is there and whole: complete, and only now the master goes")
        suite.expect(Plan.plan(facts(.finalizing, stopReason: .user, master: Media(duration: 3000),
                                     final: Media(duration: 2900)))
                        == .finalize(stopReason: .user, recovered: false, discardDrafts: false),
                     "a final file under 99 % of the master is not trusted: the master stays and the pass runs again")
        suite.expect(Plan.plan(facts(.complete, master: Media(duration: 3000), final: Media(duration: 3000)))
                        == .complete(removeMaster: true, discardDrafts: false),
                     "a complete meeting whose master was left behind loses it once the final file is checked")
        suite.expect(Plan.plan(facts(.finalizing, final: Media(duration: 3000)))
                        == .complete(removeMaster: false, discardDrafts: false),
                     "a final file without its master: complete, nothing to remove")
    }

    private static func leftAlone(_ suite: TestSuite) {
        suite.expect(Plan.plan(facts(.complete, master: Media(duration: nil), final: Media(duration: 3000))) == .leave,
                     "a master whose length cannot be read is never removed")
        suite.expect(Plan.plan(facts(.interrupted, master: Media(duration: nil))) == .leave
                        && Plan.plan(facts(.interrupted)) == .leave,
                     "an interrupted meeting with nothing readable stays as it is, launch after launch")
        suite.expect(Plan.plan(facts(.complete, final: Media(duration: 3000))) == .leave,
                     "a complete meeting is left alone")
        for fault in [ForkMeetingSidecarFault.absent, .unreadable("x"), .corrupt("x")] {
            suite.expect(Plan.plan(Plan.Facts(sidecar: .failure(fault), master: Media(duration: 3000))) == .leave,
                         "a folder whose sidecar does not read is never touched (\(fault))")
        }
        suite.expect(Plan.plan(Plan.Facts(sidecar: sidecar(.recording, schema: 2), master: Media(duration: 3000))) == .leave,
                     "a meeting written by a later version is left to it")
        suite.expect(Plan.plan(facts(nil, master: Media(duration: 3000))) == .leave,
                     "a sidecar without a state is not guessed at")
    }

    private static func patches(_ suite: TestSuite) {
        let crash = facts(.recording, master: Media(duration: 2220))
        suite.expect(Plan.patch(for: Plan.plan(crash), facts: crash)
                        == ForkMeetingSidecarPatch(state: .finalizing, stopReason: .crash, recordedSeconds: 2220, recovered: true),
                     "a recovered meeting is marked recovered, with the master's length and no invented end")
        let cut = facts(.finalizing, stopReason: .user, master: Media(duration: 500), drafts: true)
        suite.expect(Plan.patch(for: Plan.plan(cut), facts: cut) == ForkMeetingSidecarPatch(state: .finalizing, stopReason: .user),
                     "a final pass run again keeps the meeting's length and is not called a recovery")
        let lost = facts(.recording)
        suite.expect(Plan.patch(for: Plan.plan(lost), facts: lost)
                        == ForkMeetingSidecarPatch(state: .interrupted, stopReason: .crash),
                     "an interrupted meeting is marked so, without an end")
        let whole = facts(.finalizing, final: Media(duration: 10))
        suite.expect(Plan.patch(for: Plan.plan(whole), facts: whole) == ForkMeetingSidecarPatch(state: .complete, finalPass: .done),
                     "a meeting found whole is marked complete")
        suite.expect(Plan.patch(for: .leave, facts: lost) == nil, "nothing to do writes nothing")
    }

    private static func inspection(_ suite: TestSuite) {
        typealias Contents = ForkMeetingFolder.Contents
        let master = Contents(video: nil, audio: nil, hasSidecar: true, hasMaster: true)
        let clean = Contents(video: "a.mp4", audio: "a.m4a", hasSidecar: true)
        suite.expect(Plan.needsInspection(sidecar(.recording), contents: clean)
                        && Plan.needsInspection(sidecar(.finalizing), contents: clean),
                     "a meeting left recording or finalizing is inspected")
        suite.expect(!Plan.needsInspection(sidecar(.complete), contents: clean)
                        && !Plan.needsInspection(sidecar(.interrupted), contents: clean),
                     "a complete meeting, or an interrupted one with nothing left to recover, is not probed at each launch")
        suite.expect(Plan.needsInspection(sidecar(.interrupted), contents: master)
                        && Plan.needsInspection(sidecar(.complete), contents: master),
                     "a master left in the folder is worth a look")
        suite.expect(!Plan.needsInspection(.failure(.corrupt("x")), contents: master)
                        && !Plan.needsInspection(sidecar(.recording, schema: 3), contents: master),
                     "a sidecar that does not read, or is from a later version, is not inspected")
    }

    /// Every combination of facts: whatever is removed, what it held is safe
    /// elsewhere.
    private static func nothingLost(_ suite: TestSuite) {
        let states: [ForkMeetingSidecar.State?] = [nil, .recording, .finalizing, .complete, .interrupted]
        let medias: [Media?] = [nil, Media(duration: nil), Media(duration: 0.5), Media(duration: 100), Media(duration: 3000)]
        var checked = 0
        var safe = true
        for state in states {
            for master in medias {
                for final in medias {
                    for drafts in [false, true] {
                        let facts = facts(state, master: master, final: final, drafts: drafts)
                        checked += 1
                        switch Plan.plan(facts) {
                        case let .complete(removeMaster, discardDrafts):
                            let finalSeconds = final?.duration ?? 0
                            if removeMaster {
                                guard let masterSeconds = master?.duration,
                                      finalSeconds >= masterSeconds * Plan.completeShare else { safe = false; break }
                            }
                            if discardDrafts, finalSeconds <= 0 { safe = false }
                        case let .finalize(_, _, discardDrafts):
                            if discardDrafts, (master?.duration ?? 0) < Plan.minimumMasterSeconds { safe = false }
                        case .markInterrupted, .leave:
                            break
                        }
                    }
                }
            }
        }
        suite.expect(safe && checked == 250,
                     "in all \(checked) cases, the master goes only behind a whole final file, a draft only behind a readable copy")
    }
}
