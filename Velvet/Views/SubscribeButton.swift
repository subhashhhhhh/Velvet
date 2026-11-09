import SwiftUI

/// Subscribe, or once subscribed, YouTube's "🔔 Subscribed ⌄" menu: the notification bell
/// (All / Personalized / None) and Unsubscribe (confirmed first).
struct SubscribeButton: View {
    let channelName: String
    let isSubscribed: Bool
    let bell: ChannelBell?
    var onSubscribe: () -> Void
    var onUnsubscribe: () -> Void
    var onBell: (BellSetting) -> Void

    @State private var confirmingUnsubscribe = false

    var body: some View {
        Group {
            if isSubscribed {
                Menu {
                    if let bell {
                        Section("Notifications") {
                            ForEach(BellSetting.allCases) { setting in
                                Button { onBell(setting) } label: {
                                    if bell.setting == setting {
                                        Label(setting.label, systemImage: "checkmark")
                                    } else {
                                        Label(setting.label, systemImage: setting.symbol)
                                    }
                                }
                                .disabled(bell.params[setting] == nil)
                            }
                        }
                    }
                    Divider()
                    Button("Unsubscribe", systemImage: "person.badge.minus", role: .destructive) { confirmingUnsubscribe = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: bell?.setting?.symbol ?? "checkmark")
                        Text("Subscribed")
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(PillButtonStyle())
                .background(.quaternary, in: Capsule())
                .fixedSize()
                .help(bell?.setting.map { "Notifications: \($0.label)" } ?? "Subscribed")
            } else {
                Button("Subscribe", action: onSubscribe)
                    .buttonStyle(PillButtonStyle())
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .background(.primary, in: Capsule())
            }
        }
        .confirmationDialog("Unsubscribe from \(channelName)?", isPresented: $confirmingUnsubscribe) {
            Button("Unsubscribe", role: .destructive, action: onUnsubscribe)
        }
    }
}
