#!/bin/bash
# Tests du fork : Tests/Fork/*.swift, compilés avec le harnais officiel (Tests/TestSuite.swift).
#
#   fork/test.sh                      toutes les suites du fork
#   fork/test.sh --suite=<nom>        une seule (fork/test.sh --list pour les voir)
#
# Sans option, lance aussi fork/release-notes-test.sh (notes de release, hors réseau).
#
# Les tests officiels ne compilent qu'une liste de fichiers écrite dans build.sh, qu'on ne
# modifie jamais : ce script relit cette liste telle quelle et y ajoute les fichiers « purs »
# du fork (sans service ni interface), listés ci-dessous. Lancé aussi par la synchro
# automatique avec l'officiel (.github/workflows/fork-sync.yml).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$FORK_ROOT"

FORK_SOURCES=(
    Sources/Vorssaint/Fork/Core/ForkBackup.swift
    Sources/Vorssaint/Fork/Core/ForkDefaults.swift
    Sources/Vorssaint/Fork/Core/ForkExtrasStrings.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationEngineChoice.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationParakeetOffer.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationFailure.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationMachine.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationPresentation.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationReplacements.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationShortcut.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationStrings.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationSupport.swift
    Sources/Vorssaint/Fork/Dictation/ForkDictationWaveform.swift
    Sources/Vorssaint/Fork/Dictation/History/ForkDictationRecord.swift
    Sources/Vorssaint/Fork/Dictation/History/ForkDictationHistorySearch.swift
    Sources/Vorssaint/Fork/Dictation/History/ForkNotchDictationsSupport.swift
    Sources/Vorssaint/Fork/Dictation/Parakeet/ForkParakeetDecoding.swift
    Sources/Vorssaint/Fork/Dictation/Parakeet/ForkParakeetLong.swift
    Sources/Vorssaint/Fork/Dictation/Parakeet/ForkParakeetManifest.swift
    Sources/Vorssaint/Fork/Dictation/Parakeet/ForkParakeetVocabulary.swift
    Sources/Vorssaint/Fork/Gestures/ForkLayoutComplement.swift
    Sources/Vorssaint/Fork/Gestures/ForkLinkedResizeSupport.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadDiagnosticsSupport.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureGroups.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureMachine.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureStrings.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadGestureSupport.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadModifierKeys.swift
    Sources/Vorssaint/Fork/Gestures/ForkTrackpadTuning.swift
    Sources/Vorssaint/Fork/Meetings/Export/ForkDropFolderExporter.swift
    Sources/Vorssaint/Fork/Meetings/Export/ForkImmichStrings.swift
    Sources/Vorssaint/Fork/Meetings/Export/ForkImmichSupport.swift
    Sources/Vorssaint/Fork/Meetings/Export/ForkMeetingExporter.swift
    Sources/Vorssaint/Fork/Meetings/Export/ForkMeetingOriginPolicy.swift
    Sources/Vorssaint/Fork/Meetings/Export/ForkWebhookSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingActivity.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingAppTitleRules.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingAppsSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingAudioOnly.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingCaptureSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingDetectionSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingFailure.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingFinalPass.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingFolder.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingIslandSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingLibrary.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingLibraryRules.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingLibrarySupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingLiveSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingMachine.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingMarkerSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingNotifications.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingOfferSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingPlaybackSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingPreferences.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingProviders.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingQuality.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingRecoveryPlan.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingResolver.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingServiceSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingSidecar.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingSignals.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingStrings.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingSummarySupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingSystemSupport.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingTitleRules.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingTranscriptFormat.swift
    Sources/Vorssaint/Fork/Meetings/ForkMeetingTranscriptSupport.swift
    Sources/Vorssaint/Fork/Update/ForkUpdateNotes.swift
    Sources/Vorssaint/Fork/Update/ForkUpdateStrings.swift
    Sources/Vorssaint/Fork/Update/ForkUpdateSupport.swift
)

# La liste officielle : les lignes Sources/… du bloc TEST_SOURCES=( … ) de build.sh.
OFFICIAL_SOURCES=()
while IFS= read -r line; do
    # build.sh écrit certains fichiers en motif (Strings+*.swift) : on les développe.
    # shellcheck disable=SC2206
    OFFICIAL_SOURCES+=($line)
done < <(sed -n '/^    TEST_SOURCES=(/,/^    )/p' build.sh | sed -n 's/^ *\(Sources\/[^ ]*\.swift\) *$/\1/p')
[ "${#OFFICIAL_SOURCES[@]}" -gt 0 ] || die "Liste des sources de test introuvable dans build.sh."

PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
SDK_COMPAT_FLAGS=()
if [ -n "${DEVELOPER_DIR:-}" ] || [ ! -d "$PINNED_SDK" ]; then
    SDK="$(xcrun --show-sdk-path)"
else
    SDK="$PINNED_SDK"
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# Les sources officielles de cette liste s'appuient sur les doublures des tests officiels :
# on compile donc aussi Tests/*.swift et les sources générées, sauf le point d'entrée officiel
# (MetricsTests.swift), remplacé par celui du fork (Tests/Fork/ForkTestsMain.swift).
python3 Tests/generate_sources.py
OFFICIAL_TESTS=()
for file in Tests/*.swift build/generated-tests/*.swift; do
    [ "$file" = Tests/MetricsTests.swift ] || OFFICIAL_TESTS+=("$file")
done
OBJECTS=build/objects/fork-tests
mkdir -p "$OBJECTS"
ALL_SOURCES=("${OFFICIAL_TESTS[@]}" Tests/Fork/*.swift "${OFFICIAL_SOURCES[@]}" "${FORK_SOURCES[@]}")
# Les objets vont dans build/ (comme pour build.sh --test) : compilation incrémentale, et rien
# dans le dossier temporaire du système, qui peut être vidé pendant une longue compilation.
{
    printf '{\n  "": { "swift-dependencies": "%s/master.swiftdeps" }' "$OBJECTS"
    for source in "${ALL_SOURCES[@]}"; do
        artifact="${source//\//__}"
        artifact="${artifact%.swift}"
        printf ',\n  "%s": { "object": "%s/%s.o", "swift-dependencies": "%s/%s.swiftdeps" }' \
            "$source" "$OBJECTS" "$artifact" "$OBJECTS" "$artifact"
    done
    printf '\n}\n'
} > "$OBJECTS/output-file-map.json"
note "Compilation des tests du fork…"
swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" -module-name ForkTests \
    -output-file-map "$OBJECTS/output-file-map.json" \
    -target arm64-apple-macosx14.0 -sdk "$SDK" ${SDK_COMPAT_FLAGS[@]+"${SDK_COMPAT_FLAGS[@]}"} \
    -I Sources/VMStatisticsCompat \
    "${ALL_SOURCES[@]}" -o build/fork-tests
status=0
./build/fork-tests "$@" || status=$?
# Les suites UserDefaults laissent des plists vides : même ménage que build.sh.
rm -f "$HOME"/Library/Preferences/vorss.tests.fork.*.plist
# Toutes les suites demandées : aussi les notes de release (fork/release-notes.sh), hors réseau.
if [ "$#" -eq 0 ]; then
    fork/release-notes-test.sh || status=1
fi
exit $status
