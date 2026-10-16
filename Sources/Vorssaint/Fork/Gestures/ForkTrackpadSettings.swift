// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Hector Passerat

import SwiftUI

/// The Trackpad half of Window Layout: the title bar gestures shown rather
/// than described.
///
/// Gestures cannot be guessed: nobody tries "↓ then →" on a title bar by
/// chance. So each gesture has its drawing, which replays the movement on
/// hover, the way System Settings › Trackpad teaches its own. A card is its
/// own switch: clicking it turns that gesture on or off, read from three
/// signs that do not rest on color alone (the check, the outline, and the
/// greyed drawing of a gesture that is off).
struct ForkTrackpadSettingsSections: View {
    let text: ForkTrackpadGestureStrings
    let layoutText: WindowLayoutFeatureStrings

    @AppStorage(ForkDefaultsKey.gesturesEnabled) private var gesturesEnabled = false
    @AppStorage(ForkDefaultsKey.linkedResizeEnabled) private var linkedResizeEnabled = false
    @AppStorage(ForkDefaultsKey.disabledGestures) private var disabledStorage = ""
    @AppStorage(ForkDefaultsKey.centerSizeStep)
    private var centerSizeStep = ForkTrackpadTuning.centerSize.defaultStep
    @AppStorage(ForkDefaultsKey.swipeSensitivityStep)
    private var swipeSensitivityStep = ForkTrackpadTuning.swipeSensitivity.defaultStep
    @AppStorage(ForkDefaultsKey.pinchSensitivityStep)
    private var pinchSensitivityStep = ForkTrackpadTuning.pinchSensitivity.defaultStep
    @AppStorage(ForkDefaultsKey.stepPauseStep)
    private var stepPauseStep = ForkTrackpadTuning.stepPause.defaultStep
    @AppStorage(ForkDefaultsKey.cancelDelayStep)
    private var cancelDelayStep = ForkTrackpadTuning.cancelDelay.defaultStep
    @AppStorage(ForkDefaultsKey.cancelEnabled) private var cancelEnabled = true
    @AppStorage(ForkDefaultsKey.gridModifierKeys)
    private var gridKeysRaw = ForkTrackpadModifierKeys.gridDefault.rawValue
    @AppStorage(ForkDefaultsKey.strongerModifierKeys)
    private var strongerKeysRaw = ForkTrackpadModifierKeys.strongerDefault.rawValue
    @AppStorage(ForkDefaultsKey.titlebarBandStep)
    private var titlebarBandStep = ForkTrackpadTuning.titlebarBand.defaultStep
    @AppStorage(ForkDefaultsKey.previewEnabled) private var previewEnabled = true
    @AppStorage(ForkDefaultsKey.hapticsEnabled) private var hapticsEnabled = true
    @State private var showsAdvanced = false
    /// The groups unfolded. Only the most used one at first: thirty cards
    /// shown at once are too much to take in.
    @State private var expandedGroups: Set<ForkTrackpadGestureGroup> = [.grid4]
    @ObservedObject private var diagnostics = ForkTrackpadDiagnosticsMonitor.shared
    @State private var diagnosticsSurface = UUID()

