// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// The dictionary of corrections, with every case bran's VocabularyFixer
/// learned the hard way.
enum ForkDictationReplacementsTests {
    static func run(_ suite: TestSuite) {
        let apply = ForkDictationReplacements.apply

        suite.expect(apply(rules(("castral", "Castral")), "j'ai vu castral hier") == "j'ai vu Castral hier",
                     "a proper noun gets its capital")
        suite.expect(apply(rules(("castral", "Castral")), "castral") == "Castral"
                        && apply(rules(("castral", "Castral")), "chez castral") == "chez Castral"
                        && apply(rules(("castral", "Castral")), "castral arrive") == "Castral arrive",
                     "at the start and the end of the text")
        suite.expect(apply(rules(("sdr", "SDR")), "sdrastvouitie") == "sdrastvouitie"
                        && apply(rules(("sdr", "SDR")), "le sdr appelle") == "le SDR appelle",
                     "never inside a word")
        suite.expect(apply(rules(("crm", "CRM")), "dans le crm, hier.") == "dans le CRM, hier."
                        && apply(rules(("crm", "CRM")), "(crm)") == "(CRM)",
                     "punctuation is a word boundary")
        suite.expect(apply(rules(("crm", "CRM")), "crm puis crm et crm") == "CRM puis CRM et CRM",
                     "every occurrence, not only the first")
        suite.expect(apply(rules(("meet", "Meet"), ("google meet", "Google Meet")), "sur google meet")
                        == "sur Google Meet",
                     "the longest rule wins")
        suite.expect(apply(rules(("resume", "compte-rendu")), "envoie le résumé") == "envoie le compte-rendu",
                     "accents do not miss a match")
        suite.expect(apply(rules(("opa ventures", "Opah Ventures")), "chez opa ventures") == "chez Opah Ventures",
                     "rules of several words")
        suite.expect(apply([], "rien ne change") == "rien ne change", "no rule changes nothing")
        suite.expect(apply([.init(heard: "castral", written: "   "), .init(heard: "  ", written: "Castral")],
                           "castral") == "castral",
                     "an incomplete rule is skipped rather than erasing text")
        suite.expect(apply(rules(("a", "b")), "") == "", "an empty text stays empty")
        suite.expect(apply(rules(("", "x")), "abc") == "abc", "an empty needle never loops")

        let measured = "On se voit sur Google, mais est à 14h, et je mettrai le compte rendu dans le CRM juste après."
        let starter = rules(("google, mais est", "Google Meet"), ("google mais est", "Google Meet"),
                            ("google meet", "Google Meet"), ("crm", "CRM"))
        let fixed = apply(starter, measured)
        suite.expect(fixed.contains("Google Meet") && !fixed.contains("mais est") && fixed.contains("CRM"),
                     "the mistake measured on « Google Meet » is caught")

        // What one rule writes, another never reads.
        let meet = rules(("meet", "réunion"), ("google meet", "Google Meet"))
        suite.expect(apply(meet, "sur google meet") == "sur Google Meet" && apply(meet, "sur meet") == "sur réunion",
                     "a short rule does not eat what a long one wrote, and still works alone")
        let chain = rules(("sdr", "commercial"), ("commercial", "vendeur"))
        suite.expect(apply(chain, "le sdr appelle") == "le commercial appelle"
                        && apply(chain, "le commercial appelle") == "le vendeur appelle",
                     "a replacement that makes another rule's word is not read again")
        let poule = rules(("poule", "pull"), ("pull", "sweat"))
        suite.expect(apply(poule, "la poule et le pull") == "la pull et le sweat",
                     "poule gives pull, not sweat")
        suite.expect(apply(rules(("crm", "crm")), "le crm") == "le crm"
                        && apply(rules(("crm", "crm crm")), "le crm") == "le crm crm",
                     "a rule writing what it hears does not loop")
        suite.expect(apply(rules((".*", "tout")), "a .* b") == "a tout b"
                        && apply(rules((".*", "tout")), "abc") == "abc"
                        && apply(rules(("c++", "C++")), "du c++ partout") == "du C++ partout"
                        && apply(rules(("java", "$1\\n")), "du java") == "du $1\\n",
                     "metacharacters are text, not patterns")
        suite.expect(apply(rules(("crm", "CRM"), ("crm", "Castral")), "le crm") == "le CRM",
                     "between two rules of the same length, the first declared wins")
        let nfd = "envoie le résumé demain".decomposedStringWithCanonicalMapping
        suite.expect(apply(rules(("resume", "compte-rendu")), nfd) == "envoie le compte-rendu demain",
                     "decomposed accents are corrected like composed ones")
        suite.expect(apply(rules(("poule rique ouest", "pull request"), ("poule", "pull")),
                           "Ouvre la Poule rique ouest et la poule.") == "Ouvre la pull request et la pull.",
                     "whatever the case")
        suite.expect(apply(rules(("poule", "pull")), "Les poulets et la poulette") == "Les poulets et la poulette",
                     "only whole words")
    }

    private static func rules(_ pairs: (String, String)...) -> [ForkDictationSupport.Replacement] {
        pairs.map { ForkDictationSupport.Replacement(heard: $0.0, written: $0.1) }
    }
}
