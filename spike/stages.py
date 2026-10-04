"""Phase 0 memory spike: run one pipeline stage per process and report peak RSS above baseline.

    python stages.py layout <model.onnx> <pages...>     -> writes <page>.layout.json
    python stages.py ocr <pages...>                      (needs layout json)
    python stages.py aot <pages...>                      (needs layout json)
"""
from __future__ import annotations

import json
import sys
import threading
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import psutil
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
THRESH = {0: 0.25, 1: 0.20, 2: 0.50, 3: 0.50}
CLASSES = ["text", "onomatopoeia", "bubble", "panel"]


class Peak:
    """Samples RSS every 2 ms; reports MB above the baseline taken at construction."""

    def __init__(self):
        self.proc = psutil.Process()
        self.base = self.proc.memory_info().rss
        self.peak = self.base
        self._run = True
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while self._run:
            self.peak = max(self.peak, self.proc.memory_info().rss)
            time.sleep(0.002)

    def mb(self) -> tuple[float, float]:
        self.peak = max(self.peak, self.proc.memory_info().rss)
        return (self.peak - self.base) / 2**20, self.peak / 2**20


def session(path: Path) -> ort.InferenceSession:
    so = ort.SessionOptions()
    so.enable_cpu_mem_arena = False
    so.enable_mem_pattern = False
    so.intra_op_num_threads = 4
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    return ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])


def layout(model: Path, pages: list[Path]) -> None:
    peak = Peak()
    sess = session(model)
    mean, std = np.array([0.485, 0.456, 0.406], np.float32), np.array([0.229, 0.224, 0.225], np.float32)
    for page in pages:
        img = Image.open(page).convert("RGB")
        w, h = img.size
        x = (np.asarray(img.resize((sess.get_inputs()[0].shape[3],) * 2, Image.BILINEAR), np.float32) / 255 - mean) / std
        t = time.time()
        dets, logits, masks = sess.run(None, {"input": x.transpose(2, 0, 1)[None]})
        dt = time.time() - t
        prob = 1 / (1 + np.exp(-logits[0, :, :4]))
        out = []
        for q, c in zip(*np.nonzero(prob >= np.array([THRESH[i] for i in range(4)]))):
            cx, cy, bw, bh = dets[0, q]
            m = masks[0, q] > 0
            out.append({
                "cls": CLASSES[c], "score": float(prob[q, c]),
                "box": [float((cx - bw / 2) * w), float((cy - bh / 2) * h), float((cx + bw / 2) * w), float((cy + bh / 2) * h)],
                "mask_px": int(m.sum()),
            })
        del dets, logits, masks
        page.with_suffix(".layout.json").write_text(json.dumps(out))
        counts = {k: sum(o["cls"] == k for o in out) for k in CLASSES}
        print(f"{page.name}: {dt:.2f}s {counts}")
    d, total = peak.mb()
    print(f"LAYOUT {model.name}: peak +{d:.0f} MB above baseline (process {total:.0f} MB)")


def ocr(pages: list[Path]) -> None:
    sys.path.insert(0, str(Path(__file__).parent))
    from baberu import Vocab, preprocess, decode  # noqa: E402

    d = MODELS / "ocr" / "baberu"
    vocab = Vocab(d / "vocab.json")
    peak = Peak()
    # Stage A: vision tower only, collect embeddings for every crop, then free it.
    vis = session(d / "vision_int4.onnx")
    jobs = []
    for page in pages:
        img = Image.open(page).convert("RGB")
        for o in json.loads(page.with_suffix(".layout.json").read_text()):
            if o["cls"] in ("text", "onomatopoeia"):
                crop = img.crop(tuple(int(v) for v in o["box"]))
                jobs.append((page.name, vis.run(["vision_embeds"], {"pixel_values": preprocess(crop)})[0]))
    del vis
    a, _ = peak.mb()
    # Stage B: decoder graphs.
    pre, stp = session(d / "decoder_prefill_int8.onnx"), session(d / "decoder_step_int8.onnx")
    t = time.time()
    for name, emb in jobs:
        print(f"{name}: {decode(pre, stp, vocab, emb)}")
    print(f"decode {len(jobs)} crops in {time.time() - t:.1f}s")
    d_, total = peak.mb()
    print(f"OCR baberu: vision stage +{a:.0f} MB, peak +{d_:.0f} MB above baseline (process {total:.0f} MB)")


def aot(pages: list[Path]) -> None:
    peak = Peak()
    sess = session(MODELS / "inpaint" / "aot.onnx")
    for page in pages:
        img = np.asarray(Image.open(page).convert("RGB"), np.float32)
        mask = np.zeros(img.shape[:2], np.float32)
        for o in json.loads(page.with_suffix(".layout.json").read_text()):
            if o["cls"] == "text":
                x0, y0, x1, y1 = (int(v) for v in o["box"])
                mask[y0:y1, x0:x1] = 1
        ys, xs = np.nonzero(mask)
        if not len(ys):
            continue
        out = img.copy()
        t = time.time()
        for ty in range(0, img.shape[0], 512):
            for tx in range(0, img.shape[1], 512):
                m = mask[ty:ty + 512, tx:tx + 512]
                if not m.any():
                    continue
                tile = img[ty:ty + 512, tx:tx + 512]
                th, tw = m.shape
                ph, pw = (8 - th % 8) % 8, (8 - tw % 8) % 8
                ti = np.pad(tile / 127.5 - 1, ((0, ph), (0, pw), (0, 0)), mode="edge")
                tm = np.pad(m, ((0, ph), (0, pw)))
                ti = ti * (1 - tm[..., None])
                res = sess.run(None, {"image": ti.transpose(2, 0, 1)[None].astype(np.float32), "mask": tm[None, None]})[0]
                res = (res[0].transpose(1, 2, 0)[:th, :tw] + 1) * 127.5
                out[ty:ty + th, tx:tx + tw] = np.where(m[..., None] > 0, res, tile)
        Image.fromarray(out.clip(0, 255).astype(np.uint8)).save(page.with_suffix(".clean.png"))
        print(f"{page.name}: inpaint {time.time() - t:.2f}s")
    d, total = peak.mb()
    print(f"AOT: peak +{d:.0f} MB above baseline (process {total:.0f} MB)")


if __name__ == "__main__":
    stage, args = sys.argv[1], sys.argv[2:]
    if stage == "layout":
        layout(Path(args[0]), [Path(p) for p in args[1:]])
    elif stage == "ocr":
        ocr([Path(p) for p in args])
    elif stage == "aot":
        aot([Path(p) for p in args])
