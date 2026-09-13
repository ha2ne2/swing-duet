# 学習した検出器（YOLO の .pt）をスイング区間の全フレームに掛け、ヘッド／クラブの検出率と軌跡を出す（開発機だけ）
#   python detect_video.py <model.pt> <video> <address> <top> <impact> <finish> <outdir> [imgsz] [conf]
# 出力：heads.csv（t, ヘッド中心 x y 信頼度, クラブ箱 x1 y1 x2 y2 信頼度）、sheet.png（8 フェーズの箱と軌跡）、trajectory.png
import sys, os, time, csv
import cv2, numpy as np
from ultralytics import YOLO

model_path, video = sys.argv[1], sys.argv[2]
A, T, I, F = map(float, sys.argv[3:7])
outdir = sys.argv[7]
imgsz = int(sys.argv[8]) if len(sys.argv) > 8 else 1280
conf = float(sys.argv[9]) if len(sys.argv) > 9 else 0.15
os.makedirs(outdir, exist_ok=True)
model = YOLO(model_path)
names = model.names
cap = cv2.VideoCapture(video); fps = cap.get(cv2.CAP_PROP_FPS)
W, H = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
rows, frames, all_heads = [], {}, []
i, t0 = 0, time.time()
while True:
    ok, frame = cap.read()
    if not ok: break
    t = i / fps; i += 1
    if t < A - 0.3 or t > F + 0.3: continue
    r = model.predict(frame, conf=conf, imgsz=imgsz, verbose=False)[0]
    head, club = None, None
    heads = []
    for b in r.boxes:
        n, c = names[int(b.cls)], float(b.conf)
        x1, y1, x2, y2 = b.xyxy[0].tolist()
        if n == "club_head":
            heads.append(((x1 + x2) / 2 / W, (y1 + y2) / 2 / H, c))
            if head is None or c > head[4]: head = (x1, y1, x2, y2, c)
        if n == "club" and (club is None or c > club[4]): club = (x1, y1, x2, y2, c)
    rows.append((t, head, club))
    all_heads.append((t, sorted(heads, key=lambda h: -h[2])[:3]))
    frames[round(t, 3)] = frame
n = sum(1 for t, _, _ in rows if A <= t <= F)
print(f"{os.path.basename(video)}: {n} frames in the swing, {(time.time()-t0)/max(len(rows),1)*1000:.0f} ms/frame @imgsz {imgsz}")
for label, idx in (("club_head", 1), ("club", 2)):
    hits = [(row[0], row[idx] is not None) for row in rows if A <= row[0] <= F]
    total = sum(h for _, h in hits)
    by8 = [[0, 0] for _ in range(8)]
    for t, h in hits:
        k = min(int((t - A) / (F - A) * 8), 7); by8[k][1] += 1; by8[k][0] += int(h)
    print(f"  {label:9s} {total}/{n} ({total/max(n,1)*100:.0f}%)  by eighth:", " ".join(f"{a}/{b}" for a, b in by8))
with open(os.path.join(outdir, "heads.csv"), "w", newline="") as f:
    w = csv.writer(f); w.writerow(["t", "headX", "headY", "headConf", "clubX1", "clubY1", "clubX2", "clubY2", "clubConf"])
    for t, h, c in rows:
        w.writerow([f"{t:.3f}"] + ([f"{(h[0]+h[2])/2/W:.3f}", f"{(h[1]+h[3])/2/H:.3f}", f"{h[4]:.2f}"] if h else ["", "", ""])
                   + ([f"{v/W if k%2==0 else v/H:.3f}" for k, v in enumerate(c[:4])] + [f"{c[4]:.2f}"] if c else ["", "", "", "", ""]))

with open(os.path.join(outdir, "heads_all.csv"), "w") as f:
    for t, hs in all_heads:
        f.write(f"{t:.3f}," + ",".join(f"{x:.3f},{y:.3f},{c:.2f}" for x, y, c in hs) + "\n")

def draw_track(img, upto):
    pts = [((h[0]+h[2])/2, (h[1]+h[3])/2, t) for t, h, _ in rows if h and A <= t <= min(upto, F)]
    for k in range(1, len(pts)):
        a, b = pts[k-1], pts[k]
        if b[2] - a[2] > 3.5 / fps: continue   # 途切れは結ばない
        hue = int((b[2] - A) / (F - A) * 120)
        col = tuple(int(v) for v in cv2.cvtColor(np.uint8([[[hue, 255, 255]]]), cv2.COLOR_HSV2BGR)[0][0])
        cv2.line(img, (int(a[0]), int(a[1])), (int(b[0]), int(b[1])), col, 3)
    for x, y, _ in pts: cv2.circle(img, (int(x), int(y)), 3, (255, 255, 255), -1)

def nearest(t):
    return min(frames, key=lambda k: abs(k - t))
marks = [("A", A), ("B1", A + (T - A) * .33), ("B2", A + (T - A) * .66), ("T", T), ("D1", T + (I - T) * .5), ("I", I), ("F1", I + (F - I) * .4), ("F", F)]
tiles = []
for name, t in marks:
    k = nearest(t); img = frames[k].copy()
    row = next((r for r in rows if round(r[0], 3) == k), None)
    if row and row[2]: cv2.rectangle(img, (int(row[2][0]), int(row[2][1])), (int(row[2][2]), int(row[2][3])), (80, 80, 255), 2)
    if row and row[1]: cv2.rectangle(img, (int(row[1][0]), int(row[1][1])), (int(row[1][2]), int(row[1][3])), (80, 255, 80), 3)
    draw_track(img, t)
    cv2.putText(img, f"{name} {t:.2f}", (10, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255, 255, 255), 3)
    tiles.append(cv2.resize(img, (360, int(360 * H / W))))
sheet = np.vstack([np.hstack(tiles[:4]), np.hstack(tiles[4:])])
cv2.imwrite(os.path.join(outdir, "sheet.png"), sheet)
full = frames[nearest(I)].copy(); draw_track(full, F)
cv2.imwrite(os.path.join(outdir, "trajectory.png"), full)
print("  wrote", outdir)
