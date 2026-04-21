# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build (debug)
swift build

# Build release app bundle + zip (dist/AiGallery.app, dist/AiGallery.zip)
./buildrun

# Build with custom version
VERSION=1.2.0 ./buildrun

# App bundle only (no zip)
./scripts/build-app.sh
```

There are no automated tests.

## Architecture

AiGallery is a native macOS SwiftUI + AppKit app (macOS 13+, Swift Package Manager, zero external dependencies) for browsing AI-generated images from local folder hierarchies.

**Three-pane layout:** Sidebar (category tree) | Grid (thumbnails) | Inspector (metadata)

### State Management

`LibraryStore` (ObservableObject, injected as `@EnvironmentObject`) is the single source of truth. It owns:
- Discovered categories/images built from a user-selected root folder
- PNG metadata cache (`[String: PNGInfo?]`) and folder metadata cache
- Search index (flattened image list for ranked tag search)
- Favorites (persisted to UserDefaults, keyed by root path)

### Data Flow

1. User picks root folder → `LibraryStore.reload()` → `discoverCategoryFolders()` → `loadImages()` per folder
2. Metadata is loaded on demand: `PNGInfoReader` parses binary PNG chunks; `FolderMetadataReader` reads `aigallery.json` / `metadata.cfg` from the folder
3. Thumbnails load asynchronously via `SafeImageLoader`, throttled to 2 concurrent loads via `ThumbnailLoadGate` (256MB NSCache, 2000-item cap, max 70M pixels / 256MB per file)
4. Search runs `searchTags()` on the flattened index with ranked matching (exact → prefix → contains), diacritic/case insensitive

### Metadata Fallback Chain

Embedded PNG chunks (Automatic1111 → ComfyUI → DrawThings) → folder `aigallery.json` → folder `metadata.cfg`

### Key Files

| File | Role |
|------|------|
| `TagBrowserApp.swift` | `@main` entry, window config, Cmd+O shortcut |
| `LibraryStore.swift` | All state, folder scanning, search, favorites, persistence |
| `ContentView.swift` | NavigationSplitView wiring sidebar + grid + inspector |
| `Models.swift` | `Category`, `ImageItem`, `PNGInfo`, `FolderMetadata`, `TagSearchResult` |
| `PNGInfoReader.swift` | Binary PNG chunk parser for AI metadata formats |
| `FolderMetadataReader.swift` | JSON/CFG folder-level metadata reader |
| `SafeImageLoader.swift` | Async thumbnail loading with caching and throttling |
| `PreviewOverlayController.swift` | Full-screen preview window management |

### Folder → Category Mapping

Subfolders of the root become categories. Names containing ` - ` (space-hyphen-space) are split into group/subcategory (TagExplorer convention). Supported image extensions: `png`, `jpg`, `jpeg`, `webp`.

### Persistence (UserDefaults)

`selectedRootURL`, `selectedCategoryID`, `favoriteImageIDsByRoot`, `showInspector`, `imageSortOrder`, `thumbnailSizeIndex`, `inspectorPanelWidth`
