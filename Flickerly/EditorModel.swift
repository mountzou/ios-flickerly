import Combine
import Photos
import PhotosUI
import SwiftUI

struct EditorNotice {
    let title: String
    let message: String
    var offersSettings = false
}

enum PhotoLibraryError: LocalizedError, Equatable {
    case denied
    case restricted

    var errorDescription: String? {
        switch self {
        case .denied:
            "To save photos, allow Flickerly to add photos in Settings."
        case .restricted:
            "Adding photos is restricted on this device."
        }
    }
}

private enum PhotoLibraryWriter {
    static func requestAddAccess() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        switch status {
        case .authorized, .limited: return
        case .restricted: throw PhotoLibraryError.restricted
        default: throw PhotoLibraryError.denied
        }
    }

    static func save(fileURL: URL) async throws {
        // The file must remain available until PhotoKit finishes importing it.
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = fileURL.lastPathComponent
            request.addResource(with: .photo, fileURL: fileURL, options: options)
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var photo: PreparedPhoto?
    @Published private(set) var preview: UIImage?
    @Published private(set) var isImporting = false
    @Published private(set) var isRendering = false
    @Published private(set) var isSaving = false
    @Published private(set) var isPreparingExport = false
    @Published private(set) var exportOptions: [ExportOption] = []
    @Published var notice: EditorNotice?

    @Published var selectedPreset: PhotoPreset = .amber {
        didSet {
            lastPresetByFamily[selectedPreset.family] = selectedPreset
            scheduleRender()
        }
    }

    @Published var intensity: Double = 0.8 {
        didSet { scheduleRender() }
    }

    private struct PreviewRequest {
        let preset: PhotoPreset
        let intensity: Double
    }

    private let renderer: any PhotoRendering
    private let previewFrameInterval: Duration
    private let previewClock = ContinuousClock()
    private var nextPreviewFrame: ContinuousClock.Instant?
    private var pendingPreview: PreviewRequest?
    private var previewWorkerID: UUID?
    private var importTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportRequestID: UUID?
    private var lastPresetByFamily: [PhotoPresetFamily: PhotoPreset] = [.originals: .amber]

    init(
        renderer: any PhotoRendering = PhotoRenderer(),
        previewFrameInterval: Duration = .nanoseconds(16_666_667),
        initialPreset: PhotoPreset = .amber
    ) {
        self.renderer = renderer
        self.previewFrameInterval = previewFrameInterval
        self.selectedPreset = initialPreset
        self.lastPresetByFamily = [initialPreset.family: initialPreset]
    }

    var hasPhoto: Bool { photo != nil }
    var selectedFamily: PhotoPresetFamily { selectedPreset.family }

    func selectFamily(_ family: PhotoPresetFamily) {
        guard !isImporting, !isSaving,
              let preset = lastPresetByFamily[family] ?? family.presets.first else { return }
        selectedPreset = preset
    }

    func importPhoto(_ selection: PhotosPickerItem) {
        startImport {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw PhotoError.unreadableImage
            }
            return data
        }
    }

    func importPhoto(data: Data) {
        startImport { data }
    }

    private func startImport(load: @escaping @MainActor () async throws -> Data) {
        guard !isSaving else { return }
        importTask?.cancel()
        cancelPreviewUpdates()
        isImporting = true

        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await load()
                try Task.checkCancellation()
                let prepared = try await renderer.prepare(data: data)
                try Task.checkCancellation()
                let rendered = try await renderer.blend(
                    photo: prepared, preset: selectedPreset, intensity: intensity
                )
                try Task.checkCancellation()
                photo = prepared
                preview = UIImage(cgImage: rendered)
                isImporting = false
            } catch is CancellationError {
                // A newer selection owns the loading state and the preview.
            } catch {
                guard !Task.isCancelled else { return }
                isImporting = false
                showError(error)
            }
        }
    }

    func resetIntensity() {
        intensity = 0.8
    }

    func prepareExportOptions() {
        guard let photo, !isImporting, !isSaving else { return }
        cancelExportOptions()
        let preset = selectedPreset
        let amount = intensity
        let requestID = UUID()
        exportRequestID = requestID
        isPreparingExport = true
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = try await renderer.exportOptions(photo: photo, preset: preset, intensity: amount)
                guard !Task.isCancelled, exportRequestID == requestID else {
                    for option in options { try? FileManager.default.removeItem(at: option.url) }
                    return
                }
                exportOptions = options
                isPreparingExport = false
            } catch is CancellationError {
                return
            } catch {
                guard exportRequestID == requestID else { return }
                isPreparingExport = false
                showError(error)
            }
        }
    }

    func cancelExportOptions() {
        exportTask?.cancel()
        exportTask = nil
        exportRequestID = nil
        isPreparingExport = false
        for option in exportOptions { try? FileManager.default.removeItem(at: option.url) }
        exportOptions = []
    }

    func savePhoto(_ option: ExportOption) {
        guard exportOptions.contains(where: { $0.url == option.url }), !isSaving else { return }
        exportOptions.removeAll { $0.url == option.url }
        cancelExportOptions()
        isSaving = true
        notice = nil

        saveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: option.url)
                isSaving = false
            }
            do {
                try await PhotoLibraryWriter.requestAddAccess()
                try await PhotoLibraryWriter.save(fileURL: option.url)
                notice = EditorNotice(
                    title: "Saved",
                    message: "A new copy was saved to Photos."
                )
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        notice = EditorNotice(
            title: "Something went wrong",
            message: (error as? PhotoError)?.errorDescription
                ?? (error as? PhotoLibraryError)?.errorDescription
                ?? "We couldn't complete this action. Please try again.",
            offersSettings: (error as? PhotoLibraryError) == .denied
        )
    }

    private func scheduleRender() {
        guard hasPhoto, !isImporting, !isSaving else { return }
        // One pending slot: new input replaces waiting input, never active work.
        pendingPreview = PreviewRequest(preset: selectedPreset, intensity: intensity)
        guard renderTask == nil else { return }

        let workerID = UUID()
        previewWorkerID = workerID
        isRendering = true

        renderTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // An old photo's worker must not clear the new photo's worker.
                if previewWorkerID == workerID {
                    renderTask = nil
                    previewWorkerID = nil
                    isRendering = false
                }
            }

            while pendingPreview != nil, !Task.isCancelled {
                do {
                    // Pace from the last frame's start, not from slider input.
                    // Input can keep changing while this fixed deadline stays put.
                    if let deadline = nextPreviewFrame, previewClock.now < deadline {
                        try await previewClock.sleep(until: deadline, tolerance: .milliseconds(1))
                    }
                    try Task.checkCancellation()
                    guard previewWorkerID == workerID, !isImporting,
                          let photo, let request = pendingPreview else { return }
                    pendingPreview = nil
                    nextPreviewFrame = previewClock.now.advanced(by: previewFrameInterval)

                    let rendered = try await renderer.blend(
                        photo: photo, preset: request.preset, intensity: request.intensity
                    )
                    try Task.checkCancellation()
                    guard previewWorkerID == workerID, !isImporting else { return }

                    // Publish completed frames even when newer intensity is waiting.
                    // Dropping them would starve the preview throughout a fast drag.
                    preview = UIImage(cgImage: rendered)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, previewWorkerID == workerID else { return }
                    pendingPreview = nil
                    showError(error)
                    return
                }
            }
        }
    }

    private func cancelPreviewUpdates() {
        renderTask?.cancel()
        renderTask = nil
        previewWorkerID = nil
        pendingPreview = nil
        nextPreviewFrame = nil
        isRendering = false
    }
}
