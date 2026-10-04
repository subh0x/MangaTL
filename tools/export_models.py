"""Fetch the manga models MangaTL runs (detector, Baberu OCR, AOT inpainting) and install them.

    tools/.venv/bin/python tools/export_models.py [--out models] [--with-layout] [--no-install]

Output layout (what the app's ModelStore expects), ~160 MB:
    detect/detector-v4-s_int8.onnx         ogkalu RT-DETR-v2 bubble/text detector
    ocr/baberu/{vision_int4,decoder_prefill_int8,decoder_step_int8}.onnx + vocab.json
    inpaint/aot.onnx
Optional (--with-layout): layout/rfdetr_seg_2xl_1152*.onnx, Koharu's RF-DETR, kept for comparison only.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import shutil
from pathlib import Path

from huggingface_hub import hf_hub_download

LAYOUT_REPO = "mayocream/koharu-layout-rfdetr-seg-2xl-1152"
LAYOUT_SHA256 = "9bf6d2cbd7793c956d8c857bb1672a396eb7f100eb0682f86830d05e31168efb"
BABERU_REPO = "genshiai-daichi/baberu-ocr"
BABERU_FILES = ["onnx/vision_int4.onnx", "onnx/decoder_prefill_int8.onnx", "onnx/decoder_step_int8.onnx", "tokenizer/vocab.json"]
AOT_REPO = "ogkalu/aot-inpainting"
DETECTOR_REPO = "ogkalu/comic-text-and-bubble-detector"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def export_layout(out: Path) -> None:
    dst = out / "layout" / "rfdetr_seg_2xl_1152.onnx"
    dst_q = dst.with_name("rfdetr_seg_2xl_1152_int8.onnx")
    if dst_q.exists():
        print("layout: up to date")
        return
    weights = Path(hf_hub_download(LAYOUT_REPO, "model.safetensors"))
    if sha256(weights) != LAYOUT_SHA256:
        raise SystemExit(f"layout weights checksum mismatch: {weights}")
    spec = importlib.util.spec_from_file_location("koharu_layout_loader", hf_hub_download(LAYOUT_REPO, "load_model.py"))
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    model = loader.load_model(weights)

    tmp = out / "layout" / "_export"
    exported = Path(model.export(output_dir=str(tmp), opset_version=17, verbose=False))
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(exported, dst)
    shutil.rmtree(tmp, ignore_errors=True)

    from onnxruntime.quantization import QuantType, quantize_dynamic

    quantize_dynamic(dst, dst_q, weight_type=QuantType.QInt8, per_channel=True)
    print(f"layout: {dst.stat().st_size >> 20} MB fp32, {dst_q.stat().st_size >> 20} MB int8")


def fetch_baberu(out: Path) -> None:
    d = out / "ocr" / "baberu"
    d.mkdir(parents=True, exist_ok=True)
    for name in BABERU_FILES:
        target = d / Path(name).name
        if not target.exists():
            shutil.copy(hf_hub_download(BABERU_REPO, name), target)
    print("baberu: ok")


def fetch_aot(out: Path) -> None:
    d = out / "inpaint"
    d.mkdir(parents=True, exist_ok=True)
    if not (d / "aot.onnx").exists():
        shutil.copy(hf_hub_download(AOT_REPO, "aot.onnx"), d / "aot.onnx")
    print("aot: ok")


def fetch_detector(out: Path) -> None:
    d = out / "detect"
    d.mkdir(parents=True, exist_ok=True)
    if not (d / "detector-v4-s_int8.onnx").exists():
        shutil.copy(hf_hub_download(DETECTOR_REPO, "detector-v4-s_int8.onnx"), d / "detector-v4-s_int8.onnx")
    print("detector: ok")


APP_MODELS = Path.home() / "Library/Application Support/MangaTL/models"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "models"))
    ap.add_argument("--with-layout", action="store_true",
                    help="also export Koharu RF-DETR (needs 0.5-2.8 GB RAM at inference; not used by the app)")
    ap.add_argument("--no-install", action="store_true", help=f"don't copy the app's models to {APP_MODELS}")
    args = ap.parse_args()
    out = Path(args.out)
    fetch_detector(out)
    fetch_baberu(out)
    fetch_aot(out)
    if args.with_layout:
        export_layout(out)
    if not args.no_install:
        for rel in ["detect/detector-v4-s_int8.onnx", "inpaint/aot.onnx", *(f"ocr/baberu/{Path(f).name}" for f in BABERU_FILES)]:
            (APP_MODELS / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(out / rel, APP_MODELS / rel)
        print(f"installed to {APP_MODELS}")


if __name__ == "__main__":
    main()