    private static let columns = [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 10)]

    private var disabled: Set<ForkTrackpadGestureAction> {
        ForkTrackpadDisabledGestures.actions(from: disabledStorage)
    }

    private var centerScale: Double {
        ForkTrackpadTuning.centerSize.value(atStep: centerSizeStep)
    }

    private var failingDiagnostics: [ForkTrackpadDiagnosticCheck] {
        ForkTrackpadDiagnosticCheck.allCases.filter { diagnostics.results[$0] == false }
    }

    var body: some View {
        Section {
            ForkTrackpadHero(text: text, layoutText: layoutText, isOn: gesturesEnabled) {
                gesturesEnabled.toggle()
                ForkGestures.sync()
            }
        }

        if !failingDiagnostics.isEmpty {
            Section {
                ForEach(failingDiagnostics, id: \.self) { check in
                    ForkTrackpadDiagnosticRow(check: check, text: text)
                }
            } header: {
                Text(text.diagnosticsTitle)
            }
        }

        Group {
            ForEach(ForkTrackpadGestureGroup.grouped(), id: \.group) { group, entries in
                groupSection(group, entries: entries)
            }
            linkedSection
            duringSection
            advancedSection
        }
        // Off, the page stays adjustable: gestures are chosen before turning
        // them on. It simply reads as set back.
        .opacity(gesturesEnabled ? 1 : 0.62)
        .animation(.easeInOut(duration: 0.18), value: gesturesEnabled)
        // Checked regardless of `gesturesEnabled`: a system setting worth
        // fixing before gestures are even turned on in the first place.
        .onAppear { diagnostics.setObservingSurface(diagnosticsSurface, visible: true) }
        .onDisappear { diagnostics.setObservingSurface(diagnosticsSurface, visible: false) }
    }

    // MARK: Groups

    private func groupSection(_ group: ForkTrackpadGestureGroup,
                              entries: [ForkTrackpadGestureCatalog.Entry]) -> some View {
        let allOff = ForkTrackpadGestureGroup.allDisabled(entries, in: disabled)
        let enabledCount = entries.filter { !disabled.contains($0.action) }.count
        let isExpanded = Binding(
            get: { expandedGroups.contains(group) },
            set: { open in
                if open { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
            })
        return Section {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(caption(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if group == .grid6 {
                        ForkTrackpadModifierKeyPicker(title: text.holdKeyTitle, value: $gridKeysRaw,
                                                        other: strongerKeysRaw,
                                                        fallback: .gridDefault)
                    } else if group == .shift {
                        ForkTrackpadModifierKeyPicker(title: text.holdKeyTitle, value: $strongerKeysRaw,
                                                        other: gridKeysRaw,
                                                        fallback: .strongerDefault)
                    }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                        ForEach(entries, id: \.action) { entry in
                            ForkTrackpadGestureCard(entry: entry,
                                                      symbols: symbols(of: entry),
                                                      centerScale: centerScale,
                                                      title: title(of: entry.action),
                                                      isEnabled: !disabled.contains(entry.action),
                                                      onText: text.gestureOn,
                                                      offText: text.gestureOff) {
                                toggle(entry.action)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    if group == .tap {
                        centerSizeControl
                    }
                }
                .padding(.top, 6)
            } label: {
                // Folded, the row still says what is on, and still switches
                // the whole group.
                HStack(alignment: .firstTextBaseline) {
                    Text(title(group))
                        .font(.headline)
                    Text("\(enabledCount)/\(entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(allOff ? text.enableAll : text.disableAll) {
                        store(ForkTrackpadGestureGroup.setting(entries, enabled: allOff, in: disabled))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var linkedSection: some View {
        Section(text.linkedTitle) {
            ForkTrackpadToggleCard(isEnabled: linkedResizeEnabled,
                                     onText: text.gestureOn, offText: text.gestureOff) {
                linkedResizeEnabled.toggle()
                ForkGestures.sync()
            } content: { isHovering in
                HStack(alignment: .center, spacing: 16) {
                    ForkLinkedWindowsIllustration(isDragged: isHovering,
                                                    tint: linkedResizeEnabled ? .accentColor : .secondary)
                        .frame(width: 176, height: 88)
                        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: isHovering)
                    VStack(alignment: .leading, spacing: 6) {
                        ForkTrackpadCardTitle(title: text.linkedEnable, isEnabled: linkedResizeEnabled)
                        Text(text.linkedCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Center size

    /// Right under the double tap it sizes: the Center card above redraws
    /// with each step, so the result shows while the knob moves.
    private var centerSizeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForkTrackpadStepSlider(title: text.centerSizeTitle, tuning: .centerSize,
                                     lowLabel: text.sizeSmall, highLabel: text.sizeLarge,
                                     step: $centerSizeStep)
            Text(text.centerSizeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(disabled.contains(.centerReduced))
        .opacity(disabled.contains(.centerReduced) ? 0.5 : 1)
    }

    // MARK: During the gesture

    private var duringSection: some View {
        Section {
            Text(text.duringCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                ForkTrackpadOptionCard(symbol: "rectangle.inset.filled.on.rectangle",
                                         title: text.previewTitle, detail: text.previewDetail,
                                         isEnabled: previewEnabled,
                                         onText: text.gestureOn, offText: text.gestureOff) {
                    previewEnabled.toggle()
                    ForkGestures.sync()
                }
                ForkTrackpadOptionCard(symbol: "hand.tap",
                                         title: text.hapticsTitle, detail: text.hapticsDetail,
                                         isEnabled: hapticsEnabled,
                                         onText: text.gestureOn, offText: text.gestureOff) {
                    hapticsEnabled.toggle()
                    ForkGestures.sync()
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text(text.duringTitle)
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    ForkTrackpadStepSlider(title: text.swipeSensitivityTitle, tuning: .swipeSensitivity,
                                             lowLabel: text.lessSensitive, highLabel: text.moreSensitive,
                                             step: $swipeSensitivityStep)
                    ForkTrackpadStepSlider(title: text.pinchSensitivityTitle, tuning: .pinchSensitivity,
                                             lowLabel: text.lessSensitive, highLabel: text.moreSensitive,
                                             step: $pinchSensitivityStep)
                    note(text.sensitivityCaption)
                    ForkTrackpadStepSlider(title: text.stepPauseTitle, tuning: .stepPause,
                                             lowLabel: text.shorter, highLabel: text.longer,
                                             step: $stepPauseStep)
                    note(text.stepPauseCaption)
                    Toggle(text.cancelEnabledTitle, isOn: $cancelEnabled)
                        .onChange(of: cancelEnabled) { _, _ in ForkGestures.sync() }
                    ForkTrackpadStepSlider(title: text.cancelDelayTitle, tuning: .cancelDelay,
                                             lowLabel: text.shorter, highLabel: text.longer,
                                             step: $cancelDelayStep)
                        .disabled(!cancelEnabled)
                        .opacity(cancelEnabled ? 1 : 0.5)
                    note(text.cancelDelayCaption)
                    ForkTrackpadStepSlider(title: text.titlebarBandTitle, tuning: .titlebarBand,
                                             lowLabel: text.bandThin, highLabel: text.bandTall,
                                             step: $titlebarBandStep)
                    note(text.titlebarBandCaption)
                    Button(text.resetDefaults, action: resetAdvanced)
                        .disabled(advancedIsDefault)
                }
                .padding(.top, 8)
            } label: {
                Text(text.advancedTitle)
            }
        }
    }

    private var advancedIsDefault: Bool {
        swipeSensitivityStep == ForkTrackpadTuning.swipeSensitivity.defaultStep
            && pinchSensitivityStep == ForkTrackpadTuning.pinchSensitivity.defaultStep
            && stepPauseStep == ForkTrackpadTuning.stepPause.defaultStep
            && cancelDelayStep == ForkTrackpadTuning.cancelDelay.defaultStep
            && cancelEnabled
            && titlebarBandStep == ForkTrackpadTuning.titlebarBand.defaultStep
    }

    private func resetAdvanced() {
        swipeSensitivityStep = ForkTrackpadTuning.swipeSensitivity.defaultStep
        pinchSensitivityStep = ForkTrackpadTuning.pinchSensitivity.defaultStep
        stepPauseStep = ForkTrackpadTuning.stepPause.defaultStep
        cancelDelayStep = ForkTrackpadTuning.cancelDelay.defaultStep
        cancelEnabled = true
        titlebarBandStep = ForkTrackpadTuning.titlebarBand.defaultStep
        ForkGestures.sync()
    }

    private func note(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Text

    private func title(_ group: ForkTrackpadGestureGroup) -> String {
        switch group {
        case .grid4: return text.groupGrid4
        case .grid6: return text.groupGrid6
        case .titlebar: return text.groupTitlebar
        case .pinch: return text.groupPinch
        case .tap: return text.groupTap
        case .shift: return text.groupShift
        case .dock: return text.groupDock
        }
    }

    private func caption(_ group: ForkTrackpadGestureGroup) -> String {
        switch group {
        case .grid4: return text.groupGrid4Caption
        case .grid6: return text.groupGrid6Caption
        case .titlebar: return text.groupTitlebarCaption
        case .pinch: return text.groupPinchCaption
        case .tap: return text.groupTapCaption
        case .shift: return text.groupShiftCaption
        case .dock: return text.groupDockCaption
        }
    }

    /// Read from the stored keys here, so every card follows the pickers.
    private func symbols(of entry: ForkTrackpadGestureCatalog.Entry) -> String {
        let keys: ForkTrackpadModifierKeys?
        switch entry.modifier {
        case .option?: keys = ForkTrackpadModifierKeys(rawValue: gridKeysRaw)
        case .shift?: keys = ForkTrackpadModifierKeys(rawValue: strongerKeysRaw)
        case nil: keys = nil
        }
        return [keys?.symbols, entry.triggers[0].symbols].compactMap { $0 }.joined(separator: " ")
    }

    private func title(of action: ForkTrackpadGestureAction) -> String {
        ForkTrackpadGestureTitle.title(of: action, text: text, layoutText: layoutText)
    }

    // MARK: Storage

    private func toggle(_ action: ForkTrackpadGestureAction) {
        var next = disabled
        if !next.insert(action).inserted { next.remove(action) }
        store(next)
    }

    /// The machine reads the set when the service syncs, so the next
    /// gesture already follows it.
    private func store(_ actions: Set<ForkTrackpadGestureAction>) {
        disabledStorage = ForkTrackpadDisabledGestures.storageValue(actions)
        ForkGestures.sync()
    }
}

// MARK: - Hero

/// The page's entry: a gesture replaying in a loop, and the one button that
/// turns everything on or off.
private struct ForkTrackpadHero: View {
    let text: ForkTrackpadGestureStrings
    let layoutText: WindowLayoutFeatureStrings
    let isOn: Bool
    let toggle: () -> Void

    /// The gestures the banner shows in turn, the common ones first.
    private static let reel: [ForkTrackpadGestureAction] = [
        .leftHalf, .rightHalf, .maximize, .bottomRightQuarter, .toggleFullScreen,
    ]
    private static let beat: TimeInterval = 2.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            TimelineView(.periodic(from: .now, by: Self.beat / 2)) { context in
                let tick = reduceMotion ? 1 : Int(context.date.timeIntervalSinceReferenceDate / (Self.beat / 2))
                let action = Self.reel[(tick / 2) % Self.reel.count]
                VStack(spacing: 6) {
                    ForkTrackpadGestureDrawing(action: action, isDone: tick % 2 == 1,
                                             showsFingers: !reduceMotion,
                                             tint: isOn ? .accentColor : .secondary)
                        .frame(width: 190)
                        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: tick)
                    Text("\(ForkTrackpadGestureCatalog.entry(for: action)?.triggers[0].symbols ?? "")  \(ForkTrackpadGestureTitle.title(of: action, text: text, layoutText: layoutText))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(text.enable)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                activation
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            // Faint, and only while on.
            RadialGradient(colors: [Color.accentColor.opacity(0.14), .clear],
                           center: .leading, startRadius: 0, endRadius: 280)
                .opacity(isOn ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }

    @ViewBuilder
    private var activation: some View {
        if isOn {
            HStack(spacing: 10) {
                Label(text.activeNow, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Button(text.deactivate, action: toggle)
            }
        } else {
            Button(action: toggle) {
                Label(text.activate, systemImage: "hand.draw")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Cards

/// A card's name and its check.
private struct ForkTrackpadCardTitle: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// A card that is its own switch, in the zone picker's colors: accent fill
/// and outline while on, and the hover passed to its content so it can
/// replay its gesture.
private struct ForkTrackpadToggleCard<Content: View>: View {
    let isEnabled: Bool
    let onText: String
    let offText: String
    let action: () -> Void
    @ViewBuilder var content: (_ isHovering: Bool) -> Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content(isHovering)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isEnabled
                            ? Color.accentColor.opacity(isHovering ? 0.12 : 0.07)
                            : Color.primary.opacity(isHovering ? 0.06 : 0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isEnabled
                            ? Color.accentColor.opacity(isHovering ? 0.65 : 0.42)
                            : Color.primary.opacity(isHovering ? 0.2 : 0.09),
                                      lineWidth: isEnabled ? 1.2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.14), value: isEnabled)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isEnabled ? onText : offText)
    }
}

/// One gesture: its drawing, its name, and what the fingers do.
private struct ForkTrackpadGestureCard: View {
    let entry: ForkTrackpadGestureCatalog.Entry
    /// What the hand does, its held keys first.
    let symbols: String
    let centerScale: Double
    let title: String
    let isEnabled: Bool
    let onText: String
    let offText: String
    let toggle: () -> Void

    /// False for the moment it takes to start over, on hover.
    @State private var isDone = true
    @State private var replay: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForkTrackpadToggleCard(isEnabled: isEnabled, onText: onText, offText: offText,
                                 action: toggle) { isHovering in
            VStack(alignment: .leading, spacing: 6) {
                ForkTrackpadGestureDrawing(action: entry.action, isDone: isDone,
                                             showsFingers: isHovering && !reduceMotion,
                                             tint: isEnabled ? .accentColor : .secondary,
                                             centerScale: centerScale)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: centerScale)
                    .saturation(isEnabled ? 1 : 0)
                    .opacity(isEnabled ? 1 : 0.6)
                ForkTrackpadCardTitle(title: title, isEnabled: isEnabled)
                Text(symbols)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: isHovering) { _, hovering in
                if hovering { play() }
            }
        }
        .accessibilityLabel("\(title), \(symbols)")
    }

    /// Replays the gesture: the window leaves from its place, then goes back.
    private func play() {
        guard !reduceMotion else { return }
        replay?.cancel()
        isDone = false
        replay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { isDone = true }
        }
    }
}

/// Why a gesture that looks enabled still does nothing: a system setting it
/// depends on is off. Shown only for a check caught failing; a passing or
/// unreadable one says nothing, the same restraint as `SecureInputRow`.
private struct ForkTrackpadDiagnosticRow: View {
    let check: ForkTrackpadDiagnosticCheck
    let text: ForkTrackpadGestureStrings

    private var message: String {
        switch check {
        case .smartZoom: return text.diagnosticSmartZoomOff
        case .pinchToZoom: return text.diagnosticPinchToZoomOff
        case .forceClickHaptics: return text.diagnosticForceClickOff
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            Button(text.diagnosticsOpenTrackpadSettings) {
                ForkTrackpadDiagnosticsSettings.openTrackpadSettings()
            }
            .controlSize(.small)
        }
    }
}

/// A setting for the moment of the gesture: a large symbol rather than a
/// drawing.
private struct ForkTrackpadOptionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let isEnabled: Bool
    let onText: String
    let offText: String
    let toggle: () -> Void

    var body: some View {
        ForkTrackpadToggleCard(isEnabled: isEnabled, onText: onText, offText: offText,
                                 action: toggle) { _ in
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(height: 30)
                ForkTrackpadCardTitle(title: title, isEnabled: isEnabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(title)
    }
}

/// The keys to hold, as key caps the way Window Layout picks its own: any
/// combination of ⌃ ⌥ ⇧ ⌘, never none, and never the very same as the other
/// held meaning's, which would make one gesture mean two things.
private struct ForkTrackpadModifierKeyPicker: View {
    let title: String
    @Binding var value: Int
    let other: Int
    let fallback: ForkTrackpadModifierKeys

    private var keys: ForkTrackpadModifierKeys {
        ForkTrackpadModifierKeys.valid(ForkTrackpadModifierKeys(rawValue: value), fallback: fallback)
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
            Spacer(minLength: 6)
            ForEach(ForkTrackpadModifierKeys.ordered, id: \.symbol) { choice in
                let selected = keys.contains(choice.key)
                Button {
                    toggle(choice.key)
                } label: {
                    Text(choice.symbol)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(width: 30, height: 25)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(next(toggling: choice.key) == nil)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// The keys after one is pressed, `nil` when that would leave none or
    /// match the other choice.
    private func next(toggling key: ForkTrackpadModifierKeys) -> ForkTrackpadModifierKeys? {
        var next = keys
        if next.contains(key) { next.remove(key) } else { next.insert(key) }
        guard !next.isEmpty, next.rawValue != other else { return nil }
        return next
    }

    private func toggle(_ key: ForkTrackpadModifierKeys) {
        guard let next = next(toggling: key) else { return }
        value = next.rawValue
        ForkGestures.sync()
    }
}

/// A tuned setting as notches between two words, never a number: each
/// notch is one step of its `ForkTrackpadTuning` ladder, and the words
/// say which way is which.
private struct ForkTrackpadStepSlider: View {
    let title: String
    let tuning: ForkTrackpadTuning
    let lowLabel: String
    let highLabel: String
    @Binding var step: Int

    var body: some View {
        Slider(value: Binding(get: { Double(tuning.clampedStep(step)) },
                              set: { step = tuning.clampedStep(Int($0.rounded())) }),
               in: 0...Double(tuning.steps.count - 1),
               step: 1) {
            Text(title)
        } minimumValueLabel: {
            Text(lowLabel).font(.caption2)
        } maximumValueLabel: {
            Text(highLabel).font(.caption2)
        }
        .onChange(of: step) { _, _ in ForkGestures.sync() }
    }
}

// MARK: - Drawings

/// A gesture's mini screen: what the gesture does, drawn.
///
/// No image and no video: shapes, in a fixed 160 × 100 space scaled to fit.
/// The landing zone comes from `ForkTrackpadPreviewContent`, the geometry
/// the live preview itself shows, so the drawing cannot promise a half the
/// gesture would not give.
///
/// At rest the card shows the result; on hover it replays the gesture (the
/// window leaves from its place, two dots slide like fingers).
struct ForkTrackpadGestureDrawing: View {
    let action: ForkTrackpadGestureAction
    /// False: the window is at its starting place. True: the gesture is done.
    let isDone: Bool
    /// The fingers only show while replaying.
    let showsFingers: Bool
    let tint: Color
    /// The tuned center size: the Center card draws what the gesture will
    /// really do.
    var centerScale: Double = ForkTrackpadTuning.centerSize.defaultValue

    enum Metric {
        static let screen = CGSize(width: 160, height: 100)
        static let menuBar: CGFloat = 6
        static let dockHeight: CGFloat = 9
        static let dockWidth: CGFloat = 64
        static let visible = CGRect(x: 0, y: menuBar, width: 160, height: 100 - menuBar - dockHeight - 3)
        static let start = CGRect(x: 44, y: 24, width: 72, height: 46)
        static let dockIcons = 5
        /// The Dock icon that minimize and quit aim at.
        static let dockTarget = 3
        /// The Trash, at the Dock's end as on screen.
        static let dockTrash = dockIcons - 1
        /// An app at the Dock's start, whose windows come back.
        static let dockApp = 0
        /// Right before the Trash: where macOS puts minimized windows.
        static let dockMinimized = dockIcons - 2
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Metric.screen.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: proxy.size.width, height: Metric.menuBar * scale)
                    .opacity(hidesChrome ? 0 : 1)

                dock(scale: scale)
                    .opacity(hidesChrome ? 0 : 1)

                // Where the window left from, so the move reads even frozen.
                if showsGhost {
                    RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(.tertiary)
                        .frame(width: start.width * scale, height: start.height * scale)
                        .offset(x: start.minX * scale, y: start.minY * scale)
                }

                window(scale: scale)

                if showsFingers {
                    fingers(scale: scale)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
        }
        .aspectRatio(Metric.screen.width / Metric.screen.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    // MARK: Window

    private var target: CGRect {
        switch action {
        case .minimize, .minimizeAllWindows:
            let icon = Self.dockIconFrame(Metric.dockTarget)
            return CGRect(x: icon.midX - 5, y: icon.minY, width: 10, height: 6)
        case .toggleFullScreen:
            return CGRect(origin: .zero, size: Metric.screen)
        case .close, .quitApp, .quitWindowApp, .closeMinimizedWindow:
            return start
        case .showAppWindows, .restoreMinimizedWindow:
            return Metric.start
        default:
            guard case let .zone(zone) = ForkTrackpadPreviewContent(.action(action), centerScale: centerScale)
            else { return start }
            let visible = Metric.visible
            return CGRect(x: visible.minX + zone.minX * visible.width,
                          y: visible.minY + zone.minY * visible.height,
                          width: zone.width * visible.width,
                          height: zone.height * visible.height)
                .insetBy(dx: 1, dy: 1)
        }
    }

    /// Center leaves from a corner: from the usual place, already almost
    /// centered, the gesture would not show.
    private var start: CGRect {
        switch action {
        case .centerReduced:
            return CGRect(x: 8, y: 11, width: 58, height: 38)
        case .showAppWindows, .restoreMinimizedWindow, .closeMinimizedWindow:
            // Folded into its Dock icon, which it rises out of.
            let icon = Self.dockIconFrame(dockIndex ?? Metric.dockApp)
            return CGRect(x: icon.midX - 4, y: icon.minY, width: 8, height: 5)
        default:
            return Metric.start
        }
    }

    private var frame: CGRect { isDone ? target : start }

    /// Close and quit make the window vanish where it is.
    private var vanishes: Bool { isDone && [.close, .quitApp, .quitWindowApp, .emptyTrash, .closeMinimizedWindow].contains(action) }

    private var hidesChrome: Bool { isDone && action == .toggleFullScreen }

    private var showsGhost: Bool {
        switch action {
        case .close, .quitApp, .quitWindowApp, .toggleFullScreen, .minimize, .minimizeAllWindows, .emptyTrash,
             .showAppWindows, .restoreMinimizedWindow, .closeMinimizedWindow: return false
        default: return isDone
        }
    }

    private func window(scale: CGFloat) -> some View {
        let rect = frame
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                .fill(tint.opacity(isDone ? 0.28 : 0.14))
            RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                .strokeBorder(tint.opacity(0.9), lineWidth: 1)
            // The title bar and its three lights: that is where the gesture
            // happens, so that is what must be recognized.
            HStack(spacing: 1.6 * scale) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(lightColor(index))
                        .frame(width: 2.6 * scale, height: 2.6 * scale)
                }
            }
            .padding(.leading, 3 * scale)
            .padding(.top, 2.5 * scale)
            .opacity(rect.height > 12 ? 1 : 0)
        }
        .frame(width: rect.width * scale, height: rect.height * scale)
        .scaleEffect(vanishes ? 0.82 : 1)
        // Emptying the Trash or closing a thumbnail moves no window: only the
        // Dock shows.
        .opacity(vanishes || action == .emptyTrash || action == .closeMinimizedWindow ? 0 : 1)
        .offset(x: rect.minX * scale, y: rect.minY * scale)
    }

    /// The gesture's light comes on: red to close, yellow to minimize, green
    /// for full screen. The others stay neutral.
    private func lightColor(_ index: Int) -> Color {
        let lit: Int?
        switch action {
        case .close, .quitApp, .quitWindowApp: lit = 0
        case .minimize, .minimizeAllWindows: lit = 1
        case .toggleFullScreen: lit = 2
        default: lit = nil
        }
        guard index == lit else { return Color.secondary.opacity(0.45) }
        return [Color.red, .yellow, .green][index]
    }

    // MARK: Dock

    /// The Dock icon the gesture is about: made on it, or, for minimize,
    /// where the window goes.
    private var dockIndex: Int? {
        switch action {
        case .minimize, .minimizeAllWindows, .quitApp: return Metric.dockTarget
        case .emptyTrash: return Metric.dockTrash
        case .showAppWindows: return Metric.dockApp
        case .restoreMinimizedWindow, .closeMinimizedWindow: return Metric.dockMinimized
        default: return nil
        }
    }

    static func dockIconFrame(_ index: Int) -> CGRect {
        let size: CGFloat = 7
        let gap: CGFloat = 3.5
        let total = CGFloat(Metric.dockIcons) * size + CGFloat(Metric.dockIcons - 1) * gap
        let x = (Metric.screen.width - total) / 2 + CGFloat(index) * (size + gap)
        return CGRect(x: x, y: Metric.screen.height - Metric.dockHeight - 1, width: size, height: size)
    }

    private func dock(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            let width = Metric.dockWidth
            RoundedRectangle(cornerRadius: 3.5 * scale, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: width * scale, height: (Metric.dockHeight + 2) * scale)
                .offset(x: (Metric.screen.width - width) / 2 * scale,
                        y: (Metric.screen.height - Metric.dockHeight - 3) * scale)
            ForEach(0..<Metric.dockIcons, id: \.self) { index in
                let icon = Self.dockIconFrame(index)
                let isTarget = index == dockIndex
                let isTrash = isTarget && action == .emptyTrash
                let isThumbnail = isTarget && [.restoreMinimizedWindow, .closeMinimizedWindow].contains(action)
                // Restored, a thumbnail leaves the Dock; closed, it goes too.
                let empties = isDone && isTarget
                    && [.quitApp, .emptyTrash, .restoreMinimizedWindow, .closeMinimizedWindow].contains(action)
                RoundedRectangle(cornerRadius: 1.8 * scale, style: .continuous)
                    .fill(isTarget ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                    .frame(width: icon.width * scale, height: icon.height * scale)
                    .overlay {
                        if isTrash || isThumbnail {
                            Image(systemName: isTrash ? (isDone ? "trash" : "trash.fill") : "macwindow")
                                .font(.system(size: 4.6 * scale, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .scaleEffect(empties ? 0.55 : 1)
                    .opacity(empties ? 0.35 : 1)
                    .offset(x: icon.minX * scale, y: icon.minY * scale)
            }
        }
    }

    // MARK: Fingers

    /// Two dots side by side where the gesture happens (the title bar, or
    /// the Dock icon), sliding the way of the gesture or spreading and
    /// closing.
    private func fingers(scale: CGFloat) -> some View {
        let anchor = fingerAnchor
        let (first, second) = fingerOffsets
        let dot = 5.5 * scale
        return ZStack(alignment: .topLeading) {
            ForEach(Array([first, second].enumerated()), id: \.offset) { _, offset in
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .frame(width: dot, height: dot)
                    .offset(x: (anchor.x + offset.width) * scale - dot / 2,
                            y: (anchor.y + offset.height) * scale - dot / 2)
            }
        }
    }

    private var fingerAnchor: CGPoint {
        if action != .minimize, action != .minimizeAllWindows, let index = dockIndex {
            let icon = Self.dockIconFrame(index)
            return CGPoint(x: icon.midX, y: icon.midY - 6)
        }
        // The middle of the starting title bar: the fingers stay where the
        // gesture began, the window leaves from under them.
        return CGPoint(x: start.midX, y: start.minY + 4)
    }

    /// Each finger's offset, gesture done. At the start both sit side by
    /// side, 4 points apart.
    private var fingerOffsets: (CGSize, CGSize) {
        let spread: CGFloat = 4
        guard isDone else {
            // A closing pinch starts spread out.
            let open: CGFloat = [.close, .quitApp, .quitWindowApp, .emptyTrash, .closeMinimizedWindow].contains(action) ? 9 : spread
            return (CGSize(width: -open, height: 0), CGSize(width: open, height: 0))
        }
        switch action {
        case .toggleFullScreen:
            return (CGSize(width: -12, height: 0), CGSize(width: 12, height: 0))
        case .close, .quitApp, .quitWindowApp, .emptyTrash, .closeMinimizedWindow:
            return (CGSize(width: -2.5, height: 0), CGSize(width: 2.5, height: 0))
        default:
            let travel = swipeTravel
            return (CGSize(width: -spread + travel.width, height: travel.height),
                    CGSize(width: spread + travel.width, height: travel.height))
        }
    }

    /// Where the fingers slid: the sum of the trigger's steps, a diagonal
    /// counting both its parts in one stroke.
    private var swipeTravel: CGSize {
        guard let entry = ForkTrackpadGestureCatalog.entry(for: action),
              case let .swipes(steps) = entry.triggers[0] else { return .zero }
        let step: CGFloat = 13
        return steps.reduce(.zero) { sum, direction in
            let dx: CGFloat
            switch direction.horizontal {
            case .left?: dx = -step
            case .right?: dx = step
            default: dx = 0
            }
            let dy: CGFloat
            switch direction.vertical {
            case .up?: dy = -step * 0.7
            case .down?: dy = step * 0.7
            default: dy = 0
            }
            return CGSize(width: sum.width + dx, height: sum.height + dy)
        }
    }
}

/// Two linked windows, and their shared edge moving.
private struct ForkLinkedWindowsIllustration: View {
    /// False: split at 50 %. True: the shared edge dragged to the right.
    let isDragged: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let border = size.width * (isDragged ? 0.64 : 0.5)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
                pane(width: border - 6)
                    .offset(x: 4, y: 4)
                pane(width: size.width - border - 6)
                    .offset(x: border + 2, y: 4)
                // The handle: an accent bar and the ↔ cursor.
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: size.height * 0.34)
                    .offset(x: border - 1.5, y: size.height * 0.33)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(3)
                    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                    .offset(x: border - 11, y: size.height * 0.5 + 12)
            }
            .frame(height: size.height)
        }
        .accessibilityHidden(true)
    }

    private func pane(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tint.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(0.8)))
            .frame(width: max(width, 0))
            .padding(.bottom, 8)
    }
}
