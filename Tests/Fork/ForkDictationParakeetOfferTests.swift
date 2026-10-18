// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// When Parakeet is offered, copied without a question, or left alone.
enum ForkDictationParakeetOfferTests {
    static func run(_ suite: TestSuite) {
        typealias Offer = ForkDictationParakeetOffer
        func decide(_ reason: Offer.Reason, enabled: Bool = true, engine: ForkDictationEngineSetting = .auto,
                    installed: Bool = false, canClone: Bool = false, offered: Bool = false,
                    busy: Bool = false) -> Offer.Decision {
            Offer.decide(reason: reason, enabled: enabled, engine: engine, installed: installed,
                         canClone: canClone, alreadyOffered: offered, busy: busy)
        }

        suite.expect(decide(.turnedOn) == .ask, "dictation turned on without Parakeet: the person is asked")
        suite.expect(decide(.turnedOn, engine: .parakeet) == .ask, "Parakeet chosen but missing: asked too")
        suite.expect(decide(.turnedOn, canClone: true) == .installSilently,
                     "a FluidAudio copy downloads nothing: installed without a question")
        suite.expect(decide(.launch, canClone: true, offered: true) == .installSilently,
                     "a copy is made even once the question was asked")
        suite.expect(decide(.turnedOn, engine: .apple) == .none, "Apple's engine chosen: nothing is offered")
        suite.expect(decide(.turnedOn, installed: true) == .none, "already installed: nothing to do")
        suite.expect(decide(.launch, enabled: false) == .none, "dictation off: nothing at launch")
        suite.expect(decide(.launch) == .ask, "a launch with dictation on asks once")
        suite.expect(decide(.launch, offered: true) == .none, "after Later, a launch does not ask again")
        suite.expect(decide(.turnedOn, offered: true) == .ask, "turning dictation on again asks again")
        suite.expect(decide(.turnedOn, busy: true) == .none && decide(.launch, canClone: true, busy: true) == .none,
                     "nothing while a dictation or an install is under way")
    }
}
