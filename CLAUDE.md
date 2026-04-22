# AiGallery — Claude Session Context

## Project Overview

Native macOS SwiftUI app (minimum macOS 13). A general-purpose AI-generated image browser that reads embedded PNG generation metadata (pnginfo) from local image folders. Filesystem-based category navigation with SQLite-backed metadata indexing, facet filtering, and smart saved-search filters.

**Tech stack:** Swift / SwiftUI, SPM, no external dependencies (SQLite3 via system library).

---

## Key Source Files

| File | Role | Lines |
|---|---|---|
| `Sources/TagBrowserApp.swift` | App entry point, AppDelegate | 62 |
| `Sources/ContentView.swift` | Main UI — sidebar, grid, inspector, search, filter bar | 2690 |
| `Sources/LibraryStore.swift` | Core state — scanning, categories, filters, smart filters, metadata index | 826 |
| `Sources/MetadataIndex.swift` | SQLite-backed persistent metadata index (actor) | 441 |
| `Sources/LibraryProfile.swift` | Search algorithm + `parseSearchTerms` + mode-specific folder logic | 190 |
| `Sources/Models.swift` | Data structs: Category, ImageItem, ImageMetadata, SmartFilter, MetadataField, MetadataFilter | 103 |
| `Sources/PNGInfoReader.swift` | PNG chunk parser (A1111, ComfyUI, DrawThings formats) | 982 |
| `Sources/FolderMetadataReader.swift` | Folder-level metadata fallback (JSON/CFG files) | 279 |
| `Sources/AppSettings.swift` | UserDefaults-backed settings (app mode only) | 33 |
| `Sources/WindowReader.swift` | NSView bridges: HostWindowReader, KeyAwareView, KeyHandlingView | 129 |
| `Sources/PreviewOverlayController.swift` | QuickLook / fullscreen preview controller | 276 |
| `Sources/PreviewOverlayView.swift` | SwiftUI view for fullscreen preview overlay (controls, layout, sizing) | 336 |
| `Sources/SafeImageLoader.swift` | Async thumbnail loader with cancellation | 194 |

---

## Architecture

### Navigation Model

The left sidebar IS the root folder. The root folder itself is not a navigation level — its subfolders are top-level items. Group headers are selectable (show images in that folder) and collapsible (expand subfolders). Leaf folders (no subfolders) render as plain selectable rows.

- Root-level images (directly in root, no subfolder) appear as a plain named row using the actual folder name — indistinguishable from subfolders.
- Synthetic categories (Favorites, Filtered) appear above the filesystem tree.
- Smart Filters section appears at the bottom of the sidebar.

### Category / Group Hierarchy

`CategoryGroup` groups `Category` objects by their `rootGroupID` (first path component). Special reserved IDs:

| ID | Meaning |
|---|---|
| `__root__` | Images directly in root folder |
| `__favorites__` | Favorites synthetic category |
| `__filtered__` | Active metadata-filter synthetic category |
| `__smart_filters__` | Smart Filters group (sidebar section) |
| `__smart_<UUID>__` | Individual smart filter category |

### Search

`LibraryProfile.searchImages` + `LibraryStore.searchWithMetadata`:

- **Multi-term AND** — space-separated terms all must match. Quoted phrases (`"foo bar"`) treated as a single term.
- **Filename search** first (ranked: exact → prefix → contains for single term).
- **Metadata search** second — LIKE queries on all `MetadataField` columns + `prompt` + `negative_prompt`, unioned per term then intersected across terms. Results appended after filename matches, deduplicated by path.
- Entry point: `searchWithMetadata(matching:limit:) async` in LibraryStore.
- Term parser: `parseSearchTerms(_:)` in LibraryProfile.swift (internal, not `private` so LibraryStore can call it).

### Metadata Index (`MetadataIndex` actor)

SQLite file at `~/Library/Application Support/AiGallery/<djb2-hash>.sqlite`.

**Schema** (`indexed_images` table):
```
path, mod_date, model, sampler, scheduler, vae, upscaler,
steps, cfg, strength, width, height, source_fmt,
prompt, negative_prompt
```

**Key methods:**
- `scan(images:onProgress:) async` — incremental; skips unchanged mod dates; batches of 200; yields every 100 files.
- `facetValues(for: MetadataField)` — for populating filter UI dropdowns.
- `imagePaths(matching: [MetadataFilter])` — AND-filter across fields (exact match).
- `imagePaths(where: MetadataField, contains: String)` — LIKE search on a single field.
- `imagePathsWherePromptContains(_:)` — LIKE on both `prompt` and `negative_prompt`.

**Schema migration:** `ALTER TABLE ADD COLUMN` in `createSchema(db:)` (static). If a new column is added successfully, `mod_date` is zeroed on all rows to force re-index.

