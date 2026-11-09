import SwiftUI

/// The search box's dropdown: what YouTube suggests for what's typed, with your account's
/// past searches (from any device) first, as youtube.com shows them. Drawn at the window's
/// top level (RootView), not inside the top bar, so the watch page's player, which floats
/// above the page, can't cover it.
@Observable
final class SearchAssist {
    /// The search field is being typed in (the dropdown shows only then).
    var isActive = false {
        didSet { if isActive && !oldValue { queryChanged(lastQuery) } }
    }
    /// Where the search field is, in window coordinates; the dropdown hangs below it.
    var fieldFrame: CGRect = .zero
    /// Where the dropdown is (window coordinates); a click outside both closes it.
    @ObservationIgnored var dropdownFrame: CGRect = .zero
    /// The list is on screen.
    var isShowing: Bool { isActive && !rows.isEmpty }

    /// Clicking the field: shows your recent searches (or the suggestions for what's typed),
    /// and hides them on the next click.
    func toggleFromClick(query: String) {
        if isShowing { isActive = false } else { isActive = true; queryChanged(query) }
    }
    /// The row picked with ↑/↓ (nil: what's typed).
    var highlighted: Int?

    private(set) var rows: [Row] = []

    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let account: () async -> YouTubeSession?
    @ObservationIgnored private var fetch: Task<Void, Never>?
    @ObservationIgnored private var lastQuery = ""
    /// Reads the full history from My Activity, for the signed-in account it was made for.
    @ObservationIgnored private var myActivity: (account: YouTubeSession, reader: MyActivitySearches)?
    /// Searches made in Velvet this run, newest first: shown before My Activity has caught up.
    @ObservationIgnored private var justSearched: [String] = []

    init(client: InnerTubeClient, preferences: Preferences, account: @escaping () async -> YouTubeSession?) {
        self.client = client
        prefs = preferences
        self.account = account
    }

    /// A search was made: it goes to the top of your history now, and My Activity is read
    /// again next time.
    func searched(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        justSearched.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        justSearched.insert(q, at: 0)
        if justSearched.count > 10 { justSearched.removeLast() }
        if let reader = myActivity?.reader { Task { await reader.invalidate() } }
    }

    /// Loads the My Activity history in the background (at sign-in), since reading it takes
    /// a few seconds.
    func prefetchHistory() {
        guard prefs.searchSuggestions else { return }
        Task { _ = await myActivityReader()?.recent() }
    }

    private func myActivityReader() async -> MyActivitySearches? {
        guard prefs.searchHistoryFromMyActivity, let session = await account() else { return nil }
        if let myActivity, myActivity.account === session { return myActivity.reader }
        let reader = MyActivitySearches(account: session)
        myActivity = (session, reader)
        return reader
    }

    struct Row: Hashable {
        let text: String
        /// One of your past searches (any device) rather than a general suggestion.
        let isHistory: Bool
    }

    /// Typing (or opening the field): fetch after a short pause, not on every keystroke. An
    /// empty box asks too: signed in, YouTube answers with your recent searches.
    func queryChanged(_ query: String) {
        lastQuery = query
        highlighted = nil
        fetch?.cancel()
        guard prefs.searchSuggestions, isActive else { rows = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        fetch = Task {
            try? await Task.sleep(for: .milliseconds(q.isEmpty ? 0 : 120))
            guard !Task.isCancelled else { return }
            let reader = await myActivityReader()
            async let mine = reader?.recent() ?? []
            async let found = Self.suggestions(for: q, client: client)
            let merged = Self.merge(query: q, history: justSearched + (await mine), suggestions: await found)
            guard !Task.isCancelled else { return }
            rows = merged
        }
    }

    /// ↑/↓ in the field.
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (highlighted ?? (delta > 0 ? -1 : rows.count)) + delta
        highlighted = next < 0 || next >= rows.count ? nil : next
    }

    /// Your own searches first (all of them with an empty box; those starting with what's
    /// typed otherwise), then YouTube's list, without repeats.
    nonisolated private static func merge(query: String, history: [String], suggestions: [Row]) -> [Row] {
        let q = query.lowercased()
        var seen = Set<String>(), rows: [Row] = []
        func add(_ row: Row) {
            if seen.insert(row.text.lowercased()).inserted { rows.append(row) }
        }
        let mine = history.filter { q.isEmpty || ($0.lowercased().hasPrefix(q) && $0.count > q.count) }
        for text in mine.prefix(q.isEmpty ? 10 : 4) { add(Row(text: text, isHistory: true)) }
        for row in suggestions { add(row) }
        return Array(rows.prefix(10))
    }

    /// youtube.com's suggestion service, with the account's cookies:
    /// ["q", [["text", 0, [subtypes…], {…}], …]]. General suggestions carry subtype 512; your
    /// own past searches don't (signed out, an empty query returns nothing).
    @concurrent
    private static func suggestions(for query: String, client: InnerTubeClient) async -> [Row] {
        var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "youtube"), URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "gs_ri", value: "youtube"), URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "xhr", value: "t"), URLQueryItem(name: "q", value: query),
        ]
        guard let url = components?.url,
              let data = try? await client.get(url),
              let json = try? JSON(data: data) else { return [] }
        return json[1].array.prefix(10).compactMap { item in
            guard let text = item[0].string else { return nil }
            let subtypes = item[2].array.compactMap(\.int)
            return Row(text: text, isHistory: !subtypes.contains(512))
        }
    }
}

/// The dropdown itself, under the search field.
struct SearchSuggestionsDropdown: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let assist = app.searchAssist
        let rows = assist.isActive ? assist.rows : []
        GeometryReader { geo in
            if !rows.isEmpty {
                let origin = geo.frame(in: .global).origin
                let field = assist.fieldFrame
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element) { i, row in
                        SuggestionRow(row: row, query: app.searchText, isHighlighted: assist.highlighted == i) {
                            app.pickSuggestion(row.text)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(width: field.width)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                // Measured before the offset moves it under the field (a frame doesn't follow
                // an offset), so the real place is the field's corner plus this size.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    assist.dropdownFrame = CGRect(origin: CGPoint(x: field.minX, y: field.maxY + 6), size: size)
                }
                .offset(x: field.minX - origin.x, y: field.maxY - origin.y + 6)
            }
        }
        .ignoresSafeArea()
    }
}

private struct SuggestionRow: View {
    let row: SearchAssist.Row
    let query: String
    let isHighlighted: Bool
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.isHistory ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            highlightedText
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background((hovering || isHighlighted) ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onHover { hovering = $0 }
    }

    /// What's typed in regular weight, the rest of the suggestion bold (as YouTube does).
    private var highlightedText: Text {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, row.text.lowercased().hasPrefix(q) {
            let typed = String(row.text.prefix(q.count))
            let rest = String(row.text.dropFirst(q.count))
            return Text("\(typed)\(Text(rest).fontWeight(.semibold))")
        }
        return Text(row.text)
    }
}
