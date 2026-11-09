import AppKit
import SwiftUI

/// The Downloads page: videos saved for offline viewing, and those still downloading.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingRemoveAll = false

    private var downloads: Downloads { app.downloads }

    var body: some View {
        Group {
            if downloads.items.isEmpty && downloads.active.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download a video from its page or its menu to watch it offline. Downloads play in Velvet."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                        if !downloads.active.isEmpty {
                            VStack(spacing: 10) {
                                ForEach(activeIDs, id: \.self) { id in
                                    ActiveDownloadRow(id: id, progress: downloads.active[id] ?? .waiting)
                                }
                            }
                        }
                        LazyVGrid(columns: VideoGrid.gridItems(VideoGrid.columns(GridLayout(width: 0, sidebarCollapsed: app.isSidebarCollapsed), prefs: app.settings)),
                                  alignment: .leading, spacing: VideoGrid.spacing) {
                            ForEach(downloads.items) { item in
                                let video = card(item)
                                Button { app.open(video) } label: { VideoCard(video: video) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(VideoGrid.padding)
                }
            }
        }
        .navigationTitle("Downloads")
        .topBarTitle("Downloads")
        .topBarActions([
            TopBarAction(id: "Show in Finder", symbol: "folder", disabled: downloads.items.isEmpty) {
                NSWorkspace.shared.activateFileViewerSelecting([Downloads.root])
            },
            TopBarAction(id: "Remove All Downloads", symbol: "trash", disabled: downloads.items.isEmpty && downloads.active.isEmpty) {
                confirmingRemoveAll = true
            },
        ])
        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAll) {
            Button("Remove All", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("This frees \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)).")
        }
    }

    private var activeIDs: [String] { downloads.active.keys.sorted() }

    private var summary: String {
        let count = downloads.items.count
        let size = ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)
        return "\(count) \(count == 1 ? "video" : "videos") · \(size)"
    }

    /// The card shows the saved thumbnail, and the resolution and size where views and date go.
    private func card(_ item: DownloadedVideo) -> Video {
        var video = downloads.asVideo(item)
        video.viewCount = item.resolution
        video.published = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        return video
    }
}

private struct ActiveDownloadRow: View {
    let id: String
    let progress: Downloads.Progress
    @Environment(AppModel.self) private var app

    private var isFailed: Bool {
        if case .failed = progress { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.downloads.title(for: id)).lineLimit(1)
                switch progress {
                case .waiting:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if case .failed = progress {
                Button("Retry") { app.downloads.retry(id) }
            }
            Button(isFailed ? "Remove" : "Cancel") { app.downloads.cancel(id) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The watch page's Download button, showing the download's state.
struct DownloadPill: View {
    let video: Video
    var compact: Bool
    /// Stretched to share the wide watch page's action row; else icon-sized when compact.
    var fill = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let downloads = app.downloads
        Group {
            if downloads.isDownloaded(video.id) {
                Menu {
                    Button("Show Downloads") { app.navigate(to: .downloads) }
                    Button("Remove Download", role: .destructive) { downloads.remove(video.id) }
                } label: {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .labelStyle(CompactableLabelStyle(compact: compact))
                        .foregroundStyle(Color.velvetLink)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Downloaded: plays offline")
            } else {
                switch downloads.active[video.id] {
                case .downloading(let fraction):
                    Button { downloads.cancel(video.id) } label: {
                        // A ring that fills, icon-sized like the other pills.
                        HStack(spacing: 6) {
                            ZStack {
                                Circle().stroke(.primary.opacity(0.2), lineWidth: 2)
                                Circle().trim(from: 0, to: max(0.02, fraction))
                                    .stroke(Color.velvetLink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 15, height: 15)
                            .animation(.linear(duration: 0.2), value: fraction)
                            if !compact {
                                Text("\(Int(fraction * 100)) %").monospacedDigit()
                            }
                        }
                    }
                    .help("Downloading: \(Int(fraction * 100))%. Click to cancel.")
                case .waiting:
                    Button { downloads.cancel(video.id) } label: {
                        Label("Waiting", systemImage: "clock").labelStyle(CompactableLabelStyle(compact: compact))
                    }
                        .help("Waiting for another download. Click to cancel.")
                case .failed(let message):
                    Button { downloads.retry(video.id) } label: {
                        Label("Retry", systemImage: "exclamationmark.arrow.circlepath")
                            .labelStyle(CompactableLabelStyle(compact: compact))
                    }
                    .help(message)
                case nil:
                    Button { downloads.download(video) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .labelStyle(CompactableLabelStyle(compact: compact))
                    }
                    .help("Download to watch offline")
                }
            }
        }
        .buttonStyle(PillButtonStyle(fill: fill, iconOnly: compact))
        .background(.quaternary, in: Capsule())
    }
}
