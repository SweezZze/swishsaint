// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Sweeze

import Foundation

enum ForkDictationTests {
    static func run(_ suite: TestSuite) {
        gesture(suite)
        trigger(suite)
        language(suite)
        text(suite)
    }

    private static func gesture(_ suite: TestSuite) {
        var held = ForkDictationGesture()
        suite.expect(held.triggerDown(at: 10) == .start && held.isListening,
                     "pressing the key starts listening right away")
        suite.expect(held.triggerUp(at: 11.2) == .finish && held.state == .idle,
                     "releasing a held key writes what was said")

        var tapped = ForkDictationGesture()
        _ = tapped.triggerDown(at: 10)
        suite.expect(tapped.triggerUp(at: 10.1) == .none && tapped.state == .handsFree,
                     "a short tap keeps listening, hands-free")
        suite.expect(tapped.otherKey() == .none && tapped.isListening,
                     "typing while hands-free does not stop the dictation")
        suite.expect(tapped.triggerDown(at: 14) == .finish && !tapped.isListening,
                     "the next press ends a hands-free dictation")
        suite.expect(tapped.triggerUp(at: 14.1) == .none && tapped.state == .idle,
                     "and its release starts nothing new")

        var shortcut = ForkDictationGesture()
        _ = shortcut.triggerDown(at: 10)
        suite.expect(shortcut.otherKey() == .cancel && shortcut.triggerUp(at: 10.5) == .none
                        && shortcut.state == .idle,
                     "the key held with another key is a shortcut: nothing is written")

        var escaped = ForkDictationGesture()
        _ = escaped.triggerDown(at: 10)
        _ = escaped.triggerUp(at: 10.1)
        suite.expect(escaped.escape() == .cancel && escaped.state == .idle,
                     "Escape gives up a hands-free dictation")
        suite.expect(escaped.escape() == .none && escaped.triggerUp(at: 12) == .none,
                     "Escape and a stray release do nothing when idle")

        var ended = ForkDictationGesture()
        _ = ended.triggerDown(at: 10)
        ended.end(triggerHeld: true)
        suite.expect(ended.triggerUp(at: 20) == .none && ended.state == .idle,
                     "after a dictation that ended on its own, the release of the key is not a new press")
    }

    private static func trigger(_ suite: TestSuite) {
        let command = ForkDictationTrigger.rightCommand
        suite.expect(command.isDown(keyCode: 54, flags: 0x100010) == true
                        && command.isDown(keyCode: 54, flags: 0x100) == false,
                     "right Command reads down and up from its own device bit")
        suite.expect(command.isDown(keyCode: 55, flags: 0x100008) == nil,
                     "left Command is another key")
        suite.expect(ForkDictationTrigger.fn.isDown(keyCode: 63, flags: 0x800000) == true
                        && ForkDictationTrigger.fn.isDown(keyCode: 63, flags: 0) == false,
                     "fn reads from the secondary function flag")
        suite.expect(Set(ForkDictationTrigger.allCases.map(\.keyCode)).count == ForkDictationTrigger.allCases.count,
                     "each trigger is its own key")
        suite.expect(ForkDefaults.registered[ForkDefaultsKey.dictationTrigger] as? String
                        == ForkDictationTrigger.fallback.rawValue,
                     "the default key is one of the choices")
    }

    private static func language(_ suite: TestSuite) {
        let supported = ["en_US", "en-GB", "fr-FR", "fr-CA", "de-DE"]
        suite.expect(ForkDictationSupport.localeIdentifier(chosen: "fr-CA", supported: supported,
                                                           preferred: ["en-US"]) == "fr-CA",
                     "the language chosen wins")
        suite.expect(ForkDictationSupport.localeIdentifier(chosen: "", supported: supported,
                                                           preferred: ["fr-FR", "en-US"]) == "fr-FR",
                     "automatic follows the person's first language")
        suite.expect(ForkDictationSupport.localeIdentifier(chosen: "", supported: supported,
                                                           preferred: ["de", "en-US"]) == "de-DE",
                     "a language without region finds its regional recognizer")
        suite.expect(ForkDictationSupport.localeIdentifier(chosen: "xx-XX", supported: supported,
                                                           preferred: ["ja-JP"]) == "en-US",
                     "an unknown language falls back to English")
    }

    private static func text(_ suite: TestSuite) {
        suite.expect(ForkDictationSupport.insertion("  Bonjour à tous.\n") == "Bonjour à tous.",
                     "what was said is written without the surrounding blanks")
        suite.expect(ForkDictationSupport.insertion(" \n ") == nil,
                     "nothing understood writes nothing")
        suite.expect(ForkDictationSupport.level(rms: 0) == 0 && ForkDictationSupport.level(rms: 1) == 1
                        && ForkDictationSupport.level(rms: 0.01) > 0,
                     "the level stays between 0 and 1")
        let strings = AppLanguage.allCases.map(ForkDictationStrings.strings)
        suite.expect(strings.allSatisfy { $0.languageAutomatic("X").contains("X") },
                     "every language names the automatic language")
        suite.expect(Set(strings.map(\.howTo)).count == AppLanguage.allCases.count,
                     "dictation is explained in every language")
    }
}
