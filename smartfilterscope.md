# Smart Filter Scope — Future Feature Notes

## Problem

When the search scope toggle is active (limiting to the current subfolder) and you save that search as a Smart Filter, the filter saves only the query string — the folder scope is silently dropped. The resulting Smart Filter resolves globally across all roots, which feels inconsistent with what the user scoped and saved.

## Entry Points

### 1. `SmartFilter` struct — `Sources/Models.swift:84`
Currently: `id: UUID`, `name: String`, `query: String` only.
Add: `scopeFolderURL: URL?` — stored as a path string for `Codable` compatibility.

```swift
struct SmartFilter: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var query: String
    var scopeFolderPath: String?  // nil = global; path string for Codable

    var scopeFolderURL: URL? {
        get { scopeFolderPath.map { URL(fileURLWithPath: $0) } }
        set { scopeFolderPath = newValue?.path }
    }
}
```

### 2. `resolveSmartFilters()` — `Sources/LibraryStore.swift:805`
Currently calls `searchWithMetadata(matching:limit:)` with no folder arg.
Change: pass `filter.scopeFolderURL` through to `limitToFolder:`.

```swift
let result = await searchWithMetadata(
    matching: filter.query,
    limit: smartFilterResultLimit,
    limitToFolder: filter.scopeFolderURL   // nil for global filters
)
```

### 3. Save action — `Sources/ContentView.swift` (saveSearchButton)
Currently calls `library.addSmartFilter(name:query:)`.
Change: pass the current scope folder when saving.

```swift
library.addSmartFilter(
    name: name,
    query: trimmedActiveSearchText,
    scopeFolderURL: searchScopeCurrentRootOnly ? activeScopeFolderURL : nil
)
```

`addSmartFilter` signature in `LibraryStore.swift:753` gains the same optional parameter.

## Migration / Persistence

`SmartFilter` is `Codable` and persisted in UserDefaults (global key `globalSmartFilters`). Adding `scopeFolderPath: String?` is safe if decoded with a default of `nil` — all existing filters remain global automatically. No explicit migration needed beyond the standard `Codable` optional-defaults-to-nil behavior.

## Edge Cases to Handle

- **Folder renamed or deleted after save**: `resolveSmartFilters()` would get an empty `effectiveSearchIndex` and return zero results silently. Options: surface a warning label in the sidebar row, or fall back to global search and show a badge indicating the scope is stale.
- **Sidebar label**: Consider appending the folder name to the Smart Filter display name when `scopeFolderURL` is set (e.g. "fluffy [dog images]"), so the scoped intent is visible without opening an edit form.
- **Inline add form**: The add form in the sidebar currently has Name + Query fields. If scope is active when the user clicks "+", the form could pre-populate the scope and show a small disclosure (e.g. "Scoped to: dog images ×") that can be cleared before saving.

## Files to Touch

| File | Change |
|---|---|
| `Sources/Models.swift` | Add `scopeFolderPath: String?` + computed `scopeFolderURL` to `SmartFilter` |
| `Sources/LibraryStore.swift` | `addSmartFilter(name:query:scopeFolderURL:)`, pass through in `resolveSmartFilters()` |
| `Sources/ContentView.swift` | Pass `activeScopeFolderURL` from save button; optionally show scope in sidebar label and add form |
