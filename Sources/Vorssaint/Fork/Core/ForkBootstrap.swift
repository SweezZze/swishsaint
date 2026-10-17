// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import AppKit
import Combine

/// Where the official code calls into the fork. Each call is one seam line,
/// marked `// FORK(<id>)` in the official file and listed in fork/seams.txt.
enum ForkBootstrap {
    /// First thing at launch (seam `bootstrap`): the fork's settings exist
    /// before any view or service reads them.
    static func start() {
        ForkDefaults.register()
        // Once the official launch is done: the official Window Layout only
        // syncs while its feature is available, and is only told of an
        // Accessibility change while one of its own inputs is on. The
        // gestures follow both themselves.
        DispatchQueue.main.async {
            ForkGestures.sync()
            ForkDictationService.startFollowingPermissions()
            accessibilityObserver = Permissions.shared.$accessibility
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { _ in ForkGestures.sync() }
        }
    }

    private static var accessibilityObserver: AnyCancellable?

    /// At the end of every official Window Layout sync (seam `window-layout`).
    static func windowLayoutDidSync() {
        ForkGestures.sync()
        ForkDictationService.sync()
    }

    /// When the official Window Layout suspends its inputs, before
    /// Accessibility is revoked or the app quits (seam `window-layout`).
    static func windowLayoutWillSuspend() {
        ForkGestures.suspend()
        ForkDictationService.suspend()
    }
}

/// What identifies the fork, read from the app itself.
enum ForkInfo {
    /// The fork's repository. A release build carries it in its Info.plist;
    /// a local build does not, and falls back to the fork's home.
    static var repository: String {
        ForkUpdateSupport.repository(info: Bundle.main.infoDictionary) ?? "hectorpasserat2004-create/swishsaint"
    }

    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }

    static let officialRepositoryURL = URL(string: "https://github.com/vorssaint/vorssaint-utils")!
}
