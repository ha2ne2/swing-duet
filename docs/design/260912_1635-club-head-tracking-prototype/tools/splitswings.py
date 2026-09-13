# 長回しの動画からスイングの区間を見つける（開発機だけ）：10fps に間引いた縮小グレーのフレーム差分の平均を「動き」とし、
# 短い山（1〜3 秒）をスイングとみなす。出力は 1 行 1 スイングの「開始 終了 ピーク」（秒）
import sys, cv2, numpy as np
video = sys.argv[1]; out = sys.argv[2]
cap = cv2.VideoCapture(video); fps = cap.get(cv2.CAP_PROP_FPS); stride = max(1, round(fps / 10))
prev = None; motion = []; times = []; i = 0
while True:
    ok = cap.grab()
    if not ok: break
    if i % stride == 0:
        ok, f = cap.retrieve(); g = cv2.cvtColor(cv2.resize(f, (180, 320)), cv2.COLOR_BGR2GRAY).astype(np.float32)
        motion.append(float(np.mean(cv2.absdiff(g, prev))) if prev is not None else 0.0); times.append(i / fps); prev = g
    i += 1
m = np.array(motion); t = np.array(times)
base = np.percentile(m, 30)                          # 静止しているときの水準
peak = np.percentile(m, 99)
thr = base + (peak - base) * 0.35
smooth = np.convolve(m, np.ones(5) / 5, mode="same")
above = smooth > thr
swings = []
k = 0
while k < len(above):
    if above[k]:
        j = k
        while j < len(above) and above[j]: j += 1
        dur = t[j - 1] - t[k]
        if 0.4 <= dur <= 4.0:
            p = k + int(np.argmax(smooth[k:j]))
            swings.append((max(t[k] - 1.5, 0), t[j - 1] + 1.0, t[p]))
        k = j
    else: k += 1
# 近すぎる山（同じスイングの上げと下げ）はまとめる
merged = []
for s in swings:
    if merged and s[0] < merged[-1][1]: merged[-1] = (merged[-1][0], max(merged[-1][1], s[1]), merged[-1][2])
    else: merged.append(s)
with open(out, "w") as f:
    for a, b, p in merged: f.write(f"{a:.2f} {b:.2f} {p:.2f}\n")
print(f"{video}: motion base {base:.2f} peak {peak:.2f} thr {thr:.2f}; {len(merged)} swing candidates -> {out}")
print(" ".join(f"{p:.0f}" for _, _, p in merged))
