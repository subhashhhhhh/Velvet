import SwiftUI

/// The toolbar bell: YouTube's notification inbox in a popover, with an unread badge.
struct InboxButton: View {
    @Environment(AppModel.self) private var app

    private var inbox: InboxModel { app.inbox }

    var body: some View {
        @Bindable var app = app
        Button { app.showingInbox.toggle() } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if inbox.badge > 0 {
                        Text(inbox.badge > 9 ? "9+" : "\(inbox.badge)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(.red, in: Capsule())
                            .offset(x: 8, y: -7)
                    }
                }
        }
        .help(inbox.badge > 0 ? "Notifications (\(inbox.badge) new)" : "Notifications")
        .popover(isPresented: $app.showingInbox, arrowEdge: .bottom) {
            InboxPopover { app.showingInbox = false }
        }
    }
}

private struct InboxPopover: View {
    var dismiss: () -> Void
    @Environment(AppModel.self) private var app

    private var inbox: InboxModel { app.inbox }

    /// YouTube's inbox mixes new videos (uploads, live, premieres) with activity on your comments.
    private enum Tab: Hashable { case videos, comments }
    @State private var tab: Tab = {
        #if DEBUG
        // `-VelvetInboxTab comments` (with -VelvetInboxTest) opens on the Comments tab.
        if UserDefaults.standard.string(forKey: "VelvetInboxTab") == "comments" { return .comments }
        #endif
        return .videos
    }()

    private var shown: [InboxNotification] {
        inbox.items.filter { $0.isComment == (tab == .comments) }
    }

    private func unread(_ tab: Tab) -> Int {
        inbox.items.filter { !$0.isRead && $0.isComment == (tab == .comments) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                Button("Mark All as Read", systemImage: "checkmark.circle") { inbox.markAllRead() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!inbox.hasUnread)
                    .help("Mark all as read")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Picker("", selection: $tab) {
                Text(label("Videos", unread(.videos))).tag(Tab.videos)
                Text(label("Comments", unread(.comments))).tag(Tab.comments)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(width: 440, height: 540)
        .task { await inbox.open() }
    }

    private func label(_ title: String, _ unread: Int) -> String {
        unread > 0 ? "\(title) (\(unread))" : title
    }

    @ViewBuilder
    private var content: some View {
        if inbox.items.isEmpty {
            Group {
                if inbox.isLoading {
                    ProgressView()
                } else if let error = inbox.error {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await inbox.open() } }
                    }
                } else {
                    ContentUnavailableView("No Notifications", systemImage: "bell.slash",
                                           description: Text("Turn on the bell for a channel to hear about its uploads."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { n in
                        InboxRow(notification: n) { open(n) }
                    }
                    footer
                }
                .padding(.vertical, 6)
            }
            .id(tab) // each tab starts at the top
        }
    }

    /// Loads older pages while the end of the list is on screen: comment notifications are
    /// rarer, so their tab may need several pages to fill.
    @ViewBuilder
    private var footer: some View {
        if inbox.canLoadMore {
            ProgressView().controlSize(.small).padding()
                .task(id: inbox.items.count) { await inbox.loadMore() }
        } else if shown.isEmpty {
            Text(tab == .comments ? "No replies or hearts on your comments." : "No new videos.")
                .foregroundStyle(.secondary)
                .padding(.top, 40)
        }
    }

    private func open(_ n: InboxNotification) {
        inbox.markRead(n)
        guard let video = n.video else { return }
        dismiss()
        app.open(video)
    }
}

private struct InboxRow: View {
    let notification: InboxNotification
    var onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(notification.isRead ? .clear : Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 17)
                RemoteImage(url: notification.channelAvatar)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.message)
                        .font(.system(size: 13, weight: notification.isRead ? .regular : .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let sent = notification.sent {
                        Text(sent).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let thumbnail = notification.thumbnail {
                    RemoteImage(url: thumbnail)
                        .frame(width: 112, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}
