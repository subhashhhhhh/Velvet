import SwiftUI

/// The Queue page: what plays next, in order. Drag to reorder.
struct QueueView: View {
    @Environment(AppModel.self) private var app

    private var queue: PlaybackQueue { app.queue }

    var body: some View {
        Group {
            if queue.isEmpty {
                ContentUnavailableView("Queue Is Empty", systemImage: "list.number",
                                       description: Text("Right-click a video and choose Play Next or Add to Queue."))
            } else {
                List {
                    ForEach(queue.items) { video in
                        QueueRow(video: video)
                            .contentShape(Rectangle())
                            .onTapGesture { app.playFromQueue(video) }
                            .contextMenu {
                                Button("Play Now", systemImage: "play") { app.playFromQueue(video) }
                                Button("Move to Top", systemImage: "arrow.up.to.line") { queue.playNext(video) }
                                Divider()
                                Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) { queue.remove(video.id) }
                            }
                    }
                    .onMove { queue.move(from: $0, to: $1) }
                    .onDelete { offsets in offsets.map { queue.items[$0].id }.forEach(queue.remove) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Queue")
        .topBarTitle("Queue")
        .topBarActions([
            TopBarAction(id: "Play the Queue", symbol: "play.fill", disabled: queue.isEmpty) { app.playNextInQueue() },
            TopBarAction(id: "Clear the Queue", symbol: "trash", disabled: queue.isEmpty) { queue.clear() },
        ])
    }
}

/// A compact queued-video row (thumbnail, title, channel).
struct QueueRow: View {
    let video: Video
    var thumbnailWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: video.thumbnail(minWidth: Int(thumbnailWidth * 2)))
                .frame(width: thumbnailWidth, height: thumbnailWidth * 9 / 16)
                .overlay(alignment: .bottomTrailing) {
                    if let d = video.duration { BadgeLabel(text: d, background: .black.opacity(0.75)).padding(3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if let c = video.channelName { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// The watch page's look at the queue: the next few videos and a skip button.
struct QueuePreview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let items = app.queue.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let source = app.queue.source {
                        VStack(alignment: .leading, spacing: 1) {
                            Label("Playing from \(source)", systemImage: "music.note.list")
                                .font(.headline)
                                .lineLimit(1)
                            Text("\(items.count) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Queue · \(items.count)", systemImage: "list.number").font(.headline)
                    }
                    Spacer()
                    Button("Play Next", systemImage: "forward.end.fill") { app.playNextInQueue() }
                        .buttonStyle(.borderless)
                        .help("Skip to the next queued video (⇧N)")
                    Button("Show All") { app.navigate(to: .queue) }
                        .buttonStyle(.borderless)
                }
                ForEach(items.prefix(3)) { video in
                    QueueRow(video: video, thumbnailWidth: 96)
                        .contentShape(Rectangle())
                        .onTapGesture { app.playFromQueue(video) }
                        .contextMenu {
                            Button("Remove from Queue", systemImage: "minus.circle") { app.queue.remove(video.id) }
                        }
                }
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
