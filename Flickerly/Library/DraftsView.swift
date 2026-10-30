import SwiftUI

struct DraftsView: View {
    var allowsOpening = true
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var drafts: DraftStore
    @State private var selectedDrafts: Set<UUID> = []
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(AppTypography.font(size: 18, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(Palette.surface, in: Circle())
                }
                .accessibilityLabel(allowsOpening ? "Back to collections" : "Close drafts")
                Text("Drafts")
                    .font(AppTypography.font(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity)
                if selectedDrafts.isEmpty {
                    Color.clear.frame(width: 46, height: 46).accessibilityHidden(true)
                } else {
                    Button { showsDeleteConfirmation = true } label: {
                        Image(systemName: "trash")
                            .font(AppTypography.font(size: 18, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(width: 46, height: 46)
                    }
                    .accessibilityLabel("Delete selected drafts")
                    .accessibilityValue("\(selectedDrafts.count) selected")
                    .accessibilityIdentifier("deleteSelectedDrafts")
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !drafts.drafts.isEmpty && !drafts.loadFailed {
                        Text("\(drafts.drafts.count) of \(DraftStore.limit) drafts")
                            .font(AppTypography.font(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    if drafts.loadFailed {
                        Text("Drafts couldn't be loaded. Your existing files haven't been changed.")
                        Button("Try again") { drafts.reload() }
                    } else if drafts.drafts.isEmpty {
                        emptyDrafts
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(drafts.drafts) { draft in
                                draftCard(draft)
                            }
                        }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .buttonStyle(.plain)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .alert(selectedDrafts.count == 1 ? "Delete draft?" : "Delete \(selectedDrafts.count) drafts?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelectedDrafts()
            }
        } message: {
            Text("Selected drafts will be removed from Flickerly. Copies saved to Photos won't be affected.")
        }
        .alert("Couldn't delete draft", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var emptyDrafts: some View {
        VStack(spacing: 14) {
            Image("EmptyDrafts")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 250)
                .aspectRatio(320.0 / 256.0, contentMode: .fit)
                .accessibilityHidden(true)

            Text("No drafts yet")
                .font(AppTypography.font(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Your unfinished edits will appear here. Save an edit as a draft to continue it later.")
                .font(AppTypography.font(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 270)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .accessibilityIdentifier("emptyDrafts")
    }

    private func draftCard(_ draft: PhotoDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preset = draft.preset {
                if allowsOpening {
                    NavigationLink {
                        EditorView(initialPreset: preset, isBlackAndWhite: draft.isBlackAndWhite, draft: draft)
                    } label: {
                        draftContent(draft, preset: preset)
                    }
                    .accessibilityLabel("Open draft, \(preset.name), last edited \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    draftContent(draft, preset: preset)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if let preset = draft.preset {
                Button {
                    if !selectedDrafts.insert(draft.id).inserted { selectedDrafts.remove(draft.id) }
                } label: {
                    Image(systemName: selectedDrafts.contains(draft.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.4), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(2)
                .accessibilityLabel("Select \(preset.name) draft")
                .accessibilityValue(selectedDrafts.contains(draft.id) ? "Selected" : "Not selected")
                .accessibilityAddTraits(selectedDrafts.contains(draft.id) ? .isSelected : [])
                .accessibilityIdentifier("selectDraft-\(draft.id.uuidString)")
            }
        }
    }

    private func deleteSelectedDrafts() {
        let selected = drafts.drafts.filter { selectedDrafts.contains($0.id) }
        var failures = 0
        for draft in selected {
            do {
                try drafts.delete(draft)
                selectedDrafts.remove(draft.id)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            errorMessage = failures == 1
                ? "One draft couldn't be deleted. It remains selected so you can try again."
                : "\(failures) drafts couldn't be deleted. They remain selected so you can try again."
        }
    }

    private func draftContent(_ draft: PhotoDraft, preset: PhotoPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = UIImage(data: draft.thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Palette.surface.overlay { Image(systemName: "photo").foregroundStyle(Palette.muted) }
                }
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(preset.name).font(AppTypography.font(size: 15, weight: .medium))
            Text("Last edited \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(AppTypography.font(size: 12)).foregroundStyle(Palette.muted)
        }
    }
}
