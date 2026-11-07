import Foundation
import ImageIO
import CoreGraphics
import OSLog

/// Loads remote images decoded straight to their display size.
///
/// A home feed is mostly thumbnails, so this is where memory is won or lost:
/// - images are decoded with ImageIO's thumbnailing, never at full resolution
/// - decoded bitmaps live in a cost-limited cache (evicted under pressure)
/// - downloaded bytes go to a disk cache only, never an in-memory one
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let log = Logger(subsystem: "com.subhash.Velvet", category: "Images")

    init(memoryBudgetMB: Int = 48, diskBudgetMB: Int = 300) {
        let cfg = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.subhash.Velvet/images", directoryHint: .isDirectory)
        cfg.urlCache = URLCache(memoryCapacity: 0, diskCapacity: diskBudgetMB << 20, directory: dir)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
        cache.totalCostLimit = memoryBudgetMB << 20
    }

    /// Returns `url` decoded so its longest side is at most `maxPixel` pixels.
    func image(for url: URL, maxPixel: Int) async -> CGImage? {
        // Bucket sizes so slightly different layouts share cache entries.
        let bucket = max(64, ((maxPixel + 63) / 64) * 64)
        let key = "\(bucket)|\(url.absoluteString)"
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        if let running = inFlight[key] { return await running.value }

        let task = Task<CGImage?, Never> { [session, log] in
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
                return Self.downsample(data, maxPixel: bucket)
            } catch {
                if !(error is CancellationError) {
                    log.debug("Image failed: \(url.lastPathComponent, privacy: .public) \(error.localizedDescription, privacy: .public)")
                }
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    func clearMemory() { cache.removeAllObjects() }

    /// Drops decoded images and the on-disk download cache.
    func clearAll() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// NSCache needs a class; CGImage is immutable, so sharing it is safe.
private nonisolated final class CGImageBox: Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
