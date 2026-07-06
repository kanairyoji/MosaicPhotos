<p align="center">
  <img src="docs/icon_256.png" width="120" alt="MosaicPhotos icon">
</p>

<h1 align="center">MosaicPhotos</h1>

<p align="center">
  A privacy-first iOS photo viewer that unifies your <b>device library</b> and <b>Dropbox</b> into one experience — built entirely with standard Apple frameworks, <b>no third-party SDKs</b>.
</p>

<p align="center">
  <a href="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/ci.yml"><img src="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/codeql.yml"><img src="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL%20v3-blue.svg" alt="License: AGPL v3"></a>
  <img src="https://img.shields.io/badge/iOS-26%2B-blue" alt="iOS 26+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange" alt="SwiftUI">
  <img src="https://img.shields.io/badge/AI-on--device%20CLIP-purple" alt="on-device CLIP">
  <img src="https://img.shields.io/badge/tests-270%2B%20passing-brightgreen" alt="tests">
  <a href="https://kanairyoji.github.io/MosaicPhotos/architecture-note/"><img src="https://img.shields.io/badge/docs-Architecture%20Note-brightgreen" alt="Architecture Note"></a>
</p>

<p align="center">
  <b>English</b> | <a href="README.ja.md">日本語</a>
</p>

---

## Overview

**MosaicPhotos** lets you browse the photos on your iPhone and the photos stored in your Dropbox side by side: a single merged timeline, your device albums, and an automatic **Places** view that groups photos by city — all in a clean SwiftUI interface. Dropbox is integrated directly over its HTTP API with OAuth 2.0 + PKCE; there is no Dropbox SDK and no analytics.

## Screenshots

<table>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/home.jpg" width="230" alt="Home"><br>
  <b>Home</b><br>
  <sub>Your device and Dropbox photos in one place — plus <b>Time&nbsp;&amp;&nbsp;Place</b> trips grouped automatically from when and where they were taken.</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/ai-compose.jpg" width="230" alt="AI Album composer"><br>
  <b>AI Albums — describe it</b><br>
  <sub>Describe an album in plain words, in any language (e.g. “children in the last 2 years”, “landscape without people”). Interpreted once by the on-device LLM, then matched with scene tags, CLIP and an LLM review — all on device.</sub>
</td>
</tr>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/ai-albums.jpg" width="230" alt="AI & folder albums"><br>
  <b>AI &amp; folder albums</b><br>
  <sub>Your description becomes a living album that fills in as the library is indexed. Albums inferred from Dropbox folder names appear here too — dates in the folder name are parsed so they group as “name (year)”.</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/photo-info.jpg" width="230" alt="Photo info"><br>
  <b>Photo info &amp; EXIF</b><br>
  <sub>Open any photo for place, date, full EXIF (camera, lens, exposure) and a map — plus detected scene tags and an AI description, generated on device.</sub>
</td>
</tr>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/cloud.jpg" width="230" alt="Grid browsing"><br>
  <b>Cloud (Dropbox)</b><br>
  <sub>Browse Dropbox photos in a pinch-to-resize grid. Background delta sync keeps it fresh; thumbnails and originals are cached locally.</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/grid-months.jpg" width="230" alt="Dense month grouping"><br>
  <b>Dense month grouping</b><br>
  <sub>Months with few photos are packed together under date-range headers (e.g. “2021-02 – 2021-04”) so the grid stays dense; adjustable in Settings → Photo Grid.</sub>
</td>
</tr>
</table>

<sub>Screenshots captured in the iOS Simulator.</sub>

## Features

