# Changelog

All notable changes to MangaTL. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Typesetting from scanlation practice** (AnonBlack's Typesetting Guide and related guides):
  - **Diamond line breaking:** balloon text is broken into lines that follow the balloon's curve, short at the top and bottom and widest in the middle, chosen by a dynamic program instead of plain word-wrap. Captions get evenly balanced lines.
  - **Hyphenation** only as a last resort: words of 6+ letters, split once near the middle at a dictionary hyphenation point.
  - **Balloon roles:** dialogue, thought, shout, whisper, narration, sound effect. Guessed during translation and changeable in the inspector.
  - **Typesetting Presets** (Translate › Typesetting Presets…): a style per role with a live preview. Defaults: italic thoughts, bold-italic shouts at 130% height, whispers at 85%, and an outline on narration and sound effects.
  - **New style options:** bold and italic faces, width and height scale, space inside the balloon, auto-fit scale.
  - **Typeset Check:** warns about text that doesn't fit, size outliers on a page, a lone short word on the last line, mixed fixed sizes within a role, and text touching the edge. One-click fixes are offered where possible. It appears in the editor's inspector and project-wide (⇧⌘K).

### Changed
- The outline is drawn outside the glyphs. New projects letter dialogue without an outline by default.

## [0.1.0] - 2026-10-04

First version: a native macOS app that translates manga pages on-device.

### Added
- **Projects:** a folder of page images is a project. Its state lives in a hidden `.mangatl/` folder in that folder:
  - `project.json`: settings, page order, last position
  - per-page translations and image layers
  - imported fonts
- **Welcome screen and recents:** a Welcome screen with recent projects, Open Folder, Import CBZ/PDF (extracted into a new project folder) and Close Project. Reopening a project restores its page and mode.
- **Page management:** drag thumbnails to reorder, Add Images (copied into the folder), Remove from Project (keeps files), and drop images onto the grid.
- **Thumbnail grid and continuous reader:** smooth over 2500+ pages, at about 100–150 MB.
- **Translation pipeline, on-device:**
  - detection with the RT-DETR-v2 bubble/text detector
  - OCR with Baberu (Japanese, Chinese) and Apple Vision (Korean, Spanish, French, Portuguese)
  - translation with the Apple Translation framework
  - text removal by flat fill or AOT-GAN inpainting
  - Core Text typesetting fitted to each balloon
- **Editor:**
  - text boxes: multi-select (⇧/⌘-click, rubber band, ⌘A), move and resize
  - per-box style: font (CC Wild Words by default, or any installed or imported font), size with auto-fit, colour and outline (with hex input), alignment, line height, rotation, uppercase
  - image layers: add, delete, hide, rename, reorder; saved per page
  - brushes: Erase, Heal (AOT), Clone, Unpaint
  - undo/redo, previous/next page, translating the current page from inside the editor (keeps your layers)
- **Export:** CBZ or a folder of images, in project order.
- **One window toolbar** for every mode, a status bar (progress, page, memory), a collapsible inspector, and layouts that adapt to narrow windows.

### Notes
- Peak memory: about 100–165 MB while scrolling or translating, and up to about 240 MB while healing in the editor. Apple's translation daemon adds 230–280 MB while it runs.
- Koharu's RF-DETR layout model was evaluated and rejected: 0.5–2.8 GB RAM. See `spike/PHASE0.md`.
