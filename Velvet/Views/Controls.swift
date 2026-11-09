import SwiftUI

/// A filter chip, as above the home feed: filled with the text colour when selected.
struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(hovering ? 0.16 : 0.1)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Tabs that split the width evenly, with a soft highlight that slides to the selected one
/// (the sidebar's look, in place of the system's blue segmented control).
struct SegmentedTabs<Value: Hashable>: View {
    let tabs: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.value) { tab in
                let selected = tab.value == selection
                Button { selection = tab.value } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.primary.opacity(0.13))
                                    .matchedGeometryEffect(id: "tab", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.primary.opacity(0.05)))
        .animation(.smooth(duration: 0.25), value: selection)
    }
}

#if DEBUG
/// `-VelvetRenderControls <file.png>`: draws these controls (dark) to an image, for checking
/// them without a window on screen.
enum ControlsPreview {
    static func renderIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "VelvetRenderControls") else { return }
        let sample = "More info: https://studio.blender.org/projects/big-buck-bunny/ and the best part is at 10:32."
        let links = HStack(spacing: 0) {
            ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
                LinkedText(text: sample).frame(width: 300, alignment: .leading).padding(12)
                    .background(scheme == .dark ? Color(white: 0.12) : .white)
                    .environment(\.colorScheme, scheme)
            }
        }
        let view = VStack(alignment: .leading, spacing: 18) {
            links
            SegmentedTabs(tabs: [(0, "Videos (3)"), (1, "Comments")], selection: .constant(0)).frame(width: 408)
            SegmentedTabs(tabs: [(0, "Chat"), (1, "Up Next")], selection: .constant(1)).frame(width: 360)
            HStack(spacing: 8) {
                Chip(title: "Videos", isOn: true) {}
                Chip(title: "Shorts", isOn: false) {}
                Chip(title: "Live", isOn: false) {}
                Chip(title: "Playlists", isOn: false) {}
            }
        }
        .padding(20)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

/// The main button of a view (Retry, Sign In, Install…), in place of the system's blue
/// `.borderedProminent`: filled with the text colour, like a selected `Chip`. Over video,
/// which is always dark, it's white whatever the appearance.
struct ProminentButtonStyle: ButtonStyle {
    var overMedia = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(overMedia ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
            .background(overMedia ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    static var prominent: ProminentButtonStyle { ProminentButtonStyle() }
    static var prominentOverMedia: ProminentButtonStyle { ProminentButtonStyle(overMedia: true) }
}

extension Color {
    /// Velvet's accent, neutral instead of blue: near-white in dark mode (#F5F5F7), near-black in light (#1D1D1F)
    /// (the AccentColor asset). Applied with `.tint` at each window's root, because macOS
    /// uses an app's own accent only when the system accent is set to Multicolor.
    static let velvetAccent = Color("AccentColor")
}

extension Color {
    /// The crimson of Velvet's icon, for switches only; the rest of the UI is neutral.
    static let velvetCrimson = Color(red: 0xE0 / 255, green: 0x10 / 255, blue: 0x3A / 255)
}

/// Every switch in Velvet is crimson (set at each window's root). Toggles that ask for
/// another style, such as the playlist checkboxes, keep it and the neutral tint.
struct VelvetSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(.velvetCrimson)
    }
}

extension Color {
    /// Links in descriptions and comments: Velvet's crimson, lighter on dark backgrounds so
    /// it stays readable. (The neutral tint made them look like the text around them.)
    static let velvetLink = Color(nsColor: .velvetLink)
}

extension NSColor {
    static let velvetLink = NSColor(name: "VelvetLink") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.5, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.05, blue: 0.2, alpha: 1)
    }
}
