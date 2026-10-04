"""Phase 0: memory/speed of the light detectors (Koharu's comic-text-detector, ogkalu RT-DETR-v2 v4-s int8)."""
import sys, time, json
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
from stages import Peak, session

which, pages = sys.argv[1], [Path(p) for p in sys.argv[2:]]
peak = Peak()
if which == "ctd":
    sess = session(Path("models/detect/comic-text-detector.onnx"))
    for p in pages:
        img = Image.open(p).convert("RGB"); w, h = img.size
        s = 1024 / max(w, h); im = img.resize((int(w * s), int(h * s)), Image.BILINEAR)
        canvas = np.zeros((1024, 1024, 3), np.float32); a = np.asarray(im, np.float32) / 255
        canvas[:a.shape[0], :a.shape[1]] = a
        t = time.time(); blk, seg, det = sess.run(None, {"images": canvas.transpose(2, 0, 1)[None]})
        conf = blk[0, :, 4] * blk[0, :, 5:].max(1)
        print(f"{p.name}: {time.time()-t:.2f}s blocks>0.4={int((conf > 0.4).sum())} textmask_px={int((seg[0,0] > 0.3).sum())}")
        Image.fromarray(((seg[0, 0, :a.shape[0], :a.shape[1]] > 0.3) * 255).astype(np.uint8)).save(p.with_suffix(".ctdmask.png"))
        del blk, seg, det
else:
    sess = session(Path("models/detect/detector-v4-s_int8.onnx"))
    names = ["bubble", "text_bubble", "text_free"]
    for p in pages:
        img = Image.open(p).convert("RGB"); w, h = img.size
        x = np.asarray(img.resize((640, 640), Image.BILINEAR), np.float32) / 255
        t = time.time()
        labels, boxes, scores = sess.run(None, {"images": x.transpose(2, 0, 1)[None], "orig_target_sizes": np.array([[w, h]], np.int64)})
        keep = scores[0] > 0.4
        out = [{"cls": names[int(l)], "score": float(s), "box": b.tolist()} for l, b, s in zip(labels[0][keep], boxes[0][keep], scores[0][keep])]
        p.with_suffix(".v4s.json").write_text(json.dumps(out))
        print(f"{p.name}: {time.time()-t:.2f}s", {n: sum(o['cls'] == n for o in out) for n in names})
d, tot = peak.mb(); print(f"{which}: peak +{d:.0f} MB above baseline (process {tot:.0f} MB)")
