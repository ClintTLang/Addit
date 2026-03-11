import Foundation
import UIKit

@Observable
final class AlbumArtService {
    var driveService: GoogleDriveService?

    private let fileManager = FileManager.default
    private let memoryCache = NSCache<NSString, UIImage>()

    private var cacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AlbumArt", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func image(for fileId: String) async -> UIImage? {
        if let cached = memoryCache.object(forKey: fileId as NSString) {
            return cached
        }

        let localURL = cacheDirectory.appendingPathComponent("\(fileId).jpg")
        if let data = try? Data(contentsOf: localURL), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: fileId as NSString)
            return image
        }

        guard let driveService else { return nil }
        do {
            let data = try await driveService.downloadFileData(fileId: fileId)
            guard let image = UIImage(data: data) else { return nil }
            memoryCache.setObject(image, forKey: fileId as NSString)
            try? data.write(to: localURL, options: [.atomic])
            return image
        } catch {
            return nil
        }
    }
}
