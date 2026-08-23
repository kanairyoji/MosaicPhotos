# Screenshots

These images are referenced by `README.md` / `README.ja.md` and the help pages (`docs/help/`).
All are iOS Simulator captures resized to 1652px tall JPEG.

## Privacy-safe set (regenerate with one command)

Most captures below are produced by the automated pipeline in **ADR-114** and contain
**no personal photos** — the simulator is seeded only with freely licensed images
(Lorem Picsum / Unsplash License, commercial use allowed, no attribution required),
with EXIF capture dates and GPS injected so that trips, place albums and the date grid
fill with real-looking data.

```bash
scripts/fetch_screenshot_photos.sh          # fetch free-license photos
swift scripts/inject_screenshot_exif.swift  # inject EXIF (date + GPS)
scripts/make_screenshot_sim.sh              # create the throwaway "MosaicShots" simulator
xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
  -destination 'id=<MosaicShots UDID>' \
  -only-testing:MosaicPhotosUITests/ScreenshotCaptureTests \
  -parallel-testing-enabled NO -resultBundlePath .screenshot_assets/result.xcresult
python3 scripts/export_screenshots.py       # xcresult attachments -> named PNGs
```

| File | Screen | Source | Referenced by |
|---|---|---|---|
| `home.jpg` | Home — Sources + Trips + People + AI albums | **auto (safe)** | README, help/index, help/basics |
| `places.jpg` | Home — place albums (Naha, Kyoto, …) | **auto (safe)** | help/places |
| `grid-dense.jpg` | Photo grid (dense layout, scrubber, bottom bar) | **auto (safe)** | help/basics |
| `fullscreen.jpg` | Full-screen photo | **auto (safe)** | help/basics |
| `photo-info.jpg` | Photo info panel — date, place, analysis state, EXIF, map | **auto (safe)** | README, help/basics |
| `ai-compose.jpg` | AI Album composer (suggested places/dates from the library) | **auto (safe)** | README, help/ai-search |
| `settings.jpg` | Settings root (Albums & Search incl. Cloud Sharing) | **auto (safe)** | help/settings |
| `grid-months.jpg` | Photo grid (month layout with packed date-range headers) | legacy (real photos) | README, help/basics |
| `ai-albums.jpg` | Home — People (face clusters) + AI albums | legacy (real photos) | README, help/folder-albums |
| `ai-analysis.jpg` | AI analysis status screen | legacy (real photos) | help/ai-search |
| `cloud.jpg` | Cloud (Dropbox photo grid) | legacy (real photos) | README, help/basics, help/dropbox |

> ⚠️ **The four `legacy` captures still contain real photos from the developer's library.**
> They cannot be reproduced by the automated pipeline yet, because they require things the
> throwaway simulator does not have: **faces** (no faces in the free-license set — and putting
> real people's faces in public docs needs a separate decision), a **connected Dropbox account**,
> and a **finished AI analysis pass** (CLIP embedding is skipped on the simulator by design).
> Replace them when those become available.
