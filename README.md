# MangaTL

A native macOS app (macOS 26, Apple Silicon) that reads manga in Japanese, Chinese, Korean, Spanish,
French or Portuguese and letters an English translation into each balloon. Everything runs
on this Mac.

## Setup

```sh
uv venv --python 3.12 tools/.venv
uv pip install --python tools/.venv/bin/python huggingface_hub
tools/.venv/bin/python tools/export_models.py   # ~150 MB of models, installed for the app
tools/bundle.sh                                 # builds MangaTL.app
open MangaTL.app
```

Translation uses Apple's on-device language packs. If a pack is missing, the app tells you
to install it in **System Settings › General › Language & Region › Translation Languages**.
The default lettering font is **CC Wild Words**; install it for the intended look.

Developing? See [CONTRIBUTING.md](CONTRIBUTING.md) (tests, sample pages, smoke run, ground rules)
and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Using it

- **Projects.** A project is a folder of page images. The Welcome screen lists recent projects; click one to reopen it exactly where you left off: same page, mode (grid, reader or editor) and page order.
  - **Open Folder…** (⌘O) turns any folder into a project.
  - **Import CBZ / PDF…** extracts an archive into a new project folder.
  - **Close Project** (⇧⌘W) saves and returns to the list.
  - Each project's state lives in a hidden `.mangatl/` folder inside it, so it travels with the folder:
    - `project.json`: settings, page order, last position
    - `pages/`: one file per translated page
    - `layers/`: one PNG per image layer
    - `fonts/`
  - Image files are never renamed or deleted.
- **Pages.**
  - Drag thumbnails to reorder them.
  - Drop image files on the grid, or use **Add Images**, to copy them into the project. Images added to the folder in Finder join the project automatically, in name order.
  - Right-click for Move to Start/End, Translate, Edit, Show in Finder, and Remove from Project (which keeps the file).
- **Translate.**
  - Pick the **source language** in the toolbar.
  - ⌘T translates the current page, also from inside the editor, where your own retouch layers are kept. ⇧⌘T translates every untranslated page.
  - In the reader, ⌥⌘O shows the original pages.
  - **Problems panel** (⇧⌘M, or the counts in the status bar): failed translations, exports and edits, plus pages where no text was found, each with **Retry** and **Go to Page**. It opens by itself when something fails.
- **Edit Page** (⌘E, or double-click a page in the reader). ⌘[ / ⌘] move to the previous/next page, saving as you go, and ⌥⌘I shows or hides the side panel, which also hides itself in narrow windows.
  - **Text boxes:** ⇧/⌘-click or drag a rubber band to select several, and ⌘A selects all. Drag to move them; drag a corner to resize one.
  - **Style:**
    - Font: CC Wild Words by default, any installed family, or **Add…** a TTF/OTF.
    - Size: a number field, or Auto-fit to the balloon.
    - Colours: the colour picker or a **hex code** (`#1E90FF`, `#FFF`).
    - Also outline, alignment and rotation.
  - **Layers:** text boxes plus image layers (the "Text Clean-up" made by translation, and any retouch layers you add). Each layer can be hidden, renamed, reordered, repainted or deleted.
  - **Lasso** (L): draw around text the app missed. It is read, translated into a new text box, and erased from the page, all in one undo step.
  - **Brushes:** **Erase** (E), **Heal** (H), **Clone** (C, ⌥-click to set the source) and **Unpaint** (R). `[` and `]` change the brush size.
  - Every action is its own undo step (⌘Z).
- **Typesetting:**
  - Lettering follows each balloon's shape, in a "diamond" from scanlation practice.
  - Each box has a role: dialogue, thought, shout, whisper, narration or sound effect. Roles share styles set in **Translate › Typesetting Presets…**.
- **Navigating:**
  - The page sidebar in the reader and editor (⌃⌘S) jumps to and reorders pages.
  - Zoom controls in the status bar set the grid's thumbnail size and the reader's Fit Width or Fit Height. ⌘± and trackpad pinch work too.
- **Export** (File › Export…, ⇧⌘E; also *Export Page* in the editor, and *Export Selected* in the grid):
  - **Pages:** all, current or selected, a range, or translated pages only.
  - **Content:** final, clean (text removed, no new text), text layer only (transparent PNG), or original.
  - **Format:** JPEG, PNG or HEIC, at original, working or custom size.
  - **Package:** a folder of images (with a file-name pattern), a CBZ or a PDF.

## How it works

| Stage | Model / API | Peak (measured) |
|---|---|---|
| Find balloons + text | ogkalu RT-DETR-v2 v4-s int8 (ONNX) | +72 MB |
| OCR ja / zh | Baberu OCR int4/int8 (ONNX), Koharu's manga OCR | +109 MB |
| OCR ko / es / fr / pt | Apple Vision | +55 MB |
| Translate | Apple Translation (`translationd`, separate process) | 230–280 MB while active, exits when idle |
| Erase | Flat fill on plain balloons, lattice copy on screentone, AOT-GAN (ONNX) on other artwork, 256² tiles | +7 MB |

Only one model is loaded at a time. ONNX Runtime is used through its C API with the CPU arena off.
The app runs with `MallocSpaceEfficient=1`, so freed model memory goes back to the system.
Peak app footprint: about 165 MB while translating, about 230 MB while healing in the editor,
about 160 MB while scrolling 2500 pages.

Koharu's current RF-DETR layout model was evaluated and rejected: it needed 0.5–2.8 GB of RAM
(see `spike/PHASE0.md`).

Projects opened in older builds (whose work was kept in `~/Library/Application Support/MangaTL/projects/`)
are copied into the folder's `.mangatl/` the first time they're opened. The old copy is left in place.

## Roadmap

- Context-aware chapter polish (glossary, consistency, typo fixes) with swappable models:
  [docs/roadmap/chapter-polish.md](docs/roadmap/chapter-polish.md)

## Licence and credits

MangaTL's code is released under the [MIT licence](LICENSE).

The models are downloaded separately and keep their own terms:

- [ogkalu/comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) (RT-DETR-v2): bubble and text detection
- [genshiai-daichi/baberu-ocr](https://huggingface.co/genshiai-daichi/baberu-ocr): Japanese/Chinese manga OCR
- [ogkalu/aot-inpainting](https://huggingface.co/ogkalu/aot-inpainting): AOT-GAN inpainting, from manga-image-translator

These weights were trained on **Manga109** data, which is licensed for **non-commercial / academic use only**.

Also built on:

- [Koharu](https://github.com/koharu-rs/koharu) (MIT/Apache-2.0): model choices and pipeline design
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
- [ONNX Runtime](https://github.com/microsoft/onnxruntime)

Sample pages used by the tests: [Pepper&Carrot](https://www.peppercarrot.com) by David Revoy, CC-BY 4.0,
downloaded by `tools/fetch_samples.sh`.
