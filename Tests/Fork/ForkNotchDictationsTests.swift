// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Foundation

/// The Dictations tab of the island's clipboard page: where the history
/// opens, its tab, its keys, its list and its actions.
enum ForkNotchDictationsTests {
    static func run(_ suite: TestSuite) {
        routing(suite)
        keys(suite)
        listing(suite)
        actions(suite)
        island(suite)
    }

    private static func routing(_ suite: TestSuite) {
        typealias Support = ForkNotchDictationsSupport
        suite.expect(Support.route(islandEnabled: true, clipboardPageShown: true, dictationEnabled: true,
                                   acceptsInteraction: true) == .island,
                     "the history opens in the island when it shows its clipboard page")
        suite.expect(Support.route(islandEnabled: false, clipboardPageShown: true, dictationEnabled: true,
                                   acceptsInteraction: true) == .window
                        && Support.route(islandEnabled: true, clipboardPageShown: false, dictationEnabled: true,
                                         acceptsInteraction: true) == .window,
                     "without the island or its clipboard page, the window shows the history")
        suite.expect(Support.route(islandEnabled: true, clipboardPageShown: true, dictationEnabled: false,
                                   acceptsInteraction: true) == .window
                        && Support.route(islandEnabled: true, clipboardPageShown: true, dictationEnabled: true,
                                         acceptsInteraction: false) == .window,
                     "an island without the tab, or one that takes no clicks now, leaves it to the window")
        suite.expect(Support.togglesClosed(expanded: true, onClipboardPage: true, tab: .dictations, covered: false),
                     "the shortcut closes the history it shows")
        suite.expect(!Support.togglesClosed(expanded: true, onClipboardPage: true, tab: .clipboard, covered: false)
                        && !Support.togglesClosed(expanded: false, onClipboardPage: true, tab: .dictations, covered: false)
                        && !Support.togglesClosed(expanded: true, onClipboardPage: false, tab: .dictations, covered: false)
                        && !Support.togglesClosed(expanded: true, onClipboardPage: true, tab: .dictations, covered: true),
                     "anything else on screen switches to the history instead of closing")
        suite.expect(Support.tab(.dictations, expanded: false) == .clipboard
                        && Support.tab(.dictations, expanded: true) == .dictations
                        && Support.tab(.clipboard, expanded: true) == .clipboard,
                     "a closed island opens again on the clipboard, the open one keeps its tab")
        suite.expect(Support.showsClipboardPage(expanded: true, onClipboardPage: true, covered: false)
                        && !Support.showsClipboardPage(expanded: false, onClipboardPage: true, covered: false)
                        && !Support.showsClipboardPage(expanded: true, onClipboardPage: false, covered: false)
                        && !Support.showsClipboardPage(expanded: true, onClipboardPage: true, covered: true),
                     "the tab is chosen only once the island did open on its page; otherwise the window shows it")
        let inPlace = Support.clipboardRoute(tab: .dictations, toggle: true, tabInView: true, routesToIsland: true)
        suite.expect(inPlace.tab == .clipboard && inPlace.handled,
                     "the clipboard's shortcut on the Dictations tab switches to the clipboard instead of closing")
        let opening = Support.clipboardRoute(tab: .dictations, toggle: false, tabInView: true, routesToIsland: true)
        suite.expect(opening.tab == .clipboard && !opening.handled,
                     "the clipboard's menu switches the tab and still opens the page the official way")
        let covered = Support.clipboardRoute(tab: .dictations, toggle: true, tabInView: false, routesToIsland: true)
        suite.expect(covered.tab == .clipboard && !covered.handled,
                     "under Explore or a detail, the official route opens the page, now on the clipboard")
        let window = Support.clipboardRoute(tab: .dictations, toggle: true, tabInView: true, routesToIsland: false)
        let clipboard = Support.clipboardRoute(tab: .clipboard, toggle: true, tabInView: true, routesToIsland: true)
        suite.expect(window.tab == .dictations && !window.handled && clipboard.tab == .clipboard && !clipboard.handled,
                     "a clipboard opening in its own window, or already shown, is the official route's")
        suite.expect(Support.controlAvailable(dictationEnabled: true, clipboardPageShown: true)
                        && !Support.controlAvailable(dictationEnabled: false, clipboardPageShown: true)
                        && !Support.controlAvailable(dictationEnabled: true, clipboardPageShown: false),
                     "the Dictations button needs dictation and the clipboard page its tab lives on")
    }

