// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The Meetings window: the list of the recorded meetings beside the one
/// selected (§4.5). One window only: asked again, it comes back to the front
/// where it was, on the meeting asked for if any. While it is open the app
/// has a Dock icon and a place in ⌘Tab, like Settings.
///
/// Main thread only.
final class ForkMeetingLibraryWindow: NSObject, NSWindowDelegate {
    static let shared = ForkMeetingLibraryWindow()

    private(set) var model: ForkMeetingLibraryModel?
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var keepsAppRegular = false

    static let defaultSize = NSSize(width: 940, height: 660)
    static let minimumSize = NSSize(width: 720, height: 440)

    var isVisible: Bool { window?.isVisible == true }

    private override init() {
        super.init()
        // A quit with a note still waiting for its half second: written
        // before the app goes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let model = self?.model else { return }
            model.stop()
            model.store.queue.sync {}
        }
    }

    /// Opens the window, or brings it forward; `folder` selects that
    /// meeting (the "Show" of the saved and recovered notices).
    func show(folder: URL? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(folder: folder) }
            return
        }
        let model = self.model ?? ForkMeetingLibraryModel()
        self.model = model
        let window = ensureWindow(model: model)
        window.title = ForkExtrasStrings.strings(L10n.shared.language).meetingsTitle
        model.start(focus: folder)
        installKeyMonitor()
        if !keepsAppRegular {
            keepsAppRegular = true
            WindowActivationPolicy.retain()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow(model: ForkMeetingLibraryModel) -> NSWindow {
        if let window { return window }
        let host = NSHostingController(rootView: ForkMeetingLibraryView(model: model))
        // AppKit owns the window's size; SwiftUI fills it.
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("fork.meetings.library")
        if window.frame.origin == .zero { window.center() }
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // The title being typed is kept, as when the field is left.
        window?.makeFirstResponder(nil)
        model?.stop()
        removeKeyMonitor()
        if keepsAppRegular {
            keepsAppRegular = false
            WindowActivationPolicy.release()
        }
    }

    // MARK: - Keys

    /// ⌘F finds; ⌘⌫ asks to move the selected meeting to the Trash, unless
    /// a text is being edited, where it erases to the start of the line.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                  let model = self.model else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard modifiers == [.command] else { return event }
            switch Int(event.keyCode) {
            case kVK_ANSI_F:
                model.focusSearch()
                return nil
            case kVK_Delete, kVK_ForwardDelete:
                if window.firstResponder is NSText { return event }
                model.askTrash(model.selectedEntry)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Root view

/// The list on the left, the meeting on the right; the empty library in
/// place of both.
struct ForkMeetingLibraryView: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    @ObservedObject private var l10n = L10n.shared

    private var language: AppLanguage { model.language ?? l10n.language }
    private var text: ForkMeetingStrings { ForkMeetingStrings.strings(language) }

    var body: some View {
        Group {
            if model.loaded && model.entries.isEmpty {
                ForkMeetingLibraryEmpty(model: model, text: text)
            } else {
                HStack(spacing: 0) {
                    ForkMeetingLibraryList(model: model, text: text, language: language)
                        .frame(width: 300)
                    Divider()
                    Group {
                        if let entry = model.selectedEntry {
                            ForkMeetingLibraryDetail(model: model, entry: entry, text: text, language: language)
                                // A new meeting gets fresh fields: a draft
                                // never follows the selection.
                                .id(entry.folderName)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: ForkMeetingLibraryWindow.minimumSize.width, minHeight: ForkMeetingLibraryWindow.minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(trashTitle, isPresented: trashBinding) {
            Button(text.actionTrash, role: .destructive) {
                if let folder = model.trashAsked { model.trash(folder) }
            }
            Button(text.cancel, role: .cancel) { model.trashAsked = nil }
        } message: {
            Text(text.confirmTrashMessage)
        }
    }

    private var trashTitle: String {
        let entry = model.entries.first { $0.folderName == model.trashAsked }
        return text.confirmTrash(entry?.displayTitle(text) ?? model.trashAsked ?? "")
    }

    private var trashBinding: Binding<Bool> {
        Binding(get: { model.trashAsked != nil }, set: { if !$0 { model.trashAsked = nil } })
    }
}

/// No meeting yet: what will appear here, and where the files will go.
private struct ForkMeetingLibraryEmpty: View {
    @ObservedObject var model: ForkMeetingLibraryModel
    let text: ForkMeetingStrings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "video")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text.emptyTitle)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(text.emptyCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(text.emptyWhere((model.root.path as NSString).abbreviatingWithTildeInPath))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
