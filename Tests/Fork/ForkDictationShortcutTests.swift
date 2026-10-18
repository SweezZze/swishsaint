// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import CoreGraphics
import Foundation

/// Shortcuts, engine choice, the wave, the excerpt and the failures.
enum ForkDictationShortcutTests {
    static func run(_ suite: TestSuite) {
        storage(suite)
        problems(suite)
        table(suite)
        engine(suite)
        presentation(suite)
        failures(suite)
    }

    private static let command = Int(GlobalShortcutModifiers.command.rawValue)
    private static let commandShift = Int(GlobalShortcutModifiers([.command, .shift]).rawValue)

    private static func storage(_ suite: TestSuite) {
        let legacy = ForkDictationShortcuts.decode(stored: "", legacyTrigger: "rightOption")
        suite.expect(legacy.count == 1 && legacy[0].key == .modifier(.rightOption) && legacy[0].mode == .hybrid
                        && legacy[0].action == .paste && legacy[0].id == ForkDictationShortcut.defaultID,
                     "nothing stored yet: the key chosen before becomes the first shortcut")
        suite.expect(ForkDictationShortcuts.decode(stored: "", legacyTrigger: "nonsense") == [.default]
                        && ForkDictationShortcuts.decode(stored: "{broken", legacyTrigger: "") == [.default],
                     "an unknown key or unreadable list falls back to right Command")
        suite.expect(ForkDictationShortcuts.decode(stored: "[]", legacyTrigger: "fn")[0].key == .modifier(.fn),
                     "never zero shortcuts")

        let shortcuts = [
            ForkDictationShortcut.default,
            ForkDictationShortcut(key: .combo(keyCode: 2, modifiers: commandShift), mode: .toggle, action: .copy,
                                  language: "en-US"),
            ForkDictationShortcut(key: .modifier(.leftOption), mode: .hold, action: .pasteLast),
        ]
        let stored = ForkDictationShortcuts.encode(shortcuts)
        suite.expect(ForkDictationShortcuts.decode(stored: stored, legacyTrigger: "fn") == shortcuts,
                     "shortcuts come back as stored, language and all")
        let many = (0..<9).map { _ in ForkDictationShortcut(key: .modifier(.fn)) }
        suite.expect(ForkDictationShortcuts.decode(stored: ForkDictationShortcuts.encode(many), legacyTrigger: "").count
                        == ForkDictationShortcut.maximumCount,
                     "at most six shortcuts are kept")

        let defaults = UserDefaults(suiteName: "vorss.tests.fork.dictation-shortcuts")!
        defaults.removePersistentDomain(forName: "vorss.tests.fork.dictation-shortcuts")
        defaults.set("leftControl", forKey: ForkDefaultsKey.dictationTrigger)
        suite.expect(ForkDictationShortcuts.load(defaults)[0].key == .modifier(.leftControl),
                     "loading migrates the single key of earlier versions")
        ForkDictationShortcuts.save(shortcuts, defaults)
        suite.expect(ForkDictationShortcuts.load(defaults) == shortcuts, "saving then loading keeps everything")
        defaults.removePersistentDomain(forName: "vorss.tests.fork.dictation-shortcuts")

        suite.expect(ForkDictationShortcut.default.armingDelay == 0.15
                        && ForkDictationShortcut(key: .modifier(.fn)).armingDelay == 0
                        && ForkDictationShortcut(key: .combo(keyCode: 2, modifiers: command)).armingDelay == 0,
                     "only a modifier other than fn waits before opening the microphone")
    }

