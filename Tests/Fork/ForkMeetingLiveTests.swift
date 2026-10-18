// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

enum ForkMeetingLiveTests {
    static func run(_ suite: TestSuite) {
        clock(suite)
        look(suite)
        placement(suite)
        positions(suite)
        savedDetail(suite)
        sentences(suite)
    }

    private static let running = ForkMeetingClock(recordedBefore: 30, runningSince: nil)

    private static func clock(_ suite: TestSuite) {
        suite.expect(ForkMeetingPillLayout.clock(0) == "0:00" && ForkMeetingPillLayout.clock(61.9) == "1:01"
                        && ForkMeetingPillLayout.clock(3599) == "59:59",
                     "under the hour the pill reads minutes and seconds")
        suite.expect(ForkMeetingPillLayout.clock(3600) == "1:00:00" && ForkMeetingPillLayout.clock(3 * 3600 + 5) == "3:00:05"
                        && ForkMeetingPillLayout.clock(25 * 3600) == "25:00:00",
                     "past the hour it adds the hours, never 60:00 or 180:05")
        suite.expect(ForkMeetingPillLayout.clock(-4) == "0:00" && ForkMeetingPillLayout.clock(.nan) == "0:00"
                        && ForkMeetingPillLayout.clock(.infinity) == "0:00",
                     "a clock gone wrong reads zero rather than nonsense")
    }

    private static func look(_ suite: TestSuite) {
        let context = ForkMeetingLiveContext()
        func look(_ state: ForkMeetingPillState, _ context: ForkMeetingLiveContext = context,
                  progress: Double? = nil, reducesMotion: Bool = false) -> ForkMeetingPillLook? {
            ForkMeetingPillLook(state: state, context: context, finalizingProgress: progress, reducesMotion: reducesMotion)
        }
        suite.expect(look(.hidden) == nil, "a hidden pill shows nothing")

        let recording = look(.recording(running, diskMinutesLeft: nil))
        suite.expect(recording?.mark == .recording(pulses: true) && recording?.status == .meters
                        && recording?.showsControls == true && recording?.paused == false
                        && recording?.clockIsAlert == false,
                     "recording, the red dot breathes beside the time, the meters, pause and stop")
        suite.expect(look(.recording(running, diskMinutesLeft: nil), reducesMotion: true)?.mark == .recording(pulses: false),
                     "with Reduce Motion the dot stays still")

        let paused = look(.paused(running, .user, diskMinutesLeft: nil))
        suite.expect(paused?.mark == .paused && paused?.status == .paused && paused?.clockIsAlert == true
                        && paused?.paused == true && paused?.showsControls == true,
                     "paused, the pill turns orange, says so, stops breathing and offers to resume")

        var frozen = context
        frozen.pictureFrozen = true
        suite.expect(look(.recording(running, diskMinutesLeft: nil), frozen)?.status == .pictureFrozen,
                     "a minimized window says its picture is frozen")
        let disk = look(.recording(running, diskMinutesLeft: 25), frozen)
        suite.expect(disk?.status == .diskLow(minutesLeft: 25) && disk?.clockIsAlert == true
                        && disk?.mark == .recording(pulses: true),
                     "a disk running low outranks the frozen picture, in orange, the recording going on")
        suite.expect(look(.paused(running, .sleep, diskMinutesLeft: 9))?.status == .diskLow(minutesLeft: 9),
                     "the disk stays said through a pause")

        let stopping = look(.stopping)
        suite.expect(stopping?.mark == .working && stopping?.status == .stopping && stopping?.showsControls == false
                        && stopping?.showsClock == false,
                     "stopping, the pill shows a gauge and no button to press twice")
        suite.expect(look(.finalizing)?.status == .finalizing(progress: nil)
                        && look(.finalizing, progress: 0.4)?.status == .finalizing(progress: 0.4)
                        && look(.finalizing, progress: 3)?.status == .finalizing(progress: 1),
                     "finishing, the gauge is indeterminate until a progress is known, which stays within 0 and 1")
    }

