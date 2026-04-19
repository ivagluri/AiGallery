# AiGallery
AiGallery is a lightweight native macOS app for browsing AI-generated images from local folders with pnginfo support.
Initially inspired by tag gallery websites like "tagexplorer.github.io", to have a native macos app for quick browsing of large sample sets of outputs.

## Screenshot

![AiGallery screenshot](screenshot.png)

## What It Does
AiGallery scans a root folder, treats subfolders as categories, and shows the images in a three-pane browser:

- A sidebar with folder-driven categories
- A central grid of image thumbnails
- An inspector with image details and generation metadata from PNG info or folder-level config files

## Why It Exists

I wanted an offline, native alternative to the web-based tag galleries for faster and better handling of large amounts of images.  
- Works offline
- Keeps image libraries private on your machine
- Feels more like a native file browser than a website
- Can use unique or own generated images to easily build out a custom tag/example gallery.
- simpler way to navigate tag hierarchies and see PNGinfo vs just using finder.

## Folder Layout

AiGallery builds it's category browser based on folder heirarchy, with a simple recursive structure.
Each subfolder inside the selected root is treated as a category. Images inside those folders are shown in the browser, and further subfolders are subcategories.

```text
Root Folder/
├─ Category 1/
│  ├─ Subcategory 1/
│  ├─ Subcategory 2/
│  │  └─ Sub-Subcategory 1/
└─ Category 2/
```

The category naming was originally shaped around the folder layout used in the TagExplorer repository, and that scheme for its folders is supported as well, using " - " as the subcategory divider.
The app supports common image types including:

- `png`
- `jpg`
- `jpeg`
- `webp`

## Tags

For custom libraries, each image should generally represent a single tag or concept.
The app uses the filename as the displayed tag label, replacing underscores with spaces.

```text
Artists/
    Illustrious/
        artist1.png
        artist2.png
Poses/
    arms/
        one_arm_up.png
        crossed_arms.png
```


## Folder Metadata Files

For formats that do not carry PNG-style embedded metadata well, such as large `.webp` sample sets, you can drop a simple metadata file into a category folder. AiGallery will use it as a fallback for every image in that folder.

Supported filenames:

- `aigallery.json`
- `aigallery.cfg`
- `metadata.json`
- `metadata.cfg`

Example `aigallery.json`:

```json
{
  "prompt": "portrait of a fantasy mage, detailed robe embroidery, dramatic lighting",
  "negativePrompt": "blurry, low quality, extra fingers",
  "parameters": {
    "Model": "illustrious-xl",
    "Sampler": "DPM++ 2M Karras",
    "Steps": 30,
    "CFG Scale": 6.5
  },
  "details": {
    "Batch": "iteration 04",
    "Source": "Inspiration Gens"
  }
}
```

Example `aigallery.cfg`:

```ini
prompt=portrait of a fantasy mage, detailed robe embroidery, dramatic lighting
negative_prompt=blurry, low quality, extra fingers
Model=illustrious-xl
Sampler=DPM++ 2M Karras
Steps=30
CFG Scale=6.5
Batch=iteration 04
Source=Inspiration Gens
```

Embedded PNG metadata still takes priority, but folder metadata fills in the inspector when an image has no readable PNG info.

## How To Use It

You can use AiGallery in two main ways:

1. Point it at your own folder of AI-generated images, arranged in the folder and filename structure described above.
2. Use the existing `gens` folder from the https://github.com/tagexplorer/tagexplorer.github.io repo, which is how the app was originally developed and tested, and supports that specific folder structure.

When the app launches, it will try to use a local `gens` folder if one exists, and checks for `gens` in the same folder as the app. If no `gens` folder is found, the app starts empty and you can click `Choose Folder…` at any time to select a library.

- The app bundle is unsigned. On most Macs, Gatekeeper will likely not let you open it just by double click.  macOS Sonoma removed the keyboard shortcut to bypass this so you now are forced to approve it in system settings>privacy.  Or the command line xattr method  still works.

## Build

From the project root:

```bash
swift build
```

## Disclaimer
This project was built with the help of AI coding tools, primarily Codex.
I am not a professional developer, so this repository is a vibe coded personal solution, but someone else might find it useful too.
If you decide to use it, expect there may be bugs, rough edges, or missing features.
