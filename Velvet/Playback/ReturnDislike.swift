import Foundation

/// Dislike counts from Return YouTube Dislike (returnyoutubedislikeapi.com), which estimates
/// them from its users' votes and the counts archived before YouTube hid them in 2021.
nonisolated enum ReturnDislikeAPI {
    /// Unlike SponsorBlock and DeArrow, this API has no hash-prefix lookup, so the video ID is
    /// sent as is (only when the setting is on).
    static func dislikes(for videoId: String) async -> Int? {
        guard var components = URLComponents(string: "https://returnyoutubedislikeapi.com/votes") else { return nil }
        components.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Velvet", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSON(data: data) else { return nil }
        return json["dislikes"].int
    }
}
