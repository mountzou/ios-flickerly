import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Fixed styles sampled from upstream and Flickerly-trained NILUT networks. The app's working
/// space is linear sRGB; the network's lookup coordinates and values are sRGB.
enum NILUTColorGrade {
    static let dimension = 65

    static func resourceURL(name: String, fileExtension: String, bundle: Bundle = .main) -> URL? {
        // Xcode's synchronized folders copy their members into the bundle root;
        // folder references preserve NILUT/. Support both project formats.
        bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "NILUT")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
    }

    static func loadCube(style: NILUTStyle, bundle: Bundle = .main) throws -> Data {
        guard let url = resourceURL(name: style.resourceName, fileExtension: "nlut", bundle: bundle) else {
            throw PhotoError.renderingFailed
        }
        return try decodeCube(Data(contentsOf: url), style: style)
    }

    static func decodeCube(_ packed: Data, style: NILUTStyle) throws -> Data {
        let texels = dimension * dimension * dimension
        guard packed.count == 16 + texels * 3 * 2,
              packed.prefix(8) == Data("NILUTLUT".utf8) else { throw PhotoError.renderingFailed }
        let values: [Float] = try packed.withUnsafeBytes { bytes in
            let version = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            let edge = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
            let identifier = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            guard version == 1, edge == dimension, identifier == style.rawValue else {
                throw PhotoError.renderingFailed
            }
            var rgba = [Float](repeating: 1, count: texels * 4)
            for index in 0..<(texels * 3) {
                let bits = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + index * 2, as: UInt16.self))
                let value = Float(Float16(bitPattern: bits))
                guard value.isFinite, (0...1).contains(value) else { throw PhotoError.renderingFailed }
                rgba[(index / 3) * 4 + index % 3] = value
            }
            return rgba
        }
        return values.withUnsafeBytes { Data($0) }
    }

    static func apply(to input: CIImage, cubeData: Data) throws -> CIImage {
        let cube = CIFilter.colorCube()
        cube.cubeDimension = Float(dimension)
        cube.cubeData = cubeData
        // Explicit transfer functions keep the model's encoded-sRGB lookup
        // independent of the linear working space used by all other recipes.
        cube.inputImage = input.applyingFilter("CILinearToSRGBToneCurve")
        guard let output = cube.outputImage else { throw PhotoError.renderingFailed }
        return output.applyingFilter("CISRGBToneCurveToLinear").cropped(to: input.extent)
    }
}

struct PreparedPhoto: Sendable {
    // Keep the compressed source, never the preview, for full-resolution export.
    let sourceData: Data
    let original: CGImage
    let looks: [PhotoPreset: CGImage]
    let thumbnails: [PhotoPreset: CGImage]
    let pixelWidth: Int
    let pixelHeight: Int

    var pixelSize: String { "\(pixelWidth) × \(pixelHeight)" }
}

enum PhotoError: LocalizedError {
    case unreadableImage
    case renderingFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "We couldn't read this photo. Try a JPEG, HEIC or PNG image."
        case .renderingFailed:
            "We couldn't process this photo. Please try again."
        case .exportFailed:
            "We couldn't export this photo at its original resolution. Please try again."
        }
    }
}

protocol PhotoRendering: Sendable {
    func prepare(data: Data) async throws -> PreparedPhoto
    func blend(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) async throws -> CGImage
    func export(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) async throws -> URL
}

enum ExportSize: String, CaseIterable, Sendable {
    case original, medium, small

    var title: String {
        switch self {
        case .original: "Original size"
        case .medium: "Medium size"
        case .small: "Small size"
        }
    }

    var maxDimension: Int? {
        switch self {
        case .original: nil
        case .medium: 2048
        case .small: 1024
        }
    }
}

struct ExportOption: Identifiable, Sendable {
    let size: ExportSize
    let url: URL
    let bytes: Int64
    var id: String { size.rawValue }
}