    private static func keys(_ suite: TestSuite) {
        typealias Support = ForkNotchDictationsSupport
        suite.expect(Support.key(keyCode: 49, characters: " ", modifiers: [], composing: false, query: "") == .listen,
                     "Space listens while nothing is searched")
        suite.expect(Support.key(keyCode: 49, characters: " ", modifiers: [], composing: false, query: "bonjour") == nil,
                     "in a search, Space is a character of it")
        suite.expect(Support.key(keyCode: 49, characters: " ", modifiers: [.command], composing: false, query: "") == nil
                        && Support.key(keyCode: 49, characters: " ", modifiers: [.shift], composing: false, query: "") == nil,
                     "Space held with a modifier belongs to its own shortcut")
        suite.expect(Support.key(keyCode: 49, characters: " ", modifiers: [], composing: true, query: "") == .clipboard(.reveal),
                     "an input method composing keeps every key")
        suite.expect(Support.key(keyCode: 125, characters: "", modifiers: [], composing: false, query: "") == .clipboard(.move(backwards: false))
                        && Support.key(keyCode: 126, characters: "", modifiers: [], composing: false, query: "") == .clipboard(.move(backwards: true))
                        && Support.key(keyCode: 36, characters: "\r", modifiers: [], composing: false, query: "") == .clipboard(.paste)
                        && Support.key(keyCode: 0, characters: "a", modifiers: [], composing: false, query: "") == .clipboard(.reveal),
                     "the arrows, Return and typing work as on the clipboard page")
        suite.expect(NotchClipboardPastePress.index(keyCode: 18, commandOnly: true) == 0
                        && NotchClipboardPastePress.index(keyCode: 25, commandOnly: true) == 8,
                     "⌘1 to ⌘9 are the clipboard page's own")
        suite.expect(Support.shortcutLabel(place: 0, hasKeyboard: true) == "⌘1"
                        && Support.shortcutLabel(place: 8, hasKeyboard: true) == "⌘9"
                        && Support.shortcutLabel(place: 9, hasKeyboard: true) == nil
                        && Support.shortcutLabel(place: 0, hasKeyboard: false) == nil,
                     "the first nine cards name their shortcut while the island has the keyboard")
    }

    private static func listing(_ suite: TestSuite) {
        typealias Support = ForkNotchDictationsSupport
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        func record(_ text: String, hoursAgo: Double, pinned: Bool = false) -> ForkDictationRecord {
            ForkDictationRecord(date: noon.addingTimeInterval(-hoursAgo * 3600), duration: 2, engine: "parakeet",
                                language: nil, rawText: text, text: text, outcome: .pasted, isPinned: pinned,
                                hasAudio: true)
        }
        let a = record("Bonjour Hector", hoursAgo: 1)
        let b = record("Résumé du jour", hoursAgo: 30)
        let c = record("Note épinglée", hoursAgo: 50, pinned: true)
        let records = [b, a, c]
        suite.expect(Support.entries(records, query: "", pinnedOnly: false, calendar: calendar) == [c, a, b],
                     "pinned dictations first, then the newest")
        suite.expect(Support.entries(records, query: "", pinnedOnly: true, calendar: calendar) == [c],
                     "the pinned filter keeps the pinned ones")
        suite.expect(Support.entries(records, query: "resume", pinnedOnly: false, calendar: calendar) == [b],
                     "a search ignores accents and case")
        suite.expect(Support.entries(records, query: "jour", pinnedOnly: true, calendar: calendar).isEmpty,
                     "the filter and the search add up")
        suite.expect(Support.clearable(records) == [b.id, a.id], "clearing keeps the pinned dictations")
        suite.expect(!Support.keepsPinnedFilter(true, revealing: a) && Support.keepsPinnedFilter(true, revealing: c)
                        && !Support.keepsPinnedFilter(false, revealing: c),
                     "a dictation opened from its bubble shows even under the pinned filter")
        let failed = ForkDictationRecord(duration: 1, engine: "apple", language: nil, rawText: "", text: "",
                                         outcome: .failed, hasAudio: true)
        suite.expect(Support.isFailed(failed) && !Support.isFailed(a), "a dictation without text failed")
        suite.expect(Support.preview("  Bonjour\n\tHector  ") == "Bonjour  Hector"
                        && Support.preview("\n") == "\n"
                        && Support.preview(String(repeating: "a", count: ClipboardHistoryEditing.previewCharacters + 1))
                            .hasSuffix("…"),
                     "a card's text reads on one line, cut as the clipboard page cuts an entry")
        let failures: [ForkDictationFailure] = [
            .accessibilityMissing, .microphoneDenied, .microphoneMutedInVorssaint, .microphoneSilent, .captureFailed,
            .secureInput(app: "Terminal"), .secureInput(app: "Say \"hi\""), .secureInput(app: nil), .speechDenied,
            .speechUnavailableInBuild, .languageUnavailable, .modelMissing, .modelDamaged, .transcriptionFailed,
        ]
        suite.expect(failures.allSatisfy { Support.failure(stored: String(describing: $0)) == $0 },
                     "a failed card says the failure kept with it")
        suite.expect(Support.storableFailures.count == 12
                        && Support.storableFailures.allSatisfy { Support.failure(stored: String(describing: $0)) == $0 },
                     "every failure the history keeps is read back")
        suite.expect(Support.failure(stored: nil) == nil && Support.failure(stored: "somethingNew") == nil,
                     "an unknown failure falls back to the generic words")
        let text = ForkDictationStrings.strings(.enUS)
        suite.expect(Support.engineName("apple", text: text) == text.engineApple
                        && Support.engineName("parakeet", text: text) == text.parakeetTitle,
                     "each card names its engine")
    }

