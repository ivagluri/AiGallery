# Changelog

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