- **All Photos** — Your device and Dropbox photos merged into one chronological timeline.
- **Time & Place** — Trips are detected automatically from capture time and location (multi-day, multi-city trips become a single album), with smart titles and covers.
- **AI Albums & semantic search** — Describe an album in natural language, in **any language** (e.g. “走っている子供” / “a running child”, or “Kyoto or Nara family favorites, no screenshots”). The request is interpreted **once** by the on-device LLM (Apple Foundation Models, persisted; deterministic parsers ground dates, places and common visual words) and matched by a **layered, threshold-free pipeline**: calibrated **scene tags** (built-in Vision classifier, ~1,300 classes) + **CLIP contrast** (OpenCLIP ViT-B-32 via Core ML, positive vs. negative concepts) + lexical match, fused and then **reviewed by the on-device LLM** against each photo's evidence (tags, face counts, captions — with majority voting on unsure cases). Exclusions like “without people” combine real **face detection counts** with tag and CLIP evidence. Relative dates (“last 2 years”) are parsed deterministically. Works across **both device and Dropbox** photos.
- **On-device image understanding** — Photos are indexed in the background in three passes: **scene tags** (Vision, precision-calibrated), **CLIP embeddings** (batched ANE inference), and optional **VLM captions** (bundled SmolVLM-256M, one short English sentence per photo — runs over several nights). The full-screen info panel always shows the tag field (and the AI description once generated). Heavy indexing runs **only while charging and idle** — including while the device is locked (BGProcessingTask) — so it never gets in the way. No OCR, no third-party vision API, no network.
- **Photos** — Browse your on-device library via PhotosKit, with fast thumbnail caching and a pinch-to-resize grid.
- **Cloud** — Browse Dropbox photos. Background delta sync keeps the list fresh; thumbnails and originals are cached locally.
- **Albums** — Your user-created device albums, scanned and cached independently.
- **Places** — Photos grouped by city using **on-device reverse geocoding**, combining located photos from both the device and Dropbox. Grows automatically as more location data arrives.
- **Settings & Backup** — Connect Dropbox, tune cache limits, and back up device photos to Dropbox (with people / album / favorite metadata).
- **Background work, battery & data** — Continuous/periodic background work (AI indexing, automatic albums, scanning, Dropbox sync, backup) is gated by **power** and **network** policies to save battery and cellular data. Defaults: run **only while charging** (Low Power Mode off) and use **Wi-Fi only**; both are configurable (Settings → General → Background & Battery). Photos you open or browse are always fetched — only automatic background traffic is limited. CLIP indexing is smart: on cellular it keeps indexing local photos and defers cloud photos to Wi-Fi. An optional top-of-screen **activity bar** visualizes power/network state and live background/Dropbox activity.
- **Built for large libraries** — Designed for tens of thousands of photos: metadata and image vectors are paged and stored compactly (Float16). Under memory pressure the app records diagnostics and **proactively frees image caches** (shrink on warning, full purge on critical) to stay stable instead of crashing.

> Viewing modes shared across every source: **dense**, **month**, and **year** grid layouts, pinch-to-resize, full-screen paging, and an EXIF info panel (camera, aperture, ISO, focal length). The **month** layout packs sparse months together — consecutive low-count months are greedily filled into rows under date-range headers (e.g. “2024-01 – 2024-03”) so months with few photos don't leave gaps. The density (how many rows before a new header) is adjustable in **Settings → General → Photo Grid**.

## Architecture

The app is split into focused local Swift Package Manager modules. Logic layers are UI-free so they can be unit-tested on macOS with `swift test`.

```
MosaicPhotos (app)
├── MosaicSupport     cross-cutting utilities (logging), no dependencies
├── PhotoSourceKit    shared photo-source interface (PhotoStore / PhotoItem) + grid & paging views
├── ImageCacheKit     image cache primitives (memory + disk I/O), SwiftUI-free
├── LocalPhotoCore    device-photo logic (PHAsset store, albums, thumbnail cache)
├── LocalPhotoKit     device-photo UI (depends on LocalPhotoCore)
├── DropboxCore       Dropbox logic — OAuth/PKCE, HTTP API client, sync engine, cache (SwiftUI-free)
├── DropboxKit        Dropbox UI layer (depends on DropboxCore)
├── BackupKit         device → Dropbox backup engine
├── PhotosFeatureKit  merges local + Dropbox (MergedPhotoStore) and place grouping
├── AutoAlbumCore     auto albums + on-device AI logic (SwiftUI-free): Time & Place trips,
│                     folder-name albums, composable query model (OR/NOT), search & fusion
└── MobileCLIPKit     AI runtimes + AutoAlbumCore seam implementations (CLIP, Vision scene
                      tags, SmolVLM captions + GPT2 tokenizer, face model, display labeler)
```

