// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import Foundation

enum ForkUpdateTests {
    typealias Support = ForkUpdateSupport

    static func run(_ suite: TestSuite) {
        tags(suite)
        candidates(suite)
        wiring(suite)
    }

    private static func release(tag: String = "build-1482",
                                body: String? = "- Dock fix\nSHA256: \(String(repeating: "ab", count: 32))",
                                assets: [String] = ["Vorssaint-Developer-build-1482.zip"]) -> Support.Release {
        Support.Release(tagName: tag, body: body, assets: assets.map {
            .init(name: $0, browserDownloadURL: URL(string: "https://example.com/\($0)")!, size: 10)
        })
    }

    private static func tags(_ suite: TestSuite) {
        suite.expect(Support.buildNumber(fromTag: "build-1482") == 1482
                        && Support.buildNumber(fromTag: "build-") == nil
                        && Support.buildNumber(fromTag: "v3.4.1") == nil
                        && Support.buildNumber(fromTag: "build-12a") == nil
                        && Support.buildNumber(fromTag: "build-١٢") == nil,
                     "only build-<digits> tags are test builds")
        suite.expect(Support.currentBuild(info: ["CFBundleVersion": 1480]) == 1480
                        && Support.currentBuild(info: ["CFBundleVersion": "1480"]) == 1480
                        && Support.currentBuild(info: ["CFBundleVersion": "3.4.1"]) == nil
                        && Support.currentBuild(info: [:]) == nil,
                     "the running build reads its number from CFBundleVersion, which the release sets to N")
        suite.expect(Support.repository(info: ["ForkUpdateRepository": "hectorpasserat2004-create/swishsaint"])
                        == "hectorpasserat2004-create/swishsaint"
                        && Support.repository(info: [:]) == nil
                        && Support.repository(info: ["ForkUpdateRepository": "swishsaint"]) == nil
                        && Support.repository(info: ["ForkUpdateRepository": "a/b/c"]) == nil
                        && Support.repository(info: ["ForkUpdateRepository": "a/../b"]) == nil
                        && Support.repository(info: ["ForkUpdateRepository": "a/b?x=1"]) == nil
                        && Support.repository(info: ["ForkUpdateRepository": "/b"]) == nil,
                     "the release feed is the owner/name Info.plist names, nothing else; a local build has none")
        suite.expect(Support.upstreamVersion(info: ["ForkUpstreamVersion": "3.4.1"]) == "3.4.1"
                        && Support.upstreamVersion(info: [:]) == nil,
                     "the official version the build is based on comes from Info.plist")
    }

    private static func candidates(_ suite: TestSuite) {
        let hex = String(repeating: "ab", count: 32)
        let candidate = Support.candidate(from: release())
        suite.expect(candidate?.build == 1482 && candidate?.sha256 == hex
                        && candidate?.notes == "- Dock fix"
                        && candidate?.zipURL.lastPathComponent == "Vorssaint-Developer-build-1482.zip",
                     "a release gives its build, its zip, its checksum and notes without the checksum")
        suite.expect(Support.candidate(from: release(body: "- no checksum")) == nil
                        && Support.candidate(from: release(body: "SHA256: 1234")) == nil
                        && Support.candidate(from: release(body: nil)) == nil,
                     "no installable build without a full SHA-256")
        suite.expect(Support.candidate(from: release(assets: [])) == nil
                        && Support.candidate(from: release(assets: ["a.zip", "b.zip"])) == nil
                        && Support.candidate(from: release(assets: ["notes.txt"])) == nil
                        && Support.candidate(from: release(tag: "v1.0")) == nil,
                     "no installable build without exactly one zip and a build tag")
        if let candidate {
            suite.expect(Support.isNewer(candidate, than: 1480) && !Support.isNewer(candidate, than: 1482)
                            && !Support.isNewer(candidate, than: 1500) && Support.isNewer(candidate, than: nil),
                         "only a strictly newer build is offered")
        }
        suite.expect(Support.latestReleaseURL(repository: "hectorpasserat2004-create/swishsaint").absoluteString
                        == "https://api.github.com/repos/hectorpasserat2004-create/swishsaint/releases/latest"
                        && Support.releasesPageURL(repository: "hectorpasserat2004-create/swishsaint").absoluteString
                        == "https://github.com/hectorpasserat2004-create/swishsaint/releases/latest",
                     "updates come from the fork's own releases, never the official ones")
    }

    private static func source(_ path: String) -> String {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func wiring(_ suite: TestSuite) {
        let service = source("Sources/Vorssaint/Fork/Update/ForkUpdateService.swift")
        let prepare = service.components(separatedBy: "private static func prepare(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let checksum = prepare.range(of: "UpdateServiceSupport.sha256Matches(data, expectedHex: candidate.sha256)")
        let identity = prepare.range(of: "Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier")
        let signature = prepare.range(of: "guard isSignedLikeThisApp(newApp) else { return .failure(.signature) }")
        suite.expect(checksum != nil && identity != nil && signature != nil
                        && checksum!.lowerBound < identity!.lowerBound
                        && identity!.lowerBound < signature!.lowerBound,
                     "a download installs only after its checksum, its identifier and its signature are checked")
        let signed = service.components(separatedBy: "static func isSignedLikeThisApp(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(signed.contains("SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement)")
                        && signed.contains("SecStaticCodeCheckValidity(downloaded, flags, requirement) == errSecSuccess")
                        && signed.contains("kSecCSCheckNestedCode") && signed.contains("kSecCSStrictValidate"),
                     "the download must satisfy the running app's own designated requirement, nested code included")
        let swap = service.components(separatedBy: "private func replaceRunningApp(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(swap.contains("while kill -0 \"$PID\"")
                        && swap.contains("if /bin/mv \"$DEST\" \"$BACKUP\" && /bin/mv \"$NEW\" \"$DEST\"; then")
                        && swap.contains("/bin/mv \"$BACKUP\" \"$DEST\"")
                        && swap.contains("Self.quoted(destination.path)") && swap.contains("NSApp.terminate(nil)"),
                     "the old app is swapped only once this one has quit, and put back if the move fails")
        suite.expect(service.contains("guard repository != nil, timer == nil else { return }")
                        && service.contains("func install(_ candidate: ForkUpdateSupport.Candidate) {\n        guard repository != nil else { return }"),
                     "a build without a release feed never checks or installs anything")
        let official = source("Sources/Vorssaint/Services/Update/UpdateService.swift")
        suite.expect(official.contains("    func startAutomaticChecks() {\n        if ForkUpdate.takesOver() { return } // FORK(update)\n")
                        && official.contains("    func check(manual: Bool) {\n        if ForkUpdate.takesOver(manual: manual) { return } // FORK(update)\n"),
                     "the official updater hands over before doing anything, so it never offers Vorssaint's releases")
        let takeOver = service.components(separatedBy: "static func takesOver(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        suite.expect(takeOver.contains("return true") && !takeOver.contains("return false"),
                     "the fork always takes over from the official updater")
        let delegate = source("Sources/Vorssaint/App/AppDelegate.swift")
        suite.expect(delegate.contains("    func applicationDidFinishLaunching(_ notification: Notification) {\n        ForkBootstrap.start() // FORK(bootstrap)\n"),
                     "the fork registers its settings first thing at launch")
    }
}
