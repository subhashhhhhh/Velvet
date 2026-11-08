import Foundation
import Observation

// MARK: - Option types

nonisolated enum VideoQuality: Int, CaseIterable, Identifiable, Codable, Sendable {
    case auto = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480, p360 = 360
    var id: Int { rawValue }
    var label: String { self == .auto ? "Best for This Display" : (self == .p2160 ? "2160p (4K)" : "\(rawValue)p") }
    /// Max height to request; nil means no cap.
    var maxHeight: Int? { self == .auto ? nil : rawValue }
}

nonisolated enum VideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, av1, vp9, h264
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .h264: "H.264"
        }
    }
    var detail: String {
        switch self {
        case .auto: "Best quality the Mac can decode in hardware."
        case .av1: "Smallest files. Hardware decoding needs M3 or newer."
        case .vp9: "Good quality, hardware decoded on Apple silicon."
        case .h264: "Most compatible, but YouTube caps it at 1080p."
        }
    }
}

nonisolated enum CardSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case compact, regular, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var minWidth: Double {
        switch self {
        case .compact: 210
        case .regular: 260
        case .large: 330
        }
    }
}

nonisolated enum JSRuntime: String, CaseIterable, Identifiable, Codable, Sendable {
    case deno, bun, quickjs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .deno: "Deno (recommended)"
        case .bun: "Bun"
        case .quickjs: "QuickJS"
        }
    }
    var detail: String {
        switch self {
        case .deno: "Sandboxed and fast. yt-dlp's default; maintained until ~Oct 2027."
        case .bun: "Fast, but runs YouTube's code without a sandbox."
        case .quickjs: "Tiny (~2 MB) but slow on YouTube's player script."
        }
    }
}

nonisolated enum SponsorCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-Promotion"
        case .interaction: "Interaction Reminder"
        case .intro: "Intro"
        case .outro: "Endcards / Credits"
        case .preview: "Preview / Recap"
        case .music_offtopic: "Non-Music in Music Videos"
        case .filler: "Filler Tangent"
        }
    }
    var defaultAction: SponsorAction {
        switch self {
        case .sponsor, .selfpromo, .interaction: .skip
        case .intro, .outro, .preview, .music_offtopic: .ask
        case .filler: .ignore
        }
    }
}

nonisolated enum SponsorAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case skip, ask, ignore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .skip: "Skip Automatically"
        case .ask: "Show Skip Button"
        case .ignore: "Do Nothing"
        }
    }
}

// MARK: - Store

/// All user preferences, persisted to UserDefaults on every change.
@Observable
final class Preferences {
    // General
    var startPage: Destination { didSet { save(startPage.rawValue, .startPage) } }

    // Feed
    var showShortsShelf: Bool { didSet { save(showShortsShelf, .showShortsShelf) } }
    var shortsAfterRows: Int { didSet { save(shortsAfterRows, .shortsAfterRows) } }
    var cardSize: CardSize { didSet { save(cardSize.rawValue, .cardSize) } }
    var hideWatched: Bool { didSet { save(hideWatched, .hideWatched) } }

    // Playback
    var quality: VideoQuality { didSet { save(quality.rawValue, .quality) } }
    var codec: VideoCodec { didSet { save(codec.rawValue, .codec) } }
    var defaultSpeed: Double { didSet { save(defaultSpeed, .defaultSpeed) } }
    var autoplay: Bool { didSet { save(autoplay, .autoplay) } }
    var hardwareDecoding: Bool { didSet { save(hardwareDecoding, .hardwareDecoding) } }
    var bufferMB: Int { didSet { save(bufferMB, .bufferMB) } }
    var prefetchOnHover: Bool { didSet { save(prefetchOnHover, .prefetchOnHover) } }
    var autoPictureInPicture: Bool { didSet { save(autoPictureInPicture, .autoPictureInPicture) } }
    var pipOnScroll: Bool { didSet { save(pipOnScroll, .pipOnScroll) } }
    var autoCaptions: Bool { didSet { save(autoCaptions, .autoCaptions) } }

    // SponsorBlock
    var sponsorBlockEnabled: Bool { didSet { save(sponsorBlockEnabled, .sponsorBlockEnabled) } }
    var sponsorActions: [SponsorCategory: SponsorAction] { didSet { saveCodable(sponsorActions, .sponsorActions) } }
    var showSkipNotice: Bool { didSet { save(showSkipNotice, .showSkipNotice) } }
    var sponsorBlockServer: String { didSet { save(sponsorBlockServer, .sponsorBlockServer) } }

    // DeArrow
    var deArrowTitles: Bool { didSet { save(deArrowTitles, .deArrowTitles) } }
    var deArrowThumbnails: DeArrowThumbnailMode { didSet { save(deArrowThumbnails.rawValue, .deArrowThumbnails) } }
    var deArrowOriginalOnHover: Bool { didSet { save(deArrowOriginalOnHover, .deArrowOriginalOnHover) } }
    var deArrowEnabled: Bool { deArrowTitles || deArrowThumbnails != .off }