extension PhotoRendering {
    func exportOptions(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) async throws -> [ExportOption] {
        var files: [URL] = []
        do {
            let original = try await export(photo: photo, preset: preset, intensity: intensity)
            files.append(original)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else { throw PhotoError.exportFailed }
            var options: [ExportOption] = []
            for size in ExportSize.allCases {
                try Task.checkCancellation()
                let url: URL
                if let maxDimension = size.maxDimension {
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary) else { throw PhotoError.exportFailed }
                    url = FileManager.default.temporaryDirectory.appendingPathComponent("Flickerly-\(preset.name)-\(UUID().uuidString).jpg")
                    files.append(url)
                    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoError.exportFailed }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw PhotoError.exportFailed }
                } else {
                    url = original
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let bytes = (attributes[.size] as? NSNumber)?.int64Value else { throw PhotoError.exportFailed }
                options.append(ExportOption(size: size, url: url, bytes: bytes))
            }
            try Task.checkCancellation()
            return options
        } catch {
            for url in files { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

/// All decoding and Core Image work runs away from the main actor.
/// Rendered looks are cached once per import; slider changes only blend two images.
actor PhotoRenderer: PhotoRendering {
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let maxPreviewDimension: Int
    private var nilutCubes: [NILUTStyle: Data] = [:]

    init(maxPreviewDimension: Int = 1_800) {
        self.maxPreviewDimension = maxPreviewDimension
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false
        ])
    }

    func prepare(data: Data) throws -> PreparedPhoto {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPreviewDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw PhotoError.unreadableImage
        }

        // Normalize the preview to SDR sRGB, including its embedded orientation.
        let original = try render(onWhiteBackground(CIImage(cgImage: decoded)))
        let input = CIImage(cgImage: original)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? decoded.width
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? decoded.height
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }
        let sourceSize = CGSize(width: width, height: height)
        var looks: [PhotoPreset: CGImage] = [:]
        var thumbnails: [PhotoPreset: CGImage] = [:]
        let paperRelief = try Paper35Texture.heightMap(sourceSize: sourceSize)

        for preset in PhotoPreset.allCases {
            try Task.checkCancellation()
            let look = try recipe(preset, input: input, sourceSize: sourceSize, paperRelief: paperRelief).cropped(to: input.extent)
            let cachedLook = try render(look)
            looks[preset] = cachedLook
            let scale = min(1, 240 / max(input.extent.width, input.extent.height))
            // Derive thumbnails from the cached look, including its exact grain.
            thumbnails[preset] = try render(resized(CIImage(cgImage: cachedLook), scale: scale))
        }

        return PreparedPhoto(
            sourceData: data,
            original: original,
            looks: looks,
            thumbnails: thumbnails,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    func blend(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) throws -> CGImage {
        try Task.checkCancellation()
        guard let look = photo.looks[preset] else { throw PhotoError.renderingFailed }
        let amount = min(max(intensity, 0), 1)
        if amount == 0 { return photo.original }
        if amount == 1 { return look }

        return try render(blendImage(
            original: CIImage(cgImage: photo.original), look: CIImage(cgImage: look), intensity: amount
        ))
    }

    /// Render from the source at its native pixel dimensions. Core Image evaluates
    /// the graph directly into a JPEG file, without caching full-size preset images.
    /// The caller owns the returned temporary file and must remove it after saving.
    func export(photo: PreparedPhoto, preset: PhotoPreset, intensity: Double) throws -> URL {
        try Task.checkCancellation()
        guard let source = CIImage(data: photo.sourceData, options: [
            .applyOrientationProperty: true,
            .expandToHDR: false
        ]) else { throw PhotoError.unreadableImage }

        let input = onWhiteBackground(source.transformed(by: .init(
            translationX: -source.extent.minX, y: -source.extent.minY
        )))
        guard Int(input.extent.width) == photo.pixelWidth,
              Int(input.extent.height) == photo.pixelHeight else { throw PhotoError.exportFailed }

        let output = try blendImage(
            original: input,
            look: recipe(preset, input: input, sourceSize: CGSize(width: photo.pixelWidth, height: photo.pixelHeight)),
            intensity: intensity
        )
        // Pixels are already upright. Do not copy the source's orientation or GPS metadata.
        let upright = output.settingProperties([kCGImagePropertyOrientation as String: 1])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Flickerly-\(preset.name)-\(UUID().uuidString).jpg")

        do {
            try context.writeJPEGRepresentation(of: upright, to: url, colorSpace: colorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95
            ])
            try Task.checkCancellation()
            // Validate the encoded file itself before handing it to PhotoKit.
            guard let encoded = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == photo.pixelWidth,
                  properties[kCGImagePropertyPixelHeight] as? Int == photo.pixelHeight else {
                throw PhotoError.exportFailed
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func blendImage(original: CIImage, look: CIImage, intensity: Double) throws -> CIImage {
        let amount = min(max(intensity, 0), 1)
        if amount == 0 { return original }
        if amount == 1 { return look.cropped(to: original.extent) }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = original
        blend.targetImage = look
        blend.time = Float(amount)
        guard let output = blend.outputImage else { throw PhotoError.renderingFailed }
        return output.cropped(to: original.extent)
    }

    private func onWhiteBackground(_ image: CIImage) -> CIImage {
        image.composited(over: CIImage(color: .white).cropped(to: image.extent))
    }

    private func render(_ image: CIImage) throws -> CGImage {
        guard let result = context.createCGImage(
            image, from: image.extent, format: .RGBA8, colorSpace: colorSpace
        ) else { throw PhotoError.renderingFailed }
        return result
    }

    /// Original recipes, built from color transforms and a five-point tone curve.
    /// Every look starts from the source; edits never accumulate on previous results.
    private func recipe(_ preset: PhotoPreset, input: CIImage, sourceSize: CGSize,
                        paperRelief: CIImage? = nil) throws -> CIImage {
        if let style = preset.nilutStyle {
            if nilutCubes[style] == nil {
                nilutCubes[style] = try NILUTColorGrade.loadCube(style: style)
            }
            guard let data = nilutCubes[style] else { throw PhotoError.renderingFailed }
            return try NILUTColorGrade.apply(to: input, cubeData: data)
        }
        let controls = CIFilter.colorControls()
        controls.inputImage = input

        let matrix = CIFilter.colorMatrix()
        let curve = CIFilter.toneCurve()

        switch preset {
        case .amber:
            controls.saturation = 0.88
            controls.contrast = 0.96
            matrix.rVector = CIVector(x: 1.045, y: 0.015, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: 1.005, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0.01, z: 0.93, w: 0)
            matrix.biasVector = CIVector(x: 0.014, y: 0.004, z: 0, w: 0)
            curve.point0 = CGPoint(x: 0, y: 0.035)
            curve.point1 = CGPoint(x: 0.25, y: 0.27)
            curve.point2 = CGPoint(x: 0.5, y: 0.53)
            curve.point3 = CGPoint(x: 0.75, y: 0.77)
            curve.point4 = CGPoint(x: 1, y: 0.97)

        case .tide:
            controls.saturation = 0.85
            controls.contrast = 1.04
            matrix.rVector = CIVector(x: 0.94, y: 0.015, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: 1.015, z: 0.01, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0.015, z: 1.045, w: 0)
            matrix.biasVector = CIVector(x: 0, y: 0.005, z: 0.012, w: 0)
            curve.point0 = CGPoint(x: 0, y: 0.018)
            curve.point1 = CGPoint(x: 0.25, y: 0.23)
            curve.point2 = CGPoint(x: 0.5, y: 0.50)
            curve.point3 = CGPoint(x: 0.75, y: 0.78)
            curve.point4 = CGPoint(x: 1, y: 0.99)

        case .mono:
            controls.saturation = 0
            controls.contrast = 1.08
            curve.point0 = CGPoint(x: 0, y: 0.025)
            curve.point1 = CGPoint(x: 0.25, y: 0.20)
            curve.point2 = CGPoint(x: 0.5, y: 0.51)
            curve.point3 = CGPoint(x: 0.75, y: 0.81)
            curve.point4 = CGPoint(x: 1, y: 0.98)

        case .film35:
            controls.saturation = 0.82
            controls.contrast = 0.98
            matrix.rVector = CIVector(x: 1.025, y: 0.01, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: 0.995, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0.008, z: 0.95, w: 0)
            matrix.biasVector = CIVector(x: 0.006, y: 0.002, z: 0.004, w: 0)
            curve.point0 = CGPoint(x: 0, y: 0.028)
            curve.point1 = CGPoint(x: 0.25, y: 0.255)
            curve.point2 = CGPoint(x: 0.5, y: 0.515)
            curve.point3 = CGPoint(x: 0.75, y: 0.745)
            curve.point4 = CGPoint(x: 1, y: 0.955)

        case .silver35:
            controls.saturation = 0
            controls.contrast = 1.02
            curve.point0 = CGPoint(x: 0, y: 0.032)
            curve.point1 = CGPoint(x: 0.25, y: 0.23)
            curve.point2 = CGPoint(x: 0.5, y: 0.52)
            curve.point3 = CGPoint(x: 0.75, y: 0.79)
            curve.point4 = CGPoint(x: 1, y: 0.96)

        case .dust35:
            controls.saturation = 0.74
            controls.contrast = 0.96
            matrix.rVector = CIVector(x: 1.035, y: 0.01, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: 0.99, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0.008, z: 0.92, w: 0)
            matrix.biasVector = CIVector(x: 0.012, y: 0.006, z: 0.002, w: 0)
            curve.point0 = CGPoint(x: 0, y: 0.055)
            curve.point1 = CGPoint(x: 0.25, y: 0.28)
            curve.point2 = CGPoint(x: 0.5, y: 0.54)
            curve.point3 = CGPoint(x: 0.75, y: 0.75)
            curve.point4 = CGPoint(x: 1, y: 0.93)

        case .glow800:
            controls.saturation = 0.86
            controls.contrast = 1.02
            matrix.rVector = CIVector(x: 1.015, y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: 0.998, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: 0.97, w: 0)
            matrix.biasVector = CIVector(x: 0, y: 0.002, z: 0.008, w: 0)
            curve.point0 = CGPoint(x: 0, y: 0.014)
            curve.point1 = CGPoint(x: 0.25, y: 0.225)
            curve.point2 = CGPoint(x: 0.5, y: 0.50)
            curve.point3 = CGPoint(x: 0.75, y: 0.79)
            curve.point4 = CGPoint(x: 1, y: 0.975)

        case .scratch16:
            controls.saturation = 0
            controls.contrast = 1.08
            curve.point0 = CGPoint(x: 0, y: 0.016)
            curve.point1 = CGPoint(x: 0.25, y: 0.185)
            curve.point2 = CGPoint(x: 0.5, y: 0.49)
            curve.point3 = CGPoint(x: 0.75, y: 0.80)
            curve.point4 = CGPoint(x: 1, y: 0.955)

        case .expired35:
            controls.saturation = 0.68
            controls.contrast = 0.93
            matrix.rVector = CIVector(x: 1.01, y: 0.008, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: 0.99, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0.006, z: 0.96, w: 0)
            matrix.biasVector = CIVector(x: 0.006, y: 0.008, z: 0.002, w: 0)
            curve.point0 = CGPoint(x: 0, y: 0.065)
            curve.point1 = CGPoint(x: 0.25, y: 0.28)
            curve.point2 = CGPoint(x: 0.5, y: 0.535)
            curve.point3 = CGPoint(x: 0.75, y: 0.755)
            curve.point4 = CGPoint(x: 1, y: 0.935)

        case .paper35, .paperWarm, .paperArchive:
            guard let variant = preset.paperVariant else { throw PhotoError.renderingFailed }
            let colorLook = try PaperColorGrade.apply(to: input, variant: variant)
            let strength: CGFloat = switch variant { case .matte: 0.12; case .warm: 0.15; case .archive: 0.18 }
            let grained = try addingFilmGrain(to: colorLook, sourceSize: sourceSize,
                                            strength: strength, grainSize: 0.85, coarseAmount: 0.16, neutralNoise: true)
            return try Paper35Texture.apply(to: grained, sourceSize: sourceSize,
                                            variant: variant, reliefField: paperRelief)

        case .nilut1, .nilut2, .nilut3, .nilutNatural, .nilutSoftWarm, .nilutCoolMatte:
            // All NILUT styles return from their dedicated sRGB stage above.
            throw PhotoError.renderingFailed
        }

        matrix.inputImage = controls.outputImage
        curve.inputImage = matrix.outputImage
        guard let colorLook = curve.outputImage else { throw PhotoError.renderingFailed }
        switch preset {
        case .film35:
            return try addingFilmGrain(to: colorLook, sourceSize: sourceSize, strength: 0.22)
        case .silver35:
            return try addingFilmGrain(to: colorLook, sourceSize: sourceSize, strength: 0.26)
        case .dust35:
            let vignette = CIFilter.radialGradient()
            vignette.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
            vignette.radius0 = Float(min(input.extent.width, input.extent.height) * 0.42)
            vignette.radius1 = Float(hypot(input.extent.width, input.extent.height) / 2)
            vignette.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            vignette.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.16)
            guard let shadow = vignette.outputImage?.cropped(to: input.extent) else {
                throw PhotoError.renderingFailed
            }
            let shaded = shadow.composited(over: colorLook)
            let grained = try addingFilmGrain(to: shaded, sourceSize: sourceSize, strength: 0.24)
            let artifacts = CIImage(cgImage: try DustArtifacts.texture(sourceSize: sourceSize))
            let scale = max(input.extent.width, input.extent.height) / min(1_800, max(sourceSize.width, sourceSize.height))
            return try resized(artifacts, scale: scale)
                .cropped(to: input.extent)
                .composited(over: grained)
        case .glow800:
            let glowing = try Glow800Highlights.apply(to: colorLook, highlightsFrom: input)
            return try addingFilmGrain(to: glowing, sourceSize: sourceSize, strength: 0.30, grainSize: 1.8)
        case .scratch16:
            let grained = try addingFilmGrain(to: colorLook, sourceSize: sourceSize,
                                            strength: 0.34, grainSize: 2.1, coarseAmount: 0.42)
            let artifacts = CIImage(cgImage: try ScratchArtifacts.texture(sourceSize: sourceSize))
            let scale = max(input.extent.width, input.extent.height) / min(1_800, max(sourceSize.width, sourceSize.height))
            return try resized(artifacts, scale: scale)
                .cropped(to: input.extent)
                .composited(over: grained)
        case .expired35:
            let aged = try Expired35Artifacts.apply(to: colorLook, sourceSize: sourceSize)
            let grained = try addingFilmGrain(to: aged, sourceSize: sourceSize,
                                            strength: 0.29, grainSize: 1.55, coarseAmount: 0.34)
            let marks = CIImage(cgImage: try Expired35Artifacts.marks(sourceSize: sourceSize))
            let scale = max(input.extent.width, input.extent.height) / min(1_800, max(sourceSize.width, sourceSize.height))
            return try resized(marks, scale: scale).cropped(to: input.extent).composited(over: grained)
        default:
            return colorLook
        }
    }

    private func resized(_ image: CIImage, scale: CGFloat) throws -> CIImage {
        if scale == 1 { return image }
        let resize = CIFilter.lanczosScaleTransform()
        resize.inputImage = image
        resize.scale = Float(scale)
        resize.aspectRatio = 1
        guard let output = resize.outputImage else { throw PhotoError.renderingFailed }
        return output
    }

    /// A deterministic two-scale texture in a common image-relative coordinate
    /// system. Preview and export sample the same field; slider updates use caches.
    private func addingFilmGrain(to image: CIImage, sourceSize: CGSize, strength: CGFloat,
                                grainSize: CGFloat = 1, coarseAmount: Double = 0.22,
                                neutralNoise: Bool = false) throws -> CIImage {
        let sourceLongEdge = max(sourceSize.width, sourceSize.height)
        let referenceLongEdge = min(1_800, sourceLongEdge)
        let referenceScale = referenceLongEdge / sourceLongEdge
        let referenceBounds = CGRect(
            origin: .zero,
            size: CGSize(width: sourceSize.width * referenceScale, height: sourceSize.height * referenceScale)
        )

        // CIRandomGenerator has a stable pattern. Fixed transforms and no per-frame
        // random values prevent grain from moving when intensity or preset changes.
        guard let noise = CIFilter.randomGenerator().outputImage else { throw PhotoError.renderingFailed }
        let fine = noise
            .transformed(by: .init(a: 1.15 * grainSize, b: 0, c: 0, d: 1.15 * grainSize, tx: 17, ty: 39))
            .applyingGaussianBlur(sigma: 0.28 * grainSize)
        let coarseTransform = CGAffineTransform(translationX: 137, y: 251)
            .rotated(by: 0.61)
            .scaledBy(x: 2.6 * grainSize, y: 2.6 * grainSize)
        let coarse = noise.transformed(by: coarseTransform).applyingGaussianBlur(sigma: 0.45 * grainSize)
        let paddedBounds = referenceBounds.insetBy(dx: -8, dy: -8)
        let texture = try blendImage(
            original: fine.cropped(to: paddedBounds),
            look: coarse.cropped(to: paddedBounds), intensity: coarseAmount
        )

        // Use one noise channel for all RGB components, centered at linear 0.5,
        // the neutral value for Soft Light. Keep alpha fully opaque.
        let monochrome = CIFilter.colorMatrix()
        monochrome.inputImage = neutralNoise ? texture.settingAlphaOne(in: paddedBounds) : texture
        let noiseVector = CIVector(x: 0, y: strength, z: 0, w: 0)
        monochrome.rVector = noiseVector
        monochrome.gVector = noiseVector
        monochrome.bVector = noiseVector
        monochrome.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let neutralBias = 0.5 - strength / 2
        monochrome.biasVector = CIVector(x: neutralBias, y: neutralBias, z: neutralBias, w: 1)
        // Retain a sampling border so rescaling cannot introduce dark edge pixels.
        guard let referenceTexture = monochrome.outputImage?.cropped(to: referenceBounds.insetBy(dx: -4, dy: -4)) else {
            throw PhotoError.renderingFailed
        }
        let outputScale = max(image.extent.width, image.extent.height) / referenceLongEdge
        let grain = try resized(referenceTexture, scale: outputScale).cropped(to: image.extent)

        let softLight = CIFilter.softLightBlendMode()
        softLight.inputImage = grain
        softLight.backgroundImage = image

        let luminance = CIFilter.colorMatrix()
        luminance.inputImage = image
        let lumaVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luminance.rVector = lumaVector
        luminance.gVector = lumaVector
        luminance.bVector = lumaVector
        let mask = CIFilter.toneCurve()
        mask.inputImage = luminance.outputImage
        mask.point0 = CGPoint(x: 0, y: 0.25)
        mask.point1 = CGPoint(x: 0.25, y: 0.85)
        mask.point2 = CGPoint(x: 0.5, y: 0.65)
        mask.point3 = CGPoint(x: 0.75, y: 0.30)
        mask.point4 = CGPoint(x: 1, y: 0.05)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = softLight.outputImage
        blend.backgroundImage = image
        blend.maskImage = mask.outputImage
        guard let output = blend.outputImage else { throw PhotoError.renderingFailed }
        return output.cropped(to: image.extent)
    }
}

/// Only bright source pixels emit light. Radii are image-relative, so preview
/// and full-size export retain the same halo width. No blur touches the base image.
enum Glow800Highlights {
    static func apply(to image: CIImage, highlightsFrom source: CIImage) throws -> CIImage {
        let bounds = image.extent
        let scale = max(bounds.width, bounds.height) / 1_800

        // Smoothly select linear luminance 0.55–0.90; midtones emit no glow.
        let threshold = CIFilter.colorMatrix()
        threshold.inputImage = source
        let gain: CGFloat = 1 / (0.90 - 0.55)
        let luma = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
        threshold.rVector = luma
        threshold.gVector = luma
        threshold.bVector = luma
        threshold.biasVector = CIVector(x: -0.55 * gain, y: -0.55 * gain, z: -0.55 * gain, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = threshold.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let smooth = CIFilter.colorPolynomial()
        smooth.inputImage = clamp.outputImage
        let coefficients = CIVector(x: 0, y: 0, z: 3, w: -2)
        smooth.redCoefficients = coefficients
        smooth.greenCoefficients = coefficients
        smooth.blueCoefficients = coefficients
        guard let highlights = smooth.outputImage?.cropped(to: bounds) else { throw PhotoError.renderingFailed }

        let wide = highlights.clampedToExtent().applyingGaussianBlur(sigma: 11 * scale).cropped(to: bounds)
        let tight = highlights.clampedToExtent().applyingGaussianBlur(sigma: 3 * scale).cropped(to: bounds)
        let ring = CIFilter.blendWithMask()
        ring.inputImage = CIImage(color: .black).cropped(to: bounds)
        ring.backgroundImage = wide
        ring.maskImage = highlights
        guard let haloMask = ring.outputImage else { throw PhotoError.renderingFailed }

        // Suppress red inside the emitting highlight; its surroundings get the
        // broader warm halo, while the core receives a restrained near-white glow.
        let halo = try tinted(haloMask, red: 0.18, green: 0.035, blue: 0.01)
        let glow = try tinted(tight, red: 0.045, green: 0.04, blue: 0.032)
        let light = CIFilter.additionCompositing()
        light.inputImage = halo
        light.backgroundImage = glow
        guard let combinedLight = light.outputImage?.settingAlphaOne(in: bounds) else { throw PhotoError.renderingFailed }
        let composite = CIFilter.additionCompositing()
        composite.inputImage = combinedLight
        composite.backgroundImage = image
        guard let output = composite.outputImage else { throw PhotoError.renderingFailed }
        // Addition sums alpha as well as RGB. Restore opaque alpha without
        // changing the summed light, before grain, preview blending or JPEG export.
        return output.settingAlphaOne(in: bounds).cropped(to: bounds)
    }

    private static func tinted(_ mask: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CIImage {
        let tint = CIFilter.colorMatrix()
        tint.inputImage = mask
        tint.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: green, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: blue, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let output = tint.outputImage else { throw PhotoError.renderingFailed }
        return output
    }
}

/// Sparse translucent marks, drawn once in common image-relative coordinates.
/// A local fixed seed keeps imports, cached previews and full-size exports aligned.
enum DustArtifacts {
    static func texture(sourceSize: CGSize) throws -> CGImage {
        let sourceLongEdge = max(sourceSize.width, sourceSize.height)
        let referenceScale = min(1, 1_800 / sourceLongEdge)
        let size = CGSize(width: sourceSize.width * referenceScale, height: sourceSize.height * referenceScale)
        let longEdge = max(size.width, size.height)
        let unit = longEdge / 1_800
        guard let context = CGContext(
            data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoError.renderingFailed }

        var random = ArtifactRandom()
        let speckCount = max(24, Int(135 * size.width * size.height / (longEdge * longEdge)))
        for index in 0..<speckCount {
            let x = (0.02 + random.next() * 0.96) * size.width
            let y = (0.02 + random.next() * 0.96) * size.height
            let radius = (0.5 + random.next() * 1.4) * unit
            let stretch = 0.65 + random.next() * 0.9
            let light = index % 3 != 0
            let opacity = 0.18 + random.next() * 0.26
            context.setFillColor(gray: light ? 0.96 : 0.08, alpha: opacity)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius * stretch,
                                          width: radius * 2, height: radius * stretch * 2))
        }

        context.setLineCap(.round)
        for index in 0..<3 {
            let length = (55 + random.next() * 90) * unit
            let x = (0.06 + random.next() * 0.88) * size.width
            let y = (0.06 + random.next() * 0.80) * max(0, size.height - length)
            let bend = (random.next() - 0.5) * 3 * unit
            context.setStrokeColor(gray: index == 1 ? 0.08 : 0.96, alpha: 0.16 + random.next() * 0.10)
            context.setLineWidth((0.5 + random.next() * 0.35) * unit)
            context.move(to: CGPoint(x: x, y: y))
            context.addQuadCurve(to: CGPoint(x: x + bend, y: y + length),
                                 control: CGPoint(x: x - bend, y: y + length * 0.55))
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw PhotoError.renderingFailed }
        return image
    }

    private struct ArtifactRandom {
        private var state: UInt64 = 0xD057_35A6_91C2_B4E7

        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(UInt64.max >> 11)
        }
    }
}

