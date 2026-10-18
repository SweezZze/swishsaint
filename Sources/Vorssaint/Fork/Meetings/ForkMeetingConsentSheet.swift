// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import AppKit
import SwiftUI

/// The sheet shown once per Mac before the first recording: the permissions,
/// a one-sentence reminder of the law with the box the person ticks to go
/// on, what to film, and the announcement to paste in the meeting's chat.
/// Confirmed, it is not asked again on this Mac; cancelled, the feature
/// turns back off.
///
/// A sheet on the window in front when there is one (the Settings, where
/// the switch was turned on, from the Meetings page or from Extras), else a
/// window of its own (the shortcut pressed in another app).
final class ForkMeetingConsentSheet: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private weak var parent: NSWindow?
    /// Called once, with whether the person confirmed. Nil once answered.
    private var answer: ((Bool) -> Void)?

    init(answer: @escaping (Bool) -> Void) {
        self.answer = answer
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                        styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        let host = NSHostingController(rootView: ForkMeetingConsentView(
            confirm: { [weak self] in self?.finish(true) },
            cancel: { [weak self] in self?.finish(false) }))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.title = ForkMeetingStrings.current.consentTitle
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, window.attachedSheet == nil,
           !(window is NSPanel), window.styleMask.contains(.titled) {
            parent = window
            window.beginSheet(panel)
        } else {
            panel.level = .floating
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Asked again while it is open: shown, not opened twice.
    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        (parent ?? panel).makeKeyAndOrderFront(nil)
    }

    /// Closes it without an answer: the feature was turned off elsewhere.
    func dismiss() {
        answer = nil
        close()
    }

    private func finish(_ confirmed: Bool) {
        let answer = self.answer
        self.answer = nil
        close()
        answer?(confirmed)
    }

    private func close() {
        if let parent, panel.sheetParent === parent {
            parent.endSheet(panel)
        }
        panel.orderOut(nil)
    }

    /// The window's own close button, when it stands alone, cancels.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(false)
        return false
    }
}

private struct ForkMeetingConsentView: View {
    let confirm: () -> Void
    let cancel: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(ForkDefaultsKey.meetingsCaptureTarget)
    private var target = ForkMeetingCaptureTarget.fallback.rawValue
    @AppStorage(ForkDefaultsKey.meetingsAnnouncement) private var announcement = ""
    @State private var pledged = false
    @State private var copied = false

    private var text: ForkMeetingStrings { ForkMeetingStrings.strings(l10n.language) }
    private var announcementText: String { ForkMeetingAnnouncementText.text(stored: announcement, strings: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.consentTitle)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(text.consentIntro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    PermissionRow(kind: .screenRecording)
                    PermissionRow(kind: .microphone)
                    ForkMeetingSystemAudioRow(text: text)
                }
                .padding(4)
            } label: {
                Text(text.permissionsTitle)
            }

            GroupBox {
                // The box already says what is chosen.
                ForkMeetingPicturePicker(text: text, target: $target)
                    .labelsHidden()
                    .padding(4)
            } label: {
                Text(text.pictureTitle)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(announcementText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer()
                        Button(copied ? text.announcementCopied : text.copyAnnouncement, action: copy)
                    }
                }
                .padding(4)
            } label: {
                Text(text.consentAnnouncementTitle)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(text.consentLegal)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(text.consentPledge, isOn: $pledged)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button(text.cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(text.consentConfirm, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pledged)
                    .accessibilityHint(pledged ? "" : text.consentPledgeNeeded)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(announcementText, forType: .string)
        copied = true
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text.voiceAnnouncementCopied,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
