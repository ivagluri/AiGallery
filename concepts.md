# AiGallery Feature Concepts

These are exploratory "far out" feature ideas for AiGallery. The common theme is to make the app feel like it understands the strange little universe inside a user's generated-image folders, instead of behaving like a generic photo browser.

## Prompt Constellation Map

A spatial view where images become stars clustered by shared prompt tags, models, styles, artists, LoRAs, aspect ratios, seeds, or folder metadata. The user can zoom around a galaxy of their own generation habits.

Distilled version: a 2D tag map where selecting a tag pulls related images into clusters. This could start with tag co-occurrence and avoid ML.

## Image Family Trees

AI images often come in batches, evolutions, seed variations, upscales, inpaints, and prompt tweaks. The app could detect nearby filenames, seeds, dimensions, and metadata similarity, then show images as likely lineages.

Distilled version: for a selected image, show possible siblings based on same folder, similar prompt, same seed or model, and nearby dates.

## Prompt Archaeology Mode

A cinematic inspector mode that reconstructs how an image was made: prompt, negative prompt, model, sampler, CFG, steps, seed, LoRAs, then highlights which parts are shared with other images.

Distilled version: show how many other images share key traits, such as tags, model, sampler, CFG range, or LoRAs, with clickable links.

## Moodboard Alchemy

Select a handful of images and the app extracts a "vibe recipe": common tags, colors, aspect ratios, model names, metadata patterns, and dominant folder themes. It could produce a reusable prompt snippet or collection summary.

Distilled version: create a moodboard summary from selected images, including common prompt tags, common negative tags, favorite models, average dimensions, and dominant colors.

## Timeline Of Obsessions

Instead of a file-date timeline, show waves of aesthetic interest: "cyberpunk week", "porcelain dolls phase", "wide cinematic landscapes", or "blue-gold lighting era".

Distilled version: group images by month or week and surface top tags, models, and colors per period.

## The Remix Lens

When viewing an image, show its metadata ingredients as interactive controls: model, seed, sampler, CFG, steps, LoRAs, dimensions, and tags. Clicking one ingredient instantly filters the grid to "more like this because of X".

Distilled version: inspector chips for metadata values with one-click filtering or search.

## Serendipity Engine

A "surprise me intelligently" button that does not pick random images, but navigates between distant-yet-related images: same color mood but different subject, same model but different tags, same seed family, or same folder metadata but different year.

Distilled version: random image selection weighted by weak relationships. Modes could include "jump to a cousin", "jump to an opposite", or "jump to a forgotten favorite".

## Contact Sheet Storyboards

Generate polished contact sheets from a category or selection: cinematic rows, metadata captions, prompt snippets, folder title, and color palette strips.

Distilled version: export selected images as a local contact sheet PNG with filename, prompt, and model captions.

## Prompt Diff Viewer

Select two images and compare their generation metadata like source code: added tags, removed tags, changed sampler, seed, CFG, model, and dimensions.

Distilled version: "Compare With Selected" in the inspector, showing prompt, negative prompt, and metadata diffs.

## Dream Deck Mode

Turn a folder or category into a full-screen ambient slideshow where transitions are influenced by metadata relationships. Similar tags fade smoothly, sharp prompt changes cut harder, and favorites linger longer.

Distilled version: full-screen slideshow with optional related-next ordering and a subtle metadata overlay.

## Color Portal Browser

Extract palettes from thumbnails and let users browse by color atmosphere: for example, show all images with a teal-shadow and gold-highlight combination.

Distilled version: show a palette strip per image or category, then support clicking a color swatch to find visually similar dominant colors.

## Cabinet Of Curiosities

A special view for anomalies: huge images, rare samplers, one-off models, odd aspect ratios, prompts with tags used only once, files with broken or missing metadata, ancient images, and forgotten favorites.

Distilled version: a "Curiosities" smart collection powered by local rules.

## Strongest Prototype Candidates

- Image Family Trees
- Prompt Diff Viewer
- Prompt Constellation Map
- Timeline Of Obsessions
- Contact Sheet Storyboards

Image Family Trees and Prompt Diff Viewer are likely the strongest first prototypes because they fit AiGallery's identity, reuse metadata already parsed by the app, and make the app feel purpose-built for AI image archaeology.
