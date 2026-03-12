import Foundation

struct AdditMetadata: Codable {
    var tracklist: [String]?
    var artist: String?

    static let discMarkerPrefix = "::disc::"
}

enum TracklistItem: Identifiable {
    case track(Track)
    case discMarker(id: UUID, label: String)

    var id: String {
        switch self {
        case .track(let track):
            return track.googleFileId
        case .discMarker(let id, _):
            return "disc-\(id.uuidString)"
        }
    }

    var isDiscMarker: Bool {
        if case .discMarker = self { return true }
        return false
    }

    var asTrack: Track? {
        if case .track(let t) = self { return t }
        return nil
    }
}
