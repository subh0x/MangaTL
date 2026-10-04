"""Baberu OCR decode loop, adapted from genshiai-daichi/baberu-ocr onnx_infer.py (vision split out)."""
from __future__ import annotations

import json
import unicodedata
from pathlib import Path

import numpy as np
from PIL import Image

_MEAN = np.array([0.485, 0.456, 0.406], np.float32)
_STD = np.array([0.229, 0.224, 0.225], np.float32)
_PAST = [f"past_k{i}" for i in range(6)] + [f"past_v{i}" for i in range(6)]


def preprocess(image: Image.Image) -> np.ndarray:
    img = image.convert("RGB").resize((224, 224), Image.BICUBIC)
    return ((np.asarray(img, np.float32) / 255.0 - _MEAN) / _STD).transpose(2, 0, 1)[None]


class Vocab:
    def __init__(self, vocab_json: Path):
        charset = json.loads(Path(vocab_json).read_text(encoding="utf-8"))
        self.id2ch = {i + 4: ch for i, ch in enumerate(charset)}
        self.bos, self.eos = 1, 2
        self.content_ids = {
            i + 4 for i, ch in enumerate(charset)
            if len(ch) == 1 and ch not in "ーｰ〜~" and unicodedata.category(ch)[0] in "LN"
        }

    def decode(self, ids) -> str:
        return "".join(self.id2ch.get(i, "") for i in ids if i >= 4)


def decode(pre, stp, v: Vocab, vis: np.ndarray, max_new_tokens=128, repetition_penalty=1.2, max_content_run=12) -> str:
    out = pre.run(None, {"vision_embeds": vis, "input_ids": np.array([[v.bos]], np.int64)})
    logits, present = out[0][0, -1].astype(np.float64), out[1:]
    seq, toks, pos = [v.bos], [], vis.shape[1] + 1
    for _ in range(max_new_tokens):
        for tid in set(seq):
            s = logits[tid]
            logits[tid] = s * repetition_penalty if s < 0 else s / repetition_penalty
        if toks and toks[-1] in v.content_ids:
            last, run = toks[-1], 0
            for t in reversed(toks):
                if t != last:
                    break
                run += 1
            if run >= max_content_run:
                logits[last] = -np.inf
        nxt = int(np.argmax(logits))
        if nxt == v.eos:
            break
        toks.append(nxt)
        seq.append(nxt)
        feed = {"input_ids": np.array([[nxt]], np.int64), "position_ids": np.array([[pos]], np.int64)}
        feed.update(dict(zip(_PAST, present)))
        out = stp.run(None, feed)
        logits, present = out[0][0, -1].astype(np.float64), out[1:]
        pos += 1
    return v.decode(toks)