    private static func problems(_ suite: TestSuite) {
        let first = ForkDictationShortcut.default
        let twin = ForkDictationShortcut(key: .modifier(.fallback), action: .copy)
        let letter = ForkDictationShortcut(key: .combo(keyCode: 0, modifiers: 0))
        let shiftLetter = ForkDictationShortcut(key: .combo(keyCode: 0, modifiers: Int(GlobalShortcutModifiers.shift.rawValue)))
        let escape = ForkDictationShortcut(key: .combo(keyCode: 53, modifiers: command))
        let space = ForkDictationShortcut(key: .combo(keyCode: 49, modifiers: 0))
        let commandSpace = ForkDictationShortcut(key: .combo(keyCode: 49, modifiers: command))
        let f5 = ForkDictationShortcut(key: .combo(keyCode: 96, modifiers: 0))
        let free: (GlobalShortcut) -> Bool = { _ in false }
        let problems = ForkDictationShortcuts.problems([first, twin, letter, shiftLetter, escape, space, commandSpace, f5],
                                                       isTaken: free)
        suite.expect(problems[first.id] == nil && problems[twin.id] == .duplicate,
                     "the second shortcut on the same key is the duplicate")
        suite.expect(problems[letter.id] == .needsModifier && problems[shiftLetter.id] == .needsModifier,
                     "a letter alone, or with Shift, would be typing")
        suite.expect(problems[escape.id] == .reservedKey && problems[space.id] == .reservedKey,
                     "Escape always, Space alone, are reserved")
        suite.expect(problems[commandSpace.id] == nil && problems[f5.id] == nil,
                     "⌘Space and a bare function key are fine")
        let table = ForkDictationShortcutTable([first, twin, letter], isTaken: free)
        suite.expect(table.shortcut(first.id) != nil && table.shortcut(twin.id) == nil && table.shortcut(letter.id) == nil,
                     "only working shortcuts reach the tap")

        let taken = ForkDictationShortcut(key: .combo(keyCode: 2, modifiers: Int(GlobalShortcutModifiers([.control, .option]).rawValue)))
        let takenProblems = ForkDictationShortcuts.problems([first, taken], isTaken: { $0.keyCode == 2 })
        suite.expect(takenProblems[taken.id] == .conflict && takenProblems[first.id] == nil,
                     "a combination macOS or Vorssaint answers to is a conflict")
        suite.expect(ForkDictationShortcutTable([taken], isTaken: { _ in true }).isEmpty,
                     "a conflicting combination never reaches the tap")
        let menu = ForkDictationShortcuts.isAppMenuShortcut
        suite.expect(menu(GlobalShortcut(keyCode: 8, modifiers: .command))
                        && menu(GlobalShortcut(keyCode: 6, modifiers: [.command, .shift]))
                        && menu(GlobalShortcut(keyCode: 48, modifiers: .command)),
                     "⌘C, ⇧⌘Z and ⌘Tab belong to the apps")
        suite.expect(!menu(GlobalShortcut(keyCode: 2, modifiers: [.control, .option]))
                        && !menu(GlobalShortcut(keyCode: 2, modifiers: [.command, .option]))
                        && !menu(GlobalShortcut(keyCode: 96, modifiers: .command)),
                     "⌃⌥D, ⌥⌘D and ⌘F5 are free for the dictation")
    }

    private static func table(_ suite: TestSuite) {
        let right = ForkDictationShortcut.default
        let left = ForkDictationShortcut(key: .modifier(.leftCommand))
        let fn = ForkDictationShortcut(key: .modifier(.fn))
        let combo = ForkDictationShortcut(key: .combo(keyCode: 2, modifiers: commandShift))
        let table = ForkDictationShortcutTable([right, left, fn, combo], isTaken: { _ in false })

        suite.expect(table.modifierChange(keyCode: 54, flags: 0x100010).map { $0.id == right.id && $0.isDown } == true
                        && table.modifierChange(keyCode: 54, flags: 0x100).map { $0.id == right.id && !$0.isDown } == true,
                     "right Command presses and releases its own shortcut")
        suite.expect(table.modifierChange(keyCode: 55, flags: 0x100008)?.id == left.id,
                     "left Command is its own shortcut")
        suite.expect(table.modifierChange(keyCode: 63, flags: 0x800000).map { $0.id == fn.id && $0.isDown } == true,
                     "fn reads from the secondary function flag")
        suite.expect(table.modifierChange(keyCode: 58, flags: 0x80020) == nil, "a modifier without a shortcut is ignored")

        let cmdShift = CGEventFlags([.maskCommand, .maskShift]).rawValue
        suite.expect(table.combo(keyCode: 2, flags: cmdShift) == combo.id, "the combination with its exact modifiers")
        suite.expect(table.combo(keyCode: 2, flags: cmdShift | CGEventFlags.maskAlphaShift.rawValue
                                    | CGEventFlags.maskSecondaryFn.rawValue | 0x10 | 0x02) == combo.id,
                     "Caps Lock, fn and the device bits never count")
        suite.expect(table.combo(keyCode: 2, flags: CGEventFlags.maskCommand.rawValue) == nil
                        && table.combo(keyCode: 2, flags: cmdShift | CGEventFlags.maskAlternate.rawValue) == nil,
                     "a modifier missing or added is another shortcut")
        suite.expect(table.combo(keyCode: 3, flags: cmdShift) == nil, "another key is not the combination")
        suite.expect(table.keyCodes == [54, 55, 63, 2], "the tap only looks at the shortcuts' keys")
        suite.expect(ForkDictationShortcutTable([]).isEmpty, "no shortcut, an empty table")
    }

