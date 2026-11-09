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
        let view = VStack(alignment: .leading, spacing: 18) {
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
