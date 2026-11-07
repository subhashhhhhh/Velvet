import SwiftUI

/// Shows a remote image, decoded at exactly the pixel size it's displayed at.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var loadedURL: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .task(id: TaskKey(url: url, side: bucket(geo.size))) {
                await load(side: bucket(geo.size))
            }
        }
    }

    /// Pixel size rounded up to 64px steps, so live window resizing doesn't refetch constantly.
    private func bucket(_ size: CGSize) -> Int {
        let px = Int(max(size.width, size.height) * displayScale)
        return px <= 0 ? 0 : ((px + 63) / 64) * 64
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let side: Int
    }

    private func load(side: Int) async {
        guard let url, side > 0 else { image = nil; return }
        if loadedURL != url { image = nil }
        let result = await ImagePipeline.shared.image(for: url, maxPixel: side)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) { image = result }
        loadedURL = url
    }
}
