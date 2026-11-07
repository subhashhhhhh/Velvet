import SwiftUI

/// Live chat beside (or under) a live stream. Stays pinned to the newest message unless
/// you scroll up to read.
struct LiveChatPanel: View {
    let chat: LiveChatModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(chat.isConnected ? Color.red : Color.secondary).frame(width: 8, height: 8)
                Text("Top chat").font(.headline)
                Spacer()
                if let error = chat.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if chat.messages.isEmpty {
                VStack(spacing: 8) {
                    if chat.error == nil { ProgressView().controlSize(.small) }
                    Text(chat.error == nil ? "Waiting for messages…" : "No chat").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(chat.messages) { ChatRow(message: $0) }
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom) // follow new messages while at the bottom
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}

private struct ChatRow: View {
    let message: LiveChatMessage

    var body: some View {
        if let amount = message.paidAmount {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    avatar
                    Text(message.author).font(.caption.weight(.semibold))
                    Spacer()
                    Text(amount).font(.caption.weight(.bold))
                }
                if !message.text.isEmpty { Text(message.text).font(.callout).textSelection(.enabled) }
            }
            .padding(10)
            .foregroundStyle(.black)
            .background(paidColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            HStack(alignment: .top, spacing: 8) {
                avatar
                Text(line)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Author (role-coloured, bold) then the message, as one wrapping line.
    private var line: AttributedString {
        var author = AttributedString(message.author + (message.isVerified ? " ✓" : "") + "  ")
        author.foregroundColor = roleColor
        author.inlinePresentationIntent = .stronglyEmphasized
        return author + AttributedString(message.text)
    }

    private var avatar: some View {
        RemoteImage(url: message.avatar).frame(width: 22, height: 22).clipShape(Circle())
            .channelLink(message.authorChannelId)
    }

    private var roleColor: Color {
        switch message.role {
        case .owner: .yellow
        case .moderator: .blue
        case .member: .green
        case .viewer: .secondary
        }
    }

    /// Super Chat colours arrive as ARGB integers.
    private var paidColor: Color {
        guard let argb = message.paidColor else { return .yellow }
        return Color(red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                     blue: Double(argb & 0xFF) / 255)
    }
}