**Normalization:**
- Model names: strips path, extension, hash annotations `[abc123]`, precision suffixes (`-fp16`, `-fp8`, `-bf16`, `-pruned`, `-emaonly`).
- Sampler/Scheduler: A1111 combined "DPM++ 2M Karras" → split on known scheduler suffixes. ComfyUI provides them separately.
- Source format: ComfyUI (has `Scheduler` key) / DrawThings (has `Guidance Scale`) / A1111.

---

## LibraryStore Key State

```swift
@Published var rootURL: URL
@Published var categories: [Category]
@Published var selectedCategoryID: Category.ID?
@Published var selectedImageID: ImageItem.ID?
@Published var isLoading: Bool
@Published var errorMessage: String?
@Published var hasChosenRoot: Bool          // false until user picks a folder
@Published var indexProgress: Double        // 0.0 → 1.0 during scan
@Published var activeMetadataFilters: [MetadataFilter]
@Published var smartFilters: [SmartFilter]  // persisted per root URL
private(set) var metadataIndex: MetadataIndex?
```

**Smart Filters** persist as JSON in UserDefaults keyed per root URL (`smartFiltersByRoot`). Resolution (running `searchWithMetadata` for each filter) happens after every index scan and after `addSmartFilter`. Results cached in `smartFilterResults: [UUID: [ImageItem]]` and rebuilt into synthetic categories via `rebuildCategories()`.

**Metadata filters** (`activeMetadataFilters`) create a synthetic `__filtered__` category via async `applyMetadataFilters()` → `index.imagePaths(matching:)` → `rebuildCategories()`.

---

## ContentView Structure

- **Sidebar** (`var sidebar`) — `List` with filesystem groups + Smart Filters section at bottom. Disabled during search was removed; category clicks now clear search and navigate.
- **Grid** (`var thumbnailGrid`) — switches on `isSearching` / `selectedCategory` / `hasChosenRoot`. Empty state shown when `!library.hasChosenRoot`. Accepts file drops via `.onDrop`; `isDropTargeted` drives the drop-target overlay.
- **Filter bar** (`var filterBar`) — horizontal scroll of `Menu` dropdowns per `MetadataField`. Toggled via `filterBarToggleButton` in grid controls. Shown above grid when active.
- **Inspector** — right-side panel, toggled via toolbar. When a file is dragged onto the app (`droppedInspectionImage` set), the inspector shows a `temporaryInspectionBanner` with a "Return to Library" action to clear the temporary view.
- **Search** — toolbar `TextField`; `handleSearchTextChange` debounces 180ms into async Task; `clearSearch()` wipes state and allows sidebar clicks to navigate; `saveSearchButton` saves query as Smart Filter.
- **Reveal in Finder** — available via grid thumbnail context menu and inspector toolbar button; calls `NSWorkspace.shared.activateFileViewerSelecting([url])`.

### Smart Filters Sidebar Section

Rendered as `@ViewBuilder var smartFiltersSidebarSection` — a `Section` with a "+" header button. Inline add form (Name + Query text fields). Right-click context menu for Rename / Delete on each filter. Pending-resolution rows show a spinner.

---

## App Modes

`AppMode` enum in AppSettings: `.general` (default) / `.tagExplorerLegacy`. Toggled from Mode menu. Legacy mode uses `TagExplorerLegacyProfile` which parses `gens`-style folder slugs and has a `suggestedInitialRootURL` that auto-detects a `gens` folder.

---

## Known Patterns / Gotchas

- **No welcome sheet** — removed (`WelcomeView.swift` deleted, `isShowingWelcome`/`completeWelcome()` removed from AppSettings). Empty state in main grid guides first-run.
- **ComfyUI complex workflows** — deeply nested or unsupported node graphs gracefully skip metadata extraction rather than dumping a raw JSON blob. `parseComfyUIPrompt()` returns `nil` for unsupported graph shapes.
- **`chooseRootFolder` uses `NSOpenPanel.begin(completionHandler:)`** (non-modal) — never use `runModal()`, it conflicts with SwiftUI's sheet teardown.
- **`KeyHandlingView.activateIfNeeded`** only claims first responder when `window.firstResponder is NSWindow` (nothing focused) — prevents stealing focus mid-click during async re-renders.
- **`createSchema(db:)` is `static`** — called from actor `init` which is non-isolated; passing the db pointer avoids the Swift 6 actor-isolation warning.
- **Smart filter categories always exist** in `categories` (even with empty images array) so the sidebar row appears immediately; the spinner shows until resolution completes.
- **Resetting state for testing:** `rm ~/Library/Preferences/AiGallery.plist ~/Library/Preferences/com.aigallery.app.plist` (swift run vs packaged app write to different files).
- **Resetting the metadata index:** `rm ~/Library/Application\ Support/AiGallery/*.sqlite`

---

## Build

```bash
swift build
# Full app bundle:
./scripts/build-app.sh
```
