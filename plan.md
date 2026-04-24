# Image Family Tree Plan

## Concept

Image Family Tree is a lineage-discovery feature for AiGallery. When a user selects an image, the app surfaces other images that likely belong to the same creative thread: siblings from the same generation batch, prompt or seed variants, possible upscales, edits, and looser cousins.

The feature should avoid claiming certainty. The language should stay inferential: "likely sibling", "possible variant", "looks like an upscale", or "related by prompt". Each match should show short reasons so the user understands why it appeared.

## User Experience

The first version should live in the inspector as a compact "Family" section for the selected image.

Suggested groups:

- Same Batch
- Variants
- Possible Upscales / Edits
- Related Images

Each related image can appear as a thumbnail with a confidence indicator and reason chips such as:

- same prompt
- similar prompt
- same model
- same seed
- nearby filename
- same folder
- close timestamp
- larger dimensions

A later version can add a dedicated visual graph or overlay.

## Relationship Signals

AiGallery can infer family links from information it already has or can cheaply inspect on demand.

### Filename Similarity

Examples:

- `image_001.png`, `image_002.png`
- `foo.png`, `foo_upscale.png`
- `foo-1.png`, `foo-2.png`
- numeric suffixes
- tool-specific batch naming patterns

### Folder Proximity

Images in the same category or folder are stronger candidates than images elsewhere. Nearby files by creation or modification date may be part of the same generation session.

### Prompt Similarity

Useful relationships:

- exact same prompt
- high tag overlap
- prompt A mostly contained in prompt B
- same negative prompt

### Metadata Similarity

Useful metadata fields:

- model / checkpoint
- sampler
- CFG scale
- steps
- seed
- LoRAs
- dimensions

### Dimension Relationship

Possible signals:

- same aspect ratio at larger dimensions may imply upscale
- same dimensions with small prompt changes may imply variant
- related aspect ratio with changed bounds may imply crop, edit, inpaint, or outpaint

### Time Ordering

Earlier files may be source images. Later files may be variants, edits, or upscales. Close timestamps can imply batch siblings.

## Scoring Sketch

Initial heuristic scoring can be simple and explainable:

```text
+40 same exact prompt
+25 same seed
+20 same model
+15 filename stem match
+15 same folder
+10 close timestamp
+10 dimensions imply upscale
-20 very different aspect ratio
```

Possible confidence bands:

- 90+: very likely same family
- 60-89: likely related
- 35-59: maybe related
- below 35: hidden by default

## Data Model Sketch

Potential model additions:

```swift
struct ImageFamilyMatch: Identifiable {
    let id: String
    let image: ImageItem
    let relationship: ImageRelationship
    let confidence: Double
    let reasons: [ImageFamilyReason]
}

enum ImageRelationship {
    case sibling
    case variant
    case possibleParent
    case possibleChild
    case cousin
}

enum ImageFamilyReason {
    case samePrompt
    case similarPrompt
    case sameSeed
    case sameModel
    case sameFolder
    case filenamePattern
    case closeTimestamp
    case upscaleDimensions
}
```

This keeps the first version computed on demand instead of requiring persistent lineage storage.

## MVP

Scope the first implementation tightly:

- Compute relatives only for the selected image.
- Search within the same folder or category first.
- Rank candidates using filename, prompt, model, seed, dimensions, and timestamp signals.
- Display the top related images in the inspector.
- Group matches into Same Batch, Variants, Possible Upscales / Edits, and Related Images.
- Show reason chips for every match.
- Avoid background indexing or persistent storage.

## Later Enhancements

Possible follow-up features:

- Dedicated "Show Image Family" overlay.
- Visual graph with selected image at the center.
- Prompt diff between selected image and family member.
- Click reason chips to filter the grid.
- Manual parent / child linking.
- Persist user-confirmed relationships.
- Smart sidebar collection for discovered families.
- Folder-level "find all families" clustering.
- Contact-sheet export for a family.

## Open Questions

- Do user folders usually keep raw generations, upscales, and edits together, or split them into separate folders?
- Which filename patterns are most common in real user libraries?
- Should the first UI be inspector-only, or should it include a larger overlay from the beginning?
- Should manual "this came from this" linking be supported later?