    private static func engine(_ suite: TestSuite) {
        let resolve = ForkDictationEngineChoice.resolve
        suite.expect(resolve(.auto, true, "fr-FR") == .success(.parakeet)
                        && resolve(.auto, true, "") == .success(.parakeet)
                        && resolve(.auto, true, "uk") == .success(.parakeet),
                     "automatic: Parakeet when installed and the language is one of its 25")
        suite.expect(resolve(.auto, true, "ja-JP") == .success(.apple)
                        && resolve(.auto, true, "zh-Hans") == .success(.apple)
                        && resolve(.auto, true, "tr") == .success(.apple),
                     "automatic: Apple for Japanese, Chinese, Turkish")
        suite.expect(resolve(.auto, false, "fr-FR") == .success(.apple),
                     "automatic: Apple while Parakeet is not installed")
        suite.expect(resolve(.parakeet, false, "fr") == .failure(.modelMissing)
                        && resolve(.parakeet, true, "fr") == .success(.parakeet),
                     "Parakeet chosen: missing model is a failure, never a silent download")
        suite.expect(resolve(.apple, true, "fr") == .success(.apple), "Apple chosen: always Apple")
        suite.expect(ForkDictationEngineChoice.parakeetLanguages.count == 25, "Parakeet knows 25 languages")

        let choice = ForkDictationEngineChoice.choiceLanguage
        suite.expect(choice("", ["ja-JP", "en-US"]) == "ja-JP" && choice("de", ["ja-JP"]) == "de" && choice("", []) == "",
                     "no language chosen: the person's own picks the engine")
        suite.expect(resolve(.auto, true, choice("", ["ja-JP"])) == .success(.apple)
                        && resolve(.auto, true, choice("", ["fr-FR"])) == .success(.parakeet),
                     "automatic on a Japanese Mac goes to Apple, on a French one to Parakeet")
    }

    private static func presentation(_ suite: TestSuite) {
        suite.expect(ForkDictationPresentation.excerpt("  Bonjour\n\nà   tous  ") == "Bonjour à tous",
                     "the excerpt is one line")
        let long = ForkDictationPresentation.excerpt(String(repeating: "mot ", count: 30))
        suite.expect(long.count <= ForkDictationPresentation.excerptLength && long.hasSuffix("…"),
                     "a long excerpt is cut with an ellipsis")
        suite.expect(ForkDictationPresentation.pasted(excerpt: "").holdDuration == 1.6
                        && ForkDictationPresentation.cancelled.holdDuration == 0.9
                        && ForkDictationPresentation.nothingHeard(afterSilence: false).holdDuration == 1.4
                        && ForkDictationPresentation.keptInClipboard.holdDuration == 4
                        && ForkDictationPresentation.transcribing.holdDuration == nil,
                     "each state stays the time the plan gives it")

        var wave = ForkDictationWaveform()
        let quiet = wave.samples(at: 0)
        suite.expect(quiet.count == ForkDictationWaveform.points && quiet.allSatisfy { $0 >= 0 && $0 <= 1 },
                     "the wave has its points, between 0 and 1")
        suite.expect(quiet[ForkDictationWaveform.points / 2] > 0.01,
                     "a silence still breathes, it never looks frozen")
        suite.expect(quiet.first == 0 && quiet.last.map { $0 < 0.0001 } == true, "the ends taper to nothing")
        suite.expect(wave.samples(at: 0) == wave.samples(at: 0) && wave.samples(at: 0) != wave.samples(at: 1),
                     "the floor moves with time, and holds still at time 0")
        for _ in 0..<ForkDictationWaveform.points { wave.push(5) }
        wave.push(.nan)
        let loud = wave.samples(at: 0)
        suite.expect(loud.allSatisfy { $0 >= 0 && $0 <= 1 } && loud[ForkDictationWaveform.points / 2] > 0.9,
                     "loud levels are bounded, and odd ones ignored")
    }

    private static func failures(_ suite: TestSuite) {
        let strings = AppLanguage.allCases.map(ForkDictationStrings.strings)
        for s in strings {
            for failure in ForkDictationFailure.all {
                suite.expect(!failure.summary(s).isEmpty && !failure.remedy(s).isEmpty,
                             "every failure explains itself, in every language")
            }
            suite.expect(ForkDictationFailure.secureInput(app: "Terminal").summary(s).contains("Terminal"),
                         "secure input names the app holding it")
        }
        let en = ForkDictationStrings.strings(.enUS)
        suite.expect(ForkDictationFailure.microphoneSilent.summary(en) != ForkDictationFailure.microphoneDenied.summary(en),
                     "a silent microphone is not a denied one")
        suite.expect(ForkDictationFailure.modelMissing.action == .downloadModel
                        && ForkDictationFailure.microphoneMutedInVorssaint.action == .unmuteMicrophone
                        && ForkDictationFailure.secureInput(app: nil).action == nil,
                     "each failure offers the right button")
    }
}
