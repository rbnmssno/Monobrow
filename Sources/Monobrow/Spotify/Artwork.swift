import AppKit
import ImageIO

struct Artwork {
    let image: NSImage
    /// A bright colour taken from the cover, used for the equalizer.
    let accent: NSColor
}

/// Downloads a cover once per track, keeps a small downscaled copy and a few recent ones in memory.
final class ArtworkLoader {
    static let neutralAccent = NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.93, alpha: 1)

    /// Created on first use, so the app holds no networking state until a cover is needed.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()
    private var cache: [String: Artwork] = [:]
    private var order: [String] = []
    private let limit = 12
    private var task: URLSessionDataTask?
    private var requestID = 0

    /// The completion runs on the main thread. A newer `load` supersedes an unfinished one,
    /// whose completion is then never called.
    func load(_ url: URL, completion: @escaping (Artwork?) -> Void) {
        task?.cancel()
        requestID += 1
        let key = url.absoluteString
        if let hit = cache[key] {
            touch(key)
            completion(hit)
            return
        }
        fetch(Self.candidates(for: url), key: key, request: requestID, completion: completion)
    }

    func removeAll() {
        task?.cancel()
        requestID += 1
        cache.removeAll()
        order.removeAll()
    }

    /// Spotify hands out the 640 px cover. The island shows it at 56 pt, so the 300 px file is tried first.
    static func candidates(for url: URL) -> [URL] {
        let large = "ab67616d0000b273"
        let medium = "ab67616d00001e02"
        let text = url.absoluteString
        if url.host == "i.scdn.co", text.contains(large),
           let smaller = URL(string: text.replacingOccurrences(of: large, with: medium)) {
            return [smaller, url]
        }
        return [url]
    }

    private func fetch(_ urls: [URL], key: String, request: Int, completion: @escaping (Artwork?) -> Void) {
        guard let url = urls.first else {
            completion(nil)
            return
        }
        let rest = Array(urls.dropFirst())
        let task = session.dataTask(with: url) { [weak self] data, response, _ in
            var artwork: Artwork?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                artwork = Self.decode(data)
            }
            DispatchQueue.main.async {
                guard let self, request == self.requestID else { return }
                if let artwork {
                    self.store(artwork, key: key)
                    completion(artwork)
                } else {
                    self.fetch(rest, key: key, request: request, completion: completion)
                }
            }
        }
        self.task = task
        task.resume()
    }

    private func store(_ artwork: Artwork, key: String) {
        cache[key] = artwork
        touch(key)
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    static func decode(_ data: Data) -> Artwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = NSSize(width: image.width, height: image.height)
        return Artwork(image: NSImage(cgImage: image, size: size), accent: accentColor(of: image))
    }

    /// Averages the hue of the vivid pixels and returns it as a light, readable colour for a black background.
    static func accentColor(of image: CGImage) -> NSColor {
        let side = 20
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return neutralAccent }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = context.data else { return neutralAccent }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var sumX = 0.0, sumY = 0.0, weightSum = 0.0, saturationSum = 0.0
        for index in 0..<(side * side) {
            let r = Double(pixels[index * 4]) / 255
            let g = Double(pixels[index * 4 + 1]) / 255
            let b = Double(pixels[index * 4 + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let delta = high - low
            guard high > 0.1, delta > 0.04 else { continue }
            let saturation = delta / high
            var hue: Double
            if high == r {
                hue = (g - b) / delta
            } else if high == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue *= Double.pi / 3
            let weight = saturation * saturation * (0.3 + 0.7 * high)
            sumX += cos(hue) * weight
            sumY += sin(hue) * weight
            weightSum += weight
            saturationSum += saturation * weight
        }
        // Mostly grey cover: a tint would be arbitrary.
        guard weightSum > 3 else { return neutralAccent }
        var hue = atan2(sumY, sumX) / (2 * Double.pi)
        if hue < 0 { hue += 1 }
        let coherence = (sumX * sumX + sumY * sumY).squareRoot() / weightSum
        let saturation = (saturationSum / weightSum).clamped(0.4, 0.72) * (0.55 + 0.45 * coherence)
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: 1, alpha: 1)
    }
}