/// Smooth color/exposure wear and edge light leaks in a fixed normalized field.
/// Small opaque linear-sRGB maps preserve detail through Soft Light and Screen;
/// fine marks use a separate higher-resolution transparent reference texture.
enum Expired35Artifacts {
    static func apply(to image: CIImage, sourceSize: CGSize) throws -> CIImage {
        let fields = try fields(sourceSize: sourceSize)
        func fitted(_ texture: CGImage) -> CIImage {
            CIImage(cgImage: texture).clampedToExtent().transformed(by: .init(
                scaleX: image.extent.width / CGFloat(texture.width),
                y: image.extent.height / CGFloat(texture.height)
            )).cropped(to: image.extent)
        }
        let wear = CIFilter.softLightBlendMode()
        wear.inputImage = fitted(fields.stains)
        wear.backgroundImage = image
        let leaks = CIFilter.screenBlendMode()
        leaks.inputImage = fitted(fields.leaks)
        leaks.backgroundImage = wear.outputImage
        guard let output = leaks.outputImage else { throw PhotoError.renderingFailed }
        return output.cropped(to: image.extent)
    }

    static func fields(sourceSize: CGSize) throws -> (stains: CGImage, leaks: CGImage) {
        let scale = min(1, 600 / max(sourceSize.width, sourceSize.height))
        let width = Int(ceil(sourceSize.width * scale))
        let height = Int(ceil(sourceSize.height * scale))
        var stains = [UInt8](repeating: 255, count: width * height * 4)
        var leaks = stains
        func byte(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        func bell(_ value: Double) -> Double { exp(-value * value) }

        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                // Overlapping warped lobes give the wear soft, irregular outlines.
                let warpedU = u + 0.035 * sin(11 * v + 4 * u) + 0.016 * sin(23 * v - 5 * u)
                let warpedV = v + 0.035 * sin(12 * u - 3 * v) + 0.012 * cos(19 * u + 7 * v)
                func spot(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Double {
                    bell((warpedU - cx) / rx) * bell((warpedV - cy) / ry)
                }
                let radius = hypot((u - 0.5) * 2, (v - 0.5) * 2)
                let t = min(1, max(0, (radius - 0.30) / 0.70))
                let edge = t * t * (3 - 2 * t)
                let green = edge * (spot(0.08, 0.72, 0.20, 0.29) + 0.7 * spot(0.64, 0.98, 0.28, 0.16))
                let magenta = edge * (spot(0.92, 0.30, 0.19, 0.27) + 0.65 * spot(0.25, 0.02, 0.23, 0.17))
                let exposure = 0.025 * edge * (sin(6 * u + 2 * v) * cos(7 * v - u) + 0.35 * sin(14 * u - 9 * v))
                let i = (y * width + x) * 4
                stains[i] = byte(0.5 + exposure + 0.08 * magenta - 0.04 * green)
                stains[i + 1] = byte(0.5 + exposure + 0.055 * green - 0.065 * magenta)
                stains[i + 2] = byte(0.5 + exposure + 0.06 * magenta - 0.025 * green)

                let left = bell((u + 0.012 + 0.018 * sin(9 * v)) / 0.09)
                    * (0.18 + 0.82 * bell((v - 0.73) / 0.28))
                let right = 0.7 * bell((u - 0.998 + 0.014 * sin(11 * v + 1)) / 0.08)
                    * bell((v - 0.18) / 0.30)
                leaks[i] = byte(0.22 * left + 0.15 * right)
                leaks[i + 1] = byte(0.045 * left + 0.012 * right)
                leaks[i + 2] = byte(0.006 * left + 0.018 * right)
            }
        }
        return (try fieldImage(stains, width: width, height: height),
                try fieldImage(leaks, width: width, height: height))
    }

