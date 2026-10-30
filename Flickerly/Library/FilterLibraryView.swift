import SwiftUI

private struct EditorDestination: Hashable {
    let preset: PhotoPreset
    let isBlackAndWhite: Bool
}

struct FilterLibraryView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var previews: CatalogPreviewStore

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    favoritesSection
                    ForEach(PhotoPresetFamily.allCases) { family in
                        collection(
                            title: family.name, caption: family.caption,
                            presets: family.presets, section: family.rawValue
                        )
                        if family == .originals {
                            collection(
                                title: "Black and white", caption: "Timeless filters in black and white",
                                presets: PhotoPreset.blackAndWhite, section: "black-and-white"
                            )
                        }
                    }
                }
                .padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(Palette.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(Palette.background)
            }
            .navigationDestination(for: EditorDestination.self) { destination in
                EditorView(initialPreset: destination.preset, isBlackAndWhite: destination.isBlackAndWhite)
                    .navigationBarBackButtonHidden()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Palette.accent)
        .foregroundStyle(Palette.ink)
        .task { await previews.loadIfNeeded() }
        .accessibilityHidden(favorites.notice != nil)
        .overlay {
            if let notice = favorites.notice {
                EditorNoticeView(notice: notice, dismiss: { favorites.notice = nil }, openSettings: {})
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("FlickerlyMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Palette.ink)
                    .accessibilityHidden(true)

                Text("FLICKERLY")
                    .font(AppTypography.font(size: 25, weight: .semibold))
                    .tracking(5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Spacer(minLength: 8)

                NavigationLink {
                    DraftsView()
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(AppTypography.font(size: 18, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(Palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Drafts")
                .accessibilityIdentifier("openDrafts")

                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .font(AppTypography.font(size: 18, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(Palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("openSettings")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Find your filter. Make it yours.")
                .font(AppTypography.font(size: 13))
                .foregroundStyle(Palette.muted)
            if previews.failed {
                Button("Previews unavailable. Tap to retry.") {
                    Task { await previews.loadIfNeeded() }
                }
                .font(AppTypography.font(size: 12))
                .accessibilityIdentifier("retryCatalogPreviews")
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        if favorites.presets.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading("Favorites", caption: "Your favorite filters, all in one place", count: 0)
                HStack(spacing: 14) {
                    Image(systemName: "bookmark")
                        .font(AppTypography.font(size: 22))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keep your favorites close.")
                            .font(AppTypography.font(size: 14, weight: .medium))
                        Text("Tap a bookmark on any filter to save it here.")
                            .font(AppTypography.font(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
            }
            .accessibilityIdentifier("emptyFavorites")
        } else {
            collection(title: "Favorites", caption: "Your favorite filters, all in one place",
                       presets: favorites.orderedPresets, section: "favorites")
        }
    }

    private func collection(title: String, caption: String, presets: [PhotoPreset], section: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading(title, caption: caption, count: presets.count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(presets) { preset in
                        catalogCard(preset, section: section)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("catalog-\(section)")
        }
    }

    private func sectionHeading(_ title: String, caption: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(AppTypography.font(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(caption).")
                    .font(AppTypography.font(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Text("\(count) \(count == 1 ? "filter" : "filters")")
                .font(AppTypography.font(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 24)
    }

    private func catalogCard(_ preset: PhotoPreset, section: String) -> some View {
        NavigationLink(value: EditorDestination(preset: preset, isBlackAndWhite: section == "black-and-white")) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 9).fill(Palette.surface)
                    if let image = previews.images[preset] {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: 164, height: 180)
                            .clipped()
                    } else {
                        Image(systemName: "photo")
                            .font(AppTypography.font(size: 28))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 164, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(preset.name)
                    .font(AppTypography.font(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(preset.caption)
                    .font(AppTypography.font(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 164, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name), \(preset.caption). Open \(preset.family.name) editor")
        .accessibilityIdentifier("open-\(section)-\(preset.rawValue)")
        .overlay(alignment: .topTrailing) {
            FavoriteButton(preset: preset, identifier: "bookmark-\(section)-\(preset.rawValue)")
                .background(.black.opacity(0.75), in: Circle())
                .padding(6)
        }
    }
}

struct FavoriteButton: View {
    @EnvironmentObject private var favorites: FavoritesStore
    let preset: PhotoPreset
    let identifier: String
    var isCompact = false

    var body: some View {
        let saved = favorites.contains(preset)
        Button { favorites.toggle(preset) } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .font(AppTypography.font(size: isCompact ? 13 : 17, weight: .medium))
                .frame(width: isCompact ? 28 : 44, height: isCompact ? 28 : 44)
                .background {
                    if isCompact {
                        Circle().fill(.black.opacity(0.5))
                    }
                }
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("\(saved ? "Remove" : "Add") \(preset.name) \(saved ? "from" : "to") favorites")
        .accessibilityValue(saved ? "Saved" : "Not saved")
        .accessibilityIdentifier(identifier)
    }
}