    private static func actions(_ suite: TestSuite) {
        typealias Support = ForkNotchDictationsSupport
        let both = Support.retranscription(hasAudio: true, busy: false, parakeetInstalled: true, appleUsable: true)
        suite.expect(both.parakeet && both.apple && both.any, "both engines can transcribe a kept recording again")
        suite.expect(!Support.retranscription(hasAudio: false, busy: false, parakeetInstalled: true, appleUsable: true).any,
                     "no audio left, nothing to transcribe again")
        suite.expect(!Support.retranscription(hasAudio: true, busy: true, parakeetInstalled: true, appleUsable: true).any,
                     "one transcription again at a time")
        let appleOnly = Support.retranscription(hasAudio: true, busy: false, parakeetInstalled: false, appleUsable: true)
        suite.expect(!appleOnly.parakeet && appleOnly.apple, "Parakeet not installed: only Apple is offered")
        suite.expect(!Support.retranscription(hasAudio: true, busy: false, parakeetInstalled: false, appleUsable: false).any,
                     "no engine, no transcription again")
        suite.expect(Support.copyFeedback(.copied) == .tick && Support.copyFeedback(.superseded) == .none
                        && Support.copyFeedback(.inHistoryOnly) == .beep && Support.copyFeedback(.keptInClipboard) == .beep,
                     "the tick only for a copy that reached the clipboard, the beep otherwise")
        suite.expect(Support.isPasteTarget(bundleID: "com.apple.TextEdit", ownBundleID: "fork.app", regular: true, terminated: false),
                     "the app the island opened over takes the paste")
        suite.expect(!Support.isPasteTarget(bundleID: "fork.app", ownBundleID: "fork.app", regular: true, terminated: false)
                        && !Support.isPasteTarget(bundleID: "x", ownBundleID: "fork.app", regular: false, terminated: false)
                        && !Support.isPasteTarget(bundleID: "x", ownBundleID: "fork.app", regular: true, terminated: true),
                     "never Swishsaint itself, a background app or one that quit")
    }

    private static func island(_ suite: TestSuite) {
        let saved = NotchControlItem.dictationIsAvailable
        defer { NotchControlItem.dictationIsAvailable = saved }
        NotchControlItem.dictationIsAvailable = { _ in false }
        suite.expect(!NotchControlItem.dictation.isAvailable(), "the Dictations button waits for dictation")
        NotchControlItem.dictationIsAvailable = { _ in true }
        suite.expect(NotchControlItem.dictation.isAvailable() && NotchControlItem.dictation.symbol == "waveform"
                        && NotchControlItem.dictation.setupRequirement == .page(.clipboard, feature: .clipboardHistory)
                        && NotchQuickAction.optionalActions.contains(.control(.dictation))
                        && NotchQuickAction(id: NotchQuickAction.control(.dictation).id) == .control(.dictation),
                     "the Dictations button can sit among the controls and float beside the island")
        let strings = AppLanguage.allCases.map(ForkDictationStrings.strings)
        suite.expect(strings.allSatisfy { $0.historyIslandCaption("X").contains("X") },
                     "every language says where the history opens")
        suite.expect(strings.allSatisfy { !$0.historyOff.isEmpty && !$0.historyTurnOn.isEmpty
                                            && !$0.historyClearConfirmMessage.isEmpty && !$0.historyClearUnpinned.isEmpty
                                            && $0.historyClearConfirmFormat.contains("%d") && !$0.historySettings.isEmpty
                                            && !$0.historyIslandSettings.isEmpty },
                     "the tab's words exist in every language")
        let seams = (try? String(contentsOfFile: "Sources/Vorssaint/Services/Notch/NotchSupport.swift", encoding: .utf8)) ?? ""
        suite.expect(!seams.split(separator: "\n").contains { $0.contains("FORK(") && $0.contains("Fork") },
                     "the seams in a file the official tests compile name no type of the fork")
    }
}