    private static func fieldImage(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { throw PhotoError.renderingFailed }
        return image
    }

    static func marks(sourceSize: CGSize) throws -> CGImage {
        let scale = min(1, 1_800 / max(sourceSize.width, sourceSize.height))
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let unit = max(size.width, size.height) / 1_800
        guard let context = CGContext(
            data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoError.renderingFailed }
        var state: UInt64 = 0xE931_35A8_78D2_041B
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(UInt64.max >> 11)
        }
        let count = max(18, Int(90 * size.width * size.height / pow(max(size.width, size.height), 2)))
        for index in 0..<count {
            // Keep most dust in the outer strips, leaving the center unobstructed.
            let x = (index % 2 == 0 ? next() * 0.23 : 0.77 + next() * 0.23) * size.width
            let y = next() * size.height
            let radius = (0.45 + next() * 1.1) * unit
            context.setFillColor(gray: index % 3 == 0 ? 0.10 : 0.94, alpha: 0.14 + next() * 0.17)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        context.setLineCap(.round)
        for (index, position) in [CGFloat(0.07), 0.93, 0.16].enumerated() {
            let x = position * size.width
            let y = (0.12 + next() * 0.65) * size.height
            let length = (40 + next() * 95) * unit
            context.setStrokeColor(gray: index == 1 ? 0.08 : 0.96, alpha: 0.17 + next() * 0.10)
            context.setLineWidth((0.45 + next() * 0.25) * unit)
            context.move(to: CGPoint(x: x, y: y))
            context.addQuadCurve(to: CGPoint(x: x + 2 * unit, y: y + length),
                                 control: CGPoint(x: x - 2 * unit, y: y + length * 0.6))
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw PhotoError.renderingFailed }
        return image
    }
}

