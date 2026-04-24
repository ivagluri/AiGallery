# Changelog

## Midstream changes

### 2026-04-23 · 846b139..HEAD

- **Image Family Tree** — select any image and open the Family Tree view from the grid toolbar to see related images grouped as Siblings, Variants, Possible Upscales, and Related. Each match shows reason chips explaining why it appeared. Clicking a thumbnail updates the inspector without leaving the tree; the Back button returns to the library. Navigating via the sidebar dismisses the tree.
- **Seed added to metadata index** — generation seed is now stored in the SQLite index alongside model, prompt, and other fields, enabling reliable same-seed variant detection in Family Tree results. Triggers a one-time background re-index on first launch.
- **Smart filters and search work across unloaded roots** — registered root folders that haven't been expanded yet now contribute to smart filter results and text search from the moment their background index scan completes, without requiring the folder to be loaded first.

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

