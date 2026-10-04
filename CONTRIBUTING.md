# Contributing to MangaTL

Thanks for helping. This guide gets you from a fresh clone to a running app and a green test suite. It also covers the rules that keep MangaTL fast and small.

## Prerequisites

- Apple Silicon Mac with **macOS 26** or later
- **Xcode 26** (Swift 6.2+). Command Line Tools alone are enough to build and test.
- [`uv`](https://docs.astral.sh/uv/), only to download the models
- Translation language packs: **System Settings › General › Language & Region › Translation Languages**. Install the ones you work with (ja, zh, ko, es, fr, pt → en).
- Optional: the **CC Wild Words** font (the default lettering font). Without it, the system font is used.

## Setup

```sh
git clone <repo> MangaTL && cd MangaTL

# 1. Models (~150 MB; installed into ~/Library/Application Support/MangaTL/models)
uv venv --python 3.12 tools/.venv
uv pip install --python tools/.venv/bin/python huggingface_hub
tools/.venv/bin/python tools/export_models.py

# 2. Sample pages for the tests and smoke run (Pepper&Carrot, CC-BY)
tools/fetch_samples.sh
```

`tools/export_models.py --with-layout` also exports Koharu's RF-DETR model, for comparison only. That needs the extra packages listed in the script (`rfdetr`, `onnxruntime`) and several GB of RAM.

## Build and run

```sh
tools/bundle.sh            # release build → MangaTL.app
tools/bundle.sh debug      # debug build
open MangaTL.app
```

The package also opens in Xcode (`open Package.swift`). Run the `MangaTL` scheme.

## Tests

```sh
tools/test.sh                        # everything
tools/test.sh --filter ProjectTests  # one suite
```

- `tools/test.sh` runs `swift test` with `MallocSpaceEfficient=1` and serially, because the memory assertions measure one stage at a time. The app sets the same allocator flag at launch (see `docs/ARCHITECTURE.md`).
- **Model tests** (`PipelineTests`, `StageMemoryTests`) are skipped when the models or sample pages are missing. Run the setup above to enable them.

### Smoke run and benchmark (debug or `-DBENCH` builds only)

```sh
SWIFT_FLAGS="-Xswiftc -DBENCH" tools/bundle.sh release

# Whole workflow on a temp copy: open, add/reorder, translate, editor, close, reopen.
MANGATL_SMOKE="$PWD/spike/smoke" ./MangaTL.app/Contents/MacOS/MangaTL | grep SMOKE

# Scroll benchmark: hitch time and peak memory.
# Make a large book first, e.g. 2500 hard links to the sample pages.
MANGATL_BENCH=/path/to/book ./MangaTL.app/Contents/MacOS/MangaTL | grep BENCH
```

The smoke run writes window snapshots to `$TMPDIR/mangatl_*.png`.

## Ground rules

- **Memory budget.** The app process stays at or below **250 MB** at peak; Apple's translation daemon is extra. Concretely:
  - Load **one ML model at a time** (`OnnxModel.withSession`) and release it before the next stage.
  - Never hold full-resolution images you don't display. Decode with `PageDecoder` at the size you need.
  - When you add a stage, add it to `StageMemoryTests`.
- **Scrolling stays smooth.** Re-run the benchmark when you touch `PageCollectionView`, `ReaderLayout`, `ThumbnailCache` or decoding. Target: 0 hitches in the grid, under 10 ms/s in the reader.
- **Code style:**
  - Match the surrounding code (naming, comment density, file layout).
  - Swift 6 strict concurrency: no new warnings.
  - Comments explain *why*, not *what*.
- **No user data in git.** Models, sample images and `.mangatl/` folders are ignored. Keep it that way.
- **Fonts and models.** Don't commit fonts. Model weights have their own licences; see the README.

## Commits and pull requests

- Small, focused commits with an imperative subject line (≤ 72 chars), e.g. `Add diamond line breaking to Typesetter`.
- Explain the reason in the body when it isn't obvious.
- Before opening a PR, check that:
  - `tools/test.sh` passes
  - the app builds with `tools/bundle.sh`
  - if UI or performance changed: the smoke run passes and the snapshots look right
- Update `CHANGELOG.md` under **Unreleased**.

## Releases

1. Move the **Unreleased** entries into a new version section in `CHANGELOG.md` (Semantic Versioning).
2. Commit `Release vX.Y.Z`.
3. Tag it: `git tag -a vX.Y.Z -m "MangaTL vX.Y.Z"`.

## Where things live

| Path | What |
|---|---|
| `Sources/MangaTLCore/Sources` | Page sources (folder project, CBZ, PDF) |
| `Sources/MangaTLCore/Imaging` | Decoding, thumbnails, pixel buffers, memory footprint |
| `Sources/MangaTLCore/ML` | ONNX wrapper, detector, OCR, inpainting |
| `Sources/MangaTLCore/Pipeline` | Page pipeline, translator, typesetter, renderer, exporter |
| `Sources/MangaTLCore/Model` | Project file, page docs, layers, store |
| `Sources/MangaTL` | The app: window, grid/reader, editor, welcome, chrome |
| `Tests/MangaTLCoreTests` | Unit, project, export, pipeline and memory tests |
| `tools/` | Model export, sample download, bundling, test runner |
| `spike/` | Phase 0 measurements and scripts (`PHASE0.md`) |
| `docs/` | Architecture and roadmap |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.
