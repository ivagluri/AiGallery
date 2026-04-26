import AppKit
import SwiftUI

// MARK: - Enums

enum SlideshowPlaybackOrder: String, CaseIterable {
    case inOrder = "inOrder"
    case random = "random"

    var label: String {
        switch self {
        case .inOrder: return "In Order"
        case .random: return "Random"
        }
    }
}

enum SlideshowImageFitMode: String, CaseIterable {
    case fit = "fit"
    case fill = "fill"
    case center = "center"
    case stretch = "stretch"

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .center: return "Actual Size"
        case .stretch: return "Stretch"
        }
    }
}

enum SlideshowBackgroundColor: String, CaseIterable {
    case black = "black"
    case darkGray = "darkGray"
    case white = "white"
    case custom = "custom"

    var label: String {
        switch self {
        case .black: return "Black"
        case .darkGray: return "Dark Gray"
        case .white: return "White"
        case .custom: return "Custom…"
        }
    }
}

enum SlideshowTransition: String, CaseIterable {
    case crossfade = "crossfade"
    case none = "none"

    var label: String {
        switch self {
        case .crossfade: return "Cross-Fade"
        case .none: return "None"
        }
    }
}

enum SlideshowOverlayPreset: String, CaseIterable {
    case none = "none"
    case filename = "filename"
    case basicInfo = "basicInfo"
    case fullPrompt = "fullPrompt"

    var label: String {
        switch self {
        case .none: return "None"
        case .filename: return "Filename"
        case .basicInfo: return "Basic Info"
        case .fullPrompt: return "Prompt"
        }
    }
}

enum SlideshowPromptContent: String, CaseIterable {
    case positive = "positive"
    case negative = "negative"
    case both = "both"

    var label: String {
        switch self {
        case .positive: return "Positive"
        case .negative: return "Negative"
        case .both: return "Both"
        }
    }
}

enum SlideshowOverlayPosition: String, CaseIterable {
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomCenter = "bottomCenter"
    case bottomRight = "bottomRight"

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
}

// MARK: - Settings

@MainActor
final class SlideshowSettings: ObservableObject {
    static let shared = SlideshowSettings()

    @AppStorage("slideshow.duration") var duration: Double = 5.0
    @AppStorage("slideshow.playbackOrder") var playbackOrderRaw: String = SlideshowPlaybackOrder.inOrder.rawValue
    @AppStorage("slideshow.loopEnabled") var loopEnabled: Bool = true
    @AppStorage("slideshow.imageFitMode") var imageFitModeRaw: String = SlideshowImageFitMode.fit.rawValue
    @AppStorage("slideshow.backgroundColorID") var backgroundColorRaw: String = SlideshowBackgroundColor.black.rawValue
    @AppStorage("slideshow.customColorR") var customColorR: Double = 0.1
    @AppStorage("slideshow.customColorG") var customColorG: Double = 0.1
    @AppStorage("slideshow.customColorB") var customColorB: Double = 0.1
    @AppStorage("slideshow.transition") var transitionRaw: String = SlideshowTransition.crossfade.rawValue
    @AppStorage("slideshow.overlayEnabled") var overlayEnabled: Bool = true
    @AppStorage("slideshow.overlayPreset") var overlayPresetRaw: String = SlideshowOverlayPreset.filename.rawValue
    @AppStorage("slideshow.overlayPosition") var overlayPositionRaw: String = SlideshowOverlayPosition.bottomCenter.rawValue
    @AppStorage("slideshow.promptContent") var promptContentRaw: String = SlideshowPromptContent.positive.rawValue

    private init() {}

    var playbackOrder: SlideshowPlaybackOrder {
        get { SlideshowPlaybackOrder(rawValue: playbackOrderRaw) ?? .inOrder }
        set { playbackOrderRaw = newValue.rawValue }
    }

    var imageFitMode: SlideshowImageFitMode {
        get { SlideshowImageFitMode(rawValue: imageFitModeRaw) ?? .fit }
        set { imageFitModeRaw = newValue.rawValue }
    }

    var backgroundColorPreset: SlideshowBackgroundColor {
        get { SlideshowBackgroundColor(rawValue: backgroundColorRaw) ?? .black }
        set { backgroundColorRaw = newValue.rawValue }
    }

    var transition: SlideshowTransition {
        get { SlideshowTransition(rawValue: transitionRaw) ?? .crossfade }
        set { transitionRaw = newValue.rawValue }
    }

    var overlayPreset: SlideshowOverlayPreset {
        get { SlideshowOverlayPreset(rawValue: overlayPresetRaw) ?? .filename }
        set { overlayPresetRaw = newValue.rawValue }
    }

    var overlayPosition: SlideshowOverlayPosition {
        get { SlideshowOverlayPosition(rawValue: overlayPositionRaw) ?? .bottomCenter }
        set { overlayPositionRaw = newValue.rawValue }
    }

    var promptContent: SlideshowPromptContent {
        get { SlideshowPromptContent(rawValue: promptContentRaw) ?? .positive }
        set { promptContentRaw = newValue.rawValue }
    }

    var nsBackgroundColor: NSColor {
        switch backgroundColorPreset {
        case .black: return .black
        case .darkGray: return NSColor(white: 0.12, alpha: 1)
        case .white: return .white
        case .custom: return NSColor(red: customColorR, green: customColorG, blue: customColorB, alpha: 1)
        }
    }

    func snapshot() -> SlideshowSettingsSnapshot {
        SlideshowSettingsSnapshot(
            duration: duration,
            playbackOrder: playbackOrder,
            loopEnabled: loopEnabled,
            imageFitMode: imageFitMode,
            nsBackgroundColor: nsBackgroundColor,
            transition: transition,
            overlayEnabled: overlayEnabled,
            overlayPreset: overlayPreset,
            overlayPosition: overlayPosition,
            promptContent: promptContent
        )
    }
}

// MARK: - Snapshot (plain struct, thread-safe)

struct SlideshowSettingsSnapshot {
    let duration: Double
    let playbackOrder: SlideshowPlaybackOrder
    let loopEnabled: Bool
    let imageFitMode: SlideshowImageFitMode
    let nsBackgroundColor: NSColor
    let transition: SlideshowTransition
    let overlayEnabled: Bool
    let overlayPreset: SlideshowOverlayPreset
    let overlayPosition: SlideshowOverlayPosition
    let promptContent: SlideshowPromptContent

    var swiftUIBackgroundColor: Color {
        Color(nsColor: nsBackgroundColor)
    }
}