- **Logic vs. UI separation** — `DropboxCore` (logic) and `DropboxKit` (UI) are separate packages; `DropboxCore` never imports SwiftUI.
- **Dependency-injection seams** — networking (`HTTPClient`), time (`DateProvider`), and tokens (`AccessTokenProvider`) are protocols, so the sync engine, batcher, auth, and backup are testable without the network.

### On-device AI — how it works

All AI lives in **`AutoAlbumCore`** (SwiftUI-free); the app injects the on-device implementations.

- **Embeddings** — Each photo (device *and* Dropbox) is encoded once with **OpenCLIP ViT-B-32 (DataComp)** (Core ML, 512-dim) into a normalized image vector. The model was chosen by an **on-device recognition benchmark** (`scripts/eval_recognition.sh`): ImageNet-1k zero-shot **≈75% top-1** and **10/10** natural-language queries, balancing accuracy against on-device cost (lightweight patch-32 image encoder ≈60MB). Vectors live in a **separate SwiftData table (`PhotoEmbedding`) stored as Float16**, so metadata fetches never load the blobs (this fixed a photo-count-proportional launch crash). A `PhotoTagger` fills these in the background in small throttled batches (`.background` QoS; speed is user-selectable). Cloud photos are embedded from their cached thumbnails.
- **Scene tags & captions** — Alongside CLIP, every photo gets **scene tags** from the built-in Vision classifier (~1,300 classes, precision-calibrated with `hasMinimumRecall(forPrecision:)` — no hand-tuned thresholds) and, if the optional **SmolVLM-256M** model is bundled (`scripts/build_smolvlm.sh`, Apache-2.0), a one-sentence **English caption**. All three indexes are filled by a nightly pipeline (tags → embeddings → captions) that runs only while **charging and idle**, including locked (BGProcessingTask).
- **Interpretation** — A request is interpreted **once** when the album is created (Apple Foundation Models, guided generation) and persisted with a version. Small on-device LLMs produce unreliable structure, so the output is defensively sanitized and grounded by deterministic layers: dates come from `RelativeDateParser` (JA/EN) only, places/people must match the catalog or the original text, and a small `JapaneseVisualLexicon` extracts common visual words and people-negations even when the LLM fails.
- **Search** — Hard conditions filter first (`QueryEvaluator`), then three signals are fused with **Reciprocal Rank Fusion**: **tag matches** (discrete, threshold-free), **CLIP contrast** (positive vs. per-exclusion negative embeddings, relative comparison only), and lexical matches. Exclusion-bearing albums pass an **evidence gate** (a photo must have tags, a face count, or a caption to qualify) and finally an **LLM review** (`AlbumVerifier`): the model reads each candidate's evidence line and keeps/drops it, re-judging unsure cases with majority voting. Re-evaluation is incremental — only newly indexed photos are scored and merged into a persisted score pool.
- **Seams** — Perception (`PhotoPerceptionProvider`, `TagPerceptionProvider`), text (`TextEmbedder`, `QueryTranslator`), and review (`AlbumCandidateVerifier`) are protocols in `AutoAlbumCore`; **`MobileCLIPKit`** implements them (CLIP runtime, Vision tags, SmolVLM runtime + GPT2 tokenizer), and the app's composition root wires them in. `PhotoSourceKit` stays unaware of AI and receives per-photo info through a `photoInsight` environment closure.

