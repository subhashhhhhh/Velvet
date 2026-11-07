import SwiftUI

struct ChannelView: View {
    let model: ChannelModel
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: PlaylistSummary.self) { PlaylistDetailView(summary: $0) }
        }
        .navigationTitle(model.header?.name ?? "Channel")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { app.closeChannel() }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        .task { await model.load() }
        .alert("Couldn't Complete That", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: { Text(model.actionError ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let header = model.header {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ChannelHeaderView(header: header, model: model)
                    if !header.tabs.isEmpty {
                        tabBar(header.tabs)
                    }
                    if let tab = model.currentTab {
                        ChannelTabGrid(content: tab).id(tab.tab.id)
                    }
                }
                .padding(20)
            }
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Couldn't Load Channel", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: { Text(error) }
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabBar(_ tabs: [ChannelTab]) -> some View {
        @Bindable var model = model
        return HStack {
            Picker("Section", selection: $model.selectedTab) {
                ForEach(tabs) { Text($0.title).tag($0.kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let tab = model.currentTab, !tab.chips.isEmpty {
                Menu {
                    ForEach(tab.chips) { chip in
                        Button { Task { await tab.select(chip) } } label: {
                            if chip.selected { Label(chip.title, systemImage: "checkmark") } else { Text(chip.title) }
                        }
                    }
                } label: {
                    Label(tab.selectedChip?.title ?? "Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
    }
}

private struct ChannelHeaderView: View {
    let header: ChannelHeader
    let model: ChannelModel
    @State private var confirmingUnsubscribe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let banner = header.banner {
                RemoteImage(url: banner)
                    .aspectRatio(6.2, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(alignment: .center, spacing: 16) {
                RemoteImage(url: header.avatar)
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(header.name).font(.largeTitle.weight(.bold)).lineLimit(1)
                    Text([header.handle, header.subscribers, header.videoCount].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let d = header.description, !d.isEmpty {
                        Text(d).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
                Spacer()
                subscribeButton
            }
        }
        .confirmationDialog("Unsubscribe from \(header.name)?", isPresented: $confirmingUnsubscribe) {
            Button("Unsubscribe", role: .destructive) { model.setSubscribed(false) }
        }
    }

    @ViewBuilder
    private var subscribeButton: some View {
        if model.isSubscribed {
            Button { confirmingUnsubscribe = true } label: { Label("Subscribed", systemImage: "checkmark") }
                .buttonStyle(.bordered)
                .controlSize(.large)
        } else {
            Button("Subscribe") { model.setSubscribed(true) }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .controlSize(.large)
        }
    }
}

private struct ChannelTabGrid: View {
    let content: ChannelTabContent
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if content.isEmpty {
                if content.isLoading || !content.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                } else if let error = content.error {
                    ContentUnavailableView("Couldn't Load", systemImage: "wifi.exclamationmark", description: Text(error))
                } else {
                    ContentUnavailableView("Nothing Here", systemImage: "tray")
                }
            } else {
                switch content.tab.kind {
                case .shorts:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(content.shorts) { s in
                            Button { app.open(s) } label: { ShortCard(video: s) }.buttonStyle(.plain)
                                .onAppear { if s.id == content.shorts.last?.id { Task { await content.loadMore() } } }
                        }
                    }
                case .playlists:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 16, alignment: .top)], spacing: 20) {
                        ForEach(content.playlists) { p in
                            NavigationLink(value: p) { PlaylistCard(playlist: p) }.buttonStyle(.plain)
                                .onAppear { if p.id == content.playlists.last?.id { Task { await content.loadMore() } } }
                        }
                    }
                case .videos, .live:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: app.settings.cardSize.minWidth, maximum: 420), spacing: 14, alignment: .top)], spacing: 18) {
                        ForEach(content.videos) { v in
                            Button { app.open(v) } label: { VideoCard(video: v) }.buttonStyle(.plain)
                                .onAppear { if v.id == content.videos.last?.id { Task { await content.loadMore() } } }
                        }
                    }
                }
                if content.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
        }
        .task { await content.loadIfNeeded() }
    }
}
