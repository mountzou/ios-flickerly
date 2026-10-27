# Flickerly icon kit

The approved Grain symbol, faithfully traced from `source/selected-grain-reference.png` into four closed cubic Bézier paths. `grain-mark.svg` is the editable master. There are no embedded raster images, fonts or external resources in the vector artwork.

## Main icon

Use `png/light/flickerly-light-1024.png` for the App Store: black symbol, pure white background, RGB PNG without alpha. The square artwork has no baked-in rounded outer corners; the operating system applies its icon mask. All sizes retain the approved proportions and margins.

## Variants and formats

| Folder / variant | Appearance | Intended use |
| --- | --- | --- |
| `light` | Black on opaque white | Main app icon / App Store |
| `dark` | White symbol on transparency | iOS dark appearance with system background |
| `tinted` | White on opaque black, grayscale | iOS tinted appearance |
| `inverse` | White on opaque black | General dark-background branding |
| `mark-black` | Black symbol on transparency | Light-background layouts |
| `mark-white` | White symbol on transparency | Dark-background layouts |

- `vector/`: SVG and vector PDF for all six variants. The master and all vector exports use a 1024 × 1024 artboard and scale without losing shape detail.
- `png/`: every variant at **16, 20, 24, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87, 120, 128, 152, 167, 180, 192, 256, 512, 1024 and 2048 pixels**. This includes the standard iPhone/iPad legacy icon pixel dimensions and larger branding exports.
- `AppIcon.appiconset/`: modern Xcode catalog with 1024-pixel light/dark/tinted sources. Xcode derives the required iPhone/iPad renditions.
- `ios-all-sizes/AppIcon.appiconset/`: standalone legacy light-icon catalog, with explicit iPhone/iPad/App Store size slots. This alternative is not simultaneously included in the app.
- `web/`: 16/32/48/192/512 PNG files and a multi-resolution `favicon.ico`.
- `manifest.json`: source hash, renderer versions and hashes of generated files.

## App integration

The active catalog is `Flickerly/Catalog/Assets.xcassets`, inside the project's existing synchronized resource folder. The primary icon setting is **AppIcon** in Debug and Release. The bundle identifier is unchanged. The additional `FlickerlyMark` imageset is a recolorable, resolution-preserving vector PDF for future in-app use.

The catalog follows Apple's [app icon configuration guidance](https://developer.apple.com/documentation/xcode/configuring-your-app-icon): a 1024-pixel single-size source, a transparent dark variant, and a grayscale tinted variant. This project uses asset catalogs rather than introducing an Icon Composer dependency.

## Regeneration

Install the Python dependencies in `scripts/app-icon-requirements.txt` and native Cairo, then run from the repository root:

```sh
python3 scripts/generate_app_icons.py
python3 scripts/generate_app_icons.py --check
```

Generation uses the saved vector, not an AI image model. The initial silhouette was selected from imagegen concepts. Renderer versions are recorded in the manifest; review the regenerated output when upgrading them. PDF timestamps are fixed for reproducible checks.
