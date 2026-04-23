# Changelog

## v0.1.9 (final release)

- **Multiple root folders** — register as many root folders as you like from the toolbar or File menu. Each appears as its own collapsible section in the sidebar. Right-click any section header to remove it.
- **Lazy folder loading** — roots are only scanned when first expanded, keeping startup instant regardless of how many are registered.
- **Persistent metadata index** — generation parameters (model, sampler, scheduler, VAE, upscaler, prompt, negative prompt) are now indexed to a local SQLite database per root folder and survive between launches.
- **Search your prompts** — search now queries both filenames and your full generation metadata. Multiple words narrow results to images matching all of them; wrap a phrase in quotes for an exact match.
- **Metadata filter bar** — filter the grid by model, sampler, scheduler, VAE, or upscaler from a dropdown bar above the thumbnails.
- **Smart Filters** — save any search as a persistent folder in the sidebar. A filter named "blue eyes" always shows matching images. Right-click to rename or delete.
- **Move to Trash** — press Delete with an image selected, use the Image menu, right-click a thumbnail, or use the inspector toolbar button.
- **Reveal in Finder** — available from the inspector toolbar and the thumbnail right-click menu.
- **Expanded thumbnail context menu** — right-click any thumbnail for: Open, Add/Remove Favorites, Reveal in Finder, Copy Image, Copy File Path, Move to Trash.
- **Save search as Smart Filter** — a save button appears in the search bar while a search is active.
- **Broader ComfyUI support** — handles linked-node graphs including concatenated string chains and preview-text-assisted workflows; shows a clear message when prompt reconstruction isn't possible rather than dropping metadata silently.
- **Drag-and-drop metadata inspection** — drop any PNG onto the app window to inspect its generation metadata without adding it to your library.

## v0.1.8

- **Fullscreen image viewer** — click any thumbnail or press Space to open a fullscreen overlay with keyboard navigation (arrow keys, Escape to close).
- **Keyboard navigation in grid** — arrow keys move selection through the thumbnail grid; Space opens the viewer.

## v0.1.5 – v0.1.7

- Performance and stability improvements to the image loading pipeline and thumbnail rendering.

## v0.1

- Initial release. TagExplorer-style `gens` folder navigation, PNG metadata inspector, favorites.
