import Combine
import Foundation
import UIKit

struct PhotoDraft: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let presetID: String
    let intensity: Double
    let isBlackAndWhite: Bool
    let updatedAt: Date
    let sourceFile: String
    let thumbnail: Data

    var preset: PhotoPreset? { PhotoPreset(rawValue: presetID) }
}

enum DraftError: LocalizedError {
    case full, unavailable, invalid

    var errorDescription: String? {
        switch self {
        case .full: "You can keep up to 12 drafts. Delete one from Drafts to make room."
        case .unavailable: "Drafts couldn't be loaded. Your existing files haven't been changed."
        case .invalid: "This draft couldn't be opened. Its files haven't been changed."
        }
    }
}

@MainActor
final class DraftStore: ObservableObject {
    static let limit = 12
    @Published private(set) var drafts: [PhotoDraft] = []
    @Published private(set) var loadFailed = false
    @Published private(set) var isSaving = false
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "PhotoDrafts", directoryHint: .isDirectory)) {
        self.directory = directory
        reload()
    }

    func reload() {
        do {
            let manager = FileManager.default
            guard manager.fileExists(atPath: directory.path) else { drafts = []; loadFailed = false; return }
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let loaded = try files.map { url in
                let draft = try JSONDecoder().decode(PhotoDraft.self, from: Data(contentsOf: url))
                guard url.lastPathComponent == "\(draft.id.uuidString).json",
                      draft.sourceFile == URL(fileURLWithPath: draft.sourceFile).lastPathComponent,
                      draft.preset != nil, (0...1).contains(draft.intensity),
                      manager.fileExists(atPath: directory.appending(path: draft.sourceFile).path) else { throw DraftError.invalid }
                return draft
            }
            drafts = loaded.sorted { $0.updatedAt > $1.updatedAt }
            loadFailed = false
        } catch { loadFailed = true }
    }

    func source(for draft: PhotoDraft) throws -> Data {
        guard drafts.contains(where: { $0.id == draft.id }) else { throw DraftError.invalid }
        return try Data(contentsOf: directory.appending(path: draft.sourceFile))
    }

    func save(id: UUID?, source: Data, preset: PhotoPreset, intensity: Double,
              isBlackAndWhite: Bool, thumbnail: Data, lastEditedAt: Date? = nil) async throws -> UUID {
        guard !loadFailed, !isSaving else { throw DraftError.unavailable }
        let existing = id.flatMap { wanted in drafts.first { $0.id == wanted } }
        guard existing != nil || drafts.count < Self.limit else { throw DraftError.full }
        let draftID = existing?.id ?? UUID()
        let sourceFile = "\(draftID.uuidString)-\(UUID().uuidString).image"
        let draft = PhotoDraft(id: draftID, presetID: preset.rawValue, intensity: intensity,
                               isBlackAndWhite: isBlackAndWhite, updatedAt: lastEditedAt ?? existing?.updatedAt ?? Date(),
                               sourceFile: sourceFile, thumbnail: thumbnail)
        let directory = self.directory
        isSaving = true
        defer { isSaving = false }
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appending(path: sourceFile)
            do {
                try source.write(to: sourceURL, options: .atomic)
                let metadata = try JSONEncoder().encode(draft)
                try metadata.write(to: directory.appending(path: "\(draftID.uuidString).json"), options: .atomic)
            } catch {
                try? manager.removeItem(at: sourceURL)
                throw error
            }
            if let existing { try? manager.removeItem(at: directory.appending(path: existing.sourceFile)) }
        }.value
        drafts.removeAll { $0.id == draftID }
        drafts.append(draft)
        drafts.sort { $0.updatedAt > $1.updatedAt }
        return draftID
    }

    func delete(_ draft: PhotoDraft) throws {
        guard !loadFailed, !isSaving, drafts.contains(where: { $0.id == draft.id }) else { throw DraftError.unavailable }
        try FileManager.default.removeItem(at: directory.appending(path: "\(draft.id.uuidString).json"))
        drafts.removeAll { $0.id == draft.id }
        try? FileManager.default.removeItem(at: directory.appending(path: draft.sourceFile))
    }
}
