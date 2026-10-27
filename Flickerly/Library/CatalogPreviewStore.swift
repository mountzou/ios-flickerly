import Combine
import CoreGraphics
import Foundation

/// One shared sample, processed with the same recipes as the real editor.
/// Rendering happens on PhotoRenderer's actor; navigation reuses the results.
@MainActor
final class CatalogPreviewStore: ObservableObject {
    @Published private(set) var images: [PhotoPreset: CGImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    static var sampleURL: URL? {
        Bundle.main.url(forResource: "catalog-sample", withExtension: "png", subdirectory: "Catalog")
            ?? Bundle.main.url(forResource: "catalog-sample", withExtension: "png")
    }

    func loadIfNeeded() async {
        guard images.isEmpty, !isLoading else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            guard let url = Self.sampleURL else { throw PhotoError.unreadableImage }
            let data = try Data(contentsOf: url)
            let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(data: data)
            try Task.checkCancellation()
            images = photo.looks
        } catch is CancellationError {
            // A cancelled task can retry on the next appearance.
        } catch {
            failed = true
        }
    }
}