/// Restrained color and a separate luminosity curve preserve the source palette.
/// The paper relief and grain are applied only after this color stage.
enum PaperColorGrade {
    static func apply(to image: CIImage, variant: PaperVariant) throws -> CIImage {
        let color = CIFilter.colorControls()
        color.inputImage = image
        color.saturation = switch variant { case .matte: 0.98; case .warm: 0.96; case .archive: 0 }
        let curve = CIFilter.toneCurve()
        curve.inputImage = color.outputImage
        switch variant {
        case .matte:
            curve.point0 = CGPoint(x: 0, y: 0.018)
            curve.point1 = CGPoint(x: 0.25, y: 0.24)
            curve.point2 = CGPoint(x: 0.5, y: 0.505)
            curve.point3 = CGPoint(x: 0.75, y: 0.775)
            curve.point4 = CGPoint(x: 1, y: 0.985)
        case .warm:
            curve.point0 = CGPoint(x: 0, y: 0.022)
            curve.point1 = CGPoint(x: 0.25, y: 0.235)
            curve.point2 = CGPoint(x: 0.5, y: 0.52)
            curve.point3 = CGPoint(x: 0.75, y: 0.79)
            curve.point4 = CGPoint(x: 1, y: 0.985)
        case .archive:
            curve.point0 = CGPoint(x: 0, y: 0.02)
            curve.point1 = CGPoint(x: 0.25, y: 0.225)
            curve.point2 = CGPoint(x: 0.5, y: 0.50)
            curve.point3 = CGPoint(x: 0.75, y: 0.78)
            curve.point4 = CGPoint(x: 1, y: 0.98)
        }
        let tone = CIFilter.luminosityBlendMode()
        tone.inputImage = curve.outputImage
        tone.backgroundImage = color.outputImage
        guard let toned = tone.outputImage else { throw PhotoError.renderingFailed }
        if variant == .matte { return toned.cropped(to: image.extent) }

        let warmth = CIFilter.colorMatrix()
        warmth.inputImage = toned
        if variant == .warm {
            // Rows sum to one, so neutral colors stay neutral. Warm reds gently
            // without pushing foliage toward yellow or painting white highlights.
            warmth.rVector = CIVector(x: 1.025, y: -0.025, z: 0, w: 0)
            warmth.bVector = CIVector(x: -0.025, y: 0.025, z: 1, w: 0)
        } else {
            warmth.rVector = CIVector(x: 1.008, y: 0, z: 0, w: 0)
            warmth.bVector = CIVector(x: 0, y: 0, z: 0.988, w: 0)
        }
        let luma = CIFilter.colorControls()
        luma.inputImage = toned
        luma.saturation = 0
        let midtones = CIFilter.toneCurve()
        midtones.inputImage = luma.outputImage
        midtones.point0 = CGPoint(x: 0, y: 0)
        midtones.point1 = CGPoint(x: 0.25, y: 0.60)
        midtones.point2 = CGPoint(x: 0.5, y: 0.75)
        midtones.point3 = CGPoint(x: 0.75, y: 0.25)
        midtones.point4 = CGPoint(x: 1, y: 0)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = warmth.outputImage
        blend.backgroundImage = toned
        blend.maskImage = midtones.outputImage
        guard let result = blend.outputImage else { throw PhotoError.renderingFailed }
        return result.cropped(to: image.extent)
    }
}

