# Flickerly — iOS photo editor

Native SwiftUI photo editor using Core Image. Open **Flickerly.xcodeproj**, choose the **Flickerly** scheme and an iPhone simulator, then Run. Requires Xcode 16+ (Swift 6); deployment target is iOS 17+. No packages, API keys, or backend.

The app target/product/module is **Flickerly** and its test target is **FlickerlyTests**. The final bundle identifiers are **`gr.mountzou.flickerly`** and **`gr.mountzou.flickerly.tests`**, using developer team `5CPM5925FS`. This replaces the development-only `com.example.images.prototype` identity. iOS treats the final identifier as a separate app: prototype favorites, appearance preferences and Photos permission remain in the prototype's container and are not migrated. The workspace directory remains `ios-images`; source folders and the shared Xcode scheme use the new name. New photo exports are named `Flickerly-<preset>-<UUID>.jpg`.

## First release device support

The app targets **iPhone and iPad natively**. Both app and test targets use
`TARGETED_DEVICE_FAMILY = "1,2"` in Debug and Release; the generated app Info.plist
must contain `UIDeviceFamily = [1,2]`. The iPad-specific
`UISupportedInterfaceOrientations~ipad` array includes all four orientations so
the app supports rotation and resizable windows. iPhone portrait and landscape
orientations remain as before. Device-support QA artifacts are in
`artifacts/ipad-support/`.

On October 25, 2026, native iPad support passed a simulator smoke test on iPad
Pro 13-inch (M5), iPadOS 27.0: portrait, landscape, a quarter-size window,
photo import, NILUT selection, bookmarks, intensity, before/after, 2× detail
zoom, appearance settings and Photos export. Saved JPEGs were read back and
fully decoded at 3000 × 2002 and 6343 × 8457. Debug simulator and unsigned
Release device builds both succeeded. See `artifacts/ipad-support/QA.md` for
evidence and limits. Physical iPad validation is still pending.

On October 25, 2026, the user confirmed that a final test on a physical iPhone
worked correctly. This is user-reported validation; the exact device, iOS
version and installed build were not recorded.

## App Store release

