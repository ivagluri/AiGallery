# AiGallery — Claude Session Context

## Project Overview

Native macOS SwiftUI app (minimum macOS 13). A general-purpose AI-generated image browser that reads embedded PNG generation metadata (pnginfo) from local image folders. Originally a strict tag-variation gallery; now pivoted to a general pnginfo browser with metadata-driven organisation.

**Tech stack:** Swift / SwiftUI, SPM, no external dependencies (SQLite3 via system library).

**Key source files:**

| File | Role |
|---|---|
| `Sources/TagBrowserApp.swift` | App entry point |
| `Sources/ContentView.swift` | Main UI (~2350 lines) |
| `Sources/LibraryStore.swift` | Core state — library scanning, caching, categories |
| `Sources/PNGInfoReader.swift` | PNG chunk parser (A1111, ComfyUI, DrawThings formats) |
| `Sources/FolderMetadataReader.swift` | Folder-level metadata fallback (JSON/CFG files) |
| `Sources/LibraryProfile.swift` | Search algorithm + mode-specific folder interpretation |
| `Sources/Models.swift` | Data structs: Category, ImageItem, ImageMetadata, MetadataField, MetadataFilter |
| `Sources/MetadataIndex.swift` | **NEW** SQLite-backed persistent metadata index (actor) |
| `Sources/AppSettings.swift` | UserDefaults-backed settings (app mode) |

---

## Active Feature Branch

`claude/pnginfo-metadata-categories-CJtoF`

---

## Feature: Synthetic pnginfo Categorisation

### Goal

Lightroom-style smart filters driven by embedded generation metadata. Stable, categorical fields (Model, Sampler, Scheduler, VAE, Upscaler) become browsable facets. Numeric fields (Steps, CFG, Strength) get range sliders. Prompts extend the existing text search.

### Design decisions

- **Categorical** (low-cardinality) → facet sidebar/filter bar
- **Numeric / continuous** → range filter sliders (Phase 4)
- **Free-text** (Prompt, Negative Prompt) → full-text search extension (Phase 3)
- **Seed** → not surfaced (every image is unique)
- **Resolution** → skipped as facet (too many unique values); treat width/height as numeric range if needed

**UI pattern:** Lightroom-style collapsible filter bar above the image grid (primary), plus a "Smart Filters" section at the bottom of the sidebar for saved filter presets.

**Persistence:** One SQLite file per library root, stored in `~/Library/Application Support/AiGallery/<root-hash>.sqlite`. Incremental updates via file modification dates.

### Implementation phases

| Phase | Status | Summary |
|---|---|---|
| **1 — Persistent Metadata Index** | ✅ Complete | SQLite actor, background scan, mod-date incremental updates |
| **2 — Facet Sidebar + Filter State** | ⬜ TODO | MetadataFilter state in LibraryStore, synthetic "Filtered" category, Smart Filters sidebar section + filter bar in ContentView |
| **3 — Metadata Search Extension** | ⬜ TODO | Extend LibraryProfile.search to query MetadataIndex (model/sampler match ranked below filename match) |
| **4 — Range Filters** | ⬜ TODO | Steps / CFG sliders in filter bar |

---

## Phase 1 — What Was Built

### `Sources/MetadataIndex.swift` (new file)

`actor MetadataIndex` backed by SQLite3 (system library, no SPM dependency — just `linkerSettings: [.linkedLibrary("sqlite3")]` in Package.swift).

**DB schema:** `indexed_images` table with columns `path, mod_date, model, sampler, scheduler, vae, upscaler, steps, cfg, strength, width, height, source_fmt`. Indexes on `model`, `sampler`, `scheduler`, `vae`.

**Key methods:**
- `scan(images: [ImageItem], onProgress:) async` — incremental scan; skips files whose mod date hasn't changed; batched transactions (commit every 200 rows); yields cooperatively every 100 files.
- `facetValues(for: MetadataField) -> [(value: String, count: Int)]` — for populating filter UI.
- `imagePaths(matching: [MetadataFilter]) -> Set<String>` — AND-filter across fields.
- `imagePaths(where:contains:) -> Set<String>` — LIKE search on a single field (for Phase 3).

**Normalization:**
- **Model names** — strips path prefix, file extension, hash annotations (`[xxxxxxxx]`), precision suffixes (`-fp16`, `-fp8`, `-bf16`, `-pruned`, `-emaonly`).
- **Sampler/Scheduler** — for A1111's combined field ("DPM++ 2M Karras"), splits on known scheduler suffixes (Karras, Exponential, SGM Uniform, Simple, Beta). ComfyUI already provides them separately.
- **Source format** detected heuristically: ComfyUI has a distinct `Scheduler` key; DrawThings uses `Guidance Scale`; otherwise A1111.

**DB location:** `~/Library/Application Support/AiGallery/<djb2-hash-of-root-path>.sqlite`

### `Sources/Models.swift` additions

```swift
enum MetadataField: String, CaseIterable { case model, sampler, scheduler, vae, upscaler }
struct MetadataFilter: Identifiable, Hashable { let field: MetadataField; let value: String }
```

### `Sources/LibraryStore.swift` changes

Added:
- `private(set) var metadataIndex: MetadataIndex?`
- `@Published var indexProgress: Double = 0`
- `private var indexScanTask: Task<Void, Never>?`
- `private func startBackgroundIndexing()` — cancels any prior scan, creates MetadataIndex for the current rootURL, launches background Task, posts progress updates to main actor.

`startBackgroundIndexing()` is called from:
1. `init` — after synchronous library load
2. `reload()` — inside the `MainActor.run` block after categories are updated

---

## Phase 2 — Next Steps (when resuming)

Files to modify:
1. **`Sources/LibraryStore.swift`** — add `activeMetadataFilters: [MetadataFilter]`, `setMetadataFilter()`, `clearMetadataFilters()`. Modify `rebuildCategories()` to create a synthetic `"__filtered__"` Category from `await metadataIndex.imagePaths(matching: activeMetadataFilters)` when filters are active.
2. **`Sources/ContentView.swift`** — add collapsible filter bar above the image grid (toolbar toggle); one picker per MetadataField showing `facetValues`; active filter chips; progress indicator while `indexProgress < 1`. Add "Smart Filters" section at the bottom of the sidebar for saved presets.

Key pattern to follow: `rebuildCategories()` / Favorites synthetic category (LibraryStore.swift:~317) is the template for the `"__filtered__"` synthetic category.

Filter bar UI: a `HStack` of `Menu` buttons (one per field), each presenting a searchable list of `(value, count)` tuples from `metadataIndex.facetValues(for:)`. Active filters render as dismissable chips.

---

## Build

This is a macOS-only Swift app. Build with:
```bash
swift build
# or the full app bundle:
./scripts/build-app.sh
```

Swift is required — this environment may not have Swift installed if running on Linux.
