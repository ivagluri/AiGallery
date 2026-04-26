import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            SlideshowPreferencesTab()
                .tabItem {
                    Label("Slideshow", systemImage: "play.circle")
                }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - Slideshow Tab

private struct SlideshowPreferencesTab: View {
    @ObservedObject private var settings = SlideshowSettings.shared

    @State private var customColor: Color

    init() {
        let s = SlideshowSettings.shared
        _customColor = State(initialValue: Color(red: s.customColorR, green: s.customColorG, blue: s.customColorB))
    }

    var body: some View {
        Form {
            playbackSection
            imageDisplaySection
            textOverlaySection
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    // MARK: Sections

    private var playbackSection: some View {
        Section("Playback") {
            durationRow
            Picker("Order", selection: Binding(
                get: { settings.playbackOrder },
                set: { settings.playbackOrder = $0 }
            )) {
                ForEach(SlideshowPlaybackOrder.allCases, id: \.rawValue) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Loop", isOn: $settings.loopEnabled)

            Picker("Transition", selection: Binding(
                get: { settings.transition },
                set: { settings.transition = $0 }
            )) {
                ForEach(SlideshowTransition.allCases, id: \.rawValue) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var imageDisplaySection: some View {
        Section("Image Display") {
            Picker("Fit Mode", selection: Binding(
                get: { settings.imageFitMode },
                set: { settings.imageFitMode = $0 }
            )) {
                ForEach(SlideshowImageFitMode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Background", selection: Binding(
                get: { settings.backgroundColorPreset },
                set: { settings.backgroundColorPreset = $0 }
            )) {
                ForEach(SlideshowBackgroundColor.allCases, id: \.rawValue) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if settings.backgroundColorPreset == .custom {
                ColorPicker("Custom Color", selection: $customColor)
                    .onChange(of: customColor) { newColor in
                        if let ns = NSColor(newColor).usingColorSpace(.deviceRGB) {
                            settings.customColorR = Double(ns.redComponent)
                            settings.customColorG = Double(ns.greenComponent)
                            settings.customColorB = Double(ns.blueComponent)
                        }
                    }
            }
        }
    }

    private var textOverlaySection: some View {
        Section("Text Overlay") {
            Toggle("Show Overlay", isOn: $settings.overlayEnabled)

            Picker("Preset", selection: Binding(
                get: { settings.overlayPreset },
                set: { settings.overlayPreset = $0 }
            )) {
                ForEach(SlideshowOverlayPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .disabled(!settings.overlayEnabled)

            if settings.overlayEnabled && settings.overlayPreset == .fullPrompt {
                Picker("Prompt", selection: Binding(
                    get: { settings.promptContent },
                    set: { settings.promptContent = $0 }
                )) {
                    ForEach(SlideshowPromptContent.allCases, id: \.rawValue) { content in
                        Text(content.label).tag(content)
                    }
                }
                .pickerStyle(.segmented)
            }

            Picker("Position", selection: Binding(
                get: { settings.overlayPosition },
                set: { settings.overlayPosition = $0 }
            )) {
                ForEach(SlideshowOverlayPosition.allCases, id: \.rawValue) { pos in
                    Text(pos.label).tag(pos)
                }
            }
            .disabled(!settings.overlayEnabled || settings.overlayPreset == .none)
        }
    }

    // MARK: Duration row

    private var durationRow: some View {
        HStack {
            Text("Slide Duration")
            Spacer()
            Slider(value: $settings.duration, in: 1...60, step: 1)
                .frame(width: 180)
            Text("\(Int(settings.duration))s")
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}