App Store release preparation is recorded in
[`artifacts/app-store/release-1.0.0-1/README.md`](artifacts/app-store/release-1.0.0-1/README.md).
Version **1.0.0 (1)** was submitted on October 25, 2026. On October 28, the
owner confirmed that Apple approved it and the app was available on the
[App Store](https://apps.apple.com/app/id6826854864).

Version **1.0.1 (2)** was submitted on October 28, 2026, with automatic release
selected. Submission ID: `78423a3e-e1d8-40e1-88d9-8607fe66eb8b`. The owner
subsequently confirmed that the new version is live.

## Repository and local artifacts

The source repository is [mountzou/ios-flickerly](https://github.com/mountzou/ios-flickerly).
It includes the Xcode project, app and test sources, bundled resources and licenses,
branding assets, and development scripts. The workspace directory remains
`ios-images`; the repository and app names are `ios-flickerly` and `Flickerly`.

`artifacts/`, `build/` and `TestResults/` are retained locally and excluded from
Git. References to those paths below describe local experiment or QA evidence;
they are not available in a fresh clone. App Store contact screenshots and
submission logs also remain local. Building and running the app and its native
tests requires none of these files: the six ready-to-use NILUT tables and their
reference values are bundled in `Flickerly/Resources/NILUT/`. Regenerating NILUT
tables with the Python scripts requires the separate local experiment inputs
and checkpoints described below.

## Appearance and language

The editor uses black backgrounds, neutral gray surfaces and secondary text,
and white controls/selection accents. Empty preset cards use neutral grayscale
placeholders. Photo previews and saved images retain the selected look's colors.

All app-owned text uses the bundled **Bricolage Grotesque** variable font, with
explicit weight/optical-size axes and UIFontMetrics scaling. The font and its
SIL Open Font License are in `Flickerly/Resources/Fonts/`; `UIAppFonts` registers
the unchanged TTF at launch. There is no font download or network dependency.

The app declares **English** as its development/supported localization and sets
the SwiftUI locale to English. Editor text, filter descriptions, accessibility
labels, photo-library permission text, loading/saving copy, and error messages
are English. App-owned save/error notices use a matching Bricolage/monochrome
modal with accessible title focus and a Settings action when access is denied.
System-owned interfaces such as the Photos picker and iOS permission dialogs
retain Apple's system typography and can follow the device language. On the
Greek-language QA Simulator, the system Photos picker still displays Greek;
the editor's own text and notices are English.

## Try it

The gear icon opens **Settings**, with **Appearance** choices for **Light** and
**Dark**. Dark remains the default. The selection applies immediately throughout
the app, including the editor and full-screen photo detail, and is stored locally
in UserDefaults under `appearanceTheme` for subsequent launches. The monochrome
palette adapts to the chosen theme; photo pixels, filtered previews and exports
do not change. Controls over photographs keep white labels on dark backgrounds.
`Library/PrivacyInfo.xcprivacy` declares UserDefaults use for the app's own
preferences with reason `CA92.1`, following
[Apple's privacy manifest guidance](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).

Settings also includes a **Privacy policy** card and a **Version** footer pinned
above the bottom safe area, outside the scrollable content. The footer uses the
built app's `CFBundleShortVersionString`, so it updates with each app version.
The privacy card matches Flytly's Bricolage 17-point semibold label, northeast arrow,
20-point padding and 16-point rounded background, using Flickerly's monochrome
palette. The link opens the Flickerly policy in the default browser. Both public
documents allow **anyone with the link** to view them, with no sign-in required
and no public editing or search discovery:

- [Privacy Policy](https://docs.google.com/document/d/133g1EmOIsIxwXrFyK4BgxO8l-LYfl71YzTPs99P8vpM)
- [Support](https://docs.google.com/document/d/1lMPtTG_vehPXXo1LZuZdldQW8mNCuskYTqUFxo3FbEE)

Anonymous page and text access were verified on October 25, 2026. Readback
evidence is in `artifacts/app-store/public-links-and-identity/`.

The Grain app icon is dark gray on white, with dark and tinted variants. The editable Icon Composer document used by the app is `Flickerly/Catalog/AppIcon.icon`. The vector, SVG/PDF exports, PNG sizes, legacy catalog and web assets are in [Branding/Flickerly](Branding/Flickerly/README.md). Regenerate or verify the exported assets with `scripts/generate_app_icons.py` (`--check` verifies saved files).

1. Browse **Originals**, **Black and white**, **Paper** and **NILUT** on the home screen. Each collection has a horizontal row of real filtered previews of the same bundled sample photograph at 100%. Black and white groups four existing looks from Originals and Paper.
2. Tap a card to open its editor with that exact look selected. The editor offers the other looks in the selected collection. After importing a photo, use the back arrow to save a draft, discard the current changes, or keep editing. The same choice appears before replacing the current photo.
3. Tap **Choose photo** to import your own photo. After import, the **+** appears in the header to choose another photo; it is hidden when editing a draft, which remains tied to its original photo. The selected look is preserved, with the existing default intensity of 80%. Before import, the sample shows the full-strength look and saving/intensity are unavailable.
4. Adjust **Intensity** from 0% (original) to 100% (full preset). Touch and hold the photo to see the original immediately until you release; use the expand button for the detail view and its comparison control.
5. Tap the **bookmark** at the top right of any filter thumbnail on the home screen or in the editor to add/remove a favorite. Bookmarking a filter does not select or apply it. The **Favorites** row updates immediately.
6. Tap **Save a copy** and choose Original, Medium or Small after their JPEG sizes are calculated. On the first save, allow Flickerly to add photos. A confirmation appears after the selected image has been written to the library.

The Drafts button beside Settings opens up to 12 locally stored editing sessions. Each draft retains the original image data, selected filter, intensity and collection context for reopening; saving an existing draft updates it. Delete a draft explicitly to free a slot. Exporting a copy to Photos does not automatically remove the draft. Drafts are stored in the app's Application Support directory and are removed if the app is deleted; they are not published or synced by the app.

## Home, favorites and sample previews

`FilterLibraryView` is the initial screen. Each card opens `EditorView(initialPreset:)`; the editor's choices are restricted to that preset's family. Switching variants before importing updates the sample, and the first real import retains the chosen variant. Starting a new editor from the home screen starts a new editing session.

`FavoritesStore` persists stable preset IDs as a small JSON array in the app container's **Application Support/FavoriteFilters.json**. It uses atomic writes, deduplicates known IDs on load and ignores identifiers no longer in the catalog. A write failure keeps the previous selection and displays an English error. Favorites survive app restarts and require no account or server; deleting the app removes its local data. All screens share the same observable store, and favorites appear in stable catalog order.

`CatalogPreviewStore` processes `Flickerly/Catalog/catalog-sample.png` with the actual `PhotoRenderer` recipes, once per app session on the rendering actor. All fifteen 600-pixel previews are shared by home and the empty editor. They are generated locally from a bundled source and need no network or Photos access. The sample is an AI-generated still life, not a personal library photo. Its built-in imagegen prompt and provenance are in [catalog-image.md](artifacts/library-favorites/catalog-image.md).

The loaded-photo canvas follows the orientation-corrected image's aspect ratio, with narrower side margins and no padding or letterboxing. It fits the available width and caps its height at 60% of the editor viewport (280–640 points), reducing the width of tall portraits to keep the full image visible. **Before / After** sits inside the image at the bottom left, opposite the expand button. Tap the preview or its expand button to inspect it full screen. Pinch to zoom from 1× to 5×, double-tap or use the 2×/1× button, and drag to inspect other parts of the image. **Before / After** in the detail view preserves the current zoom and position. Close with **×** to return to the same preset and intensity. The save button remains pinned at the bottom. Inspection uses the cached preview, so it does not export or save a photo.

## Collections

The home screen presents **Originals**, **Black and white**, **Paper**, and **NILUT** in separate rows. Inside the editor, the Black and white row keeps its four grouped looks; other cards open their original family. The row brings the selected look into view. Selecting another look keeps intensity and returns to the edited image; importing a new photo preserves the selected collection/look/intensity.

The first family shares a paper relief field and fine-grain pattern:

| Paper code | Look | Character |
| --- | --- | --- |
| P1 | Matte | Natural source color, mild luminosity contrast, soft blacks and neutral paper whites. |
| P2 | Warm | Slightly warmer colored midtones, preserved neutral whites, 1.20× relief and gentle edge aging. |
| P3 | Archive | Restrained warm black and white, 1.45× relief, stronger fine grain and neutral edge patina. |

The family changes color, tone, texture strength and aging while keeping fiber/pore positions aligned. The latest color pass uses near-source saturation for P1/P2 and confines warmth to midtones. P3 is desaturated before a small warm midtone treatment; partial intensity restores source colors as the whole look fades.

## Presets

- **Amber:** warm color matrix, slightly muted colors, lifted shadows and soft highlights.
- **Tide:** cool cyan/blue color matrix, restrained saturation and a gentle contrast curve.
- **Mono:** neutral black and white, deeper midtone contrast and softened endpoints.
- **Film 35:** warm, slightly muted colors, lifted blacks, soft highlights, and fine monochrome film grain. The intensity slider fades the color treatment and grain together.
- **Silver 35:** neutral black and white with a softer black point and white roll-off than Mono, plus slightly stronger monochrome grain than Film 35. At 100% it is fully black and white; lower intensity mixes in the source colors as the whole look fades.
- **Dust 35:** faded warm colors, lifted blacks, soft whites, fine grain, a gentle vignette and sparse light/dark dust specks with three short hairline scratches. Intensity fades the complete look and its artifacts together.
- **Glow 800:** cool shadows, warm highlights, coarser grain, a restrained glow and a red-orange halo around strong highlights. Intensity fades the complete color, grain and light treatment.
- **Scratch 16:** black and white with deeper shadows, soft whites, coarse clustered grain, four long interrupted vertical scratches, shorter diagonal marks, curved fibers and light/dark specks. At 100% it is neutral black and white; lower intensity fades the whole look back toward the source, including its colors.
- **Expired 35:** faded colors, lifted blacks, soft whites, two-scale grain, warm edge light leaks and soft irregular green/magenta stains with uneven exposure. Sparse dust and three fine scratches stay near the side edges; the center receives very little optical wear. Intensity fades the complete look and its artifacts together.
- **Paper family:** P1 Matte, P2 Warm and P3 Archive share fine tooth, pulp variation, short fibers, pores and three faint creases near the edges. Texture is more visible in pale areas and reduced in deep shadows. Intensity fades the complete print look. The original `paper35` identifier now represents P1 Matte.
- **NILUT family:** N1 Style 1 adds contrast, N2 Style 2 shifts toward cyan/green, and N3 Style 3 adds pink/magenta highlights. These reproduce the three sample styles of the official pretrained NILUT model (LUT01, LUT03 and LUT04). N4 Natural, N5 Soft Warm and N6 Cool Matte are original Flickerly grades. The revised N4 has deep shadows, brighter upper midtones, emerald foliage and cleaner cyan-blues. The revised N5 has golden midtones, softer contrast and quieter olive/blue colors, tapering the warmth toward white and skin-like hues. N6 retains its original lifted blacks, cool shadows and restrained chroma. No film grain or paper texture is added. The same slider fades from the original at 0% to the full look at 100%, with 80% as the existing reset/default value.

The earlier recipes combine `CIColorControls`, `CIColorMatrix`, and `CIToneCurve`. The Paper family uses its own color stage, separating luminosity contrast from hue/saturation. Intensity uses `CIDissolveTransition` between the original and the full preset in a linear sRGB working space. Every render starts from the original; edits never accumulate.

The nine film/print presets share two fixed, softly blurred noise layers from `CIRandomGenerator`, at different scales/rotation, then extract one noise channel and center it around neutral gray. Noise amplitude is 0.22 for Film 35, 0.26 for Silver 35, 0.24 for Dust 35, 0.30 for Glow 800, 0.34 for Scratch 16, 0.29 for Expired 35, 0.12 for P1, 0.15 for P2 and 0.18 for P3. Glow 800 expands the grain texture by 1.8×; Scratch 16 uses 2.1× with a higher share of the coarse layer (0.42 versus the default 0.22). Expired 35 uses 1.55× grain with a coarse-layer share of 0.34; all Paper variants use 0.85× with a share of 0.16. `CISoftLightBlendMode` adds the texture; a luminance-derived tone-curve mask reduces it in highlights and deep blacks. Grain coordinates use a common reference whose long edge is `min(1800, source long edge)`, with Lanczos resampling for preview/export and a sampling border to prevent edge artifacts. The pattern is deterministic and does not change as the slider moves. All complete previews are cached at import, so dragging still only blends two ready images. Thumbnails are downsampled from the cached looks.

Dust 35 adds a radial transparent-black gradient for the vignette and a translucent sRGB texture drawn with Core Graphics. A local fixed-seed generator places sparse elliptical specks and three short curved scratches. Texture dimensions are capped at a 1,800-pixel long edge; positions and mark sizes use a common image-relative coordinate system in preview/export. The overlay is composited over the grainy look through Core Image. No texture files or dependencies are required.

Glow 800 selects source highlights with a smooth mask over linear luminance 0.55–0.90. Two Gaussian blurs spread only this mask: a tight near-white glow and a wider warm halo whose red contribution is suppressed inside the original highlight. Blur radii scale with image dimensions; the base image stays sharp. Additive light compositing restores opaque alpha after each sum so cached previews and JPEG exports agree. Grain is applied after the light effects. This is a creative film-inspired look, with no claim to reproduce a specific film stock.

Scratch 16 draws a separate neutral, translucent Core Graphics texture using a local fixed seed. Four long scratches have small bends, gaps and changing width/opacity. Ten shorter diagonal marks, five curved fibers and sparse elliptical specks add irregular details. The shared reference field is capped at a 1,800-pixel long edge and resampled for the current render, keeping artifact positions and relative sizes aligned in preview/export. The complete texture and grain fade together with intensity; no artifacts are regenerated during slider movement.

Expired 35 generates two smooth opaque linear-sRGB maps capped at a 600-pixel long edge. Warped overlapping lobes form green/magenta stains and gentle exposure variation; Soft Light blending retains source detail. Screen blending adds orange/red light leaks along the side edges. A smooth radial weight protects the center from stains, and the leak field is zero there. Grain follows these stages; a separate fixed-seed transparent texture capped at 1,800 pixels adds sparse edge dust and three short scratches. All fields use the upright source aspect ratio and fixed normalized coordinates, so preview/export retain their locations and scale. This is a creative aged-film look rather than a simulation of a specific film stock.

The Paper family builds one shared neutral relief field per import from two fixed noise scales plus a Core Graphics layer of short curved fibers, paired pore highlights/shadows, and three faint edge creases. The reference long edge is capped at 1,800 pixels, with a sampling border for Lanczos scaling. Paper-only noise is made opaque before centering, eliminating an unwanted midtone lift. Relief amplitude is balanced around linear 0.5 while keeping fiber/pore locations stable. Soft Light adds relief; a largely neutral Multiply layer gives pale areas the paper base. P2/P3 scale relief around neutral gray and add faint neutral radial edge wear before the luminance mask. This mask reduces the paper stages in deep shadows. Fine film grain is applied before the paper texture. The shared field is generated locally without texture assets or dependencies; its fixed pattern and scale match in cached previews and full-size exports.

`PaperColorGrade` keeps P1/P2 saturation at 0.98/0.96, using [Luminosity blending](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/#//apple_ref/doc/filter/ci/CILuminosityBlendMode) to apply the tone curve while retaining the base hue/saturation. P2's small color matrix preserves the neutral axis and is blended only into midtones; it avoids a global yellow cast. P3 uses a restrained warm monochrome midtone treatment. Regression fixtures cover neutral ramps and seven representative skin/scene color patches; these numerical checks do not replace portrait/color-calibrated physical-device review.

## NILUT implementation

The fixed NILUT styles are sampled **offline from trained networks** into six
65³ color cubes: three upstream pretrained styles and three Flickerly originals.
The iOS app evaluates these cubes with Core Image;
it does not run a neural network or require PyTorch, Core ML, downloads, or a
server. The six packed RGB float16 assets total **9,886,596 bytes** (about
9.89 MB), plus a small provenance/reference manifest, MIT license, and notice.

`NILUTColorGrade` validates the resource header, size, style ID, and finite 0–1
values, expands RGB float16 into opaque RGBA float32 once per renderer, and
caches the six cubes. Explicit linear-to-sRGB and sRGB-to-linear stages around
`CIColorCube` preserve the model's encoded-sRGB mapping within the editor's
linear working space. The cached full-strength previews keep slider work to
the existing dissolve blend. Export uses the same LUT and blend stages on the
original compressed source at full resolution.

The additional cubes add about 4.94 MB of packed resources and 13.18 MB of
decoded cube data per renderer, plus three cached preview images per import.
Initial loading therefore does more work; slider changes still only blend
cached images. Physical-device memory and import latency need profiling.

The three original targets are authored in OKLab with smooth monotone lightness
curves, bounded hue/chroma adjustments, and hue-preserving gamut compression.
Warm skin-like hues receive smaller color shifts; this is color-based weighting,
not face recognition or semantic skin masking. Whites are kept clean. The new
conditional residual network is trained from scratch on the 65³ RGB target LUTs
and neutral/skin-color anchor samples, without photographs or upstream weights.
This is a fixed color mapping, not an image-adaptive or generative model.
N4/N5 v2 use an RGB residual MLP with low-frequency sine/cosine RGB features
to fit the stronger curves. N6 continues to bake from the retained v1 checkpoint;
its packed resource is verified byte for byte against the previous version.

Source: [NILUT (AAAI 2024)](https://github.com/mv-lab/nilut), revision
`effe074007edf48b1081f3838b8d30bee8ec18e1`. Assets, attribution, and model
reference patches are in `Flickerly/Resources/NILUT/`. Their synchronized Xcode
folder is part of the Flickerly target; the loader supports both flattened and
folder-preserving resource layouts.

With the existing local experiment files and a Python environment containing
PyTorch, NumPy, and Pillow, regenerate or verify the bundled assets with:

```sh
python scripts/generate_nilut_luts.py
python scripts/generate_nilut_luts.py --check
```

To refit N4/N5 while retaining the recorded N6 checkpoint, use:

```sh
python scripts/train_nilut_originals.py
python scripts/generate_nilut_luts.py
python scripts/verify_nilut_originals.py
python scripts/preview_nilut_originals.py
python scripts/preview_nilut_originals.py --intensity .8 --compare-previous
```

The separate checkpoints, original `.cube` targets, training seed/schedule,
validation-only image credits, and full-strength comparisons are retained in
`artifacts/nilut-originals/`. Only the packed lookup tables ship in the app.
See [the implementation and verification report](artifacts/nilut-originals/REPORT.md)
for the current look definitions, v1/v2 comparisons, fit limitations and native
tests. The earlier Photos-save readback is preserved in the v1 snapshot.

The two original demo photographs were compared with direct neural inference
at full resolution for all three styles: mean per-channel 8-bit error is
0.022–0.035, with a worst channel error of 2. Native Core Image reference tests
also check the transfer functions and cube ordering against independent neural
outputs, including neutral ramps, RGB endpoints, and skin/scene color patches.
Those N1–N3 results are measured approximations of the pretrained looks.
N4–N6 use their own authored targets and checkpoint. See
`artifacts/nilut-integration/lut-accuracy.json` for cube measurements and
`artifacts/nilut-preview/` for the earlier direct-model results.

## Structure

- `Flickerly/EditorView.swift`: SwiftUI editor and PhotosPicker.
- The same view file includes full-screen photo inspection with bounded zoom/pan and before/after comparison.
- `Flickerly/EditorModel.swift`: main-actor UI state, cancellable loading, a paced preview worker, add-only PhotoKit permission and saving.
- `Flickerly/PhotoRenderer.swift`: actor-isolated ImageIO decoding, recipes, cached previews and full-resolution JPEG export.
- `Flickerly/PhotoPreset.swift`: preset names and descriptions.
- `FlickerlyTests/PhotoRendererTests.swift`: identity, local favorites, catalog previews, rendering, intensity, orientation, full-resolution export, continuous slider input and stale/error recovery checks.

## Prototype scope

The editor creates an orientation-corrected **SDR sRGB preview capped at 1,800 pixels on its longest side**. Cached looks keep slider updates lightweight. The photo remains local; the system picker may download an iCloud asset before returning it.

Slider changes update one pending slot. A single preview worker renders at a target cadence of up to 60 updates per second, always taking the newest pending value. It publishes completed frames while input continues, then processes the latest waiting value. It does not cancel/restart on each slider event. Importing another photo invalidates the old worker, so old frames cannot overwrite the new photo. There is no spinner for slider updates; loading and saving keep their progress indicators. The current display path still uses `CGImage`/`UIImage`; direct Metal display can be evaluated after physical-device profiling if further improvement is needed.

Saving renders again from the retained compressed source at its **original pixel dimensions**, using the selected preset and intensity. The app prepares a **95%-quality JPEG in SDR sRGB**, then derives Medium and Small versions capped at 2048 and 1024 pixels on their longest side without upscaling. The size picker shows the actual byte size of each prepared file. The chosen JPEG is imported into Photos as a new asset. Source orientation is baked into the pixels (portrait dimensions are correctly swapped), and temporary export files are removed on cancellation or after PhotoKit finishes. Transparent pixels are composited over white in both preview and export. Source location/capture metadata is not copied; the new asset has its save date.

Only the first save requests **add-only** access to Photos via `NSPhotoLibraryAddUsageDescription`; the system picker still does not require read access. Denied access shows a Settings action, and restricted access or write failures show an error. Controls are disabled during saving, and success is shown only after PhotoKit completes. The original library asset is never modified.

This version does not process RAW/Live Photo content or preserve HDR. Physical-device memory/performance and HDR/wide-gamut behavior still require validation.

## Build and test

```sh
xcodebuild -project Flickerly.xcodeproj -scheme Flickerly -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Flickerly.xcodeproj -scheme Flickerly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

For a physical iPhone, select your development team under Signing & Capabilities. Keep the current bundle identifier when updating an existing installation; use a different identifier only when intentionally creating a separate app.

Apple references: [Core Image](https://developer.apple.com/documentation/coreimage), [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker), [Dissolve transition](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/dissolvetransition%28%29), [Photo library authorization](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app).

See [verification notes](artifacts/VERIFICATION.md), the [Paper color before/after comparison at 80%](artifacts/paper-natural/paper-natural-before-after.jpg), the [current family comparison](artifacts/paper-natural/paper-natural-comparison.jpg), and [natural Matte in the editor](artifacts/screenshots/paper-natural-p1-qa.png). Current full-size saved samples: [P1 Matte](artifacts/paper-natural/p1-matte-full-resolution.jpg), [P2 Warm](artifacts/paper-natural/p2-warm-full-resolution.jpg), [P3 Archive](artifacts/paper-natural/p3-archive-full-resolution.jpg). Earlier artifacts: [original Paper family](artifacts/paper-family/paper-family-comparison.jpg), [Paper 35 texture detail](artifacts/paper35/paper35-artifact-detail.png), [Expired 35 sample at 80%](artifacts/expired35/expired35-full-resolution.jpg), [Scratch 16 sample at 100%](artifacts/scratch16/scratch16-full-resolution.jpg), [Glow 800 sample at 100%](artifacts/glow800/glow800-full-resolution.jpg), [Dust 35 sample at 80%](artifacts/dust35/dust35-full-resolution.jpg), [portrait preview](artifacts/screenshots/larger-preview-portrait.png), [Silver 35 sample](artifacts/silver35/silver35-full-resolution.jpg), and [Film 35 sample](artifacts/film35/film35-full-resolution.jpg).

NILUT integration: **46 tests passed** plus a generic iPhone build. Interactive
Simulator saves were independently read back at **4032 × 3024**. See the
[editor](artifacts/screenshots/nilut-family-n1-qa.png), the
[saved three-style comparison at 80%](artifacts/nilut-integration/saved-family-comparison.jpg),
and full-size saved [N1](artifacts/nilut-integration/n1-full-resolution.jpg),
[N2](artifacts/nilut-integration/n2-full-resolution.jpg),
[N3](artifacts/nilut-integration/n3-full-resolution.jpg).