## Documentation

An in-depth internal **architecture note** — design rationale (ADR), deep-dive implementation pages (concurrency, caching, data model), and a general, app-independent AI primer — is available as a multi-page HTML site:

- **[Architecture Note → kanairyoji.github.io/MosaicPhotos/architecture-note](https://kanairyoji.github.io/MosaicPhotos/architecture-note/)** — published via GitHub Pages (diagrams via Mermaid). Source: [`docs/architecture-note/`](docs/architecture-note/). End-user **[Help guide](https://kanairyoji.github.io/MosaicPhotos/help/)** is also published (source: [`docs/help/`](docs/help/)).

> ⚠️ **The architecture note is written in Japanese only.** Its master records live as Markdown in `docs/architecture-note/records/`.

## Tech Stack

| Area | Technology |
|---|---|
| Language / UI | Swift · SwiftUI |
| State | Swift Observation (`@Observable`) |
| Device photos | PhotosKit (`PHPhotoLibrary`, `PHImageManager`) |
| Dropbox auth | `AuthenticationServices` (`ASWebAuthenticationSession`, OAuth 2.0 + PKCE) |
| Token storage | Keychain Services |
| Dropbox API | `URLSession` async/await (no SDK) |
| Caching | SwiftData (metadata) + custom binary cache with LRU eviction |
| On-device AI | Vision image classification (built-in, ~1,300 classes) · OpenCLIP ViT-B-32 (DataComp/MIT) embeddings · SmolVLM-256M captions (Apache-2.0, optional) — all Core ML · Apple Foundation Models for interpretation, translation & candidate review |
| Minimum OS | iOS 26 |
| Packaging | Swift Package Manager (11 local packages) |

## Privacy & Security

- **No third-party SDKs** — everything uses standard Apple frameworks.
- **OAuth 2.0 + PKCE** for Dropbox; access/refresh tokens are stored in the **Keychain**, never in plain files.
- **On-device processing** — reverse geocoding and EXIF parsing happen locally.
- No analytics, no tracking.

## Build & Test

```bash
# Build (iOS Simulator)
xcodebuild -project MosaicPhotos.xcodeproj -scheme MosaicPhotos -sdk iphonesimulator build

# Run the full test suite (packages + app target) — 270+ tests
scripts/test.sh all

# Subsets
scripts/test.sh fast   # macOS swift test (pure logic)
scripts/test.sh ios    # iOS Simulator package tests
scripts/test.sh app    # app-target unit tests
```

### On-device AI model (optional)

Semantic search and the detected keyword tags use an **OpenCLIP** model (Core ML). The model is **not committed** (size) and is generated locally:

```bash
bash scripts/build_mobileclip.sh   # converts OpenCLIP ViT-B-32 (DataComp, MIT) → MosaicPhotos/MobileCLIP/
```

Without the model the app still runs fully; only CLIP-based semantic search and keyword tags are disabled (structured filters by date/place/people keep working).

## License

Source code is licensed under the **GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)** — see [LICENSE](LICENSE).

**Dual distribution:** in addition to the AGPL, the copyright holder (Ryoji KANAI) also distributes the compiled app via the Apple App Store under Apple's standard terms (see [NOTICE](NOTICE)). Contributions are accepted under the DCO with a relicensing grant — see [CONTRIBUTING.md](CONTRIBUTING.md).

Third-party assets are listed in-app under **Settings → Licenses** (and in `MosaicPhotos/Settings/Licenses.swift`): the bundled CLIP model is **OpenCLIP ViT-B-32 (DataComp, MIT)**, the CLIP BPE vocabulary / tokenizer (MIT), build tools (coremltools, PyTorch, open_clip, Pillow, NumPy), and Mermaid (docs). Apple SDKs and SF Symbols are used under Apple's terms.