/// A neutral paper relief field: fine tooth, soft pulp variation, fibers, pores
/// and faint edge creases. All coordinates share the upright source reference.
enum Paper35Texture {
    static func apply(to image: CIImage, sourceSize: CGSize, variant: PaperVariant = .matte,
                      reliefField: CIImage? = nil) throws -> CIImage {
        let referenceLongEdge = min(1_800, max(sourceSize.width, sourceSize.height))
        let resize = CIFilter.lanczosScaleTransform()
        resize.inputImage = try reliefField ?? heightMap(sourceSize: sourceSize)
        resize.scale = Float(max(image.extent.width, image.extent.height) / referenceLongEdge)
        resize.aspectRatio = 1
        guard var paper = resize.outputImage?.cropped(to: image.extent) else { throw PhotoError.renderingFailed }
        let textureStrength: CGFloat
        let paperBias: CIVector
        let edgeWear: CGFloat
        switch variant {
        case .matte:
            textureStrength = 1
            paperBias = CIVector(x: 0.83, y: 0.83, z: 0.83, w: 0)
            edgeWear = 0
        case .warm:
            textureStrength = 1.20
            paperBias = CIVector(x: 0.83, y: 0.829, z: 0.826, w: 0)
            edgeWear = 0.025
        case .archive:
            textureStrength = 1.45
            paperBias = CIVector(x: 0.83, y: 0.829, z: 0.827, w: 0)
            edgeWear = 0.08
        }
        if textureStrength != 1 {
            let reliefAmount = CIFilter.colorMatrix()
            reliefAmount.inputImage = paper
            reliefAmount.rVector = CIVector(x: textureStrength, y: 0, z: 0, w: 0)
            reliefAmount.gVector = CIVector(x: 0, y: textureStrength, z: 0, w: 0)
            reliefAmount.bVector = CIVector(x: 0, y: 0, z: textureStrength, w: 0)
            let bias = (1 - textureStrength) / 2
            reliefAmount.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
            guard let scaled = reliefAmount.outputImage else { throw PhotoError.renderingFailed }
            paper = scaled
        }

        let relief = CIFilter.softLightBlendMode()
        relief.inputImage = paper
        relief.backgroundImage = image

        // A lightly tinted paper base gives fibers a presence even in pale areas.
        let tint = CIFilter.colorMatrix()
        tint.inputImage = paper
        let amount = CIVector(x: 0.28, y: 0, z: 0, w: 0)
        tint.rVector = amount
        tint.gVector = amount
        tint.bVector = amount
        tint.biasVector = paperBias
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = tint.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let printOnPaper = CIFilter.multiplyBlendMode()
        printOnPaper.inputImage = clamp.outputImage
        printOnPaper.backgroundImage = relief.outputImage
        guard var printed = printOnPaper.outputImage else { throw PhotoError.renderingFailed }
        if edgeWear > 0 {
            let patina = CIFilter.radialGradient()
            patina.center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            patina.radius0 = Float(min(image.extent.width, image.extent.height) * 0.38)
            patina.radius1 = Float(hypot(image.extent.width, image.extent.height) / 2)
            patina.color0 = CIColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 0)
            patina.color1 = CIColor(red: 0.14, green: 0.14, blue: 0.14, alpha: edgeWear)
            guard let wear = patina.outputImage?.cropped(to: image.extent) else { throw PhotoError.renderingFailed }
            printed = wear.composited(over: printed)
        }

