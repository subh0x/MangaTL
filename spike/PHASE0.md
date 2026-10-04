# Phase 0 results (2026-10-04, M3, 8 GB, macOS 26.4)

Test pages: Pepper&Carrot ep06 (CC-BY, David Revoy) in ja/cn/kr/es/fr/pt, 1200×1660.
Python numbers are peak RSS above a ~60 MB interpreter baseline (ORT CPU, arena off).

| Stage | Model | Peak | Speed/page | Verdict |
|---|---|---|---|---|
| Layout | Koharu RF-DETR-Seg-2XL int8 @1152 | **+2790 MB** | 12–134 s (swapping) | ✗ |
| Layout | same @768 / @576 | +1027 / +532 MB | 3 s / 1 s, bubbles lost @576 | ✗ |
| Layout | same fp32 via CoreML EP (ANE) | +2143 MB | 13 s | ✗ |
| Detect | Koharu comic-text-detector @1024 | +943 MB | 2–4 s | ✗ |
| Detect | ogkalu RT-DETR-v2 v4-s int8 @640 (bubble/text_bubble/text_free) | **+175 MB** | 0.2–0.5 s | ✓ quality ≈ RF-DETR on text+bubbles (compare_*.jpg) |
| OCR ja/zh | Baberu vision int4 + decoder int8 (vision freed before decode) | **+143 MB** | ~0.2 s/crop | ✓ hallucinates on non-text crops → filter |
| OCR ko/es/fr/pt (+ja horiz) | Apple Vision accurate | **89 MB whole process** | <1 s | ✓ excellent Latin, good Korean |
| Inpaint | AOT, 512² tiles | +397 MB | ~20 s | ✗ |
| Inpaint | AOT, 256² tiles | **+150 MB** | ~10 s | ✓ |
| Translate | Apple Translation (all 6 packs installed) | app +3 MB; **translationd 55–218 MB RSS, footprint 230–280 MB** | 2 s warm, 10–28 s cold | ⚠ daemon exits ~30 s idle |

Conclusions
- Koharu's current detector cannot meet 250 MB on this hardware at any usable resolution. Use v4-s int8; derive text pixel masks by thresholding inside text boxes.
- Every in-app model stage fits ≤ ~175 MB when run one at a time.
- Apple's translation daemon alone is ~230–280 MB footprint while loaded → violates an "everything combined ≤ 250 MB" reading.
