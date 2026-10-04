# Architecture

MangaTL is a Swift package with two targets plus a small C shim:

- **MangaTLCore**: everything except UI: page sources, imaging, ML stages, the page pipeline, project storage. It has unit tests.
- **MangaTL**: the SwiftUI/AppKit app, a thin layer over Core.
- **COnnxRuntime**: exposes ONNX Runtime's C API (from the `onnxruntime` binary package) to Swift.

## Projects

A project is a folder of images. Everything MangaTL knows about it lives in `<folder>/.mangatl/`:

```
project.json                 ProjectFile: version, settings (language, reading direction, style),
                             pages [{id, file}] in reading order, state {page, mode}
pages/<page id>.json         PageDoc: text blocks + image-layer list + working size
layers/<page id>/<id>.png    one PNG per image layer, cropped to the layer's rect
fonts/                       fonts imported by the user
```

- **Page ids** are UUIDs, so reordering or adding pages never detaches a page's work.
- **On open**, `ProjectFile.reconcile` appends new image files and drops entries whose file is gone.
- **Image files** are never renamed or deleted.
- **Older builds** kept work in `~/Library/Application Support/MangaTL/projects/<hash>`, keyed by page index. `ProjectStore.importLegacy` copies it in on first open.

`ProjectSource` (Core) reads the folder in project order and keeps `project.json`. `ProjectSession` (App) wraps it for the UI: page list, translation queue, export and state.

## Page pipeline

`PagePipeline.process` runs on one page at a time (it's an actor):

1. **Decode** the page at most 2400 px on the long side (`PageDecoder`, ImageIO downsampling).
2. **Detect** with ogkalu RT-DETR-v2 v4-s int8 at 640² (`TextDetector`). It finds bubbles, text in bubbles and free text. `PageLayout` removes duplicate boxes, pairs text with its bubble and sorts by reading order.
3. **OCR:**
   - Japanese and Chinese: Baberu (`MangaOCR`). The vision tower embeds every crop and is released before the int8 decoder loads.
   - Other languages: Apple Vision (`SystemOCR`).
4. **Translate** with the Apple Translation framework (`Translator`): one session per language, released after 60 s idle so `translationd` can exit.
5. **Erase** (`Inpainter`):
   - flat balloons are filled with the balloon's own colour
   - text over artwork is rebuilt with AOT-GAN in 256² tiles
   - the result becomes the page's "Text Clean-up" image layer
6. **Save** the `PageDoc`. Text stays live; `PageRenderer` composites page + visible layers + typeset text for display and export.

Translating a page again replaces its text and clean-up layer but keeps the user's own layers.

## Rendering and typesetting

- **`Typesetter`** fits text into each balloon's usable box with Core Text. It binary-searches the font size, never breaks inside a word, and caches layouts.
- **`PageRenderer`** draws layers and text in a bottom-left context. The reader, editor and exporter all use it, so what you see is what you export.

## Memory decisions (see `spike/PHASE0.md`)

| Decision | Why |
|---|---|
| One ONNX session at a time (`OnnxModel.withSession`) | Each model stage fits in about 70–110 MB on its own |
| ONNX Runtime **C API** with the CPU arena and memory patterns **off** | The Objective-C wrapper can't disable the arena; Baberu used +470 MB with it, +93 MB without |
| `MallocSpaceEfficient=1`, set at launch (`LSEnvironment` + re-exec) | Without it, macOS malloc keeps freed model buffers resident: ~165 MB stayed after detection |
| Reader pages shown as **IOSurfaces** | With a CGImage as layer contents, Core Animation kept a converted copy of every page and re-rendered on the main thread (~400 MB) |
| `ReaderLayout` uses a prefix sum of page heights | `NSCollectionViewFlowLayout` re-queried every item when one page's height changed |
| Thumbnails: 320 px HEIC on disk + 40 MB `NSCache`, keyed per file | One decode per page ever; reordering reuses thumbnails |
| Editor layers kept cropped; only the active layer is full-page; undo snapshots 64² tiles | Extra layers and strokes cost memory only for the area they touch |

Measured (M3, 8 GB): 2500-page grid at 0 hitches and ~100 MB; reader at 2–5 ms/s hitches and ~145 MB; translating a page at ~90–165 MB peak.

## Rejected and deferred

- **Koharu RF-DETR-Seg-2XL** (layout segmentation) needed 0.5–2.8 GB at every resolution and runtime tried.
- **comic-text-detector** needed ~940 MB.
- **LaMa** and LLM translation don't fit the memory budget on 8 GB Macs.
- **Context-aware chapter polish** (glossary, summary, refinement with Apple's on-device model or a user-supplied provider): see [roadmap/chapter-polish.md](roadmap/chapter-polish.md).