        let luminance = CIFilter.colorMatrix()
        luminance.inputImage = image
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luminance.rVector = luma
        luminance.gVector = luma
        luminance.bVector = luma
        let visibility = CIFilter.toneCurve()
        visibility.inputImage = luminance.outputImage
        visibility.point0 = CGPoint(x: 0, y: 0.06)
        visibility.point1 = CGPoint(x: 0.25, y: 0.20)
        visibility.point2 = CGPoint(x: 0.5, y: 0.60)
        visibility.point3 = CGPoint(x: 0.75, y: 0.90)
        visibility.point4 = CGPoint(x: 1, y: 1)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = printed
        blend.backgroundImage = image
        blend.maskImage = visibility.outputImage
        guard let output = blend.outputImage else { throw PhotoError.renderingFailed }
        return output.cropped(to: image.extent)
    }

    static func heightMap(sourceSize: CGSize) throws -> CIImage {
        let scale = min(1, 1_800 / max(sourceSize.width, sourceSize.height))
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let bounds = CGRect(origin: .zero, size: size)
        guard let noise = CIFilter.randomGenerator().outputImage else { throw PhotoError.renderingFailed }
        let tooth = noise.transformed(by: .init(a: 1.8, b: 0.15, c: 0.1, d: 1.1, tx: 409, ty: 83))
            .applyingGaussianBlur(sigma: 0.35)
        let pulp = noise.transformed(by: .init(a: 14, b: 2, c: -1, d: 9, tx: 37, ty: 613))
            .applyingGaussianBlur(sigma: 3.5)
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = tooth
        mix.targetImage = pulp
        mix.time = 0.18
        let neutral = CIFilter.colorMatrix()
        neutral.inputImage = mix.outputImage?.settingAlphaOne(in: bounds.insetBy(dx: -4, dy: -4))
        let strength = CIVector(x: 0, y: 0.48, z: 0, w: 0)
        neutral.rVector = strength
        neutral.gVector = strength
        neutral.bVector = strength
        neutral.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        neutral.biasVector = CIVector(x: 0.26, y: 0.26, z: 0.26, w: 1)
        guard let roughness = neutral.outputImage else { throw PhotoError.renderingFailed }
        let fibers = CIImage(cgImage: try fibersAndPores(size: size)).clampedToExtent()
        // Keep a sampling border for Lanczos, including very small previews.
        return fibers.composited(over: roughness).cropped(to: bounds.insetBy(dx: -4, dy: -4))
    }

    private static func fibersAndPores(size: CGSize) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let context = CGContext(
            data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoError.renderingFailed }
        let longEdge = max(size.width, size.height)
        let unit = longEdge / 1_800
        let area = size.width * size.height / (longEdge * longEdge)
        var state: UInt64 = 0xFA93_3510_4B8C_69D2
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(UInt64.max >> 11)
        }
        func ink(_ level: CGFloat, _ alpha: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [level, level, level, alpha])!
        }
        context.setLineCap(.round)
        for index in 0..<max(80, Int(950 * area)) {
            let x = next() * size.width
            let y = next() * size.height
            let length = (6 + next() * 22) * unit
            let angle = next() * .pi * 2
            let end = CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length)
            context.setStrokeColor(ink(index % 2 == 0 ? 0.18 : 0.83, 0.16 + next() * 0.18))
            context.setLineWidth((0.55 + next() * 0.65) * unit)
            context.move(to: CGPoint(x: x, y: y))
            context.addQuadCurve(to: end, control: CGPoint(x: (x + end.x) / 2 + 2 * unit,
                                                           y: (y + end.y) / 2 - 2 * unit))
            context.strokePath()
        }
        for _ in 0..<max(200, Int(6_000 * area)) {
            let x = next() * size.width
            let y = next() * size.height
            let radius = (0.45 + next() * 0.8) * unit
            let rect = CGRect(x: x, y: y, width: radius * 1.5, height: radius * 2)
            context.setFillColor(ink(0.18, 0.18 + next() * 0.12))
            context.fillEllipse(in: rect)
            context.setFillColor(ink(0.84, 0.15))
            context.fillEllipse(in: rect.offsetBy(dx: 0.6 * unit, dy: 0.7 * unit))
        }
        for (index, position) in [CGPoint(x: 0.035, y: 0.18), CGPoint(x: 0.95, y: 0.72), CGPoint(x: 0.08, y: 0.92)].enumerated() {
            let start = CGPoint(x: position.x * size.width, y: position.y * size.height)
            let direction: CGFloat = index == 1 ? -1 : 1
            let end = CGPoint(x: start.x + direction * 32 * unit, y: start.y + (75 + next() * 60) * unit)
            for (offset, level) in [(CGFloat(0), CGFloat(0.15)), (CGFloat(1.4), CGFloat(0.85))] {
                context.setStrokeColor(ink(level, 0.12))
                context.setLineWidth(1.8 * unit)
                context.move(to: CGPoint(x: start.x + offset * unit, y: start.y))
                context.addQuadCurve(to: CGPoint(x: end.x + offset * unit, y: end.y),
                                     control: CGPoint(x: start.x + direction * 10 * unit + offset * unit,
                                                      y: (start.y + end.y) / 2))
                context.strokePath()
            }
        }
        guard let image = context.makeImage() else { throw PhotoError.renderingFailed }
        return image
    }
}

