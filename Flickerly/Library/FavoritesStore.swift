import Combine
import Foundation

/// Only stable preset identifiers are written to the app's local container.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var presets: Set<PhotoPreset>
    @Published var notice: EditorNotice?
    let storageURL: URL

    init(storageURL: URL = URL.applicationSupportDirectory.appending(path: "FavoriteFilters.json")) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let identifiers = try? JSONDecoder().decode([String].self, from: data) {
            presets = Set(identifiers.compactMap(PhotoPreset.init(rawValue:)))
        } else {
            presets = []
        }
    }

    /// Catalog order stays stable when a look is bookmarked in several places.
    var orderedPresets: [PhotoPreset] { PhotoPreset.allCases.filter { presets.contains($0) } }

    func contains(_ preset: PhotoPreset) -> Bool { presets.contains(preset) }

    func toggle(_ preset: PhotoPreset) {
        var updated = presets
        if !updated.insert(preset).inserted { updated.remove(preset) }
        do {
            let data = try JSONEncoder().encode(updated.map(\.rawValue).sorted())
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
            presets = updated
        } catch {
            notice = EditorNotice(
                title: "Couldn't save favorites",
                message: "Your favorites weren't changed. Please try again."
            )
        }
    }
}
