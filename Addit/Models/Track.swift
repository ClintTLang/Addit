import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var googleFileId: String
    var name: String
    var album: Album?
    var durationSeconds: Double?
    var mimeType: String
    var fileSize: Int64?
    var trackNumber: Int
    var modifiedTime: String?
    var localFilePath: String?

    init(googleFileId: String, name: String, album: Album? = nil,
         durationSeconds: Double? = nil, mimeType: String,
         fileSize: Int64? = nil, trackNumber: Int, modifiedTime: String? = nil,
         localFilePath: String? = nil) {
        self.googleFileId = googleFileId
        self.name = name
        self.album = album
        self.durationSeconds = durationSeconds
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.trackNumber = trackNumber
        self.modifiedTime = modifiedTime
        self.localFilePath = localFilePath
    }

    var isLocal: Bool { localFilePath != nil }

    var localFileURL: URL? {
        guard let localFilePath else { return nil }
        return URL(fileURLWithPath: localFilePath)
    }

    var fileExtension: String {
        (name as NSString).pathExtension.uppercased()
    }

    var formattedModifiedDate: String? {
        guard let modifiedTime else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: modifiedTime) ?? {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: modifiedTime)
        }()
        guard let date else { return nil }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }

    var displayName: String {
        let nameWithoutExt = (name as NSString).deletingPathExtension
        return nameWithoutExt
    }
}
