import SwiftUI

/// "Save to Playlist" for a video outside the watch page (context menus): your playlists,
/// each toggled on or off, saved as soon as it changes.
struct PlaylistPicker: View {
    let video: Video
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var options: [PlaylistOption]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to Playlist").font(.headline)
            Text(video.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Group {
                if let options {
                    if options.isEmpty {
                        Text("You have no playlists.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(options) { p in
                                    Toggle(isOn: Binding(get: { p.containsVideo }, set: { set(p.id, $0) })) {
                                        Label(p.title, systemImage: p.isWatchLater ? "clock" : (p.isPrivate ? "lock" : "list.bullet"))
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 320)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .task { await load() }
    }

    private func load() async {
        do {
            options = WatchParser.playlistOptions(from: try await app.client.playlistOptions(for: video.id))
        } catch {
            self.error = "Couldn't load your playlists: \(error.localizedDescription)"
        }
    }

    /// Optimistic, rolled back if YouTube refuses.
    private func set(_ id: String, _ included: Bool) {
        guard let i = options?.firstIndex(where: { $0.id == id }) else { return }
        options?[i].containsVideo = included
        Task {
            do {
                try await app.client.setVideo(video.id, inPlaylist: id, included)
            } catch {
                if let i = options?.firstIndex(where: { $0.id == id }) { options?[i].containsVideo = !included }
                app.actionError = "Couldn't update the playlist: \(error.localizedDescription)"
            }
        }
    }
}
