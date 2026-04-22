# Changelog

## v1.2

- **Pure filesystem browsing** — point it at any folder of images and navigate by subfolder. No special folder structure required.
- **Reads your AI generation data** — model name, sampler, steps, CFG, prompt, and more are pulled directly from your PNG files (supports Automatic1111, ComfyUI, and DrawThings formats).
- **Search your prompts** — type any word and find images that contain it in the prompt, negative prompt, or any generation parameter. Multiple words narrow results to images matching all of them. Wrap a phrase in quotes for an exact match.
- **Metadata filters** — filter the current view by model, sampler, scheduler, VAE, or upscaler using the filter bar above the grid.
- **Smart Filters** — save any search as a persistent folder in the sidebar. A filter named "turkey" always shows your turkey images. Rename or delete from the right-click menu.
- **Click folders to browse** — top-level folders are now selectable, not just collapsible. Clicking a folder shows its images; the arrow expands subfolders.
- **Legacy mode** — optional compatibility mode for TagExplorer-style `gens` folder layouts (Mode menu).

## Midstream Updates

### 2026-04-21 (`be689d2..f1d0392`)

- **Broader ComfyUI prompt reconstruction** — AiGallery now handles more than the simple "prompt is a single text string" case. It can recover prompts from some linked-node ComfyUI graphs, including concatenated string chains and preview-text-assisted workflows.
- **Clearer ComfyUI fallback behavior** — when AiGallery can still parse useful ComfyUI metadata but cannot rebuild a clean prompt string, the inspector now says `Unable to reconstruct prompt from ComfyUI nodes` instead of pretending success or dropping the rest of the metadata.
- **Added local ComfyUI edge-case samples** — the test library now includes a fresh ComfyUI sample plus an intentionally broken variant for checking how prompt reconstruction and fallback messaging behave.
