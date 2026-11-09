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

/// The watch page's queue panel, like YouTube's playlist panel: the list's name and position,
/// loop / shuffle, and every video in it (played ones above, the current one highlighted),
/// scrolling once it's long.
struct QueuePreview: View {
    @Environment(AppModel.self) private var app
    @State private var collapsed = false

    private var queue: PlaybackQueue { app.queue }

    /// The video playing now, if it's the queue's current one.
    private var currentId: String? {
        guard let id = app.watching?.video.id, queue.played.last?.id == id else { return nil }
        return id
    }

    var body: some View {
        if queue.hasContent {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !collapsed {
                    Divider()
                    list
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var subtitle: String {
        let total = queue.played.count + queue.items.count
        if currentId != nil { return "\(queue.played.count) / \(total)" }
        return total == 1 ? "1 video" : "\(total) videos"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(queue.source ?? "Queue")
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Spacer()
                ChromeButton(collapsed ? "Show the List" : "Hide the List",
                             symbol: collapsed ? "chevron.down" : "chevron.up") { collapsed.toggle() }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                @Bindable var queue = queue
                Button { queue.loops.toggle() } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(queue.loops ? Color.primary : .secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.primary.opacity(queue.loops ? 0.14 : 0)))
                }
                .buttonStyle(.plain)
                .help(queue.loops ? "Stop looping the list" : "Loop the list")
                ChromeButton("Shuffle What's Next", symbol: "shuffle") { queue.shuffle() }
                    .disabled(queue.items.count < 2)
                if !queue.isEmpty {
                    ChromeButton("Play Next (⇧N)", symbol: "forward.end.fill") { app.playNextInQueue() }
                }
                Spacer()
                Menu {
                    Button("Show Queue Page", systemImage: "list.number") { app.navigate(to: .queue) }
                    Divider()
                    Button("Clear the Queue", systemImage: "trash", role: .destructive) { queue.clear() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var list: some View {
        let rows = queue.played + queue.items
        let current = currentId
        let currentIndex = current.flatMap { id in rows.firstIndex { $0.id == id } }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, video in
                        QueuePanelRow(video: video, number: i + 1, isCurrent: i == currentIndex,
                                      isPlayed: currentIndex.map { i < $0 } ?? (i < queue.played.count))
                            .id(video.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: min(CGFloat(rows.count) * 84 + 8, 440))
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                if let id { withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct QueuePanelRow: View {
    let video: Video
    let number: Int
    let isCurrent: Bool
    let isPlayed: Bool
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: "play.fill").font(.system(size: 9))
                } else {
                    Text("\(number)").font(.system(size: 11).monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 20)
            RemoteImage(url: video.thumbnail(minWidth: 240))
                .frame(width: 120, height: 67.5)
                .background(.quaternary)
                .overlay(alignment: .bottomTrailing) {
                    if let d = video.duration { BadgeLabel(text: d, background: .black.opacity(0.75)).padding(3) }
                }
                .overlay(alignment: .bottom) {
                    if let f = app.progress.fraction(for: video.id), f > 0.02 {
                        GeometryReader { geo in
                            Rectangle().fill(.red).frame(width: geo.size.width * min(1, f), height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.system(size: 13, weight: isCurrent ? .bold : .semibold))
                    .lineLimit(2)
                if let channel = video.channelName {
                    Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(isPlayed ? 0.7 : 1)
            Spacer(minLength: 0)
            if hovering && !isCurrent && !isPlayed {
                Menu {
                    Button("Play Now", systemImage: "play") { app.playFromQueue(video) }
                    Button("Remove from Queue", systemImage: "minus.circle") { app.queue.remove(video.id) }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 24, height: 30).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(isCurrent ? AnyShapeStyle(.primary.opacity(0.1)) : hovering ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture { if !isCurrent { app.playFromQueue(video) } }
        .onHover { hovering = $0 }
        .contextMenu {
            if !isPlayed && !isCurrent {
                Button("Remove from Queue", systemImage: "minus.circle") { app.queue.remove(video.id) }
            }
        }
    }
}
