import Combine
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Flickerly

private struct NILUTReference: Decodable {
    let reference_input_srgb8: [[UInt8]]
    let styles: [Style]

    struct Style: Decodable {
        let reference_output_srgb: [[Double]]
    }
}

@MainActor
final class PhotoRendererTests: XCTestCase {
    func testExportOptionsContainActualFileSizesAndBoundedDimensions() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let photo = try await renderer.prepare(data: fixtureData(width: 2400, height: 1200))
        let options = try await renderer.exportOptions(photo: photo, preset: .mono, intensity: 0.8)
        defer { for option in options { try? FileManager.default.removeItem(at: option.url) } }
        XCTAssertEqual(options.map(\.size), [.original, .medium, .small])
        for (option, expectedWidth) in zip(options, [2400, 2048, 1024]) {
            let image = try exportedImage(option.url)
            XCTAssertEqual(image.width, expectedWidth)
            XCTAssertEqual(image.height, expectedWidth / 2)
            let attributes = try FileManager.default.attributesOfItem(atPath: option.url.path)
            XCTAssertEqual(option.bytes, (attributes[.size] as? NSNumber)?.int64Value)
        }
    }

    func testCancellingExportOptionsRemovesPreparedFiles() async throws {
        let model = EditorModel(renderer: PhotoRenderer(maxPreviewDimension: 120))
        model.importPhoto(data: try fixtureData(width: 200, height: 100))
        try await waitUntil { !model.isImporting }
        model.prepareExportOptions()
        try await waitUntil { !model.isPreparingExport }
        let options = model.exportOptions
        XCTAssertEqual(options.count, 3)
        for option in options {
            let image = try exportedImage(option.url)
            XCTAssertEqual(image.width, 200)
            XCTAssertEqual(image.height, 100)
        }
        model.cancelExportOptions()
        XCTAssertTrue(model.exportOptions.isEmpty)
        for option in options { XCTAssertFalse(FileManager.default.fileExists(atPath: option.url.path)) }
    }

    func testFlickerlyReleaseIdentity() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Flickerly")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "Flickerly")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Flickerly")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "gr.mountzou.flickerly")
        let permission = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String)
        XCTAssertTrue(permission.hasPrefix("Flickerly "))
    }

    func testFavoritesPersistAcrossStoreInstancesAndCanBeRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "FavoriteFilters.json")
        let first = FavoritesStore(storageURL: url)
        XCTAssertTrue(first.orderedPresets.isEmpty)
        first.toggle(.nilut3)
        first.toggle(.paperWarm)
        first.toggle(.film35)
        XCTAssertNil(first.notice)
        let relaunched = FavoritesStore(storageURL: url)
        XCTAssertEqual(relaunched.orderedPresets, [.film35, .paperWarm, .nilut3])
        relaunched.toggle(.paperWarm)
        XCTAssertEqual(FavoritesStore(storageURL: url).orderedPresets, [.film35, .nilut3])
        relaunched.toggle(.film35)
        relaunched.toggle(.nilut3)
        XCTAssertTrue(FavoritesStore(storageURL: url).orderedPresets.isEmpty)
    }

    func testFavoritesIgnoreUnknownAndDuplicateIdentifiers() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"["paperWarm", "removed-preset", "paperWarm", "nilut2"]"#.utf8).write(to: url)
        let store = FavoritesStore(storageURL: url)
        XCTAssertEqual(store.orderedPresets, [.paperWarm, .nilut2])
        store.toggle(.amber)
        let identifiers = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertEqual(identifiers, ["amber", "nilut2", "paperWarm"])
    }

    func testNewNILUTLooksPersistAlongsideExistingFavorites() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"["nilut1", "paperWarm"]"#.utf8).write(to: url)
        let store = FavoritesStore(storageURL: url)
        for preset in [PhotoPreset.nilutNatural, .nilutSoftWarm, .nilutCoolMatte] {
            store.toggle(preset)
        }
        XCTAssertNil(store.notice)
        XCTAssertEqual(FavoritesStore(storageURL: url).orderedPresets,
                       [.paperWarm, .nilut1, .nilutNatural, .nilutSoftWarm, .nilutCoolMatte])
    }

    func testMalformedFavoritesCanBeReplacedWithAValidSelection() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid JSON".utf8).write(to: url)
        let store = FavoritesStore(storageURL: url)
        XCTAssertTrue(store.presets.isEmpty)
        store.toggle(.silver35)
        XCTAssertEqual(FavoritesStore(storageURL: url).orderedPresets, [.silver35])
    }

    func testFailedFavoriteWriteKeepsExistingStateAndReportsAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory at the file's path makes an atomic JSON write fail.
        let store = FavoritesStore(storageURL: directory)
        store.toggle(.dust35)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertEqual(store.notice?.title, "Couldn't save favorites")
    }

    func testEveryCatalogEntryStartsItsOwnFamilyAndRemembersItsVariant() {
        for preset in PhotoPreset.allCases {
            let model = EditorModel(initialPreset: preset)
            XCTAssertEqual(model.selectedPreset, preset)
            XCTAssertEqual(model.selectedFamily, preset.family)
            XCTAssertTrue(model.selectedFamily.presets.contains(preset))
            let otherFamily: PhotoPresetFamily = preset.family == .paper ? .nilut : .paper
            model.selectFamily(otherFamily)
            model.selectFamily(preset.family)
            XCTAssertEqual(model.selectedPreset, preset)
        }
    }

    func testCatalogPresetRemainsSelectedWhenTheUserImportsAPhoto() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let model = EditorModel(renderer: renderer, initialPreset: .paperWarm)
        model.importPhoto(data: try fixtureData())
        try await waitUntil { !model.isImporting }
        let photo = try XCTUnwrap(model.photo)
        XCTAssertEqual(model.selectedPreset, .paperWarm)
        XCTAssertEqual(model.selectedFamily, .paper)
        XCTAssertEqual(model.intensity, 0.8)
        let expected = try await renderer.blend(photo: photo, preset: .paperWarm, intensity: 0.8)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expected))
    }

    func testCatalogSamplePreviewsUseAllTheActualFilterRecipes() async throws {
        let url = try XCTUnwrap(CatalogPreviewStore.sampleURL)
        let store = CatalogPreviewStore()
        await store.loadIfNeeded()
        XCTAssertFalse(store.failed)
        XCTAssertEqual(Set(store.images.keys), Set(PhotoPreset.allCases))
        let expected = try await PhotoRenderer(maxPreviewDimension: 600).prepare(data: Data(contentsOf: url))
        for preset in PhotoPreset.allCases {
            let image = try XCTUnwrap(store.images[preset])
            XCTAssertEqual(image.width, 600)
            XCTAssertEqual(image.height, 600)
            XCTAssertEqual(pixels(image), pixels(try XCTUnwrap(expected.looks[preset])), preset.name)
        }
    }

    func testBundledBricolageFontIsRegisteredForAppTypography() throws {
        let filenames = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(filenames, ["BricolageGrotesque.ttf"])
        XCTAssertNotNil(Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf"))
        let registered = try XCTUnwrap(UIFont(name: AppTypography.postScriptName, size: 17))
        XCTAssertEqual(registered.familyName, "Bricolage Grotesque")
        for weight: CGFloat in [200, 400, 500, 600] {
            let font = AppTypography.uiFont(size: 17, weight: weight)
            XCTAssertEqual(font.familyName, registered.familyName, "Custom font must not silently fall back")
        }
    }

    func testZeroIntensityReturnsOriginalForEveryPreset() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let photo = try await renderer.prepare(data: fixtureData())
        for preset in PhotoPreset.allCases {
            let result = try await renderer.blend(photo: photo, preset: preset, intensity: 0)
            XCTAssertEqual(pixels(result), pixels(photo.original), preset.name)
        }
    }

    func testPresetsAreDistinctAndBlackAndWhiteLooksAreNeutral() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let photo = try await renderer.prepare(data: fixtureData())
        let original = pixels(photo.original)
        var results: [[UInt8]] = []
        for preset in PhotoPreset.allCases {
            let image = try await renderer.blend(photo: photo, preset: preset, intensity: 1)
            let rendered = pixels(image)
            XCTAssertGreaterThan(meanDifference(original, rendered), 2, preset.name)
            results.append(rendered)
            if preset == .mono || preset == .silver35 || preset == .scratch16 {
                for index in stride(from: 0, to: rendered.count, by: 4) {
                    XCTAssertLessThanOrEqual(abs(Int(rendered[index]) - Int(rendered[index + 1])), 1)
                    XCTAssertLessThanOrEqual(abs(Int(rendered[index + 1]) - Int(rendered[index + 2])), 1)
                }
            }
        }
        for first in results.indices {
            for second in results.indices where second > first {
                XCTAssertGreaterThan(meanDifference(results[first], results[second]), 2,
                                     "\(PhotoPreset.allCases[first].name) vs \(PhotoPreset.allCases[second].name)")
            }
        }
    }

    func testIntermediateIntensityBlendsAndClampsToEndpoints() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let photo = try await renderer.prepare(data: fixtureData())
        let original = pixels(photo.original)

        for preset in PhotoPreset.allCases {
            let full = pixels(try XCTUnwrap(photo.looks[preset]))
            let half = pixels(try await renderer.blend(photo: photo, preset: preset, intensity: 0.5))
            XCTAssertGreaterThan(meanDifference(original, half), 0.5)
            XCTAssertGreaterThan(meanDifference(full, half), 0.5)
            for index in half.indices {
                XCTAssertGreaterThanOrEqual(Int(half[index]), min(Int(original[index]), Int(full[index])) - 1)
                XCTAssertLessThanOrEqual(Int(half[index]), max(Int(original[index]), Int(full[index])) + 1)
            }
            let below = try await renderer.blend(photo: photo, preset: preset, intensity: -1)
            let above = try await renderer.blend(photo: photo, preset: preset, intensity: 2)
            XCTAssertEqual(pixels(below), original)
            XCTAssertEqual(pixels(above), full)
        }
    }

    func testRepeatedEditsDoNotAccumulate() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let photo = try await renderer.prepare(data: fixtureData())
        let first = try await renderer.blend(photo: photo, preset: .amber, intensity: 0.8)
        _ = try await renderer.blend(photo: photo, preset: .mono, intensity: 1)
        _ = try await renderer.blend(photo: photo, preset: .tide, intensity: 0.2)
        let repeated = try await renderer.blend(photo: photo, preset: .amber, intensity: 0.8)
        XCTAssertEqual(pixels(first), pixels(repeated))
    }

    func testPreviewDownsamplesAndAppliesEXIFOrientation() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let data = try fixtureData(width: 400, height: 200, orientation: 6)
        let photo = try await renderer.prepare(data: data)
        XCTAssertEqual(photo.original.width, 60)
        XCTAssertEqual(photo.original.height, 120)
        XCTAssertEqual(photo.pixelSize, "200 × 400")
        for preset in PhotoPreset.allCases {
            let thumbnail = try XCTUnwrap(photo.thumbnails[preset])
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 240)
            XCTAssertEqual(thumbnail.width, 60)
            XCTAssertEqual(thumbnail.height, 120)
        }
    }

    func testInvalidImageIsRejected() async {
        let renderer = PhotoRenderer()
        do {
            _ = try await renderer.prepare(data: Data("not an image".utf8))
            XCTFail("Expected an unreadable-image error")
        } catch PhotoError.unreadableImage {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExportUsesFullResolutionSourceInsteadOfPreview() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let data = try fixtureData(width: 2_400, height: 1_600)
        let photo = try await renderer.prepare(data: data)
        XCTAssertEqual(photo.original.width, 120)
        XCTAssertEqual(photo.sourceData, data)

        let url = try await renderer.export(photo: photo, preset: .tide, intensity: 0.65)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try exportedImage(url)
        XCTAssertEqual(image.width, 2_400)
        XCTAssertEqual(image.height, 1_600)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(photo.sourceData, data, "Export must not mutate the imported source")
    }

    func testExportBakesOrientationIntoFullSizePixels() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        for orientation in [3, 6, 8] {
            let photo = try await renderer.prepare(data: fixtureData(width: 400, height: 200, orientation: orientation))
            let url = try await renderer.export(photo: photo, preset: .amber, intensity: 0)
            defer { try? FileManager.default.removeItem(at: url) }
            let image = try exportedImage(url)
            XCTAssertEqual(image.width, orientation == 3 ? 400 : 200)
            XCTAssertEqual(image.height, orientation == 3 ? 200 : 400)

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            // Compare the orientation of pixels, not just the width/height metadata.
            let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 120
            ] as CFDictionary))
            XCTAssertLessThan(meanDifference(pixels(thumbnail), pixels(photo.original)), 3)
        }
    }

    func testExportMatchesPresetAndIntensityAcrossEndpointsAndMidpoint() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let photo = try await renderer.prepare(data: fixtureData())
        for preset in PhotoPreset.allCases {
            for intensity in [0.0, 0.5, 1.0] {
                let preview = try await renderer.blend(photo: photo, preset: preset, intensity: intensity)
                let url = try await renderer.export(photo: photo, preset: preset, intensity: intensity)
                defer { try? FileManager.default.removeItem(at: url) }
                XCTAssertTrue(url.lastPathComponent.hasPrefix("Flickerly-\(preset.name)-"))
                let image = try exportedImage(url)
                XCTAssertLessThan(
                    meanDifference(pixels(image), pixels(preview)), 3,
                    "Export differs from preview for \(preset.name) at \(intensity)"
                )
            }
        }
    }

    func testExportDoesNotCopySourceLocationMetadata() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 120)
        let data = try fixtureData(includeLocation: true)
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        let photo = try await renderer.prepare(data: data)
        let url = try await renderer.export(photo: photo, preset: .mono, intensity: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    func testFilmGrainIsStableAcrossImportsAndExports() async throws {
        let data = try fixtureData(width: 600, height: 400, flatGray: 0.5)
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        let first = try await renderer.prepare(data: data)
        let second = try await PhotoRenderer(maxPreviewDimension: 600).prepare(data: data)
        for preset in [PhotoPreset.film35, .silver35, .dust35, .glow800, .scratch16, .expired35, .paper35, .paperWarm, .paperArchive] {
            let firstLook = try XCTUnwrap(first.looks[preset])
            let secondLook = try XCTUnwrap(second.looks[preset])
            XCTAssertLessThan(meanDifference(pixels(firstLook), pixels(secondLook)), 0.01, preset.name)

            let firstURL = try await renderer.export(photo: first, preset: preset, intensity: 0.8)
            let secondURL = try await renderer.export(photo: first, preset: preset, intensity: 0.8)
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }
            XCTAssertLessThan(meanDifference(pixels(try exportedImage(firstURL)), pixels(try exportedImage(secondURL))), 0.01, preset.name)
        }
    }

    func testFilmGrainIsFineMostlyMonochromeAndWeakerInHighlights() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        let mid = try await renderer.prepare(data: fixtureData(width: 600, height: 400, flatGray: 0.5))
        let bright = try await renderer.prepare(data: fixtureData(width: 600, height: 400, flatGray: 0.95))
        for preset in [PhotoPreset.film35, .silver35] {
            let midStats = grainStatistics(try XCTUnwrap(mid.looks[preset]))
            let brightStats = grainStatistics(try XCTUnwrap(bright.looks[preset]))
            XCTAssertGreaterThan(midStats.lumaSD, 0.5, "\(preset.name): a flat midtone should contain visible fine texture")
            XCTAssertLessThan(midStats.lumaSD, 8, "\(preset.name): grain should remain subtle")
            XCTAssertLessThan(midStats.chromaSD, 1.2, "\(preset.name): grain should vary in brightness rather than color")
            XCTAssertLessThan(brightStats.lumaSD, midStats.lumaSD * 0.65, preset.name)
            print("FILM_GRAIN \(preset.name): midtone SD \(midStats.lumaSD), highlight SD \(brightStats.lumaSD), chroma SD \(midStats.chromaSD)")
        }
    }

    func testFilmGrainIntensityFadesTheSamePattern() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        let photo = try await renderer.prepare(data: fixtureData(width: 600, height: 400, flatGray: 0.5))
        for preset in [PhotoPreset.film35, .silver35, .dust35, .glow800, .scratch16, .expired35, .paper35, .paperWarm, .paperArchive] {
            let zero = try await renderer.blend(photo: photo, preset: preset, intensity: 0)
            let half = try await renderer.blend(photo: photo, preset: preset, intensity: 0.5)
            let full = try await renderer.blend(photo: photo, preset: preset, intensity: 1)
            XCTAssertEqual(pixels(zero), pixels(photo.original), preset.name)
            let ratio = grainStatistics(half).lumaSD / grainStatistics(full).lumaSD
            XCTAssertGreaterThan(ratio, 0.35, preset.name)
            XCTAssertLessThan(ratio, 0.75, preset.name)
            XCTAssertGreaterThan(lumaCorrelation(half, full), 0.95, preset.name)
        }
    }

    func testFilmGrainUsesTheSameScaleInPreviewAndFullSizeJPEG() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        let photo = try await renderer.prepare(data: fixtureData(width: 1_200, height: 800, flatGray: 0.5))
        for preset in [PhotoPreset.film35, .silver35, .dust35, .glow800, .scratch16, .expired35, .paper35, .paperWarm, .paperArchive] {
            let preview = try XCTUnwrap(photo.looks[preset])
            let url = try await renderer.export(photo: photo, preset: preset, intensity: 1)
            defer { try? FileManager.default.removeItem(at: url) }
            let exported = try exportedImage(url)
            XCTAssertEqual(exported.width, 1_200)
            XCTAssertEqual(exported.height, 800)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ] as CFDictionary))
            let ratio = grainStatistics(reduced).lumaSD / grainStatistics(preview).lumaSD
            let correlation = lumaCorrelation(preview, reduced)
            XCTAssertGreaterThan(ratio, 0.55, preset.name)
            XCTAssertLessThan(ratio, 1.65, preset.name)
            XCTAssertGreaterThan(correlation, 0.65, "\(preset.name): downsampling export should retain the preview's grain locations")
            XCTAssertLessThan(meanDifference(pixels(preview), pixels(reduced)), 3, preset.name)
            print("FILM_SCALE \(preset.name): export/preview SD ratio \(ratio), pattern correlation \(correlation)")
        }
    }

    func testSilver35HasSoftBlackAndWhiteEndpoints() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        var levels: [Double] = []
        for gray in [CGFloat(0), 1] {
            let photo = try await renderer.prepare(data: fixtureData(width: 600, height: 400, flatGray: gray))
            let silver = lumaSamples(try XCTUnwrap(photo.looks[.silver35]))
            let mono = lumaSamples(try XCTUnwrap(photo.looks[.mono]))
            let silverMean = silver.reduce(0, +) / Double(silver.count)
            let monoMean = mono.reduce(0, +) / Double(mono.count)
            levels.append(silverMean)
            if gray == 0 {
                XCTAssertGreaterThan(silverMean, monoMean + 2, "Silver's black point should be softer than Mono's")
            } else {
                XCTAssertLessThan(silverMean, monoMean - 1, "Silver should roll off whites more gently than Mono")
            }
        }
        XCTAssertGreaterThan(levels[0], 2)
        XCTAssertLessThan(levels[0], 80)
        XCTAssertGreaterThan(levels[1], 220)
        XCTAssertLessThan(levels[1], 254)
        print("SILVER_TONE: black \(levels[0]), white \(levels[1]) /255")
    }

    func testSilver35GrainIsSlightlyStrongerThanFilm35() async throws {
        let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(
            data: fixtureData(width: 600, height: 400, flatGray: 0.5)
        )
        let film = grainStatistics(try XCTUnwrap(photo.looks[.film35]))
        let silver = grainStatistics(try XCTUnwrap(photo.looks[.silver35]))
        XCTAssertGreaterThan(silver.lumaSD, film.lumaSD * 1.05)
        XCTAssertLessThan(silver.lumaSD, film.lumaSD * 1.6)
        XCTAssertLessThan(silver.chromaSD, 0.8)
    }

    func testDustTextureHasSparseLightAndDarkSpecksAndShortScratches() throws {
        let size = CGSize(width: 3_000, height: 2_002)
        let texture = try DustArtifacts.texture(sourceSize: size)
        let repeated = try DustArtifacts.texture(sourceSize: size)
        XCTAssertEqual(texture.width, 1_800)
        XCTAssertEqual(texture.height, 1_202)
        let data = pixels(texture)
        XCTAssertEqual(data, pixels(repeated), "Dust placement must not depend on a global random state")
        var occupied = 0
        var light = 0
        var dark = 0
        var longestRun = 0
        var maximumAlpha = 0
        for x in 0..<texture.width {
            var run = 0
            for y in 0..<texture.height {
                let i = (y * texture.width + x) * 4
                let alpha = Int(data[i + 3])
                maximumAlpha = max(maximumAlpha, alpha)
                if alpha > 4 {
                    occupied += 1
                    if Double(data[i]) > Double(alpha) * 0.8 { light += 1 }
                    if Double(data[i]) < Double(alpha) * 0.25 { dark += 1 }
                    run += 1
                    longestRun = max(longestRun, run)
                } else {
                    run = 0
                }
            }
        }
        let coverage = Double(occupied) / Double(texture.width * texture.height)
        XCTAssertGreaterThan(coverage, 0.0001, "Texture should contain visible marks")
        XCTAssertLessThan(coverage, 0.004, "Dust should occupy less than 0.4% of the image")
        XCTAssertGreaterThan(light, 20)
        XCTAssertGreaterThan(dark, 20)
        XCTAssertLessThan(maximumAlpha, 130, "Marks should remain translucent")
        XCTAssertGreaterThan(longestRun, 20, "Include a few hairline scratches, not only dots")
        XCTAssertLessThan(longestRun, 170, "Scratches should not cross the whole photo")
        print("DUST_TEXTURE: coverage \(coverage), light pixels \(light), dark pixels \(dark), longest scratch run \(longestRun), maximum alpha \(maximumAlpha)")
    }

    func testDust35GentlyDarkensCornersAndKeepsWarmMidtones() async throws {
        let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(
            data: fixtureData(width: 1_200, height: 800, flatGray: 0.5)
        )
        let image = try XCTUnwrap(photo.looks[.dust35])
        let data = pixels(image)
        func meanRegion(x: Int, y: Int) -> (luma: Double, warmth: Double) {
            var brightness = 0.0
            var warmth = 0.0
            for row in y..<(y + 30) {
                for column in x..<(x + 30) {
                    let i = (row * image.width + column) * 4
                    brightness += (Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2])) / 3
                    warmth += Double(data[i]) - Double(data[i + 2])
                }
            }
            return (brightness / 900, warmth / 900)
        }
        let corner = meanRegion(x: 10, y: 10)
        let center = meanRegion(x: image.width / 2 - 15, y: image.height / 2 - 15)
        XCTAssertGreaterThan(center.luma - corner.luma, 2)
        XCTAssertLessThan(center.luma - corner.luma, 20, "Vignette should stay gentle")
        XCTAssertGreaterThan(center.warmth, 2)
        XCTAssertGreaterThan(grainStatistics(image).lumaSD, 1)
        print("DUST_LOOK: center/corner difference \(center.luma - corner.luma), center red-blue \(center.warmth)")
    }

    func testDust35ExportKeepsPortraitOrientationAndPreviewAlignment() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        let data = try fixtureData(width: 2_400, height: 1_600, orientation: 6)
        let photo = try await renderer.prepare(data: data)
        let preview = try XCTUnwrap(photo.looks[.dust35])
        XCTAssertEqual(preview.width, 400)
        XCTAssertEqual(preview.height, 600)
        let url = try await renderer.export(photo: photo, preset: .dust35, intensity: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try exportedImage(url)
        XCTAssertEqual(image.width, 1_600)
        XCTAssertEqual(image.height, 2_400)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ] as CFDictionary))
        XCTAssertLessThan(meanDifference(pixels(preview), pixels(reduced)), 3)
        XCTAssertGreaterThan(lumaCorrelation(preview, reduced), 0.95)
        XCTAssertEqual(photo.sourceData, data)
    }

    func testGlow800OpticsLeaveDarkAndMidtoneImagesUnchanged() throws {
        for level in [CGFloat(0), 0.2, 0.5] {
            let image = CIImage(color: CIColor(red: level, green: level, blue: level))
                .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
            let output = try Glow800Highlights.apply(to: image, highlightsFrom: image)
            XCTAssertTrue(pixels(try renderedCI(output)) == pixels(try renderedCI(image)),
                          "Optical glow must not add haze to a uniform non-highlight image at \(level)")
        }
    }

    func testGlow800HalationIsWarmLocalizedAndPreservesWhiteCore() throws {
        let source = try XCTUnwrap(CIImage(data: fixtureData(width: 1_200, height: 800, brightWindow: true)))
        let result = try renderedCI(Glow800Highlights.apply(to: source, highlightsFrom: source))
        let original = try renderedCI(source)
        let halo = meanChannels(result, x: 542, y: 370, width: 6, height: 60)
        let haloBefore = meanChannels(original, x: 542, y: 370, width: 6, height: 60)
        let core = meanChannels(result, x: 580, y: 360, width: 40, height: 80)
        let far = meanChannels(result, x: 60, y: 60, width: 40, height: 40)
        let farBefore = meanChannels(original, x: 60, y: 60, width: 40, height: 40)
        XCTAssertGreaterThan(halo[0] - halo[1], 4, "Light surroundings should receive a warm halo")
        XCTAssertGreaterThan(halo[0] - haloBefore[0], 5)
        XCTAssertGreaterThan(core.min()!, 245)
        XCTAssertLessThan(core.max()! - core.min()!, 3, "White lights should not be painted red")
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(far[channel] - farBefore[channel]), 1,
                                     "Dark pixels far from a light should stay untouched")
        }
        print("GLOW_OPTICS: halo red-green \(halo[0] - halo[1]), red lift \(halo[0] - haloBefore[0]), core RGB \(core), far RGB \(far)")
    }

    func testGlow800HasCoarserMostlyMonochromeGrainThanSilver35() async throws {
        let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(
            data: fixtureData(width: 600, height: 400, flatGray: 0.5)
        )
        let glow = try XCTUnwrap(photo.looks[.glow800])
        let silver = try XCTUnwrap(photo.looks[.silver35])
        let stats = grainStatistics(glow)
        let glowCorrelation = neighborCorrelation(glow)
        let silverCorrelation = neighborCorrelation(silver)
        XCTAssertGreaterThan(stats.lumaSD, 1)
        XCTAssertLessThan(stats.lumaSD, 10)
        XCTAssertLessThan(stats.chromaSD, 1.3)
        XCTAssertGreaterThan(glowCorrelation, silverCorrelation + 0.08,
                             "Larger grains should have stronger correlation between adjacent pixels")
        print("GLOW_GRAIN: SD \(stats.lumaSD), chroma SD \(stats.chromaSD), neighbor correlation \(glowCorrelation), Silver \(silverCorrelation)")
    }

    func testGlow800BrightWindowExportMatchesPreviewAndOrientation() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        for orientation in [1, 6] {
            let data = try fixtureData(width: 1_200, height: 800, orientation: orientation, brightWindow: true)
            let photo = try await renderer.prepare(data: data)
            for intensity in [0.5, 1.0] {
                let preview = try await renderer.blend(photo: photo, preset: .glow800, intensity: intensity)
                let url = try await renderer.export(photo: photo, preset: .glow800, intensity: intensity)
                defer { try? FileManager.default.removeItem(at: url) }
                let full = try exportedImage(url)
                XCTAssertEqual(full.width, orientation == 1 ? 1_200 : 800)
                XCTAssertEqual(full.height, orientation == 1 ? 800 : 1_200)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                ] as CFDictionary))
                let difference = meanDifference(pixels(preview), pixels(reduced))
                XCTAssertLessThan(difference, 3)
                XCTAssertGreaterThan(lumaCorrelation(preview, reduced), 0.95)
                print("GLOW_EXPORT: orientation \(orientation), intensity \(intensity), mean difference \(difference)")
            }
        }
    }

    func testScratchTextureHasLongBrokenNeutralMarksAndSparseCoverage() throws {
        let size = CGSize(width: 3_000, height: 2_002)
        let texture = try ScratchArtifacts.texture(sourceSize: size)
        let data = pixels(texture)
        XCTAssertTrue(data == pixels(try ScratchArtifacts.texture(sourceSize: size)))
        XCTAssertEqual(texture.width, 1_800)
        XCTAssertEqual(texture.height, 1_202)
        var counts = [Int](repeating: 0, count: texture.width)
        var firstRows = [Int](repeating: texture.height, count: texture.width)
        var lastRows = [Int](repeating: 0, count: texture.width)
        var occupied = 0
        var light = 0
        var dark = 0
        var maxAlpha = 0
        var maxChannelDifference = 0
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let i = (y * texture.width + x) * 4
                let alpha = Int(data[i + 3])
                maxAlpha = max(maxAlpha, alpha)
                guard alpha > 6 else { continue }
                occupied += 1
                counts[x] += 1
                firstRows[x] = min(firstRows[x], y)
                lastRows[x] = max(lastRows[x], y)
                if Double(data[i]) > Double(alpha) * 0.8 { light += 1 }
                if Double(data[i]) < Double(alpha) * 0.25 { dark += 1 }
                maxChannelDifference = max(maxChannelDifference,
                    abs(Int(data[i]) - Int(data[i + 1])), abs(Int(data[i + 1]) - Int(data[i + 2])))
            }
        }
        let column = try XCTUnwrap(counts.indices.max(by: { counts[$0] < counts[$1] }))
        let span = lastRows[column] - firstRows[column]
        var run = 0
        var longestRun = 0
        for y in 0..<texture.height {
            if data[(y * texture.width + column) * 4 + 3] > 6 {
                run += 1
                longestRun = max(longestRun, run)
            } else { run = 0 }
        }
        let coverage = Double(occupied) / Double(texture.width * texture.height)
        let dust = pixels(try DustArtifacts.texture(sourceSize: size))
        let dustOccupied = stride(from: 3, to: dust.count, by: 4).reduce(0) { $0 + (dust[$1] > 6 ? 1 : 0) }
        XCTAssertGreaterThan(occupied, dustOccupied * 2)
        XCTAssertLessThan(coverage, 0.015, "Marks should occupy less than 1.5% of the frame")
        XCTAssertGreaterThan(light, 100)
        XCTAssertGreaterThan(dark, 100)
        XCTAssertLessThan(maxAlpha, 190, "Keep the underlying image visible")
        XCTAssertLessThanOrEqual(maxChannelDifference, 1)
        XCTAssertGreaterThan(span, texture.height / 2, "Include long vertical scratches")
        XCTAssertGreaterThan(counts[column], texture.height / 8)
        XCTAssertLessThan(longestRun, span / 2, "Long marks should contain visible interruptions")
        print("SCRATCH_TEXTURE: coverage \(coverage), column span \(span), marked rows \(counts[column]), longest run \(longestRun), max alpha \(maxAlpha)")
    }

    func testScratch16HasCoarseNeutralTextureAndDistinctContrast() async throws {
        let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(
            data: fixtureData(width: 600, height: 400, flatGray: 0.5)
        )
        let scratch = try XCTUnwrap(photo.looks[.scratch16])
        let silver = try XCTUnwrap(photo.looks[.silver35])
        let stats = grainStatistics(scratch)
        let correlation = neighborCorrelation(scratch)
        XCTAssertGreaterThan(stats.lumaSD, grainStatistics(silver).lumaSD * 0.95)
        XCTAssertLessThan(stats.lumaSD, 12)
        XCTAssertLessThan(stats.chromaSD, 0.1)
        XCTAssertGreaterThan(correlation, neighborCorrelation(silver) + 0.12)
        XCTAssertGreaterThan(meanDifference(pixels(scratch), pixels(silver)), 3)
        print("SCRATCH_GRAIN: luma SD \(stats.lumaSD), chroma SD \(stats.chromaSD), neighbor correlation \(correlation)")
    }

    func testScratch16ExportKeepsTextureAlignmentAndUprightFullSize() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        for orientation in [1, 6] {
            let photo = try await renderer.prepare(data: fixtureData(
                width: 1_800, height: 1_200, orientation: orientation, flatGray: 0.5
            ))
            let preview = try XCTUnwrap(photo.looks[.scratch16])
            let url = try await renderer.export(photo: photo, preset: .scratch16, intensity: 1)
            defer { try? FileManager.default.removeItem(at: url) }
            let full = try exportedImage(url)
            XCTAssertEqual(full.width, orientation == 1 ? 1_800 : 1_200)
            XCTAssertEqual(full.height, orientation == 1 ? 1_200 : 1_800)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
            ] as CFDictionary))
            let difference = meanDifference(pixels(preview), pixels(reduced))
            let correlation = lumaCorrelation(preview, reduced)
            XCTAssertLessThan(difference, 3)
            XCTAssertGreaterThan(correlation, 0.85)
            print("SCRATCH_EXPORT: orientation \(orientation), mean difference \(difference), correlation \(correlation)")
        }
    }

    func testExpired35FieldsAreStableOpaqueAndKeepWearNearEdges() throws {
        let size = CGSize(width: 3_000, height: 2_002)
        let first = try Expired35Artifacts.fields(sourceSize: size)
        let second = try Expired35Artifacts.fields(sourceSize: size)
        XCTAssertEqual(first.stains.width, 600)
        XCTAssertEqual(first.stains.height, 401)
        for (a, b) in [(first.stains, second.stains), (first.leaks, second.leaks)] {
            XCTAssertEqual(pixels(a), pixels(b))
            let bytes = pixels(a)
            XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
        }
        let stains = pixels(first.stains)
        var greenMarks = 0
        var magentaMarks = 0
        for i in stride(from: 0, to: stains.count, by: 4) {
            if Int(stains[i + 1]) - Int(stains[i]) > 6 { greenMarks += 1 }
            if Int(stains[i]) - Int(stains[i + 1]) > 6 { magentaMarks += 1 }
        }
        XCTAssertGreaterThan(greenMarks, 1_000)
        XCTAssertGreaterThan(magentaMarks, 1_000)
        let center = meanChannels(first.stains, x: 270, y: 180, width: 60, height: 40)
        XCTAssertLessThan((center.max() ?? 0) - (center.min() ?? 0), 1)
        let centerLeak = meanChannels(first.leaks, x: 270, y: 180, width: 60, height: 40)
        XCTAssertLessThan(centerLeak.max() ?? 255, 1)
        let marks = try Expired35Artifacts.marks(sourceSize: size)
        XCTAssertEqual(pixels(marks), pixels(try Expired35Artifacts.marks(sourceSize: size)))
        let clearCenter = try XCTUnwrap(marks.cropping(to: CGRect(x: 540, y: 360, width: 720, height: 480)))
        let centerBytes = pixels(clearCenter)
        XCTAssertTrue(stride(from: 3, to: centerBytes.count, by: 4).allSatisfy { centerBytes[$0] == 0 })
        let markBytes = pixels(marks)
        XCTAssertTrue(stride(from: 3, to: markBytes.count, by: 4).contains { markBytes[$0] > 15 })
        print("EXPIRED_FIELDS: green pixels \(greenMarks), magenta pixels \(magentaMarks), center leak \(centerLeak)")
    }

    func testExpired35LightLeaksLiftWarmEdgesAndPreserveCenter() async throws {
        let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(
            data: fixtureData(width: 600, height: 400, flatGray: 0.5)
        )
        let input = CIImage(cgImage: photo.original)
        let aged = try renderedCI(Expired35Artifacts.apply(to: input, sourceSize: CGSize(width: 600, height: 400)))
        let center = meanChannels(aged, x: 270, y: 180, width: 60, height: 40)
        let originalCenter = meanChannels(photo.original, x: 270, y: 180, width: 60, height: 40)
        for channel in 0..<3 { XCTAssertLessThan(abs(center[channel] - originalCenter[channel]), 2) }
        let edge = meanChannels(aged, x: 0, y: 270, width: 20, height: 50)
        XCTAssertGreaterThan(edge[0] - center[0], 15)
        XCTAssertGreaterThan(edge[0] - edge[1], 15)
        let bytes = pixels(aged)
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
        print("EXPIRED_OPTICS: center \(center), warm edge \(edge)")
    }

    func testExpired35CenterRetainsCoarseMostlyMonochromeGrain() async throws {
        let photo = try await PhotoRenderer(maxPreviewDimension: 600).prepare(
            data: fixtureData(width: 600, height: 400, flatGray: 0.5)
        )
        let expired = try XCTUnwrap(photo.looks[.expired35])
        let crop = try XCTUnwrap(expired.cropping(to: CGRect(x: 240, y: 140, width: 120, height: 120)))
        let stats = grainStatistics(crop)
        XCTAssertGreaterThan(stats.lumaSD, 3)
        XCTAssertLessThan(stats.lumaSD, 11)
        XCTAssertLessThan(stats.chromaSD, 1.5)
        XCTAssertGreaterThan(neighborCorrelation(crop), 0.60)
        print("EXPIRED_GRAIN: center luma SD \(stats.lumaSD), chroma SD \(stats.chromaSD), neighbor correlation \(neighborCorrelation(crop))")
    }

    func testExpired35ExportKeepsWearAlignmentInBothOrientationsAndIntensities() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        for orientation in [1, 6] {
            let data = try fixtureData(width: 1_800, height: 1_200, orientation: orientation, flatGray: 0.5)
            let photo = try await renderer.prepare(data: data)
            for intensity in [0.5, 1.0] {
                let preview = try await renderer.blend(photo: photo, preset: .expired35, intensity: intensity)
                let url = try await renderer.export(photo: photo, preset: .expired35, intensity: intensity)
                defer { try? FileManager.default.removeItem(at: url) }
                let full = try exportedImage(url)
                XCTAssertEqual(full.width, orientation == 1 ? 1_800 : 1_200)
                XCTAssertEqual(full.height, orientation == 1 ? 1_200 : 1_800)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                ] as CFDictionary))
                let difference = meanDifference(pixels(preview), pixels(reduced))
                let correlation = lumaCorrelation(preview, reduced)
                XCTAssertLessThan(difference, 3)
                XCTAssertGreaterThan(correlation, 0.90)
                XCTAssertEqual(photo.sourceData, data)
                print("EXPIRED_EXPORT: orientation \(orientation), intensity \(intensity), mean difference \(difference), correlation \(correlation)")
            }
        }
    }

    func testPaper35ReliefIsStableNeutralOpaqueAndUsesBoundedReference() throws {
        let size = CGSize(width: 3_000, height: 2_000)
        let first = try Paper35Texture.heightMap(sourceSize: size)
        XCTAssertEqual(first.extent, CGRect(x: -4, y: -4, width: 1_808, height: 1_208))
        let sample = CGRect(x: 0, y: 0, width: 600, height: 400)
        let a = try renderedCI(first.cropped(to: sample))
        let b = try renderedCI(Paper35Texture.heightMap(sourceSize: size).cropped(to: sample))
        XCTAssertEqual(pixels(a), pixels(b))
        let stats = grainStatistics(a)
        XCTAssertGreaterThan(stats.lumaSD, 3)
        XCTAssertLessThan(stats.lumaSD, 20)
        XCTAssertLessThan(stats.chromaSD, 0.1)
        let data = pixels(a)
        XCTAssertTrue(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 255 })
        print("PAPER_RELIEF: luma SD \(stats.lumaSD), chroma SD \(stats.chromaSD)")
    }

    func testPaperTextureKeepsPaleAreasNeutralAndPreservesShadowDetail() throws {
        let size = CGSize(width: 600, height: 400)
        var deviations: [Double] = []
        for gray in [CGFloat(0.04), 0.5, 0.95] {
            let input = try XCTUnwrap(CIImage(data: fixtureData(width: 600, height: 400, flatGray: gray)))
            let result = try renderedCI(Paper35Texture.apply(to: input, sourceSize: size))
            let stats = grainStatistics(result)
            deviations.append(stats.lumaSD)
            let data = pixels(result)
            XCTAssertTrue(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 255 })
            if gray == 0.95 {
                let channels = meanChannels(result, x: 20, y: 20, width: 560, height: 360)
                XCTAssertLessThan((channels.max() ?? 0) - (channels.min() ?? 0), 1, "Paper relief should preserve neutral whites")
                XCTAssertLessThan(stats.lumaSD, 8, "Texture must retain smooth pale image detail")
            }
        }
        XCTAssertGreaterThan(deviations[2], 0.5)
        XCTAssertLessThan(deviations[0], deviations[2] * 0.3)
        print("PAPER_VISIBILITY: dark, midtone, highlight SD \(deviations)")
    }

    func testPaperMatteHasDeepSoftBlacksAndNeutralWhites() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        var levels: [[Double]] = []
        for gray in [CGFloat(0), 1] {
            let photo = try await renderer.prepare(data: fixtureData(width: 600, height: 400, flatGray: gray))
            let look = try XCTUnwrap(photo.looks[.paper35])
            levels.append(meanChannels(look, x: 20, y: 20, width: 560, height: 360))
        }
        XCTAssertGreaterThan(levels[0][0], 1)
        XCTAssertLessThan(levels[0][0], 20)
        XCTAssertGreaterThan(levels[1][0], 240)
        XCTAssertLessThan(levels[1][0], 254)
        XCTAssertLessThan((levels[1].max() ?? 0) - (levels[1].min() ?? 0), 2)
        print("PAPER_ENDPOINTS: black \(levels[0]), white \(levels[1])")
    }

    func testPaperFamilyExportKeepsPaperAlignmentAndUprightFullResolution() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        for orientation in [1, 6] {
            let data = try fixtureData(width: 1_800, height: 1_200, orientation: orientation, flatGray: 0.75)
            let photo = try await renderer.prepare(data: data)
            for (preset, intensity) in PhotoPresetFamily.paper.presets.flatMap({ preset in
                [0.5, 1.0].map { (preset, $0) }
            }) {
                let preview = try await renderer.blend(photo: photo, preset: preset, intensity: intensity)
                let url = try await renderer.export(photo: photo, preset: preset, intensity: intensity)
                defer { try? FileManager.default.removeItem(at: url) }
                let full = try exportedImage(url)
                XCTAssertEqual(full.width, orientation == 1 ? 1_800 : 1_200)
                XCTAssertEqual(full.height, orientation == 1 ? 1_200 : 1_800)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                ] as CFDictionary))
                let difference = meanDifference(pixels(preview), pixels(reduced))
                let correlation = lumaCorrelation(preview, reduced)
                XCTAssertLessThan(difference, 3)
                XCTAssertGreaterThan(correlation, 0.85)
                XCTAssertEqual(photo.sourceData, data)
                print("PAPER_EXPORT \(preset.code): orientation \(orientation), intensity \(intensity), mean difference \(difference), correlation \(correlation)")
            }
        }
    }

    func testFamilySelectionRemembersVariantAndKeepsEditWhenImportingAnotherPhoto() async throws {
        let model = EditorModel(renderer: PhotoRenderer(maxPreviewDimension: 120))
        model.selectFamily(.paper)
        XCTAssertEqual(model.selectedPreset, .paper35)
        model.selectedPreset = .paperWarm
        model.intensity = 0.47
        model.importPhoto(data: try fixtureData())
        try await waitUntil { !model.isImporting && model.hasPhoto }
        XCTAssertEqual(model.selectedFamily, .paper)
        XCTAssertEqual(model.selectedPreset, .paperWarm)
        model.selectFamily(.originals)
        XCTAssertEqual(model.selectedPreset, .amber)
        model.selectedPreset = .tide
        model.selectFamily(.paper)
        XCTAssertEqual(model.selectedPreset, .paperWarm)
        model.selectedPreset = .paperArchive
        model.selectFamily(.originals)
        XCTAssertEqual(model.selectedPreset, .tide)
        model.selectFamily(.paper)
        XCTAssertEqual(model.selectedPreset, .paperArchive)
        XCTAssertEqual(model.intensity, 0.47)
        try await waitUntil { !model.isRendering }
        let expected = try await PhotoRenderer().blend(photo: XCTUnwrap(model.photo), preset: .paperArchive, intensity: 0.47)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expected))
        model.importPhoto(data: try fixtureData(width: 200, height: 100, orientation: 6))
        try await waitUntil { !model.isImporting && model.hasPhoto }
        XCTAssertEqual(model.photo?.pixelSize, "100 × 200")
        XCTAssertEqual(model.selectedFamily, .paper)
        XCTAssertEqual(model.selectedPreset, .paperArchive)
        XCTAssertEqual(model.intensity, 0.47)
        let reachable = PhotoPresetFamily.allCases.flatMap(\.presets)
        XCTAssertEqual(Set(reachable), Set(PhotoPreset.allCases))
        XCTAssertEqual(reachable.count, PhotoPreset.allCases.count, "Each look should appear in one collection")
    }

    func testNILUTMatchesIndependentNeuralReferenceInSRGB() throws {
        let url = try XCTUnwrap(NILUTColorGrade.resourceURL(name: "manifest", fileExtension: "json"))
        let reference = try JSONDecoder().decode(NILUTReference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.styles.count, NILUTStyle.allCases.count)
        let bytes: [UInt8] = reference.reference_input_srgb8.flatMap { $0 + [UInt8(255)] }
        let input = CIImage(bitmapData: Data(bytes), bytesPerRow: bytes.count,
                            size: CGSize(width: reference.reference_input_srgb8.count, height: 1),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for (index, style) in NILUTStyle.allCases.enumerated() {
            let cube = try NILUTColorGrade.loadCube(style: style)
            let image = try renderedCI(NILUTColorGrade.apply(to: input, cubeData: cube))
            let output = pixels(image)
            var worst = 0
            for (sample, expected) in reference.styles[index].reference_output_srgb.enumerated() {
                for channel in 0..<3 {
                    let difference = abs(Int(output[sample * 4 + channel]) - Int((expected[channel] * 255).rounded()))
                    worst = max(worst, difference)
                    XCTAssertLessThanOrEqual(difference, 2, "\(style), RGB \(reference.reference_input_srgb8[sample]), channel \(channel)")
                }
                XCTAssertEqual(output[sample * 4 + 3], 255)
            }
            print("NILUT_REFERENCE: \(style), maximum native/model channel error \(worst)/255")
        }
    }

    func testNILUTRejectsCorruptOrMismatchedLookupResources() throws {
        let url = try XCTUnwrap(NILUTColorGrade.resourceURL(name: "style-1", fileExtension: "nlut"))
        let valid = try Data(contentsOf: url)
        XCTAssertEqual(try NILUTColorGrade.decodeCube(valid, style: .style1).count, 65 * 65 * 65 * 4 * 4)
        XCTAssertThrowsError(try NILUTColorGrade.decodeCube(valid, style: .style2))
        XCTAssertThrowsError(try NILUTColorGrade.decodeCube(valid.dropLast(), style: .style1))
        var damaged = valid
        damaged[0] = 0
        XCTAssertThrowsError(try NILUTColorGrade.decodeCube(damaged, style: .style1))
        damaged = valid
        damaged[16] = 0
        damaged[17] = 0x7e // float16 NaN
        XCTAssertThrowsError(try NILUTColorGrade.decodeCube(damaged, style: .style1))
    }

    func testNILUTFamilyRemembersStyleAndIntensityAcrossImports() async throws {
        XCTAssertEqual(PhotoPresetFamily.nilut.presets, [.nilut1, .nilut2, .nilut3, .nilutNatural, .nilutSoftWarm, .nilutCoolMatte])
        let model = EditorModel(renderer: PhotoRenderer(maxPreviewDimension: 120))
        model.selectFamily(.nilut)
        XCTAssertEqual(model.selectedPreset, .nilut1)
        model.selectedPreset = .nilut2
        model.intensity = 0.42
        model.importPhoto(data: try fixtureData())
        try await waitUntil { !model.isImporting && model.hasPhoto }
        model.selectFamily(.paper)
        model.selectedPreset = .paperWarm
        model.selectFamily(.nilut)
        XCTAssertEqual(model.selectedPreset, .nilut2)
        model.selectedPreset = .nilutCoolMatte
        model.selectFamily(.originals)
        model.selectFamily(.nilut)
        XCTAssertEqual(model.selectedPreset, .nilutCoolMatte)
        XCTAssertEqual(model.intensity, 0.42)
        try await waitUntil { !model.isRendering }
        let expected = try await PhotoRenderer().blend(photo: XCTUnwrap(model.photo), preset: .nilutCoolMatte, intensity: 0.42)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expected))
        model.importPhoto(data: try fixtureData(width: 200, height: 100, orientation: 6))
        try await waitUntil { !model.isImporting && model.hasPhoto }
        XCTAssertEqual(model.photo?.pixelSize, "100 × 200")
        XCTAssertEqual(model.selectedPreset, .nilutCoolMatte)
        XCTAssertEqual(model.intensity, 0.42)
    }

    func testOriginalNILUTLooksKeepSmoothRampsCleanWhitesAndRestrainedSkinHue() throws {
        let skin: [[UInt8]] = [[232,186,160], [198,134,99], [116,75,58], [69,43,33]]
        let ramp = (0...255).map { [UInt8($0), UInt8($0), UInt8($0)] }
        let samples = ramp + skin
        let bytes = samples.flatMap { $0 + [UInt8(255)] }
        let input = CIImage(bitmapData: Data(bytes), bytesPerRow: bytes.count,
                            size: CGSize(width: samples.count, height: 1), format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        func hue(_ rgb: [UInt8]) -> Double {
            let c = rgb.map(Double.init)
            return atan2(sqrt(3) * (c[1]-c[2]), 2*c[0]-c[1]-c[2])
        }
        for style in [NILUTStyle.natural, .softWarm, .coolMatte] {
            let output = pixels(try renderedCI(NILUTColorGrade.apply(to: input, cubeData: NILUTColorGrade.loadCube(style: style))))
            for level in 1...255 {
                for channel in 0..<3 {
                    let step = Int(output[level*4+channel])-Int(output[(level-1)*4+channel])
                    XCTAssertGreaterThanOrEqual(step, -1, "\(style): reversed neutral ramp at \(level)")
                    XCTAssertLessThanOrEqual(step, 4, "\(style): visible discontinuity at \(level)")
                }
            }
            let white = Array(output[255*4..<(255*4+3)]).map(Int.init)
            XCTAssertGreaterThanOrEqual(white.min() ?? 0, 252, "\(style): whites should stay clean")
            XCTAssertLessThanOrEqual((white.max() ?? 0)-(white.min() ?? 0), 3)
            if style == .natural {
                for level in stride(from: 16, through: 240, by: 16) {
                    let gray = output[level*4..<(level*4+3)].map(Int.init)
                    XCTAssertLessThanOrEqual((gray.max() ?? 0)-(gray.min() ?? 0), 3, "Natural must not add a global color cast")
                }
            }
            for (index, source) in skin.enumerated() {
                let result = Array(output[(256+index)*4..<((256+index)*4+3)])
                let delta = hue(result)-hue(source)
                let degrees = abs(atan2(sin(delta), cos(delta)))*180/Double.pi
                XCTAssertLessThan(degrees, 8, "\(style): skin-hue patch \(source), output \(result)")
            }
        }
    }

    func testRevisedNILUTLooksHaveVisibleCharacterAtDefaultIntensity() throws {
        let samples: [[UInt8]] = [[64,64,64], [192,192,192], [128,128,128]]
        let bytes = samples.flatMap { $0 + [UInt8(255)] }
        let input = CIImage(bitmapData: Data(bytes), bytesPerRow: bytes.count,
                            size: CGSize(width: samples.count, height: 1), format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        func atDefaultIntensity(_ style: NILUTStyle) throws -> [UInt8] {
            let look = try NILUTColorGrade.apply(to: input, cubeData: NILUTColorGrade.loadCube(style: style))
            let blend = CIFilter.dissolveTransition()
            blend.inputImage = input
            blend.targetImage = look
            blend.time = 0.8
            return pixels(try renderedCI(XCTUnwrap(blend.outputImage)))
        }
        let natural = try atDefaultIntensity(.natural)
        XCTAssertLessThan(Int(natural[0]), 56, "Natural needs visibly denser shadows at 80%")
        XCTAssertGreaterThan(Int(natural[4]), 202, "Natural needs distinct upper-midtone contrast at 80%")
        let warm = try atDefaultIntensity(.softWarm)
        XCTAssertGreaterThan(Int(warm[8])-Int(warm[10]), 18, "Soft Warm needs a clear golden midtone, not a near-identity result")
        XCTAssertGreaterThan(Int(warm[9])-Int(warm[10]), 8)
    }

    func testNILUTFullResolutionExportMatchesPreviewIncludingOrientationAndIntensity() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        for orientation in [1, 6] {
            let source = try fixtureData(width: 1_800, height: 1_200, orientation: orientation)
            let photo = try await renderer.prepare(data: source)
            for preset in PhotoPresetFamily.nilut.presets {
                for amount in [0.0, 0.5, 1.0] {
                    let preview = try await renderer.blend(photo: photo, preset: preset, intensity: amount)
                    let url = try await renderer.export(photo: photo, preset: preset, intensity: amount)
                    defer { try? FileManager.default.removeItem(at: url) }
                    let image = try exportedImage(url)
                    XCTAssertEqual(image.width, orientation == 1 ? 1_800 : 1_200)
                    XCTAssertEqual(image.height, orientation == 1 ? 1_200 : 1_800)
                    let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                    let reduced = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(encoded, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600
                    ] as CFDictionary))
                    XCTAssertEqual(reduced.width, preview.width)
                    XCTAssertEqual(reduced.height, preview.height)
                    let difference = meanDifference(pixels(reduced), pixels(preview))
                    XCTAssertLessThan(difference, 1.5, "\(preset), \(amount), EXIF \(orientation)")
                    XCTAssertEqual(photo.sourceData, source)
                    print("NILUT_EXPORT: \(preset), \(amount), EXIF \(orientation), preview/export mean error \(difference)/255")
                }
            }
        }
    }

    func testPaperFamilyHasSharedTextureAndDistinctWarmAndArchiveCharacter() async throws {
        let renderer = PhotoRenderer(maxPreviewDimension: 600)
        let photo = try await renderer.prepare(data: fixtureData(width: 600, height: 400, flatGray: 0.5))
        let matte = try XCTUnwrap(photo.looks[.paper35])
        let warm = try XCTUnwrap(photo.looks[.paperWarm])
        let archive = try XCTUnwrap(photo.looks[.paperArchive])
        let matteRGB = meanChannels(matte, x: 20, y: 20, width: 560, height: 360)
        let warmRGB = meanChannels(warm, x: 20, y: 20, width: 560, height: 360)
        XCTAssertLessThan((matteRGB.max() ?? 0) - (matteRGB.min() ?? 0), 1)
        XCTAssertLessThan((warmRGB.max() ?? 0) - (warmRGB.min() ?? 0), 2)
        XCTAssertGreaterThan(lumaCorrelation(matte, warm), 0.9)
        XCTAssertGreaterThan(lumaCorrelation(matte, archive), 0.9)
        let colorful = try await renderer.prepare(data: fixtureData(width: 600, height: 400))
        let archivePixels = pixels(try XCTUnwrap(colorful.looks[.paperArchive]))
        var greatestChroma = 0
        for i in stride(from: 0, to: archivePixels.count, by: 4) {
            let channels = archivePixels[i..<(i + 3)].map(Int.init)
            greatestChroma = max(greatestChroma, (channels.max() ?? 0) - (channels.min() ?? 0))
        }
        XCTAssertLessThan(greatestChroma, 25, "Archive should be black-and-white with a restrained warm paper tint")
        print("PAPER_FAMILY: matte RGB \(matteRGB), warm RGB \(warmRGB), correlations \(lumaCorrelation(matte, warm)) / \(lumaCorrelation(matte, archive)), Archive max chroma \(greatestChroma)")
    }

    func testPaperColorGradeKeepsNeutralRampSmoothAndUncolored() throws {
        let patches = (0...255).map { index -> [CGFloat] in
            let value = CGFloat(index) / 255
            return [value, value, value, 1]
        }
        let input = try XCTUnwrap(CIImage(data: fixtureData(width: 1_024, height: 64, colorPatches: patches)))
        for variant in [PaperVariant.matte, .warm] {
            let result = try renderedCI(PaperColorGrade.apply(to: input, variant: variant))
            let data = pixels(result)
            var previous = -1
            var levels: Set<Int> = []
            for x in 0..<result.width {
                let i = (32 * result.width + x) * 4
                let channels = data[i..<(i + 3)].map(Int.init)
                XCTAssertLessThanOrEqual((channels.max() ?? 0) - (channels.min() ?? 0), 1)
                let value = channels[0]
                XCTAssertGreaterThanOrEqual(value, previous - 1)
                previous = value
                levels.insert(value)
            }
            XCTAssertGreaterThan(levels.count, 220, "Keep a smooth tonal range")
            print("PAPER_RAMP \(variant): \(levels.count) distinct neutral levels")
        }
    }

    func testNaturalPaperColorsPreserveSkinAndSceneHueAndSaturation() async throws {
        let patches: [[CGFloat]] = [
            [0.82, 0.61, 0.49, 1], [0.61, 0.40, 0.29, 1],
            [0.36, 0.23, 0.17, 1], [0.92, 0.76, 0.65, 1],
            [0.19, 0.46, 0.23, 1], [0.18, 0.37, 0.65, 1], [0.76, 0.17, 0.17, 1]
        ]
        let renderer = PhotoRenderer(maxPreviewDimension: 700)
        let photo = try await renderer.prepare(data: fixtureData(width: 700, height: 100, colorPatches: patches))
        func hueAndSaturation(_ rgb: [Double]) -> (Double, Double) {
            let high = rgb.max() ?? 0
            let low = rgb.min() ?? 0
            let delta = high - low
            guard delta > 0 else { return (0, 0) }
            var hue: Double
            if high == rgb[0] { hue = (rgb[1] - rgb[2]) / delta }
            else if high == rgb[1] { hue = 2 + (rgb[2] - rgb[0]) / delta }
            else { hue = 4 + (rgb[0] - rgb[1]) / delta }
            hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
            return (hue, delta / high)
        }
        for preset in [PhotoPreset.paper35, .paperWarm] {
            let look = try XCTUnwrap(photo.looks[preset])
            var maximumHueChange = 0.0
            var minimumSaturationRatio = 1.0
            for index in patches.indices {
                let original = meanChannels(photo.original, x: index * 100 + 10, y: 10, width: 80, height: 80)
                let result = meanChannels(look, x: index * 100 + 10, y: 10, width: 80, height: 80)
                let a = hueAndSaturation(original)
                let b = hueAndSaturation(result)
                let hueChange = min(abs(a.0 - b.0), 360 - abs(a.0 - b.0))
                maximumHueChange = max(maximumHueChange, hueChange)
                minimumSaturationRatio = min(minimumSaturationRatio, b.1 / a.1)
                XCTAssertLessThan(hueChange, preset == .paper35 ? 5 : 9, "\(preset.code), patch \(index)")
                XCTAssertGreaterThan(b.1 / a.1, 0.85, "Preserve natural color density")
                XCTAssertLessThan(b.1 / a.1, 1.20)
            }
            print("PAPER_COLOR \(preset.code): max hue change \(maximumHueChange), min saturation ratio \(minimumSaturationRatio)")
        }
    }

    func testPreviewPublishesActiveFrameThenOnlyTheLatestWaitingValue() async throws {
        let renderer = ControlledPhotoRenderer()
        let model = EditorModel(renderer: renderer, previewFrameInterval: .zero)
        model.importPhoto(data: try fixtureData())
        try await waitUntil { !model.isImporting && model.hasPhoto }
        await renderer.resetHistory()

        await renderer.holdNextBlend()
        model.intensity = 0.2
        try await waitUntil { await renderer.isHolding(0) }
        await renderer.holdNextBlend()
        for step in 21...90 { model.intensity = Double(step) / 100 }

        await renderer.release(0)
        try await waitUntil { await renderer.isHolding(1) }
        let photo = try XCTUnwrap(model.photo)
        let expectedFirst = try await PhotoRenderer().blend(photo: photo, preset: .amber, intensity: 0.2)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expectedFirst),
                       "An in-flight frame must be published even when newer slider values are waiting")
        let calls = await renderer.history()
        XCTAssertEqual(calls.map(\.intensity), [0.2, 0.9], "Intermediate waiting values should be coalesced")
        let peak = await renderer.peakConcurrentBlends()
        XCTAssertEqual(peak, 1)

        await renderer.release(1)
        try await waitUntil { !model.isRendering }
        let expectedFinal = try await PhotoRenderer().blend(photo: photo, preset: .amber, intensity: 0.9)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expectedFinal))
    }

    func testReplacingPhotoInvalidatesOldFramesWithoutStoppingNewWorker() async throws {
        let renderer = ControlledPhotoRenderer()
        let model = EditorModel(renderer: renderer, previewFrameInterval: .zero)
        model.importPhoto(data: try fixtureData())
        try await waitUntil { !model.isImporting && model.hasPhoto }
        await renderer.resetHistory()

        await renderer.holdNextBlend()
        model.intensity = 0.2
        try await waitUntil { await renderer.isHolding(0) }

        model.importPhoto(data: try fixtureData(width: 80, height: 120))
        try await waitUntil { !model.isImporting && model.photo?.pixelWidth == 80 }
        await renderer.holdNextBlend()
        model.selectedPreset = .mono
        model.intensity = 0.7
        try await waitUntil { await renderer.isHolding(2) }
        let newPhotoPreview = pixels(try XCTUnwrap(model.preview?.cgImage))

        // Simulate an old Core Image operation completing after its task was canceled.
        await renderer.release(0)
        try await waitUntil { await renderer.hasCompleted(0) }
        await Task.yield()
        XCTAssertTrue(model.isRendering, "An obsolete worker must not clear the current worker's state")
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), newPhotoPreview)

        model.intensity = 0.9
        await renderer.release(2)
        try await waitUntil { !model.isRendering }
        let photo = try XCTUnwrap(model.photo)
        let expected = try await PhotoRenderer().blend(photo: photo, preset: .mono, intensity: 0.9)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expected))
        XCTAssertEqual(model.photo?.pixelWidth, 80)
    }

    func testPreviewWorkerRecoversAfterRenderingError() async throws {
        let renderer = ControlledPhotoRenderer()
        let model = EditorModel(renderer: renderer, previewFrameInterval: .zero)
        model.importPhoto(data: try fixtureData())
        try await waitUntil { !model.isImporting && model.hasPhoto }

        await renderer.failNextBlend()
        model.intensity = 0.3
        try await waitUntil { !model.isRendering && model.notice != nil }
        model.notice = nil
        model.intensity = 0.7
        try await waitUntil { !model.isRendering }
        XCTAssertNil(model.notice)
        let expected = try await PhotoRenderer().blend(photo: XCTUnwrap(model.photo), preset: .amber, intensity: 0.7)
        XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expected))
    }

    func testRealPreviewKeepsUpdatingDuring120HzInputAndSettlesOnLastValue() async throws {
        let model = EditorModel()
        model.importPhoto(data: try fixtureData(width: 2_400, height: 1_600))
        try await waitUntil { !model.isImporting && model.hasPhoto }
        XCTAssertEqual(model.photo?.original.width, 1_800)
        for preset in [PhotoPreset.film35, .silver35, .dust35, .glow800, .scratch16, .expired35, .paper35, .paperWarm, .paperArchive, .nilut1, .nilut2, .nilut3, .nilutNatural, .nilutSoftWarm, .nilutCoolMatte] {
            model.selectedPreset = preset
            try await waitUntil { !model.isRendering }
            var publishedFrames = 0
            let observation = model.$preview.dropFirst().sink { _ in publishedFrames += 1 }
            defer { observation.cancel() }
            let clock = ContinuousClock()
            let start = clock.now
            for index in 1...48 {
                model.intensity = Double(index) / 50
                try await Task.sleep(for: .nanoseconds(8_333_333))
            }
            let framesDuringDrag = publishedFrames
            let release = clock.now
            try await waitUntil { !model.isRendering }
            let settled = clock.now
            XCTAssertGreaterThan(framesDuringDrag, 2, "Continuous input must not starve preview publication")
            let expected = try await PhotoRenderer().blend(photo: XCTUnwrap(model.photo), preset: preset, intensity: 0.96)
            XCTAssertEqual(pixels(try XCTUnwrap(model.preview?.cgImage)), pixels(expected))
            print("PREVIEW_STRESS \(preset.name): 48 input values; \(framesDuringDrag) frames during input; input duration \(start.duration(to: release)); settle \(release.duration(to: settled))")
        }
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for preview state")
                throw PreviewTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func exportedImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func fixtureData(width: Int = 120, height: Int = 80, orientation: Int = 1, includeLocation: Bool = false, flatGray: CGFloat? = nil, brightWindow: Bool = false, colorPatches: [[CGFloat]]? = nil) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors: [[CGFloat]] = colorPatches ?? (brightWindow ? [[0.03, 0.03, 0.03, 1]] : nil) ?? flatGray.map { [[$0, $0, $0, 1]] } ?? [
            [0.72, 0.48, 0.34, 1], [0.15, 0.42, 0.65, 1],
            [0.28, 0.60, 0.30, 1], [0.85, 0.74, 0.35, 1],
            [0.12, 0.12, 0.12, 1], [0.90, 0.90, 0.90, 1]
        ]
        for (index, components) in colors.enumerated() {
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: components)))
            let start = width * index / colors.count
            let end = width * (index + 1) / colors.count
            context.fill(CGRect(x: start, y: 0, width: end - start, height: height))
        }
        if brightWindow {
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: CGFloat(width) * 0.46, y: CGFloat(height) * 0.30,
                                width: CGFloat(width) * 0.08, height: CGFloat(height) * 0.40))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1,
            kCGImagePropertyOrientation: orientation
        ]
        if includeLocation {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 10.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 20.0,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func renderedCI(_ image: CIImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        return try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space))
    }

    private func meanChannels(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> [Double] {
        let data = pixels(image)
        var channels = [Double](repeating: 0, count: 3)
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let i = (row * image.width + column) * 4
                for channel in 0..<3 { channels[channel] += Double(data[i + channel]) }
            }
        }
        return channels.map { $0 / Double(width * height) }
    }

    private func neighborCorrelation(_ image: CGImage) -> Double {
        let values = lumaSamples(image)
        let rowWidth = image.width - 16
        let mean = values.reduce(0, +) / Double(values.count)
        var covariance = 0.0
        var variance = 0.0
        for index in values.indices where index % rowWidth < rowWidth - 1 {
            covariance += (values[index] - mean) * (values[index + 1] - mean)
            variance += (values[index] - mean) * (values[index] - mean)
        }
        return covariance / variance
    }

    private func meanDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        Double(zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(lhs.count)
    }

    private func lumaSamples(_ image: CGImage) -> [Double] {
        let bytes = pixels(image)
        return (8..<(image.height - 8)).flatMap { y in
            (8..<(image.width - 8)).map { x in
                let i = (y * image.width + x) * 4
                return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
            }
        }
    }

    private func deviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
    }

    private func grainStatistics(_ image: CGImage) -> (lumaSD: Double, chromaSD: Double) {
        let bytes = pixels(image)
        var redGreen: [Double] = []
        var greenBlue: [Double] = []
        for y in 8..<(image.height - 8) {
            for x in 8..<(image.width - 8) {
                let i = (y * image.width + x) * 4
                redGreen.append(Double(bytes[i]) - Double(bytes[i + 1]))
                greenBlue.append(Double(bytes[i + 1]) - Double(bytes[i + 2]))
            }
        }
        return (deviation(lumaSamples(image)), max(deviation(redGreen), deviation(greenBlue)))
    }

    private func lumaCorrelation(_ first: CGImage, _ second: CGImage) -> Double {
        let a = lumaSamples(first)
        let b = lumaSamples(second)
        guard a.count == b.count else { return 0 }
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var covariance = 0.0
        var sumA = 0.0
        var sumB = 0.0
        for (x, y) in zip(a, b) {
            covariance += (x - meanA) * (y - meanB)
            sumA += (x - meanA) * (x - meanA)
            sumB += (y - meanB) * (y - meanB)
        }
        return covariance / sqrt(sumA * sumB)
    }
}

