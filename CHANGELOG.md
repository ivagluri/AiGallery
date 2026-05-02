# Changelog

## Midstream updates 2/5/2026

- **UI improvements** -- Can now favorite multiple selected items
- **UI imprvements** -- added a convenience "prompt copy" button to infopane.
- **metadata improvements** -- now reads embedded info in jpg files from auto1111/forge/etc outputs.  Also now reads sidecar txt for infotext as well if image has none (image.jpg/image.txt).  


## v2.2.2

- **add hidden folders** -- now able to hide folders or individual images from the gallery and also hides from search results and smart filters.
- **navbar optimization** -- the navigation bar rewritten to use a flat folder structure, so now single "leaf folder" categories load on click compared to old behaviour.
- **crop thumbnail display** -- added a togggle in the gallery view to crop thumbnails to fill the square tile instead of displaying at their native aspect ratio.
- **UI rearranging** -- moved zoom slidder and crop toggle to a separate bar anchored to gallery view bottom.

## v2.2.1

- **Image viewer info overlay** — press `p` while the image viewer is open to cycle through overlay modes: none → filename → basic info → full prompt. Reuses the slideshow overlay component, respects the slideshow position setting, and persists the last-used mode between sessions.
- **A1111 scheduler parsing** — newer A1111 images emit `Schedule type` as a separate parameter (e.g. `Align Your Steps`). The metadata index now captures this correctly; previously the scheduler column was left null for these images.
- **Draw Things upscaler indexing** — the upscaler field was extracted by the inspector but not written to the metadata index, so the Upscaler filter bar dropdown was always empty for Draw Things images. Now indexed from both the JSON blob and the alt-text parameters.
- **Fixed crash on Rebuild Metadata Index** — a data race between `facetValues` reading `metadataIndexes` off the main actor and the background scan writing to it on the main actor caused a crash when the filter bar was active during a rebuild. Fixed by isolating all `metadataIndexes` accesses to the main actor.
- **Folder-scoped metadata filter bar** — the Model / Sampler / Scheduler / VAE / Upscaler dropdowns now show only the values present in the currently selected folder, not across every loaded root. Facet counts update automatically as you navigate the sidebar.
- **In-place metadata filtering** — active metadata filters mask the current view directly rather than navigating to a synthetic "Filtered" category. Switching folders, clearing filters, or changing the selection no longer causes unexpected navigation side-effects.
- **Rebuild Metadata Index** — new button in Settings → Library. Wipes every root's indexed rows and re-parses all images from scratch. Use this when facet counts disagree with the actual file count after a parser improvement or a failed first-index. Distinct from the toolbar Reload (which stays incremental).
- **Preserve search scope when saving smart filters** — the "Search all roots / current root" toggle is now captured in saved smart filters and restored when they run.
- **Slideshow timer fix and settings polish** — corrected an off-by-one in the slide-advance timer and tightened several preferences-window layout details.

## v2.2

- **Slideshow mode** — press ⌘⇧S, use the toolbar play button, right-click a thumbnail, or tap the play button in the image viewer to launch a full-screen slideshow. Respects the current gallery view including search, filters, and smart filters. Space to pause/resume, arrow keys to step manually, Esc to exit.
- **Preferences window** — ⌘, opens a new system-standard preferences window. Slideshow tab covers all playback and display settings; structured for future tabs.
- **Slideshow settings** — configurable slide duration, playback order (in order or random), loop toggle, cross-fade transition, four image fit modes (fit, fill, actual size, stretch), and background colour presets with a custom colour picker.
- **Slideshow text overlay** — optionally show image info during playback: filename only, basic generation info (name · model · steps · cfg), or full positive prompt with a footer line. Five overlay positions.
- **Search scope toggle** — ⌘⌥L limits search results to the currently selected root folder. Toggle off to search across all roots as before.
- **Multi-select** — Cmd+click to toggle individual images, Shift+click or Shift+arrow to extend a range, Cmd+A to select all. Group delete (Backspace or right-click) shows a confirmation sheet with a "don't ask again" option. The inspector always shows the last-clicked image; its delete button still acts on that single image only.
- **Sort works in search** — the sort button now applies to search results, so you can sort a search by name or creation date the same way you would a browsed folder.
- **Info strip usability** — wider click targets and added padding on infobar controls make the strip much more reliable to hit.

