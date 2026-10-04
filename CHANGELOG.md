# Changelog

All notable changes to MangaTL. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