private enum PreviewTestError: Error { case timeout }

/// A controllable renderer with real Core Image output. Held blends deliberately
/// finish after cancellation, as synchronous image rendering may do on a device.
private actor ControlledPhotoRenderer: PhotoRendering {
    struct Call: Sendable {
        let preset: PhotoPreset
        let intensity: Double
    }

    private let renderer = PhotoRenderer(maxPreviewDimension: 120)
    private var calls: [Call] = []
    private var completed: Set<Int> = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var holdCount = 0
    private var shouldFail = false
    private var active = 0
    private var peak = 0

    func prepare(data: Data) async throws -> PreparedPhoto {
        try await renderer.prepare(data: data)
    }

    func export(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) async throws -> URL {
        try await renderer.export(photo: photo, preset: preset, intensity: intensity)
    }

    func blend(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) async throws -> CGImage {
        let index = calls.count
        calls.append(Call(preset: preset, intensity: intensity))
        active += 1
        peak = max(peak, active)
        defer { active -= 1; completed.insert(index) }
        if holdCount > 0 {
            holdCount -= 1
            await withCheckedContinuation { held[index] = $0 }
        }
        if shouldFail {
            shouldFail = false
            throw PhotoError.renderingFailed
        }
        return try await Task.detached { [renderer] in
            try await renderer.blend(photo: photo, preset: preset, intensity: intensity)
        }.value
    }

    func holdNextBlend() { holdCount += 1 }
    func failNextBlend() { shouldFail = true }
    func isHolding(_ index: Int) -> Bool { held[index] != nil }
    func hasCompleted(_ index: Int) -> Bool { completed.contains(index) }
    func release(_ index: Int) { held.removeValue(forKey: index)?.resume() }
    func history() -> [Call] { calls }
    func peakConcurrentBlends() -> Int { peak }
    func resetHistory() { calls = []; completed = []; peak = 0 }
}
