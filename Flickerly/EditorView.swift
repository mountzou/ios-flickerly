import PhotosUI
import SwiftUI

struct EditorView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var previews: CatalogPreviewStore
    @EnvironmentObject private var drafts: DraftStore
    @StateObject private var model: EditorModel
    private let isBlackAndWhite: Bool
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsOriginal = false
    @State private var showsPhotoDetail = false
    @State private var showsExportSizes = false
    @State private var showsLeaveConfirmation = false
    @State private var pendingPhoto: PhotosPickerItem?
    @State private var draftID: UUID?
    @State private var isRestoringDraft = false
    @State private var showsDraftLimit = false
    @State private var showsDraftManager = false
    private let initialDraft: PhotoDraft?

    init(initialPreset: PhotoPreset = .amber, isBlackAndWhite: Bool = false, draft: PhotoDraft? = nil) {
        self.isBlackAndWhite = isBlackAndWhite
        self.initialDraft = draft
        _draftID = State(initialValue: draft?.id)
        _model = StateObject(wrappedValue: EditorModel(initialPreset: draft?.preset ?? initialPreset))
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(620, max(1, geometry.size.width - 48))
            let canvasSize = photoCanvasSize(
                availableWidth: contentWidth + (model.hasPhoto ? 32 : 0),
                viewportHeight: geometry.size.height
            )
            ScrollView {
                VStack(spacing: 0) {
                    photoCanvas(size: canvasSize)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, model.hasPhoto ? -16 : 0)
                        .padding(.bottom, 24)

                    presetSection

                    intensitySection
                        .padding(.top, 24)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(width: geometry.size.width)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity)
                    .background(Palette.background)
            }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task { await previews.loadIfNeeded() }
        .task {
            guard let draft = initialDraft, !model.hasPhoto, !model.isImporting else { return }
            do {
                let source = try drafts.source(for: draft)
                isRestoringDraft = true
                model.intensity = draft.intensity
                model.importPhoto(data: source, lastEditedAt: draft.updatedAt)
            } catch {
                model.notice = EditorNotice(title: "Couldn't open draft", message: "The draft is still in your collection. Please try again.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasPhoto { saveBar }
        }
        .fullScreenCover(isPresented: $showsPhotoDetail) {
            if let preview = model.preview, let photo = model.photo {
                PhotoDetailView(
                    editedImage: preview,
                    originalImage: UIImage(cgImage: photo.original),
                    presetName: model.selectedPreset.name,
                    showsOriginal: false
                )
            }
        }
        .sheet(isPresented: $showsExportSizes, onDismiss: { model.cancelExportOptions() }) {
            exportSizeSheet
        }
        .sheet(isPresented: $showsDraftManager) {
            NavigationStack { DraftsView(allowsOpening: false) }
        }
        .alert("Drafts are full", isPresented: $showsDraftLimit) {
            Button("Manage drafts") { showsDraftManager = true }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("You can keep up to 12 drafts. Delete one to make room, then save this edit as a draft.")
        }
        .confirmationDialog(pendingPhoto == nil ? "Leave editor?" : "Change photo?", isPresented: $showsLeaveConfirmation, titleVisibility: .visible) {
            Button("Save draft") { Task { await saveDraftAndContinue() } }
            Button("Discard changes", role: .destructive) { continueAfterDecision() }
            Button("Keep editing") { pendingPhoto = nil }
        } message: {
            Text("Save this edit to Drafts to continue later. Discarding won't delete previously saved drafts or copies in Photos.")
        }
        .onChange(of: model.notice != nil) { _, hasNotice in
            if hasNotice { showsExportSizes = false }
        }
        .onChange(of: selectedPhoto) { _, selection in
            guard let selection, initialDraft == nil else { return }
            selectedPhoto = nil
            if model.hasPhoto {
                pendingPhoto = selection
                showsLeaveConfirmation = true
            } else {
                isRestoringDraft = false
                model.importPhoto(selection)
            }
        }
        .onChange(of: model.photoRevision) { _, _ in
            if isRestoringDraft { isRestoringDraft = false } else { draftID = nil }
        }
        .disabled(drafts.isSaving)
        .accessibilityHidden(model.notice != nil)
        .overlay {
            if drafts.isSaving {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    ProgressView("Saving draft…")
                        .padding(24)
                        .background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
                }
            } else if let notice = model.notice {
                EditorNoticeView(notice: notice, dismiss: { model.notice = nil }) {
                    model.notice = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        }
    }

    private var header: some View {
        let importFont = AppTypography.font(size: 18, weight: .medium)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                let savedDraft = initialDraft.flatMap { initial in
                    drafts.drafts.first { $0.id == initial.id }
                }
                if model.hasUnsavedChanges(comparedTo: savedDraft) {
                    pendingPhoto = nil
                    showsLeaveConfirmation = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(importFont)
                    .frame(width: 46, height: 46)
                    .background(Palette.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(initialDraft == nil ? "Back to collections" : "Back to drafts")
            .accessibilityIdentifier("backToCollections")
            .disabled(model.isImporting || model.isSaving || drafts.isSaving)

            Text("Edit your photo")
                .font(AppTypography.font(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)

            if model.hasPhoto && initialDraft == nil {
                PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                    Image(systemName: "plus")
                        .font(importFont)
                        .frame(width: 46, height: 46)
                        .background(Palette.surface, in: Circle())
                }
                .accessibilityLabel("Change photo")
                .accessibilityIdentifier("importPhoto")
                .disabled(model.isImporting || model.isSaving || drafts.isSaving)
            } else {
                Color.clear
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            }
        }
    }

    private func saveDraftAndContinue() async {
        guard let photo = model.photo, let preview = model.preview else { return }
        let ratio = min(1, 360 / max(preview.size.width, preview.size.height))
        let size = CGSize(width: max(1, preview.size.width * ratio), height: max(1, preview.size.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            preview.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.8) ?? Data()
        do {
            draftID = try await drafts.save(id: draftID, source: photo.sourceData, preset: model.selectedPreset,
                                            intensity: model.intensity, isBlackAndWhite: isBlackAndWhite,
                                            thumbnail: thumbnail, lastEditedAt: model.lastEditedAt)
            continueAfterDecision()
        } catch DraftError.full {
            pendingPhoto = nil
            showsDraftLimit = true
        } catch {
            pendingPhoto = nil
            model.notice = EditorNotice(title: "Couldn't save draft", message: (error as? LocalizedError)?.errorDescription ?? "Your edit is still open. Please try again.")
        }
    }

    private func continueAfterDecision() {
        if let selection = pendingPhoto {
            pendingPhoto = nil
            isRestoringDraft = false
            model.importPhoto(selection)
        } else {
            dismiss()
        }
    }

    private func photoCanvasSize(availableWidth: CGFloat, viewportHeight: CGFloat) -> CGSize {
        guard let photo = model.photo else {
            return CGSize(width: availableWidth, height: max(220, min(viewportHeight * 0.37, 480)))
        }

        // The cached original already has EXIF orientation baked into its pixels.
        let aspectRatio = CGFloat(photo.original.width) / CGFloat(photo.original.height)
        let height = min(availableWidth / aspectRatio, max(280, min(viewportHeight * 0.60, 640)))
        return CGSize(width: height * aspectRatio, height: height)
    }

    private func photoCanvas(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Palette.surface)

            if let preview = model.preview, let photo = model.photo {
                Image(uiImage: showsOriginal ? UIImage(cgImage: photo.original) : preview)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(showsOriginal ? "Original photo" : "Photo with filter \(model.selectedPreset.name)")
                    .accessibilityHint("Touch the photo to temporarily see the original. Use Enlarge photo for comparison controls.")
                    .accessibilityIdentifier("photoPreview")
            } else if !model.isImporting && initialDraft != nil {
                Text("Draft photo unavailable")
                    .font(AppTypography.font(size: 14))
                    .foregroundStyle(Palette.muted)
            } else if !model.isImporting {
                if let sample = previews.images[model.selectedPreset] {
                    Image(decorative: sample, scale: 1)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: size.height)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                    VStack {
                        Spacer()
                        Text("Make it your own.")
                            .font(AppTypography.font(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        choosePhotoButton(onPhoto: true)
                    }
                    .padding(24)
                } else {
                    emptyCanvas
                }
            }

            if model.isImporting {
                Palette.background.opacity(0.72)
                VStack(spacing: 14) {
                    ProgressView().tint(Palette.accent)
                    Text("Preparing your photo…")
                        .font(AppTypography.font(size: 13))
                    Text("If it's in iCloud, this may take a moment.")
                        .font(AppTypography.font(size: 11))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            if model.hasPhoto && !model.isImporting {
                PhotoTouchObserver(enabled: !model.isSaving) { showsOriginal = $0 }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.hasPhoto && !model.isImporting {
                Button { showsPhotoDetail = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(AppTypography.font(size: 15, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enlarge photo")
                .accessibilityIdentifier("enlargePhoto")
                .disabled(model.isSaving)
                .padding(12)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.hasPhoto && !model.isImporting {
                Text(showsOriginal ? "ORIGINAL" : "\(model.selectedPreset.code) / \(model.selectedPreset.name.uppercased())")
                    .font(AppTypography.font(size: 9, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.82), in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var emptyCanvas: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Palette.muted.opacity(0.25), lineWidth: 1)
                    .frame(width: 66, height: 80)
                    .rotationEffect(.degrees(-12))
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.background)
                    .frame(width: 66, height: 80)
                    .overlay {
                        Image(systemName: "camera.macro")
                            .font(AppTypography.font(size: 29, weight: .ultraLight))
                            .foregroundStyle(Palette.accent)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.muted.opacity(0.4)))
                    .rotationEffect(.degrees(7))
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Start with a photo.")
                    .font(AppTypography.font(size: 20, weight: .regular))
                Text("Find your own filter.")
                    .font(AppTypography.font(size: 12))
                    .foregroundStyle(Palette.muted)
            }

            choosePhotoButton()
        }
        .padding(20)
    }

    private func choosePhotoButton(onPhoto: Bool = false) -> some View {
        let labelFont = AppTypography.font(size: 12, weight: .semibold)
        return PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
            Label("Choose photo", systemImage: "photo.on.rectangle.angled")
                .font(labelFont)
                .foregroundStyle(onPhoto ? .black : Palette.background)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(onPhoto ? .white : Palette.accent, in: Capsule())
        }
        .accessibilityIdentifier("chooseFirstPhoto")
    }

    private var presetSection: some View {
        let presets = isBlackAndWhite ? PhotoPreset.blackAndWhite : model.selectedFamily.presets
        let name = isBlackAndWhite ? "Black and white" : model.selectedFamily.name
        let caption = isBlackAndWhite ? "Timeless filters in black and white" : model.selectedFamily.caption
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel(name.uppercased(), detail: "\(presets.count) filters")
                Text(caption)
                    .font(AppTypography.font(size: 11))
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("familyDescription")
            }

            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(presets) { preset in
                            presetCard(preset)
                                .frame(width: 100)
                                .id(preset.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("presetCollection")
                .onAppear { scroll.scrollTo(model.selectedPreset.id, anchor: .center) }
                .onChange(of: model.selectedPreset) { _, preset in
                    scroll.scrollTo(preset.id, anchor: .center)
                }
            }
            .id(name)
        }
    }

    private func presetCard(_ preset: PhotoPreset) -> some View {
        let selected = model.selectedPreset == preset
        return Button {
            model.selectedPreset = preset
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(placeholderGradient)
                        if let thumbnail = model.photo?.thumbnails[preset] ?? previews.images[preset] {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: 92)
                                .clipped()
                        } else {
                            Image(systemName: preset.symbol)
                                .font(AppTypography.font(size: 28, weight: .ultraLight))
                                .foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 1.5)
                }

                HStack(spacing: 4) {
                    Text(preset.shortName)
                        .font(AppTypography.font(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    if selected {
                        Circle().fill(Palette.accent).frame(width: 5, height: 5)
                    }
                }
                Text(preset.caption)
                    .font(AppTypography.font(size: 9))
                    .foregroundStyle(Palette.muted)
            }
            .foregroundStyle(selected ? Palette.accent : Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isImporting || model.isSaving)
        .accessibilityLabel("\(preset.name), \(preset.caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("preset-\(preset.rawValue)")
        .overlay(alignment: .topTrailing) {
            FavoriteButton(preset: preset, identifier: "bookmark-editor-\(preset.rawValue)", isCompact: true)
                .padding(6)
        }
    }

    private var intensitySection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("INTENSITY")
                    .font(AppTypography.font(size: 10, weight: .medium))
                    .tracking(2)
                Spacer()
                Text("\(Int((model.intensity * 100).rounded()))%")
                    .font(AppTypography.font(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("intensityValue")
            }

            Slider(value: $model.intensity, in: 0...1)
                .accessibilityLabel("Filter intensity")
                .accessibilityValue("\(Int((model.intensity * 100).rounded())) percent")
                .accessibilityIdentifier("intensitySlider")

            HStack {
                Text("Original")
                Spacer()
                Text("Full filter")
            }
            .font(AppTypography.font(size: 10))
            .foregroundStyle(Palette.muted)
        }
        .disabled(!model.hasPhoto || model.isImporting || model.isSaving)
        .opacity(model.hasPhoto ? 1 : 0.4)
    }

    private var saveBar: some View {
        Button {
            model.prepareExportOptions()
            showsExportSizes = true
        } label: {
            HStack(spacing: 12) {
                if model.isSaving {
                    ProgressView().tint(Palette.background)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(AppTypography.font(size: 19, weight: .medium))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isSaving ? "Saving…" : "Save a copy")
                        .font(AppTypography.font(size: 13, weight: .semibold))
                    Text("Choose image size")
                        .font(AppTypography.font(size: 10))
                        .opacity(0.7)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.background)
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.isImporting || model.isSaving)
        .accessibilityLabel(model.isSaving ? "Saving photo" : "Save edited photo")
        .accessibilityValue("Choose image size")
        .accessibilityIdentifier("savePhoto")
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.background)
    }

    private var exportSizeSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose image size")
                .font(AppTypography.font(size: 22, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if model.isPreparingExport {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Calculating sizes…")
                        .font(AppTypography.font(size: 14))
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else {
                ForEach(model.exportOptions) { option in
                    Button {
                        model.savePhoto(option)
                        showsExportSizes = false
                    } label: {
                        HStack {
                            Text(option.size.title)
                            Spacer()
                            Text(option.bytes < 10_000 ? "(<0.01 MB)" : String(format: "(%.2f MB)", Double(option.bytes) / 1_000_000))
                                .monospacedDigit()
                        }
                        .font(AppTypography.font(size: 15, weight: .medium))
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("exportSize-\(option.id)")
                }
            }
        }
        .padding(24)
        .padding(.top, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.ink)
        .background(Palette.background.ignoresSafeArea())
        .presentationDetents([.height(350), .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.font(size: 10, weight: .medium))
                .tracking(2)
            Spacer()
            Text(detail)
                .font(AppTypography.font(size: 10))
                .foregroundStyle(Palette.muted)
        }
    }

    private var placeholderGradient: LinearGradient {
        LinearGradient(colors: [Palette.muted.opacity(0.3), Palette.surface],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// App-owned notices use the same typography and monochrome palette as the
/// editor, including the save confirmation and photo-library access errors.
struct EditorNoticeView: View {
    let notice: EditorNotice
    let dismiss: () -> Void
    let openSettings: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.76).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(notice.title)
                    .font(AppTypography.font(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(notice.message)
                    .font(AppTypography.font(size: 14))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    if notice.offersSettings {
                        Button("Open Settings", action: openSettings)
                            .font(AppTypography.font(size: 14, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.muted))
                    }
                    Button(action: dismiss) {
                        Text("OK")
                            .font(AppTypography.font(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("dismissNotice")
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.muted.opacity(0.3)))
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("editorNotice")
        }
        .onAppear { titleFocused = true }
    }
}

private struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let editedImage: UIImage
    let originalImage: UIImage
    let presetName: String
    @State var showsOriginal: Bool
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var pan = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close photo detail")
                .accessibilityIdentifier("closePhotoDetail")
                Spacer()
                Text(showsOriginal ? "ORIGINAL" : presetName)
                    .font(AppTypography.font(size: 14, weight: .medium))
                Spacer()
                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)

            GeometryReader { geometry in
                let imageSize = editedImage.size
                let fit = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
                let fittedSize = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
                let zoom = min(5, max(1, scale * pinch))
                let translation = boundedOffset(
                    CGSize(width: offset.width + pan.width, height: offset.height + pan.height),
                    imageSize: fittedSize, viewport: geometry.size, scale: zoom
                )

                ZStack {
                    Image(uiImage: showsOriginal ? originalImage : editedImage)
                        .resizable()
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .scaleEffect(zoom)
                        .offset(translation)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .clipped()
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        scale = min(5, max(1, scale * value.magnification))
                        offset = boundedOffset(offset, imageSize: fittedSize, viewport: geometry.size, scale: scale)
                    })
                .simultaneousGesture(DragGesture()
                    .updating($pan) { value, state, _ in
                        if scale > 1 { state = value.translation }
                    }
                    .onEnded { value in
                        guard scale > 1 else { return }
                        offset = boundedOffset(
                            CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                            imageSize: fittedSize, viewport: geometry.size, scale: scale
                        )
                    })
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(showsOriginal ? "Original photo" : "Photo with filter \(presetName)")
                .accessibilityValue("\(Int((zoom * 100).rounded()))%")
                .accessibilityAction(named: scale > 1 ? "Reset zoom" : "Zoom in two times") { toggleZoom() }
                .accessibilityIdentifier("detailPhotoPreview")
            }

            VStack(spacing: 12) {
                Button { showsOriginal.toggle() } label: {
                    Label(
                        showsOriginal ? "Before applying filter" : "After applying filter",
                        systemImage: showsOriginal ? "square.righthalf.filled" : "square.lefthalf.filled"
                    )
                        .font(AppTypography.font(size: 14, weight: .medium))
                        .frame(minHeight: 44)
                }
                .accessibilityValue(showsOriginal ? "Original" : "Edited")
                .accessibilityHint(showsOriginal ? "Shows the photo with the filter" : "Shows the original photo")
                .accessibilityIdentifier("compareDetailOriginal")
                Text("Pinch or double-tap to zoom.\nDrag to explore the details.")
                    .font(AppTypography.font(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .buttonStyle(.plain)
    }

    private func toggleZoom() {
        withAnimation(.snappy) {
            scale = scale > 1 ? 1 : 2
            offset = .zero
        }
    }

    private func boundedOffset(_ proposed: CGSize, imageSize: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max(0, (imageSize.width * scale - viewport.width) / 2)
        let maxY = max(0, (imageSize.height * scale - viewport.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }
}

#Preview {
    EditorView().preferredColorScheme(.dark)
}