    // Advanced
    var jsRuntime: JSRuntime { didSet { save(jsRuntime.rawValue, .jsRuntime) } }
    var autoUpdateTools: Bool { didSet { save(autoUpdateTools, .autoUpdateTools) } }

    static let defaultSponsorServer = "https://sponsor.ajay.app"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func get<T>(_ key: Key, _ fallback: T) -> T { defaults.object(forKey: key.name) as? T ?? fallback }

        startPage = Destination(rawValue: get(.startPage, "")) ?? .home
        showShortsShelf = get(.showShortsShelf, true)
        shortsAfterRows = get(.shortsAfterRows, 3)
        cardSize = CardSize(rawValue: get(.cardSize, "")) ?? .regular
        hideWatched = get(.hideWatched, false)

        quality = VideoQuality(rawValue: get(.quality, 1080)) ?? .p1080
        codec = VideoCodec(rawValue: get(.codec, "")) ?? .auto
        defaultSpeed = get(.defaultSpeed, 1.0)
        autoplay = get(.autoplay, true)
        hardwareDecoding = get(.hardwareDecoding, true)
        bufferMB = get(.bufferMB, 150)
        prefetchOnHover = get(.prefetchOnHover, true)
        autoPictureInPicture = get(.autoPictureInPicture, true)
        pipOnScroll = get(.pipOnScroll, true)
        autoCaptions = get(.autoCaptions, false)

        sponsorBlockEnabled = get(.sponsorBlockEnabled, true)
        var actions = Dictionary(uniqueKeysWithValues: SponsorCategory.allCases.map { ($0, $0.defaultAction) })
        if let data = defaults.data(forKey: Key.sponsorActions.name),
           let saved = try? JSONDecoder().decode([SponsorCategory: SponsorAction].self, from: data) {
            actions.merge(saved) { $1 }
        }
        sponsorActions = actions
        showSkipNotice = get(.showSkipNotice, true)
        sponsorBlockServer = get(.sponsorBlockServer, Self.defaultSponsorServer)

        deArrowTitles = get(.deArrowTitles, true)
        deArrowThumbnails = DeArrowThumbnailMode(rawValue: get(.deArrowThumbnails, "")) ?? .random
        deArrowOriginalOnHover = get(.deArrowOriginalOnHover, true)

        jsRuntime = JSRuntime(rawValue: get(.jsRuntime, "")) ?? .deno
        autoUpdateTools = get(.autoUpdateTools, true)
    }

    func sponsorAction(for category: SponsorCategory) -> SponsorAction {
        sponsorActions[category] ?? category.defaultAction
    }

    /// Restores every preference to its default.
    func resetAll() {
        for key in Key.allCases { defaults.removeObject(forKey: key.name) }
        let fresh = Preferences(defaults: defaults)
        startPage = fresh.startPage
        showShortsShelf = fresh.showShortsShelf; shortsAfterRows = fresh.shortsAfterRows
        cardSize = fresh.cardSize; hideWatched = fresh.hideWatched
        quality = fresh.quality; codec = fresh.codec; defaultSpeed = fresh.defaultSpeed
        autoplay = fresh.autoplay; hardwareDecoding = fresh.hardwareDecoding
        bufferMB = fresh.bufferMB; prefetchOnHover = fresh.prefetchOnHover
        autoPictureInPicture = fresh.autoPictureInPicture; pipOnScroll = fresh.pipOnScroll
        autoCaptions = fresh.autoCaptions
        sponsorBlockEnabled = fresh.sponsorBlockEnabled; sponsorActions = fresh.sponsorActions
        showSkipNotice = fresh.showSkipNotice; sponsorBlockServer = fresh.sponsorBlockServer
        deArrowTitles = fresh.deArrowTitles; deArrowThumbnails = fresh.deArrowThumbnails
        deArrowOriginalOnHover = fresh.deArrowOriginalOnHover
        jsRuntime = fresh.jsRuntime; autoUpdateTools = fresh.autoUpdateTools
    }

    // MARK: Persistence

    private enum Key: CaseIterable {
        case startPage, showShortsShelf, shortsAfterRows, cardSize, hideWatched
        case quality, codec, defaultSpeed, autoplay, hardwareDecoding, bufferMB, prefetchOnHover, autoPictureInPicture, pipOnScroll, autoCaptions
        case sponsorBlockEnabled, sponsorActions, showSkipNotice, sponsorBlockServer
        case deArrowTitles, deArrowThumbnails, deArrowOriginalOnHover
        case jsRuntime, autoUpdateTools

        var name: String { "settings.\(self)" }
    }

    private func save(_ value: Any, _ key: Key) { defaults.set(value, forKey: key.name) }

    private func saveCodable(_ value: some Encodable, _ key: Key) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key.name)
    }
}