## v2.1.1

- **Critical fix: keyboard input dead on launch** — replaced the first-responder claiming mechanism with an AppKit event monitor that intercepts key events before the responder chain. Eliminates a race condition where saved sidebar selection state could permanently block gallery keyboard input until a search was opened and closed.
- **Prompt diff preview polish** — diff mode now keeps image A pinned, slides image B over it in the inspector, restores image A when compare ends, and scrolls the grid back to the active selection.
- **Expanded image sorting** — sort the grid by name or file creation date, with compact toolbar cycling and matching Sort menu controls.

## v2.1

- **Kin view** — select any image and open Kin view to see related images grouped as Same Batch, Variants, Possible Upscales, and Related, with reason chips explaining each match.
- **Kin pivot / history** — pivot from the inspected image to explore kin-of-kin, then step back through pivot history or return to the library.
- **Prompt Diff Viewer** — pin one image as A, select another as B, and compare prompt tags and generation parameters directly in the inspector.
- **Inspector action strip** — Reveal in Finder, Copy Path, Compare, and Trash now live in a compact icon row; Compare highlights while diff mode is active.
- **Search exclusions** — prefix search terms with `-` to exclude filenames or metadata matches, including exclusion-only searches across indexed libraries.
- **Stronger cross-root search and smart filters** — unloaded registered roots now participate in search and smart filter results once their background metadata scan completes.
- **Seed-aware metadata index** — generation seed is indexed alongside model, prompt, sampler, and other fields to improve same-seed variant detection.
- **ComfyUI metadata display cleanup** — long raw metadata fields are now collapsible in the inspector, keeping JSON-heavy images readable.
- **Fixed intermittent dead input on launch** — the initial library scan now runs off the main thread, preventing cold-start activation from getting stuck while the app loads.

## v2.0

- **Multiple root folders** — add as many root folders as you like. Each appears as its own collapsible section in the sidebar. Add via the toolbar `+` button or File → Add Root Folder; remove by right-clicking the section header.
- **Lazy folder loading** — root folders are only scanned when you first expand them, so startup stays fast no matter how many roots are registered.
- **Cross-root search** — metadata indexes for all registered roots are built in the background immediately, so search and smart filters work across every root even before you've expanded them.
- **Uniform folder navigation** — every folder in the tree is now a navigation target, including intermediate folders with no direct images (shows an empty grid). The chevron is the only way to expand or collapse; clicking a folder name always navigates.
- **Removed Legacy Mode** — TagExplorer-style `gens` folder support has been retired. The Mode menu and all associated code have been removed.
- **Trash from keyboard** — with an image selected, press Delete to move it to trash. Also available from the Image menu and the inspector toolbar.
- **Reveal in Finder** — available from the inspector toolbar and the thumbnail right-click menu, selecting the file in Finder without leaving the app.
- **Expanded thumbnail context menu** — right-click any thumbnail to Open, Add/Remove Favorites, Reveal in Finder, Copy Image, Copy File Path, or Move to Trash.
- **Broader ComfyUI prompt reconstruction** — handles linked-node graphs including concatenated string chains and preview-text-assisted workflows; shows a clear message when reconstruction is not possible instead of dropping metadata silently.

## v1.2

- **Pure filesystem browsing** — point it at any folder of images and navigate by subfolder. No special folder structure required.
- **Reads your AI generation data** — model name, sampler, steps, CFG, prompt, and more are pulled directly from your PNG files (supports Automatic1111, ComfyUI, and DrawThings formats).
- **Search your prompts** — type any word and find images that contain it in the prompt, negative prompt, or any generation parameter. Multiple words narrow results to images matching all of them. Wrap a phrase in quotes for an exact match.
- **Metadata filters** — filter the current view by model, sampler, scheduler, VAE, or upscaler using the filter bar above the grid.
- **Smart Filters** — save any search as a persistent folder in the sidebar. A filter named "turkey" always shows your turkey images. Rename or delete from the right-click menu.
- **Click folders to browse** — top-level folders are now selectable, not just collapsible. Clicking a folder shows its images; the arrow expands subfolders.
- **Legacy mode** — optional compatibility mode for TagExplorer-style `gens` folder layouts (Mode menu).