    private static func placement(_ suite: TestSuite) {
        let size = ForkMeetingPillLayout.restingSize
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        // A 14-inch MacBook Pro: the camera's right edge at 822.
        let notched = ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: visible, cameraRightEdge: 822,
                                                          islandFrame: nil)
        // The camera ends at 822, the official recorder's pill (centred) at 756 + 75.
        suite.expect(notched == CGPoint(x: 839, y: 949 - 10 - 32),
                     "by default the pill sits under the menu bar, 8 pt right of the camera or of the official pill")
        let island = CGRect(x: 640, y: 950, width: 232, height: 32)
        suite.expect(ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: visible, cameraRightEdge: 822,
                                                         islandFrame: island).x == 880,
                     "an island wider than the camera pushes it further right")
        suite.expect(ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: visible, cameraRightEdge: nil,
                                                         islandFrame: nil).x == 839,
                     "without a camera or an island it sits right of the official recorder's pill, never over it")
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        suite.expect(ForkMeetingPillLayout.cameraRightEdge(auxiliaryMinX: 822, screenFrame: external) == 2334
                        && ForkMeetingPillLayout.cameraRightEdge(auxiliaryMinX: 2334, screenFrame: external) == 2334
                        && ForkMeetingPillLayout.cameraRightEdge(auxiliaryMinX: 822, screenFrame: visible) == 822,
                     "the camera's edge is found whether AppKit gives it in the display's points or the screen's")
        let edge = ForkMeetingPillLayout.defaultOrigin(size: size, visibleFrame: visible, cameraRightEdge: 1500,
                                                       islandFrame: nil)
        suite.expect(edge.x + size.width <= visible.maxX - ForkMeetingPillLayout.margin,
                     "the pill never starts off its display")

        let pill = CGRect(origin: CGPoint(x: 830, y: 907), size: size)
        let wide = ForkMeetingPillLayout.resized(pill, to: CGSize(width: 360, height: 32), within: visible)
        suite.expect(wide.minX == 830 && wide.maxY == pill.maxY && wide.width == 360,
                     "growing under the pointer, the pill keeps its left edge and its top")
        let atEdge = CGRect(origin: CGPoint(x: 1300, y: 907), size: size)
        let pushed = ForkMeetingPillLayout.resized(atEdge, to: CGSize(width: 360, height: 32), within: visible)
        suite.expect(pushed.maxX <= visible.maxX - ForkMeetingPillLayout.margin && pushed.width == 360,
                     "near the right edge it grows to the left instead of leaving the display")
    }

    private static func positions(_ suite: TestSuite) {
        let size = ForkMeetingPillLayout.restingSize
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        var positions = ForkMeetingPillPositions()
        positions.remember(CGRect(origin: CGPoint(x: 200, y: 700), size: size), on: "A", screenFrame: screen)
        let restored = ForkMeetingPillPositions(json: positions.json)
        suite.expect(restored == positions
                        && restored.origin(on: "A", size: size, screenFrame: screen, visibleFrame: visible)
                            == CGPoint(x: 200, y: 700),
                     "a dragged pill comes back where it was left, per display")
        suite.expect(restored.origin(on: "B", size: size, screenFrame: screen, visibleFrame: visible) == nil,
                     "another display keeps its own place, or the default one")
        let wider = restored.origin(on: "A", size: CGSize(width: 300, height: 32), screenFrame: screen,
                                    visibleFrame: visible)
        suite.expect(wider?.x == 200 && wider.map { $0.y + 32 } == 732,
                     "the place is the pill's top left corner, whatever its width")
        let smaller = CGRect(x: 0, y: 0, width: 800, height: 600)
        var far = ForkMeetingPillPositions()
        far.remember(CGRect(origin: CGPoint(x: 1300, y: 100), size: size), on: "A", screenFrame: screen)
        let clamped = far.origin(on: "A", size: size, screenFrame: smaller, visibleFrame: smaller)
        suite.expect(clamped.map { smaller.insetBy(dx: 3, dy: 3).contains(CGRect(origin: $0, size: size)) } == true,
                     "a display that shrank brings the pill back inside it")
        suite.expect(ForkMeetingPillPositions(json: "not json") == ForkMeetingPillPositions()
                        && ForkMeetingPillPositions(json: nil) == ForkMeetingPillPositions()
                        && ForkMeetingPillPositions(json: #"{"A":[1],"B":[2,3]}"#).offsets.keys.sorted() == ["B"],
                     "an unreadable record only puts the pill back at its default place")
        var forgotten = restored
        forgotten.forget("A")
        suite.expect(forgotten.offsets.isEmpty, "a double click forgets the display's place")
    }

    private static func savedDetail(_ suite: TestSuite) {
        let english = ForkMeetingLiveText.savedDetail(seconds: 52 * 60 + 10, bytes: 410_000_000, language: .enUS)
        suite.expect(english.hasPrefix("52") && english.contains("·") && english.contains("410"),
                     "a saved meeting says its length, then its size: \(english)")
        suite.expect(ForkMeetingLiveText.savedDetail(seconds: 12, bytes: nil, language: .enUS).hasPrefix("1"),
                     "a meeting under a minute reads one minute, never zero")
        let long = AppLanguage.allCases.map {
            ForkMeetingLiveText.savedDetail(seconds: 3 * 3600 + 12 * 60, bytes: 1_800_000_000, language: $0)
        }
        suite.expect(long.allSatisfy { $0.count <= 28 && $0.contains("3") && $0.contains("12") },
                     "three hours and twelve minutes, with the size, fit in 28 characters in every language: \(long)")
        let french = ForkMeetingLiveText.size(410_000_000, language: .fr)
        let russian = ForkMeetingLiveText.size(410_000_000, language: .ru)
        suite.expect(french.contains("Mo") && !french.contains("MB") && russian.contains("МБ")
                        && ForkMeetingLiveText.size(410_000_000, language: .enUS).contains("MB"),
                     "the size is written in the app's language, not the system's: \(french), \(russian)")
        suite.expect(ForkMeetingLiveText.savedDetail(seconds: 600, bytes: 410_000_000, language: .fr).hasSuffix(french),
                     "and the saved notice uses it")
    }

    private static func sentences(_ suite: TestSuite) {
        suite.expect(ForkMeetingLiveText.sentences("Meeting saved", "52 min · 410 MB") == "Meeting saved. 52 min · 410 MB",
                     "two sentences are joined by a full stop and a space")
        suite.expect(ForkMeetingLiveText.sentences("会议已保存", "52 分钟") == "会议已保存。52 分钟"
                        && ForkMeetingLiveText.sentences("ミーティングを保存しました", "52分") == "ミーティングを保存しました。52分",
                     "after Chinese or Japanese, by the ideographic full stop, never an ASCII dot")
        suite.expect(ForkMeetingLiveText.sentences("회의 저장됨", "52분") == "회의 저장됨. 52분",
                     "Korean keeps the full stop and the space")
        suite.expect(ForkMeetingLiveText.sentences("Done.", "Next") == "Done. Next"
                        && ForkMeetingLiveText.sentences("完成。", "下一个") == "完成。下一个"
                        && ForkMeetingLiveText.sentences("", "Only") == "Only",
                     "a text that already ends its sentence gets no second stop")
        let chinese = ForkMeetingStrings.strings(.zhHans)
        let spoken = ForkMeetingAnnouncement.failure(.screenRecordingDenied).text(chinese)
        suite.expect(spoken.contains("。") && !spoken.contains(". "),
                     "a failure said by VoiceOver in Chinese has no ASCII dot between its summary and its remedy: \(spoken)")
    }
}
