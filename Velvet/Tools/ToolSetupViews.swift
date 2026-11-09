import SwiftUI

enum ToolProgressText {
    /// "31 of 48 MB", or "31 MB" before the size is known.
    static func bytes(_ received: Int64, _ total: Int64) -> String {
        let mb = { (b: Int64) in String(format: b < 10_000_000 ? "%.1f" : "%.0f", Double(b) / 1_000_000) }
        return total > 0 ? "\(mb(received)) of \(mb(total)) MB" : "\(mb(received)) MB"
    }

    /// One tool's state in a few words, for the setup strip and the player.
    static func status(_ status: ToolManager.Status) -> String {
        switch status {
        case .notInstalled: "Waiting"
        case .working(let step): step.replacingOccurrences(of: "…", with: "")
        case .downloading(let received, let total): bytes(received, total)
        case .installed: "Ready"
        case .failed: "Failed"
        }
    }
}

/// What playback setup is doing, one line per tool: shown on first run and in the player
/// while a video waits for the tools.
struct ToolSetupRows: View {
    @Environment(AppModel.self) private var app
    var onDark = false

    var body: some View {
        let runtime = app.settings.jsRuntime
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ToolManager.needed(runtime: runtime), id: \.self) { tool in
                let status = app.tools.status[tool] ?? .notInstalled
                HStack(spacing: 10) {
                    Text(tool.displayName)
                        .frame(width: 56, alignment: .leading)
                    bar(status)
                        .frame(width: 140)
                    Group {
                        if case .installed = status {
                            Image(systemName: "checkmark").fontWeight(.semibold)
                        } else {
                            Text(ToolProgressText.status(status)).monospacedDigit()
                        }
                    }
                    .foregroundStyle(onDark ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 90, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func bar(_ status: ToolManager.Status) -> some View {
        let fraction: Double = switch status {
        case .installed: 1
        case .downloading(let received, let total) where total > 0: Double(received) / Double(total)
        default: 0
        }
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(onDark ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(.primary.opacity(0.12)))
                Capsule().fill(onDark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.25), value: fraction)
    }
}