/// Long broken scratches, shorter diagonal marks, fibers and specks, all in a
/// fixed image-relative field shared by the cached preview and full-size export.
enum ScratchArtifacts {
    static func texture(sourceSize: CGSize) throws -> CGImage {
        let referenceScale = min(1, 1_800 / max(sourceSize.width, sourceSize.height))
        let size = CGSize(width: sourceSize.width * referenceScale, height: sourceSize.height * referenceScale)
        let unit = max(size.width, size.height) / 1_800
        guard let context = CGContext(
            data: nil, width: Int(ceil(size.width)), height: Int(ceil(size.height)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoError.renderingFailed }
        var random = ScratchRandom()
        context.setLineCap(.round)

        for (index, position) in [CGFloat(0.12), 0.36, 0.64, 0.87].enumerated() {
            let x = (position + (random.next() - 0.5) * 0.04) * size.width
            let start = (0.04 + random.next() * 0.12) * size.height
            let length = min((0.64 + random.next() * 0.26) * size.height, size.height * 0.96 - start)
            let phase = random.next() * .pi * 2
            let drift = (random.next() - 0.5) * 2 * unit
            func point(_ t: CGFloat) -> CGPoint {
                CGPoint(x: x + sin(t * .pi * 2 + phase) * 1.4 * unit + drift * t,
                        y: start + length * t)
            }
            var t: CGFloat = 0
            while t < 1 {
                let end = min(1, t + 0.035 + random.next() * 0.055)
                let light = index % 2 == 0
                context.setStrokeColor(gray: light ? 0.97 : 0.06,
                                       alpha: light ? 0.30 + random.next() * 0.23 : 0.18 + random.next() * 0.15)
                context.setLineWidth((0.7 + random.next() * 0.55) * unit)
                context.move(to: point(t))
                context.addQuadCurve(to: point(end), control: point((t + end) / 2))
                context.strokePath()
                t = end + 0.008 + random.next() * 0.024
            }
        }

        for index in 0..<10 {
            let x = (0.06 + random.next() * 0.88) * size.width
            let y = (0.06 + random.next() * 0.88) * size.height
            let length = (18 + random.next() * 45) * unit
            let direction: CGFloat = index % 2 == 0 ? 1 : -1
            context.setStrokeColor(gray: index % 3 == 0 ? 0.97 : 0.06, alpha: 0.18 + random.next() * 0.17)
            context.setLineWidth((0.4 + random.next() * 0.4) * unit)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + length * 0.8 * direction, y: y + length * 0.45))
            context.strokePath()
        }

        for index in 0..<5 {
            let x = (0.08 + random.next() * 0.84) * size.width
            let y = (0.08 + random.next() * 0.84) * size.height
            let length = (25 + random.next() * 50) * unit
            let direction: CGFloat = index % 2 == 0 ? 1 : -1
            context.setStrokeColor(gray: index == 0 ? 0.97 : 0.06, alpha: 0.24 + random.next() * 0.14)
            context.setLineWidth((0.4 + random.next() * 0.3) * unit)
            context.move(to: CGPoint(x: x, y: y))
            context.addCurve(to: CGPoint(x: x + length * 0.7 * direction, y: y + length * 0.6),
                             control1: CGPoint(x: x - length * 0.3 * direction, y: y + length * 0.5),
                             control2: CGPoint(x: x + length * direction, y: y + length * 0.15))
            context.strokePath()
        }

        let speckCount = max(24, Int(160 * size.width * size.height / pow(max(size.width, size.height), 2)))
        for index in 0..<speckCount {
            let x = (0.02 + random.next() * 0.96) * size.width
            let y = (0.02 + random.next() * 0.96) * size.height
            let radius = (0.45 + random.next() * 1.6) * unit
            let stretch = 0.7 + random.next() * 0.7
            context.setFillColor(gray: index % 2 == 0 ? 0.97 : 0.06, alpha: 0.18 + random.next() * 0.24)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius * stretch,
                                          width: radius * 2, height: radius * stretch * 2))
        }
        guard let image = context.makeImage() else { throw PhotoError.renderingFailed }
        return image
    }

    private struct ScratchRandom {
        private var state: UInt64 = 0x5C12_A7C4_16F1_8D39

        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(UInt64.max >> 11)
        }
    }
}
