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

- **Page sidebar** in the reader and editor: numbered thumbnails with ✓ on translated pages. Click to jump; drag to reorder. Toggle with ⌃⌘S; it collapses on its own in narrow windows.
- **Zoom:**
  - Grid thumbnail size (90–360 pt) and reader page width (Fit Width, Fit Height, or a set width) from the status bar, ⌘± / ⌘0, or a trackpad pinch.
  - The editor toolbar gains Fit Width and Fit Height.
  - Reader zoom is remembered per project.
  - Large grid sizes use sharper 640 px thumbnails.
- **Tooltips:** compact dark tooltips that appear after about 0.3 s (instead of about 1 s) and show the keyboard shortcut.
- **Export options** (File › Export…, ⇧⌘E; Export Page in the editor; Export Selected in the grid):
  - **Pages:** all, current or selected, a range, or translated only.
  - **Content:** final, clean, text layer only (transparent) or original.
  - **Format:** JPEG, PNG or HEIC with a quality setting, at original, working or custom size.
  - **Package:** a folder with a name pattern, a CBZ or a PDF.
  - The last choices are remembered per project.
- **Thumbnails show your work:** in the page sidebar and the grid, translated or edited pages show their English lettering and visible retouch layers. Thumbnails update as soon as a page is saved, translated or restyled.
- **Arrow keys move between pages:** in the editor, ← → (and ↑ ↓) go to the previous or next page and save as you go. In the reader, ← → jump a page while ↑ ↓ still scroll. Arrows stay in a text field while you type.
- **Auto source language:** choose Auto in the language menu to identify each page's language from the script and words of most of its text when it is translated, then read and translate it in that language. The menu shows just "Auto" until the page you're on has been translated, then names the language found for that page (for example "Auto · Japanese"). The language is saved with the page, and the editor uses it.
- **Delete pages from the sidebar:** ⌘/⇧-click to select several pages, then press Delete or use the right-click menu. The image files stay in the folder.
- **Lasso tool** (L) in the editor: draw around text the detector missed to read, translate and erase it in one undoable step.
- **Problems panel** (⇧⌘M): a collapsible bottom panel listing failed translations, exports and edits, and pages with no text found, each with Retry and Go to Page. It opens on new errors, and the status bar shows the counts.
- **Folder watching:** images added to or removed from a project folder outside the app update the project within a second, in name order.
- **Screentone-aware erasing:** text over dot tones, including gradient and duotone tones, is rebuilt along the tone's own dot lattice instead of being smeared into a grey blob. This applies to the automatic clean-up, the Heal brush and the Lasso.
- **Editor brush colour:** in the toolbar it is now a small swatch that opens a popover with the colour picker, hex field and recent colours.

### Fixed
- PDF pages smaller than the requested size were drawn unscaled in the corner of a white page. This affected Import PDF. PDF pages now scale to the requested size, at up to 300 dpi.
- The reader refreshes a page as soon as its translation finishes. Previously only the most recently created page view was notified.
- Hovering a control could lose its tooltip when another view disappeared.
- Translated ✓ marks in the page sidebar appear as soon as a page is translated or saved.
- The Layers panel's − button deleted the selected image layer even when a text box was selected. It now deletes what is selected. Every text and image row also has its own red delete button and a Delete item in its right-click menu.
- Pages removed from a project came back on the next folder rescan or reopen. Removed files are now remembered, and Add Images brings them back.
- Adding an image that is already in the project folder no longer makes a renamed copy of it.
- The brush-size control in the toolbar had no left padding.
- **Keyboard shortcuts:**
  - ⌘T, ⇧⌘T and ⌘. lived in the toolbar's Translate menu and ⌘0 in the editor's Fit menu, so they only worked after that menu had been opened.
  - ⇧⌘E (Export) and ⌘E (Edit Page) could trigger each other.
  - ⌘Z and ⇧⌘Z in the editor did nothing.
  - These shortcuts are now matched exactly by the app and listed in the menu bar (Translate menu, View › Zoom to Fit, Page › Edit Page). Undo and redo go to the editor, except while typing in a text field.
- Closing the editor showed page 1 although the page number said otherwise. The reader is now scrolled to the edited page once it has its size.

### Changed
- The outline is drawn outside the glyphs. New projects letter dialogue without an outline by default.
- **Page sidebar redesign:** full-width page thumbnails as in Preview, with the current page ringed and its number in an accent capsule, and a ✓ badge on translated pages. Off-screen thumbnails are released, and the list follows the reader once scrolling settles.
- **One colour control everywhere:** a swatch-and-hex button that opens preset and recent swatches, a hex field and the system colour panel. It replaces the stretched colour well and the truncated hex field in the inspector, the presets and the toolbar.
- **Finder-style window:** the page sidebar is a system sidebar column, as in Finder, with the traffic lights inside it, the title to its right, and one system toggle (View › Show Sidebar, ⌃⌘S). It is available in every project view. Toolbar buttons are standard height, and the editor's Fit Page button holds Fit Width and Fit Height in its menu.
- **Tooltips:** each editor tool has its own tooltip, and long tooltips wrap onto two lines at the right height.

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
